#!/usr/bin/env bash
# Verifica dell'esercizio finale del modulo 10 (sola lettura).
# Usa helm se è installato; altrimenti legge lo stato delle release dai Secret
# sh.helm.release.v1.* con oc.
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../lib/verifica-lib.sh"
richiedi_login

P="${LAB}-m10-exam"
R="shop"
CHART_DIR="${CHART_DIR:-$EX288_WORK/m10-exam/catalog}"
titolo "Modulo 10 - esercizio finale (progetto $P, release $R)"

check "il progetto $P esiste" oc get project "$P"
check "l'image stream tag hello-node:latest esiste in $P" oc get istag hello-node:latest -n "$P"

# --- Chart locale -------------------------------------------------------------------------
titolo "Chart in $CHART_DIR"
if [ -f "$CHART_DIR/Chart.yaml" ]; then
  ok "il chart esiste in $CHART_DIR"
  check_match "Chart.yaml: name catalog" "grep -E '^name:' '$CHART_DIR/Chart.yaml'" '^name: *"?catalog"? *$'
  check_match "Chart.yaml: version 1.2.0" "grep -E '^version:' '$CHART_DIR/Chart.yaml'" '^version: *"?1\.2\.0"? *$'
  check_match "Chart.yaml: appVersion 2.0.0" "grep -E '^appVersion:' '$CHART_DIR/Chart.yaml'" '^appVersion: *"?2\.0\.0"? *$'
  check_match "Chart.yaml: apiVersion v2" "grep -E '^apiVersion:' '$CHART_DIR/Chart.yaml'" '^apiVersion: *v2 *$'
  if command -v helm >/dev/null 2>&1; then
    check "helm lint senza errori" helm lint "$CHART_DIR"
    DEF="$(helm template verifica "$CHART_DIR" -n "$P" 2>/dev/null)"
    if [ -n "$DEF" ]; then
      # Il default va letto nel blocco "web:" di values.yaml: nel render compare comunque
      # "replicas: 1" del database, quindi un grep sul render darebbe un falso positivo.
      check_match "default di web.replicas = 1 (values.yaml)" "helm show values '$CHART_DIR' | awk '/^[^[:space:]#]/{inweb=(\$0 ~ /^web:/)} inweb'" '^[[:space:]]+replicas:[[:space:]]*1[[:space:]]*$'
      check_match "web.replicas controlla le repliche (--set web.replicas=7)" "helm template verifica '$CHART_DIR' -n $P --set web.replicas=7" 'replicas: *7'
      check_match "con i valori di default: messaggio 'Catalogo'" "printf '%s' \"\$DEF\" | grep -A1 'name: APP_MESSAGE'" 'value: *"?Catalogo"?'
      check_match "con i valori di default: la Route viene creata" "printf '%s' \"\$DEF\" | grep -E '^kind: *Route'" 'Route'
      check_match "con i valori di default: catalog.mode=standard" "printf '%s' \"\$DEF\"" 'catalog\.mode=standard'
      NOR="$(helm template verifica "$CHART_DIR" -n "$P" --set route.enabled=false 2>/dev/null | grep -cE '^kind: *Route')"
      if [ "$NOR" = "0" ]; then ok "con route.enabled=false la Route non viene creata"; else ko "con route.enabled=false la Route non viene creata"; fi
    else
      ko "helm template rende il chart con i valori di default"
    fi
  else
    info "helm non trovato: salto lint e controlli sui valori di default del chart"
  fi
else
  ko "il chart esiste in $CHART_DIR" "se lo hai creato altrove: CHART_DIR=/percorso bash $0"
fi

# --- Storia della release ------------------------------------------------------------------
titolo "Release $R e revisioni"
release_json() {  # release_json <revisione>: JSON della release (decodifica del Secret)
  oc get secret "sh.helm.release.v1.$R.v$1" -n "$P" -o jsonpath='{.data.release}' 2>/dev/null \
    | base64 --decode 2>/dev/null | base64 --decode 2>/dev/null | gunzip 2>/dev/null
}
check_eq "la release $R ha 4 revisioni (Secret di Helm)" "oc get secret -n $P -l owner=helm,name=$R -o name | grep -c ." "4"
check_eq "la revisione 4 è quella attiva (deployed)" "oc get secret sh.helm.release.v1.$R.v4 -n $P -o jsonpath='{.metadata.labels.status}'" "deployed"
for v in 1 2 3; do
  check_eq "la revisione $v è stata sostituita (superseded)" "oc get secret sh.helm.release.v1.$R.v$v -n $P -o jsonpath='{.metadata.labels.status}'" "superseded"
done
J4="$(release_json 4)"; J3="$(release_json 3)"; J1="$(release_json 1)"
if [ -n "$J4" ]; then
  check_match "la revisione 4 è un rollback alla revisione 2" "printf '%s' \"\$J4\"" '"description":"Rollback to 2"'
  check_match "la revisione 4 contiene la Route" "printf '%s' \"\$J4\"" 'kind: Route'
else
  info "impossibile decodificare la revisione 4 (servono base64 e gunzip): controlli sul contenuto saltati"
fi
if [ -n "$J3" ]; then
  if printf '%s' "$J3" | grep -q 'kind: Route'; then ko "la revisione 3 NON contiene la Route (route.enabled=false)"; else ok "la revisione 3 NON contiene la Route (route.enabled=false)"; fi
fi
if [ -n "$J1" ]; then
  check_match "la revisione 1 aveva il messaggio 'Benvenuti'" "printf '%s' \"\$J1\"" 'Benvenuti'
fi
if command -v helm >/dev/null 2>&1; then
  check_match "helm history: revisione 4 deployed" "helm history $R -n $P | awk '\$1==4'" 'deployed'
  check_match "helm list mostra il chart catalog-1.2.0" "helm list -n $P --filter '^$R\$'" 'catalog-1\.2\.0'
fi

# --- Oggetti della revisione attiva ----------------------------------------------------------
titolo "Oggetti della release"
for r in "deploy/$R-web" "deploy/$R-db" "svc/$R-web" "svc/$R-db" "secret/$R-db" "cm/$R-config" "route/$R-web"; do
  check "$r esiste" oc get "$r" -n "$P"
  check_eq "$r gestito da Helm (managed-by)" "oc get $r -n $P -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}'" "Helm"
  check_eq "$r appartiene alla release $R" "oc get $r -n $P -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-name}'" "$R"
done
check_eq "label helm.sh/chart=catalog-1.2.0 su $R-web" "oc get deploy $R-web -n $P -o jsonpath='{.metadata.labels.helm\.sh/chart}'" "catalog-1.2.0"
check_eq "label app.kubernetes.io/instance=$R su $R-web" "oc get deploy $R-web -n $P -o jsonpath='{.metadata.labels.app\.kubernetes\.io/instance}'" "$R"
check_eq "label app.kubernetes.io/version=2.0.0 su $R-web" "oc get deploy $R-web -n $P -o jsonpath='{.metadata.labels.app\.kubernetes\.io/version}'" "2.0.0"
check_eq "$R-web ha 3 repliche pronte" "oc get deploy $R-web -n $P -o jsonpath='{.status.readyReplicas}'" "3"
check_eq "$R-web ha un container chiamato web" "oc get deploy $R-web -n $P -o jsonpath='{.spec.template.spec.containers[*].name}'" "web"
check_match "$R-web usa hello-node dal registry interno di $P" "oc get deploy $R-web -n $P -o jsonpath='{.spec.template.spec.containers[0].image}'" "image-registry\.openshift-image-registry\.svc:5000/$P/hello-node"
check_eq "$R-web: readiness su /ready" "oc get deploy $R-web -n $P -o jsonpath='{.spec.template.spec.containers[0].readinessProbe.httpGet.path}'" "/ready"
check_eq "$R-web: liveness su /healthz" "oc get deploy $R-web -n $P -o jsonpath='{.spec.template.spec.containers[0].livenessProbe.httpGet.path}'" "/healthz"
check_eq "$R-db ha 1 replica pronta" "oc get deploy $R-db -n $P -o jsonpath='{.status.readyReplicas}'" "1"
DBVOL="$(oc get deploy "$R-db" -n "$P" -o jsonpath='{.spec.template.spec.containers[0].volumeMounts[?(@.mountPath=="/var/lib/pgsql/data")].name}' 2>/dev/null)"
check_match "$R-db: /var/lib/pgsql/data su un volume emptyDir" "oc get deploy $R-db -n $P -o jsonpath='{.spec.template.spec.volumes[?(@.name==\"${DBVOL:-<nessuno>}\")].emptyDir}'" '^\{'
check_match "$R-db usa PostgreSQL 16" "oc get deploy $R-db -n $P -o jsonpath='{.spec.template.spec.containers[*].image}'" 'rhel9/postgresql-16'
check_match "Service $R-web porta 8080" "oc get svc $R-web -n $P -o jsonpath='{.spec.ports[*].port}'" '(^| )8080( |$)'
check_match "Service $R-db porta 5432" "oc get svc $R-db -n $P -o jsonpath='{.spec.ports[*].port}'" '(^| )5432( |$)'
check_eq "Route $R-web con terminazione edge" "oc get route $R-web -n $P -o jsonpath='{.spec.tls.termination}'" "edge"
check_eq "Secret $R-db: database-user = catalog" "oc get secret $R-db -n $P -o jsonpath='{.data.database-user}' | base64 --decode" "catalog"
check_eq "Secret $R-db: database-name = catalogdb" "oc get secret $R-db -n $P -o jsonpath='{.data.database-name}' | base64 --decode" "catalogdb"
check_match "Secret $R-db: database-password presente" "oc get secret $R-db -n $P -o jsonpath='{.data.database-password}' | base64 --decode" '.+'
check_match "ConfigMap $R-config: catalog.mode=saldi" "oc get cm $R-config -n $P -o jsonpath='{.data.app\.properties}'" 'catalog\.mode=saldi'

URL="$(route_url "$R-web" "$P")"
if [ -n "$URL" ]; then
  check_http "/ risponde 'Saldi di fine stagione'" "$URL/" '"message": *"Saldi di fine stagione"'
  check_http "/config contiene catalog.mode=saldi" "$URL/config" 'catalog\.mode=saldi'
  check_http "/db: database raggiungibile" "$URL/db" '"db": *"raggiungibile"'
else
  ko "la route $R-web ha un host"
fi

riepilogo
