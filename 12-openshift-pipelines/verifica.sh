#!/usr/bin/env bash
# Verifica dell'esercizio finale del modulo 12 (sola lettura).
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../lib/verifica-lib.sh"
richiedi_login

P="${LAB}-m12-exam"
titolo "Modulo 12 - esercizio finale (progetto $P)"

check "il progetto $P esiste" oc get project "$P"
if ! api_disponibile tekton.dev/v1; then
  ko "API tekton.dev disponibili" "OpenShift Pipelines non risulta installato"
  riepilogo; exit 1
fi

# --- Task unit-test -------------------------------------------------------------------
titolo "Task unit-test"
check "la Task unit-test esiste" oc get task unit-test -n "$P"
check_eq "unit-test dichiara il workspace 'source'" "oc get task unit-test -n $P -o jsonpath='{.spec.workspaces[*].name}'" "source"
check_eq "unit-test ha il parametro APP_DIR con default hello-node" "oc get task unit-test -n $P -o jsonpath='{.spec.params[?(@.name==\"APP_DIR\")].default}'" "hello-node"
check_match "unit-test usa l'immagine ubi9/nodejs-22" "oc get task unit-test -n $P -o jsonpath='{.spec.steps[*].image}'" 'registry\.access\.redhat\.com/ubi9/nodejs-22'
check_match "unit-test esegue npm test" "oc get task unit-test -n $P -o jsonpath='{.spec.steps[*].script}{.spec.steps[*].args}{.spec.steps[*].command}'" 'npm[\", ]+test'

# --- Pipeline ci-hello ----------------------------------------------------------------
titolo "Pipeline ci-hello"
PJ="oc get pipeline ci-hello -n $P -o jsonpath"
check "la Pipeline ci-hello esiste" oc get pipeline ci-hello -n "$P"
check_match "parametro GIT_URL dichiarato senza default" "$PJ='{range .spec.params[?(@.name==\"GIT_URL\")]}{.name}={.default}{end}'" '^GIT_URL=$'
check_eq "parametro GIT_REVISION con default main" "$PJ='{.spec.params[?(@.name==\"GIT_REVISION\")].default}'" "main"
check_eq "parametro IMAGE_TAG con default v1" "$PJ='{.spec.params[?(@.name==\"IMAGE_TAG\")].default}'" "v1"
check_eq "un solo workspace chiamato shared" "$PJ='{.spec.workspaces[*].name}'" "shared"
check_eq "task nell'ordine clone test build deploy" "$PJ='{.spec.tasks[*].name}'" "clone test build deploy"
check_eq "clone usa il cluster resolver" "$PJ='{.spec.tasks[?(@.name==\"clone\")].taskRef.resolver}'" "cluster"
check_eq "clone usa la Task git-clone" "$PJ='{.spec.tasks[?(@.name==\"clone\")].taskRef.params[?(@.name==\"name\")].value}'" "git-clone"
check_eq "test usa la Task unit-test" "$PJ='{.spec.tasks[?(@.name==\"test\")].taskRef.name}'" "unit-test"
check_eq "build usa la Task buildah" "$PJ='{.spec.tasks[?(@.name==\"build\")].taskRef.params[?(@.name==\"name\")].value}'" "buildah"
check_eq "deploy usa la Task openshift-client" "$PJ='{.spec.tasks[?(@.name==\"deploy\")].taskRef.params[?(@.name==\"name\")].value}'" "openshift-client"
# ordine: runAfter esplicito oppure dipendenza implicita tramite result
check_match "test parte dopo clone" "$PJ='{.spec.tasks[?(@.name==\"test\")].runAfter[*]} {.spec.tasks[?(@.name==\"test\")].params[*].value}'" '(^| )clone( |$)|tasks\.clone\.'
check_match "build parte dopo test" "$PJ='{.spec.tasks[?(@.name==\"build\")].runAfter[*]} {.spec.tasks[?(@.name==\"build\")].params[*].value}'" '(^| )test( |$)|tasks\.test\.'
check_match "deploy parte dopo build" "$PJ='{.spec.tasks[?(@.name==\"deploy\")].runAfter[*]} {.spec.tasks[?(@.name==\"deploy\")].params[*].value}'" '(^| )build( |$)|tasks\.build\.'
check_match "esiste la task finally report" "$PJ='{.spec.finally[*].name}'" '(^| )report( |$)'
check_eq "nessun riferimento a ClusterTask" "oc get pipeline ci-hello -n $P -o yaml | grep -c 'ClusterTask'" "0"
check_match "build produce l'immagine hello-ci" "$PJ='{.spec.tasks[?(@.name==\"build\")].params[*].value} {.spec.params[*].default}'" 'hello-ci'
check_match "build usa hello-node/Dockerfile" "$PJ='{.spec.tasks[?(@.name==\"build\")].params[*].value} {.spec.params[*].default}'" 'hello-node'

# --- Esecuzioni -----------------------------------------------------------------------
titolo "PipelineRun"
PR_OK="$(oc get pipelinerun -n "$P" -l tekton.dev/pipeline=ci-hello \
  -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.status.conditions[?(@.type=="Succeeded")].status}{"|"}{.spec.params[?(@.name=="IMAGE_TAG")].value}{"|"}{.spec.workspaces[?(@.name=="shared")].volumeClaimTemplate}{"\n"}{end}' 2>/dev/null)"
if printf '%s\n' "$PR_OK" | awk -F'|' '$2=="True" && ($3=="" || $3=="v1") && $4!=""' | grep -q .; then
  ok "almeno una PipelineRun di ci-hello con IMAGE_TAG=v1 (default) Succeeded e workspace da volumeClaimTemplate"
else
  ko "almeno una PipelineRun di ci-hello con IMAGE_TAG=v1 (default) Succeeded e workspace da volumeClaimTemplate" "$(printf '%s' "$PR_OK" | cut -d'|' -f1-3 | head -c 300)"
fi
check "l'image stream tag hello-ci:v1 esiste" oc get istag hello-ci:v1 -n "$P"

# --- Deployment e route ---------------------------------------------------------------
titolo "Deployment hello-ci"
check_eq "hello-ci ha 1 replica pronta" "oc get deploy hello-ci -n $P -o jsonpath='{.status.readyReplicas}'" "1"
IMG="$(oc get deploy hello-ci -n "$P" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)"
if printf '%s' "$IMG" | grep -Eq "/$P/hello-ci@sha256:[0-9a-f]{64}$"; then
  ok "hello-ci usa l'immagine hello-ci per digest"
  DIG="${IMG##*@}"
  if oc get is hello-ci -n "$P" -o jsonpath='{.status.tags[*].items[*].image}' 2>/dev/null | tr ' ' '\n' | grep -qx "$DIG"; then
    ok "il digest del Deployment è un'immagine dell'image stream hello-ci"
  else
    ko "il digest del Deployment è un'immagine dell'image stream hello-ci" "digest $DIG non trovato in is/hello-ci"
  fi
else
  ko "hello-ci usa l'immagine hello-ci per digest" "immagine trovata: '${IMG:-<vuoto>}'"
fi
check "la route hello-ci esiste" oc get route hello-ci -n "$P"
URL="$(route_url hello-ci "$P")"
[ -n "$URL" ] && check_http "hello-ci risponde con il JSON di hello-node" "$URL/" '"app": *"hello-node"'

# --- Triggers -------------------------------------------------------------------------
titolo "EventListener ci-listener"
check "l'EventListener ci-listener esiste" oc get eventlistener ci-listener -n "$P"
check_eq "il pod dell'EventListener è pronto" "oc get deploy el-ci-listener -n $P -o jsonpath='{.status.readyReplicas}'" "1"
check_eq "la route el-ci-listener punta al Service el-ci-listener" "oc get route el-ci-listener -n $P -o jsonpath='{.spec.to.name}'" "el-ci-listener"
check_match "un TriggerTemplate del progetto avvia ci-hello" "oc get triggertemplate -n $P -o jsonpath='{.items[*].spec.resourcetemplates[*].spec.pipelineRef.name}'" '(^| )ci-hello( |$)'
check_match "un TriggerBinding legge repository.html_url e head_commit.id" "oc get triggerbinding -n $P -o jsonpath='{.items[*].spec.params[*].value}'" 'body\.repository\.html_url.*body\.head_commit\.id|body\.head_commit\.id.*body\.repository\.html_url'
check_match "almeno una PipelineRun creata da ci-listener è Succeeded" "oc get pipelinerun -n $P -l triggers.tekton.dev/eventlistener=ci-listener -o jsonpath='{range .items[*]}{.status.conditions[?(@.type==\"Succeeded\")].status}{\"\\n\"}{end}'" '^True$'
check "l'image stream tag hello-ci:latest esiste (prodotto dal trigger)" oc get istag hello-ci:latest -n "$P"

riepilogo
