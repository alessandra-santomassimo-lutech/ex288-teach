#!/usr/bin/env bash
# Verifica dell'esercizio finale del modulo 05 (sola lettura).
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../lib/verifica-lib.sh"
richiedi_login

P="${LAB}-m05-exam"
BC="shop-api"
REPO_NORM="${GIT_REPO:-<GIT_REPO non impostata>}"; REPO_NORM="${REPO_NORM%.git}"
titolo "Modulo 05 - esercizio finale (progetto $P)"

check "il progetto $P esiste" oc get project "$P"
check "l'image stream tag nodejs:22-ubi9 esiste" oc get istag nodejs:22-ubi9 -n "$P"
check_match "nodejs:22-ubi9 importato da ubi9/nodejs-22" "oc get is nodejs -n $P -o jsonpath='{.spec.tags[?(@.name==\"22-ubi9\")].from.name}'" 'registry\.access\.redhat\.com/ubi9/nodejs-22'

# --- BuildConfig ---------------------------------------------------------------------
titolo "BuildConfig $BC"
check "la BuildConfig $BC esiste" oc get bc "$BC" -n "$P"
check_eq "strategia Source" "oc get bc $BC -n $P -o jsonpath='{.spec.strategy.type}'" "Source"
check_eq "builder: ImageStreamTag" "oc get bc $BC -n $P -o jsonpath='{.spec.strategy.sourceStrategy.from.kind}'" "ImageStreamTag"
check_match "builder: nodejs:22-ubi9" "oc get bc $BC -n $P -o jsonpath='{.spec.strategy.sourceStrategy.from.name}'" '^nodejs:22-ubi9$'
check_eq "sorgente: \$GIT_REPO" "oc get bc $BC -n $P -o jsonpath='{.spec.source.git.uri}' | sed 's/\\.git\$//'" "$REPO_NORM"
check_eq "branch exam-v2" "oc get bc $BC -n $P -o jsonpath='{.spec.source.git.ref}'" "exam-v2"
check_match "cartella hello-node" "oc get bc $BC -n $P -o jsonpath='{.spec.source.contextDir}'" '^/?hello-node/?$'
check_eq "output: ImageStreamTag" "oc get bc $BC -n $P -o jsonpath='{.spec.output.to.kind}'" "ImageStreamTag"
check_eq "output: shop-api:2.0" "oc get bc $BC -n $P -o jsonpath='{.spec.output.to.name}'" "shop-api:2.0"
check_eq "variabile di build BUILD_LOGLEVEL=2" "oc get bc $BC -n $P -o jsonpath='{.spec.strategy.sourceStrategy.env[?(@.name==\"BUILD_LOGLEVEL\")].value}'" "2"
if oc get bc "$BC" -n "$P" >/dev/null 2>&1; then
  check_eq "FAIL_TESTS non è più nella BuildConfig" "oc get bc $BC -n $P -o jsonpath='{.spec.strategy.sourceStrategy.env[?(@.name==\"FAIL_TESTS\")].name}'" ""
fi
check_eq "runPolicy SerialLatestOnly" "oc get bc $BC -n $P -o jsonpath='{.spec.runPolicy}'" "SerialLatestOnly"
check_eq "successfulBuildsHistoryLimit 3" "oc get bc $BC -n $P -o jsonpath='{.spec.successfulBuildsHistoryLimit}'" "3"
check_eq "failedBuildsHistoryLimit 2" "oc get bc $BC -n $P -o jsonpath='{.spec.failedBuildsHistoryLimit}'" "2"

# --- Hook ----------------------------------------------------------------------------
titolo "Post-commit hook"
check_match "il post-commit hook esegue test.js (npm test o node test.js)" "oc get bc $BC -n $P -o jsonpath='{.spec.postCommit.script} {.spec.postCommit.command} {.spec.postCommit.args}'" '(npm[^a-z]+test|node[^a-z]+test\.js|test\.js)'

# --- Trigger -------------------------------------------------------------------------
titolo "Trigger"
check_match "trigger ImageChange presente" "oc get bc $BC -n $P -o jsonpath='{.spec.triggers[*].type}'" 'ImageChange'
ICFROM="$(oc get bc "$BC" -n "$P" -o jsonpath='{.spec.triggers[?(@.type=="ImageChange")].imageChange.from.name}' 2>/dev/null)"
HASIC="$(oc get bc "$BC" -n "$P" -o jsonpath='{.spec.triggers[*].type}' 2>/dev/null | grep -c ImageChange)"
if [ "${HASIC:-0}" -eq 0 ]; then
  : # già segnalato dal controllo precedente
elif [ -z "$ICFROM" ] || printf '%s' "$ICFROM" | grep -Eq '^nodejs:22-ubi9$'; then
  ok "il trigger ImageChange osserva il builder nodejs:22-ubi9"
else
  ko "il trigger ImageChange osserva il builder nodejs:22-ubi9" "osserva invece: $ICFROM"
fi
check_eq "webhook Generic con secretReference shop-api-hook" "oc get bc $BC -n $P -o jsonpath='{.spec.triggers[?(@.type==\"Generic\")].generic.secretReference.name}'" "shop-api-hook"
check "il Secret shop-api-hook esiste" oc get secret shop-api-hook -n "$P"
check_eq "il Secret ha WebHookSecretKey=ex288-hook-2026" "oc extract secret/shop-api-hook -n $P --keys=WebHookSecretKey --to=- 2>/dev/null" "ex288-hook-2026"
check_match "RoleBinding system:webhook per system:unauthenticated" "oc get rolebinding -n $P -o jsonpath='{range .items[?(@.roleRef.name==\"system:webhook\")]}{.subjects[*].name}{\"\\n\"}{end}'" 'system:unauthenticated'

# --- Build ---------------------------------------------------------------------------
titolo "Build eseguite"
BUILDS="oc get builds -n $P -l openshift.io/build-config.name=$BC -o jsonpath='{range .items[*]}{.metadata.name}|{.status.phase}|{.status.reason}|{.spec.triggeredBy[*].message}{\"\\n\"}{end}'"
check_match "almeno una build Complete" "$BUILDS" '\|Complete\|'
check_match "almeno una build fallita per il post-commit hook" "$BUILDS" '\|Failed\|PostCommitHook'
check_match "almeno una build Complete avviata dal webhook generico" "$BUILDS" '\|Complete\|[^|]*\|.*Generic WebHook'
check "l'image stream tag shop-api:2.0 esiste" oc get istag shop-api:2.0 -n "$P"

# --- Deployment ----------------------------------------------------------------------
titolo "Deployment $BC"
D20="$(oc get istag shop-api:2.0 -n "$P" -o jsonpath='{.image.metadata.name}' 2>/dev/null)"
check_eq "shop-api ha 1 replica pronta" "oc get deploy $BC -n $P -o jsonpath='{.status.readyReplicas}'" "1"
check_eq "il container si chiama shop-api" "oc get deploy $BC -n $P -o jsonpath='{.spec.template.spec.containers[*].name}'" "shop-api"
check_eq "APP_VERSION=2.0.0 nel Deployment" "oc get deploy $BC -n $P -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name==\"APP_VERSION\")].value}'" "2.0.0"
check_match "trigger del Deployment su shop-api:2.0" "oc get deploy $BC -n $P -o jsonpath='{.metadata.annotations.image\.openshift\.io/triggers}'" '"name":"shop-api:2\.0"'
oc get deploy "$BC" -n "$P" >/dev/null 2>&1 && check_eq "il trigger del Deployment non è sospeso" "oc get deploy $BC -n $P -o jsonpath='{.metadata.annotations.image\.openshift\.io/triggers}' | grep -c '\"paused\":true'" "0"
if [ -n "$D20" ]; then
  check_match "il Deployment esegue l'immagine attuale di shop-api:2.0" "oc get deploy $BC -n $P -o jsonpath='{.spec.template.spec.containers[0].image}'" "@${D20}\$"
fi
check_match "il Deployment ha almeno 2 revisioni" "oc get deploy $BC -n $P -o jsonpath='{.metadata.annotations.deployment\.kubernetes\.io/revision}'" '^([2-9]|[1-9][0-9]+)$'
URL="$(route_url "$BC" "$P")"
if [ -n "$URL" ]; then
  check_http "la route risponde con il messaggio Catalogo v2" "$URL/" '"message": *"Catalogo v2"'
  check_http "la route risponde con version 2.0.0" "$URL/" '"version": *"2\.0\.0"'
else
  ko "la route shop-api esiste"
fi

riepilogo
