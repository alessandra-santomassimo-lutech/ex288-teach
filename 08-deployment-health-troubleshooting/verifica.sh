#!/usr/bin/env bash
# Verifica dell'esercizio finale del modulo 08 (sola lettura).
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../lib/verifica-lib.sh"
richiedi_login

P="${LAB}-m08-exam"
titolo "Modulo 08 - esercizio finale (progetto $P)"

check "il progetto $P esiste" oc get project "$P"

# jp <deployment> <espressione-jsonpath-senza-graffe>
jp() { oc get deploy "$1" -n "$P" -o jsonpath="{$2}" 2>/dev/null; }
# cj <deployment> <container> <percorso-dopo-il-container>  (es. .readinessProbe.httpGet.path)
cj() { jp "$1" ".spec.template.spec.containers[?(@.name==\"$2\")]$3"; }

# --- build e image stream ----------------------------------------------------------------
titolo "BuildConfig e image stream api"
check_eq "BuildConfig api con strategia Source" "oc get bc api -n $P -o jsonpath='{.spec.strategy.type}'" "Source"
check_match "BuildConfig api usa il builder Node.js 22" "oc get bc api -n $P -o jsonpath='{.spec.strategy.sourceStrategy.from.name}'" 'nodejs.*22'
check_eq "BuildConfig api costruisce la cartella hello-node" "oc get bc api -n $P -o jsonpath='{.spec.source.contextDir}' | sed 's#^/##'" "hello-node"
check "l'image stream tag api:latest esiste" oc get istag api:latest -n "$P"
check_eq "lookup locale attivo sull'image stream api" "oc get is api -n $P -o jsonpath='{.spec.lookupPolicy.local}'" "true"

# --- deployment api ------------------------------------------------------------------------
titolo "Deployment api"
check_eq "api ha 3 repliche pronte" "jp api .status.readyReplicas" "3"
check_eq "strategia RollingUpdate" "jp api .spec.strategy.type" "RollingUpdate"
check_eq "maxSurge=1" "jp api .spec.strategy.rollingUpdate.maxSurge" "1"
check_eq "maxUnavailable=0" "jp api .spec.strategy.rollingUpdate.maxUnavailable" "0"
check_eq "il container api esiste" "cj api api .name" "api"
check_eq "api: requests cpu=100m" "cj api api .resources.requests.cpu" "100m"
check_eq "api: requests memory=128Mi" "cj api api .resources.requests.memory" "128Mi"
check_eq "api: limits cpu=500m" "cj api api .resources.limits.cpu" "500m"
check_eq "api: limits memory=256Mi" "cj api api .resources.limits.memory" "256Mi"
check_eq "api: READY_DELAY_SECONDS=15" "cj api api '.env[?(@.name==\"READY_DELAY_SECONDS\")].value'" "15"

PORT_RE='^(8080|8080-tcp)$'
check_eq "startup: path /healthz" "cj api api .startupProbe.httpGet.path" "/healthz"
check_match "startup: porta 8080" "cj api api .startupProbe.httpGet.port" "$PORT_RE"
check_eq "startup: periodSeconds=5" "cj api api .startupProbe.periodSeconds" "5"
check_eq "startup: failureThreshold=24" "cj api api .startupProbe.failureThreshold" "24"
check_eq "readiness: path /ready" "cj api api .readinessProbe.httpGet.path" "/ready"
check_match "readiness: porta 8080" "cj api api .readinessProbe.httpGet.port" "$PORT_RE"
check_eq "readiness: periodSeconds=5" "cj api api .readinessProbe.periodSeconds" "5"
check_eq "readiness: failureThreshold=2" "cj api api .readinessProbe.failureThreshold" "2"
check_eq "liveness: path /healthz" "cj api api .livenessProbe.httpGet.path" "/healthz"
check_match "liveness: porta 8080" "cj api api .livenessProbe.httpGet.port" "$PORT_RE"
check_eq "liveness: periodSeconds=10" "cj api api .livenessProbe.periodSeconds" "10"
check_eq "liveness: timeoutSeconds=2" "cj api api .livenessProbe.timeoutSeconds" "2"
check_eq "liveness: failureThreshold=3" "cj api api .livenessProbe.failureThreshold" "3"

titolo "Sidecar monitor"
check_eq "il container monitor esiste" "cj api monitor .name" "monitor"
check_match "monitor usa ubi9/ubi-minimal" "cj api monitor .image" 'registry\.access\.redhat\.com/ubi9/ubi-minimal'
check_eq "monitor: limits memory=64Mi" "cj api monitor .resources.limits.memory" "64Mi"
check_eq "monitor non ha probe" "cj api monitor .name; cj api monitor .readinessProbe; cj api monitor .livenessProbe; cj api monitor .startupProbe" "monitor"
check_match "i log di monitor contengono il codice 200" "oc logs deployment/api -c monitor -n $P --tail=20" '(^|[^0-9])200([^0-9]|$)'
check_eq "tutti i container dei pod di api sono pronti" \
  "oc get pods -n $P -l \"\$(oc get deploy api -n $P -o go-template='{{range \$k, \$v := .spec.selector.matchLabels}}{{\$k}}={{\$v}},{{end}}' | sed 's/,\$//')\" -o jsonpath='{range .items[*].status.containerStatuses[*]}{.ready}{\"\\n\"}{end}' | grep -c false" "0"

titolo "Route api"
check_eq "route api con terminazione edge" "oc get route api -n $P -o jsonpath='{.spec.tls.termination}'" "edge"
check_eq "route api non accetta HTTP in chiaro" "oc get route api -n $P -o jsonpath='{.spec.tls.insecureEdgeTerminationPolicy}' | grep -c '^Allow\$'" "0"
check_eq "nessuna route HTTP in chiaro verso api" "oc get route -n $P -o jsonpath='{range .items[?(@.spec.to.name==\"api\")]}{.spec.tls.termination}{\"\\n\"}{end}' | grep -vc edge" "0"
URL="$(route_url api "$P")"
if [ -n "$URL" ]; then
  check_http "https://<route api>/ risponde 200" "$URL/" '"app": *"hello-node"'
else
  ko "la route api esiste"
fi

# --- deployment orders ---------------------------------------------------------------------
titolo "Deployment orders (corretto sul cluster)"
check_eq "orders ha 2 repliche pronte" "jp orders .status.readyReplicas" "2"
check_match "orders usa l'image stream api" "cj orders orders .image" '(^|/)api(:latest)?(@sha256:[0-9a-f]+)?$'
check_eq "orders: readiness path /ready" "cj orders orders .readinessProbe.httpGet.path" "/ready"
check_match "orders: readiness porta 8080" "cj orders orders .readinessProbe.httpGet.port" "$PORT_RE"
check_eq "orders: requests memory=64Mi" "cj orders orders .resources.requests.memory" "64Mi"
check_eq "orders: limits memory=128Mi" "cj orders orders .resources.limits.memory" "128Mi"
check_eq "orders: change-cause 'fix orders'" "oc get deploy orders -n $P -o jsonpath='{.metadata.annotations.kubernetes\.io/change-cause}'" "fix orders"
REV="$(oc get deploy orders -n "$P" -o jsonpath='{.metadata.annotations.deployment\.kubernetes\.io/revision}' 2>/dev/null)"
if [ -n "$REV" ] && [ "$REV" -ge 2 ] 2>/dev/null; then
  ok "orders corretto con nuovi rollout (revisione corrente: $REV)"
else
  ko "orders corretto con nuovi rollout (almeno 2 revisioni)" "revisione corrente: '${REV:-<nessuna>}'"
fi
URL="$(route_url orders "$P")"
if [ -n "$URL" ]; then
  check_http "http://<route orders>/ restituisce il messaggio Ordini" "$URL/" '"message": *"Ordini"'
else
  ko "la route orders esiste"
fi

riepilogo
