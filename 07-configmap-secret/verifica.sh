#!/usr/bin/env bash
# Verifica dell'esercizio finale del modulo 07 (sola lettura).
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../lib/verifica-lib.sh"
richiedi_login

P="${LAB}-m07-exam"
titolo "Modulo 07 - esercizio finale (progetto $P)"

check "il progetto $P esiste" oc get project "$P"

# jp <deployment> <espressione-jsonpath-senza-graffe>
jp() { oc get deploy "$1" -n "$P" -o jsonpath="{$2}" 2>/dev/null; }
C='.spec.template.spec.containers[0]'

# secret_val <secret> <chiave> -> valore decodificato
secret_val() { oc get secret "$1" -n "$P" -o jsonpath="{.data.$2}" 2>/dev/null | base64 --decode 2>/dev/null; }

# da_risorsa <desc> <deploy> <VAR> <configmap|secret> <nome-risorsa> <chiave> <prefisso-envFrom-accettato|->
#   OK se VAR è letta dalla chiave della risorsa (env.valueFrom) oppure arriva da envFrom con il prefisso indicato.
da_risorsa() {
  local desc="$1" d="$2" var="$3" kind="$4" res="$5" key="$6" pfx="$7" refn refk efn efp lit
  if [ "$kind" = "configmap" ]; then
    refn="$(jp "$d" "$C.env[?(@.name==\"$var\")].valueFrom.configMapKeyRef.name")"
    refk="$(jp "$d" "$C.env[?(@.name==\"$var\")].valueFrom.configMapKeyRef.key")"
    efn="$(jp "$d" "$C.envFrom[?(@.configMapRef.name==\"$res\")].configMapRef.name")"
    efp="$(jp "$d" "$C.envFrom[?(@.configMapRef.name==\"$res\")].prefix")"
  else
    refn="$(jp "$d" "$C.env[?(@.name==\"$var\")].valueFrom.secretKeyRef.name")"
    refk="$(jp "$d" "$C.env[?(@.name==\"$var\")].valueFrom.secretKeyRef.key")"
    efn="$(jp "$d" "$C.envFrom[?(@.secretRef.name==\"$res\")].secretRef.name")"
    efp="$(jp "$d" "$C.envFrom[?(@.secretRef.name==\"$res\")].prefix")"
  fi
  lit="$(jp "$d" "$C.env[?(@.name==\"$var\")].value")"
  if [ -n "$lit" ]; then
    ko "$desc" "$var ha un valore scritto nel Deployment ('$lit'): deve arrivare da $kind/$res"
  elif [ "$refn" = "$res" ] && [ "$refk" = "$key" ]; then
    ok "$desc"
  elif [ "$pfx" != "-" ] && [ "$efn" = "$res" ] && [ "$efp" = "$pfx" ]; then
    ok "$desc"
  else
    ko "$desc" "$var non risulta letta da $kind/$res (chiave $key)"
  fi
}

# --- ConfigMap e Secret ------------------------------------------------------------
titolo "ConfigMap e Secret"
check_eq "ConfigMap shop-settings ha esattamente le chiavi COLOR e MESSAGE" \
  "oc get cm shop-settings -n $P -o go-template='{{range \$k, \$v := .data}}{{\$k}} {{end}}'" "COLOR MESSAGE"
check_eq "shop-settings: MESSAGE='Negozio configurato'" "oc get cm shop-settings -n $P -o jsonpath='{.data.MESSAGE}'" "Negozio configurato"
check_eq "shop-settings: COLOR='blu'" "oc get cm shop-settings -n $P -o jsonpath='{.data.COLOR}'" "blu"
check_match "shop-files: shop.properties contiene negozio.nome=EX288 Shop" "oc get cm shop-files -n $P -o jsonpath='{.data.shop\.properties}'" '(^|[[:space:]])negozio\.nome=EX288 Shop([[:space:]]|$)'
check_match "shop-files: shop.properties contiene negozio.valuta=EUR" "oc get cm shop-files -n $P -o jsonpath='{.data.shop\.properties}'" '(^|[[:space:]])negozio\.valuta=EUR([[:space:]]|$)'
check_eq "shop-files: shop.properties ha 2 righe" "oc get cm shop-files -n $P -o jsonpath='{.data.shop\.properties}' | grep -c ." "2"

check_eq "Secret shop-api di tipo Opaque" "oc get secret shop-api -n $P -o jsonpath='{.type}'" "Opaque"
check_eq "shop-api: API_KEY='k-12345-exam'" "secret_val shop-api API_KEY" "k-12345-exam"
check_eq "Secret shop-db di tipo Opaque" "oc get secret shop-db -n $P -o jsonpath='{.type}'" "Opaque"
check_eq "shop-db: USER='shop'" "secret_val shop-db USER" "shop"
check_eq "shop-db: PASSWORD='Negozi0-2026'" "secret_val shop-db PASSWORD" "Negozi0-2026"
check_eq "shop-db: DATABASE='shopdb'" "secret_val shop-db DATABASE" "shopdb"

# --- database ------------------------------------------------------------------------
titolo "Database shop-db"
check_eq "Deployment shop-db ha 1 replica pronta" "jp shop-db .status.readyReplicas" "1"
check_match "shop-db usa l'immagine rhel9/postgresql-16" "jp shop-db \"$C.image\"" 'postgresql-16'
for v in USER PASSWORD DATABASE; do
  da_risorsa "shop-db: POSTGRESQL_$v dal Secret shop-db" shop-db "POSTGRESQL_$v" secret shop-db "$v" "POSTGRESQL_"
done
check_match "Service shop-db espone la porta 5432" "oc get svc shop-db -n $P -o jsonpath='{.spec.ports[*].port}'" '(^| )5432( |$)'

# --- applicazione shop ----------------------------------------------------------------
titolo "Applicazione shop"
check_eq "BuildConfig shop con strategia Source" "oc get bc shop -n $P -o jsonpath='{.spec.strategy.type}'" "Source"
check_match "BuildConfig shop usa il builder Node.js 22" "oc get bc shop -n $P -o jsonpath='{.spec.strategy.sourceStrategy.from.name}'" 'nodejs.*22'
REPO_NORM="${GIT_REPO:-<GIT_REPO non impostata>}"; REPO_NORM="${REPO_NORM%.git}"
check_eq "BuildConfig shop costruisce da \$GIT_REPO" "oc get bc shop -n $P -o jsonpath='{.spec.source.git.uri}' | sed 's/\\.git\$//'" "$REPO_NORM"
check_eq "BuildConfig shop costruisce la cartella hello-node" "oc get bc shop -n $P -o jsonpath='{.spec.source.contextDir}' | sed 's#^/##'" "hello-node"
check_eq "Deployment shop ha 2 repliche pronte" "jp shop .status.readyReplicas" "2"

da_risorsa "APP_MESSAGE dalla ConfigMap shop-settings (prefisso APP_)" shop APP_MESSAGE configmap shop-settings MESSAGE "APP_"
da_risorsa "APP_COLOR dalla ConfigMap shop-settings (prefisso APP_)" shop APP_COLOR configmap shop-settings COLOR "APP_"
da_risorsa "API_KEY dal Secret shop-api" shop API_KEY secret shop-api API_KEY ""
da_risorsa "DB_USER dal Secret shop-db" shop DB_USER secret shop-db USER "DB_"
da_risorsa "DB_PASSWORD dal Secret shop-db" shop DB_PASSWORD secret shop-db PASSWORD "DB_"
da_risorsa "DB_NAME dalla chiave DATABASE del Secret shop-db" shop DB_NAME secret shop-db DATABASE "-"
check_eq "REQUIRED_ENV=APP_MESSAGE,API_KEY,DB_PASSWORD" "jp shop \"$C.env[?(@.name==\\\"REQUIRED_ENV\\\")].value\"" "APP_MESSAGE,API_KEY,DB_PASSWORD"

VOL="$(jp shop '.spec.template.spec.volumes[?(@.configMap.name=="shop-files")].name')"
if [ -n "$VOL" ]; then
  ok "shop ha un volume dalla ConfigMap shop-files ($VOL)"
  check_match "il volume $VOL è montato in /etc/shop" "jp shop \"$C.volumeMounts[?(@.name==\\\"$VOL\\\")].mountPath\"" '^/etc/shop/?( |$)'
else
  ko "shop ha un volume dalla ConfigMap shop-files"
fi
CF="$(jp shop "$C.env[?(@.name==\"CONFIG_FILE\")].value")"
if [ "$CF" = "/etc/shop/shop.properties" ]; then
  ok "CONFIG_FILE=/etc/shop/shop.properties"
elif [ -n "$(jp shop "$C.env[?(@.name==\"CONFIG_FILE\")].valueFrom")" ]; then
  info "CONFIG_FILE arriva da una risorsa esterna: verificato tramite /config"
else
  ko "CONFIG_FILE=/etc/shop/shop.properties" "trovato: '${CF:-<non impostata>}'"
fi

# --- verifiche funzionali via route ---------------------------------------------------------
titolo "Verifiche funzionali (route shop)"
URL="$(route_url shop "$P")"
if [ -n "$URL" ]; then
  check_http "/ restituisce il messaggio della ConfigMap" "$URL/" '"message": *"Negozio configurato"'
  check_http "/env mostra APP_COLOR=blu" "$URL/env" '"APP_COLOR": *"blu"'
  check_http "/env: API_KEY impostata (12 caratteri)" "$URL/env" '"API_KEY": *"impostata \(12 caratteri\)"'
  check_http "/env: DB_PASSWORD impostata (12 caratteri)" "$URL/env" '"DB_PASSWORD": *"impostata \(12 caratteri\)"'
  check_http "/config mostra shop.properties" "$URL/config" 'negozio\.nome=EX288 Shop'
  check_http "/db: database raggiungibile" "$URL/db" '"db": *"raggiungibile"'
  check_http "/db: DB_HOST=shop-db" "$URL/db" '"host": *"shop-db"'
  check_http "/db: DB_PORT=5432" "$URL/db" '"port": *5432'
  check_http "/db: DB_NAME=shopdb" "$URL/db" '"name": *"shopdb"'
  check_http "/db: DB_USER=shop" "$URL/db" '"user": *"shop"'
else
  ko "la route shop esiste"
fi

# --- RBAC -------------------------------------------------------------------------------------
titolo "Service account reader"
check "service account reader esiste" oc get sa reader -n "$P"
check_eq "reader può leggere le ConfigMap" "oc auth can-i get configmaps -n $P --as=system:serviceaccount:$P:reader" "yes"
check_eq "reader NON può leggere i Secret" "oc auth can-i get secrets -n $P --as=system:serviceaccount:$P:reader" "no"

riepilogo
