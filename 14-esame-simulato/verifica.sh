#!/usr/bin/env bash
# Verifica dell'esame simulato (sola lettura).
# Uso: CHART_DIR=$EX288_WORK/m14-exam/catalog KUST_DIR=$EX288_WORK/m14-exam/kustomize bash verifica.sh
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../lib/verifica-lib.sh"
richiedi_login

B="${LAB}-ex-build"; PR="${LAB}-ex-prod"; H="${LAB}-ex-helm"; K="${LAB}-ex-kust"; C="${LAB}-ex-cicd"; F="${LAB}-ex-fix"
CHART_DIR="${CHART_DIR:-$EX288_WORK/m14-exam/catalog}"
KUST_DIR="${KUST_DIR:-$EX288_WORK/m14-exam/kustomize}"
REPO_NORM="$(printf '%s' "$GIT_REPO" | sed 's/\.git$//')"
norm_uri() { sed 's/\.git$//'; }

# --------------------------------------------------------------------------
titolo "Task 1 - Progetti e accessi"
check_eq "display name di $B" "oc get project $B -o jsonpath='{.metadata.annotations.openshift\.io/display-name}'" "Exam Build"
check_eq "display name di $PR" "oc get project $PR -o jsonpath='{.metadata.annotations.openshift\.io/display-name}'" "Exam Prod"
check "service account deployer in $PR" oc get sa deployer -n "$PR"
check_eq "deployer può creare deployment in $PR" "oc auth can-i create deployments -n $PR --as=system:serviceaccount:$PR:deployer" "yes"
check_eq "deployer NON può creare rolebinding in $PR" "oc auth can-i create rolebindings -n $PR --as=system:serviceaccount:$PR:deployer" "no"
check_eq "i SA di $PR possono scaricare immagini da $B" "oc auth can-i get imagestreams --subresource=layers -n $B --as=system:serviceaccount:$PR:default" "yes"
check_eq "i SA di $PR NON hanno permessi di scrittura in $B" "oc auth can-i create deployments -n $B --as=system:serviceaccount:$PR:default" "no"

# --------------------------------------------------------------------------
titolo "Task 2 - Image stream del builder"
check "istag nodejs:22 in $B" oc get istag nodejs:22 -n "$B"
check_match "nodejs:22 importa da ubi9/nodejs-22" "oc get is nodejs -n $B -o jsonpath='{.spec.tags[?(@.name==\"22\")].from.name}'" 'registry\.access\.redhat\.com/ubi9/nodejs-22(:.*)?$'
check_eq "nodejs:22 con import pianificato" "oc get is nodejs -n $B -o jsonpath='{.spec.tags[?(@.name==\"22\")].importPolicy.scheduled}'" "true"

# --------------------------------------------------------------------------
titolo "Task 3 - Builder S2I personalizzato"
check_eq "BuildConfig corp-builder con strategia Docker" "oc get bc corp-builder -n $B -o jsonpath='{.spec.strategy.type}'" "Docker"
check_eq "corp-builder usa contextDir builder-nodejs-ex288" "oc get bc corp-builder -n $B -o jsonpath='{.spec.source.contextDir}'" "builder-nodejs-ex288"
check_eq "corp-builder usa il repository del corso" "oc get bc corp-builder -n $B -o jsonpath='{.spec.source.git.uri}' | sed 's/\.git\$//'" "$REPO_NORM"
check_eq "output corp-builder:1.0" "oc get bc corp-builder -n $B -o jsonpath='{.spec.output.to.name}'" "corp-builder:1.0"
check_match "almeno una build corp-builder completata" "oc get builds -n $B -l buildconfig=corp-builder -o jsonpath='{range .items[*]}{.status.phase}{\"\\n\"}{end}'" '^Complete$'
check_match "label io.openshift.s2i.scripts-url su corp-builder:1.0" "oc get istag corp-builder:1.0 -n $B -o jsonpath='{.image.dockerImageMetadata.Config.Labels.io\.openshift\.s2i\.scripts-url}'" 's2i-ex288'

# --------------------------------------------------------------------------
titolo "Task 4 - Build applicativa con hook e trigger"
check_eq "BuildConfig shop con strategia Source" "oc get bc shop -n $B -o jsonpath='{.spec.strategy.type}'" "Source"
check_eq "shop usa contextDir hello-node" "oc get bc shop -n $B -o jsonpath='{.spec.source.contextDir}'" "hello-node"
check_eq "shop usa il repository del corso" "oc get bc shop -n $B -o jsonpath='{.spec.source.git.uri}' | sed 's/\.git\$//'" "$REPO_NORM"
check_match "shop usa il builder corp-builder:1.0" "oc get bc shop -n $B -o jsonpath='{.spec.strategy.sourceStrategy.from.name}'" '^corp-builder:1\.0$'
check_eq "output shop:latest" "oc get bc shop -n $B -o jsonpath='{.spec.output.to.name}'" "shop:latest"
check_match "post-commit hook esegue npm test" "oc get bc shop -n $B -o jsonpath='{.spec.postCommit}'" 'npm.*test'
check_match "trigger ImageChange presente" "oc get bc shop -n $B -o jsonpath='{.spec.triggers[*].type}'" 'ImageChange'
check_eq "trigger Generic con secret shop-webhook" "oc get bc shop -n $B -o jsonpath='{.spec.triggers[?(@.type==\"Generic\")].generic.secretReference.name}'" "shop-webhook"
check_eq "secret shop-webhook con WebHookSecretKey=esame288" "oc get secret shop-webhook -n $B -o jsonpath='{.data.WebHookSecretKey}' | base64 -d" "esame288"
check_match "almeno una build shop completata" "oc get builds -n $B -l buildconfig=shop -o jsonpath='{range .items[*]}{.status.phase}{\"\\n\"}{end}'" '^Complete$'

# --------------------------------------------------------------------------
titolo "Task 5 - Promozione"
D_BUILD="$(oc get istag shop:latest -n "$B" -o jsonpath='{.image.metadata.name}' 2>/dev/null)"
D_PROD="$(oc get istag shop:prod -n "$PR" -o jsonpath='{.image.metadata.name}' 2>/dev/null)"
if [ -n "$D_PROD" ]; then ok "istag shop:prod in $PR"; else ko "istag shop:prod in $PR"; fi
if [ -n "$D_BUILD" ] && [ "$D_BUILD" = "$D_PROD" ]; then ok "shop:prod ha lo stesso digest di $B/shop:latest"; else ko "shop:prod ha lo stesso digest di $B/shop:latest" "build=$D_BUILD prod=$D_PROD"; fi

# --------------------------------------------------------------------------
titolo "Task 6 - Configurazione e credenziali"
check_match "ConfigMap shop-config con ambiente=produzione" "oc get cm shop-config -n $PR -o jsonpath='{.data.app\.properties}'" '^ambiente=produzione$'
check_eq "Secret shop-db: user" "oc get secret shop-db -n $PR -o jsonpath='{.data.user}' | base64 -d" "shop"
check_eq "Secret shop-db: password" "oc get secret shop-db -n $PR -o jsonpath='{.data.password}' | base64 -d" "Sh0p-Pass-288"
check_eq "Secret shop-db: database" "oc get secret shop-db -n $PR -o jsonpath='{.data.database}' | base64 -d" "shopdb"

# --------------------------------------------------------------------------
titolo "Task 7 - Applicazione multi-container da template"
check "template shop-stack salvato in $PR" oc get template shop-stack -n "$PR"
check_eq "APP_MESSAGE obbligatorio" "oc get template shop-stack -n $PR -o jsonpath='{.parameters[?(@.name==\"APP_MESSAGE\")].required}'" "true"
check_eq "APP_MESSAGE senza default" "oc get template shop-stack -n $PR -o jsonpath='{.parameters[?(@.name==\"APP_MESSAGE\")].value}'" ""
check_eq "REPLICAS con default 2" "oc get template shop-stack -n $PR -o jsonpath='{.parameters[?(@.name==\"REPLICAS\")].value}'" "2"
check_match "il template contiene Deployment, Service e Route" "oc get template shop-stack -n $PR -o jsonpath='{.objects[*].kind}'" 'Deployment.*(Service|Route)|Route.*Deployment|Service.*Deployment'
check "Deployment shop-db" oc get deploy shop-db -n "$PR"
check_match "Service shop-db porta 5432" "oc get svc shop-db -n $PR -o jsonpath='{.spec.ports[*].port}'" '(^| )5432( |$)'
check_match "shop-db legge le credenziali dal Secret shop-db" "oc get deploy shop-db -n $PR -o jsonpath='{.spec.template.spec.containers[0].env[*].valueFrom.secretKeyRef.name}{.spec.template.spec.containers[0].envFrom[*].secretRef.name}'" 'shop-db'
check_eq "Deployment shop con 2 repliche pronte" "oc get deploy shop -n $PR -o jsonpath='{.status.readyReplicas}'" "2"
check_match "shop con trigger su shop:prod" "oc get deploy shop -n $PR -o jsonpath='{.metadata.annotations.image\.openshift\.io/triggers}'" 'shop:prod'
check_match "shop riceve DB_PASSWORD dal Secret shop-db" "oc get deploy shop -n $PR -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name==\"DB_PASSWORD\")].valueFrom.secretKeyRef.name}'" '^shop-db$'
check_match "shop monta shop-config in /etc/app" "oc get deploy shop -n $PR -o jsonpath='{range .spec.template.spec.containers[0].volumeMounts[*]}{.mountPath}{\"\\n\"}{end}'" '^/etc/app/?$'
check_match "un volume di shop usa la ConfigMap shop-config" "oc get deploy shop -n $PR -o jsonpath='{.spec.template.spec.volumes[*].configMap.name}'" 'shop-config'
check_eq "readiness su /ready" "oc get deploy shop -n $PR -o jsonpath='{.spec.template.spec.containers[0].readinessProbe.httpGet.path}'" "/ready"
check_eq "liveness su /healthz" "oc get deploy shop -n $PR -o jsonpath='{.spec.template.spec.containers[0].livenessProbe.httpGet.path}'" "/healthz"
check_eq "limite memoria 256Mi" "oc get deploy shop -n $PR -o jsonpath='{.spec.template.spec.containers[0].resources.limits.memory}'" "256Mi"
check_eq "route shop edge" "oc get route shop -n $PR -o jsonpath='{.spec.tls.termination}'" "edge"
URL="$(route_url shop "$PR")"
if [ -n "$URL" ]; then
  check_http "/ mostra 'Benvenuti in produzione'" "$URL/" 'Benvenuti in produzione'
  check_http "/db raggiungibile" "$URL/db" '"raggiungibile"'
  check_http "/config mostra ambiente=produzione" "$URL/config" 'ambiente=produzione'
  check_http "/build-info dal builder personalizzato" "$URL/build-info" 'builder personalizzato ex288'
else
  ko "route shop raggiungibile" "route non trovata"
fi

# --------------------------------------------------------------------------
titolo "Task 8 - Helm"
if [ -f "$CHART_DIR/Chart.yaml" ]; then
  check_match "Chart.yaml: name catalog" "grep -E '^name:' $CHART_DIR/Chart.yaml" 'name:[[:space:]]*"?catalog"?'
  check_match "Chart.yaml: version 0.1.0" "grep -E '^version:' $CHART_DIR/Chart.yaml" 'version:[[:space:]]*"?0\.1\.0"?'
  check_match "values.yaml: replicaCount 1" "grep -E '^replicaCount:' $CHART_DIR/values.yaml" 'replicaCount:[[:space:]]*1[[:space:]]*$'
else
  ko "chart in $CHART_DIR" "imposta CHART_DIR se il chart è altrove"
fi
REVS="$(oc get secret -n "$H" -l owner=helm,name=catalog --no-headers 2>/dev/null | wc -l | tr -d ' ')"
if [ "${REVS:-0}" -ge 2 ]; then ok "release catalog con almeno 2 revisioni ($REVS)"; else ko "release catalog con almeno 2 revisioni" "trovate: ${REVS:-0}"; fi
if command -v helm >/dev/null 2>&1; then
  check_match "valore corrente replicaCount=2" "helm get values catalog -n $H -a -o yaml" '^replicaCount:[[:space:]]*2'
fi
check_match "deployment della release con 2 repliche pronte" "oc get deploy -n $H -l app.kubernetes.io/instance=catalog -o jsonpath='{.items[*].status.readyReplicas}'" '(^| )2( |$)'
check_match "la release usa httpd-24" "oc get deploy -n $H -l app.kubernetes.io/instance=catalog -o jsonpath='{.items[*].spec.template.spec.containers[*].image}'" 'ubi9/httpd-24'

# --------------------------------------------------------------------------
titolo "Task 9 - Kustomize"
check "base/kustomization.yaml presente" test -f "$KUST_DIR/base/kustomization.yaml"
check "overlays/prod/kustomization.yaml presente" test -f "$KUST_DIR/overlays/prod/kustomization.yaml"
check_eq "prod-inventory con 2 repliche pronte" "oc get deploy prod-inventory -n $K -o jsonpath='{.status.readyReplicas}'" "2"
check_eq "label env=prod sul deployment" "oc get deploy prod-inventory -n $K -o jsonpath='{.metadata.labels.env}'" "prod"
check_eq "label env=prod sul service" "oc get svc prod-inventory -n $K -o jsonpath='{.metadata.labels.env}'" "prod"
CM="$(oc get deploy prod-inventory -n "$K" -o jsonpath='{.spec.template.spec.containers[0].envFrom[*].configMapRef.name}' 2>/dev/null)"
if printf '%s' "$CM" | grep -Eq '^prod-inventory-config-[a-z0-9]+$'; then ok "envFrom da ConfigMap generata con hash ($CM)"; else ko "envFrom da ConfigMap generata con hash" "trovato: '${CM:-<vuoto>}'"; fi
[ -n "$CM" ] && check_eq "la ConfigMap contiene MODE=prod" "oc get cm $CM -n $K -o jsonpath='{.data.MODE}'" "prod"

# --------------------------------------------------------------------------
titolo "Task 10 - OpenShift Pipelines"
check "Task npm-test" oc get task npm-test -n "$C"
check_match "npm-test dichiara il workspace source" "oc get task npm-test -n $C -o jsonpath='{.spec.workspaces[*].name}'" '(^| )source( |$)'
check "Pipeline shop-ci" oc get pipeline shop-ci -n "$C"
check_match "parametri GIT_URL GIT_REVISION IMAGE" "oc get pipeline shop-ci -n $C -o jsonpath='{.spec.params[*].name}' | tr ' ' '\n' | sort | tr '\n' ' '" 'GIT_REVISION GIT_URL IMAGE'
check_eq "GIT_REVISION default main" "oc get pipeline shop-ci -n $C -o jsonpath='{.spec.params[?(@.name==\"GIT_REVISION\")].default}'" "main"
check_match "workspace source" "oc get pipeline shop-ci -n $C -o jsonpath='{.spec.workspaces[*].name}'" '(^| )source( |$)'
check_eq "task in ordine clone test build" "oc get pipeline shop-ci -n $C -o jsonpath='{.spec.tasks[*].name}'" "clone test build"
check_match "clone usa git-clone" "oc get pipeline shop-ci -n $C -o jsonpath='{.spec.tasks[?(@.name==\"clone\")].taskRef}'" 'git-clone'
check_match "build usa buildah" "oc get pipeline shop-ci -n $C -o jsonpath='{.spec.tasks[?(@.name==\"build\")].taskRef}'" 'buildah'
check_match "test dopo clone" "oc get pipeline shop-ci -n $C -o jsonpath='{.spec.tasks[?(@.name==\"test\")].runAfter[*]}'" 'clone'
check_match "build dopo test" "oc get pipeline shop-ci -n $C -o jsonpath='{.spec.tasks[?(@.name==\"build\")].runAfter[*]}'" 'test'
check_match "almeno una PipelineRun di shop-ci riuscita" "oc get pipelinerun -n $C -l tekton.dev/pipeline=shop-ci -o jsonpath='{range .items[*]}{.status.conditions[0].reason}{\"\\n\"}{end}'" '^(Succeeded|Completed)$'
check "istag shop-ci:latest nel progetto" oc get istag shop-ci:latest -n "$C"
check "EventListener shop-ci-listener" oc get eventlistener shop-ci-listener -n "$C"
check_match "route verso il service el-shop-ci-listener" "oc get route -n $C -o jsonpath='{range .items[*]}{.spec.to.name}{\"\\n\"}{end}'" '^el-shop-ci-listener$'
check_match "un TriggerTemplate avvia shop-ci" "oc get triggertemplate -n $C -o jsonpath='{.items[*].spec.resourcetemplates[*].spec.pipelineRef.name}'" 'shop-ci'

# --------------------------------------------------------------------------
titolo "Task 11 - Troubleshooting"
check_eq "legacy con 1 replica pronta" "oc get deploy legacy -n $F -o jsonpath='{.status.readyReplicas}'" "1"
check_match "legacy usa ubi9/httpd-24" "oc get deploy legacy -n $F -o jsonpath='{.spec.template.spec.containers[0].image}'" 'ubi9/httpd-24'
check_match "legacy mantiene una readiness probe" "oc get deploy legacy -n $F -o jsonpath='{.spec.template.spec.containers[0].readinessProbe}'" '.'
check_eq "LEGACY_TOKEN dal Secret legacy-secret" "oc get deploy legacy -n $F -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name==\"LEGACY_TOKEN\")].valueFrom.secretKeyRef.name}'" "legacy-secret"
check_eq "LEGACY_TOKEN dalla chiave token" "oc get deploy legacy -n $F -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name==\"LEGACY_TOKEN\")].valueFrom.secretKeyRef.key}'" "token"
check "il Secret legacy-secret ha la chiave token" test -n "$(oc get secret legacy-secret -n "$F" -o jsonpath='{.data.token}' 2>/dev/null)"
LURL="$(route_url legacy "$F")"
if [ -n "$LURL" ]; then
  code="$(curl -sk --max-time 10 -o /dev/null -w '%{http_code}' "$LURL")"
  case "$code" in 200|403) ok "route legacy risponde ($code)";; *) ko "route legacy risponde" "HTTP $code su $LURL";; esac
else
  ko "route legacy" "non trovata"
fi
check_match "almeno una build report completata" "oc get builds -n $F -l buildconfig=report -o jsonpath='{range .items[*]}{.status.phase}{\"\\n\"}{end}'" '^Complete$'

# --------------------------------------------------------------------------
titolo "Task 12 - Operator (facoltativo)"
if [ -n "${OPERATOR_KIND:-}" ]; then
  RES="${OPERATOR_RESOURCE:-$(printf '%s' "$OPERATOR_KIND" | tr '[:upper:]' '[:lower:]')}"
  check "istanza $OPERATOR_KIND exam-cache in $PR" oc get "$RES" exam-cache -n "$PR"
  if [ -n "${OPERATOR_READY_CONDITION:-}" ]; then
    check_eq "condizione $OPERATOR_READY_CONDITION = True" "oc get $RES exam-cache -n $PR -o jsonpath='{.status.conditions[?(@.type==\"$OPERATOR_READY_CONDITION\")].status}'" "True"
  fi
else
  info "OPERATOR_KIND non impostata: task 12 saltato"
fi

TOT=$((_PASS + _FAIL))
[ "$TOT" -gt 0 ] && printf "\nPunteggio indicativo: %d%%\n" $((_PASS * 100 / TOT))
riepilogo
