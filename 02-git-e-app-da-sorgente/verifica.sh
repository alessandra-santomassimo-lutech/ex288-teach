#!/usr/bin/env bash
# Verifica dell'esercizio finale del modulo 02 (sola lettura).
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../lib/verifica-lib.sh"
richiedi_login

P="${LAB}-m02-exam"
REPO_NORM="${GIT_REPO%.git}"
titolo "Modulo 02 - esercizio finale (progetto $P)"

check "il progetto $P esiste" oc get project "$P"

# --- Git ---------------------------------------------------------------------
titolo "Repository Git"
REMOTE_COMMIT=""
if command -v git >/dev/null 2>&1; then
  REMOTE_COMMIT="$(git ls-remote "$GIT_REPO" refs/heads/exam-v2 2>/dev/null | cut -f1)"
  if [ -n "$REMOTE_COMMIT" ]; then ok "il branch exam-v2 esiste sul remoto (${REMOTE_COMMIT:0:7})"; else ko "il branch exam-v2 esiste sul remoto" "git ls-remote $GIT_REPO non mostra refs/heads/exam-v2 (push dimenticato?)"; fi
else
  info "git non installato: salto il controllo del branch remoto"
fi

# --- catalog -----------------------------------------------------------------
titolo "catalog (S2I)"
check "BuildConfig catalog esiste" oc get bc catalog -n "$P"
check_eq "catalog usa la strategia Source" "oc get bc catalog -n $P -o jsonpath='{.spec.strategy.type}'" "Source"
check_match "catalog usa il builder Node.js 22 UBI 9" "oc get bc catalog -n $P -o jsonpath='{.spec.strategy.sourceStrategy.from.name}'" 'nodejs.*22'
check_eq "catalog costruisce da \$GIT_REPO" "oc get bc catalog -n $P -o jsonpath='{.spec.source.git.uri}' | sed 's/\\.git\$//'" "$REPO_NORM"
check_eq "catalog costruisce dal branch exam-v2" "oc get bc catalog -n $P -o jsonpath='{.spec.source.git.ref}'" "exam-v2"
check_eq "catalog usa la cartella hello-node" "oc get bc catalog -n $P -o jsonpath='{.spec.source.contextDir}' | sed -e 's#^/##' -e 's#/\$##'" "hello-node"
check_eq "BuildConfig catalog ha BUILD_LOGLEVEL=2" "oc get bc catalog -n $P -o jsonpath='{.spec.strategy.sourceStrategy.env[?(@.name==\"BUILD_LOGLEVEL\")].value}'" "2"

LASTV="$(oc get bc catalog -n "$P" -o jsonpath='{.status.lastVersion}' 2>/dev/null)"
if [ -n "$LASTV" ] && [ "$LASTV" != "0" ]; then
  check_eq "l'ultima build catalog-$LASTV è Complete" "oc get build catalog-$LASTV -n $P -o jsonpath='{.status.phase}'" "Complete"
  if [ -n "$REMOTE_COMMIT" ]; then
    check_eq "l'ultima build usa l'ultimo commit di exam-v2" "oc get build catalog-$LASTV -n $P -o jsonpath='{.spec.revision.git.commit}'" "$REMOTE_COMMIT"
  fi
else
  ko "esiste almeno una build di catalog"
fi

check_match "Deployment catalog ha almeno 1 replica pronta" "oc get deploy catalog -n $P -o jsonpath='{.status.readyReplicas}'" '^[1-9]'
check_eq "Deployment catalog ha APP_VERSION=2.0.0" "oc get deploy catalog -n $P -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name==\"APP_VERSION\")].value}'" "2.0.0"
check_eq "Deployment catalog NON imposta APP_MESSAGE" "oc get deploy catalog -n $P -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name==\"APP_MESSAGE\")].name}'" ""
check_eq "Deployment catalog NON importa variabili da ConfigMap/Secret (envFrom)" "oc get deploy catalog -n $P -o jsonpath='{.spec.template.spec.containers[0].envFrom}'" ""
check_eq "route catalog con terminazione edge" "oc get route catalog -n $P -o jsonpath='{.spec.tls.termination}'" "edge"
# echo "valore=..." perché check_match non riconosce un output vuoto (campo non impostato = default None)
check_match "route catalog non accetta HTTP in chiaro (insecureEdgeTerminationPolicy None o Redirect)" "echo \"valore=\$(oc get route catalog -n $P -o jsonpath='{.spec.tls.insecureEdgeTerminationPolicy}')\"" '^valore=(None|Redirect)?$'
URL="$(route_url catalog "$P")"
if [ -n "$URL" ]; then
  _prima=$_FAIL
  check_http "catalog risponde con il messaggio 'Catalogo v2'" "$URL/" '"message": *"Catalogo v2"'
  [ "$_FAIL" -gt "$_prima" ] && info "il messaggio deve essere il DEFAULT nel codice del branch exam-v2 (hello-node/server.js), pushato sul remoto e seguito da una nuova build"
  check_http "catalog risponde con la versione 2.0.0" "$URL/" '"version": *"2\.0\.0"'
else
  ko "route catalog esiste"
fi

# --- orders ------------------------------------------------------------------
titolo "orders (Docker) e orders-db"
check "BuildConfig orders esiste" oc get bc orders -n "$P"
check_eq "orders usa la strategia Docker" "oc get bc orders -n $P -o jsonpath='{.spec.strategy.type}'" "Docker"
check_eq "orders costruisce da \$GIT_REPO" "oc get bc orders -n $P -o jsonpath='{.spec.source.git.uri}' | sed 's/\\.git\$//'" "$REPO_NORM"
check_match "orders costruisce dal branch main (o dal branch di default)" "echo \"ref=\$(oc get bc orders -n $P -o jsonpath='{.spec.source.git.ref}')\"" '^ref=(main)?$'
check_eq "orders usa la cartella hello-node" "oc get bc orders -n $P -o jsonpath='{.spec.source.contextDir}' | sed -e 's#^/##' -e 's#/\$##'" "hello-node"
check_match "Deployment orders ha almeno 1 replica pronta" "oc get deploy orders -n $P -o jsonpath='{.status.readyReplicas}'" '^[1-9]'
check_eq "Deployment orders ha APP_MESSAGE=Ordini" "oc get deploy orders -n $P -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name==\"APP_MESSAGE\")].value}'" "Ordini"
check_match "orders ha DB_HOST verso orders-db" "oc get deploy orders -n $P -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name==\"DB_HOST\")].value}'" '^orders-db(\.|$)'
check_eq "orders ha DB_PORT=5432" "oc get deploy orders -n $P -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name==\"DB_PORT\")].value}'" "5432"
check_eq "orders ha DB_NAME=ordersdb" "oc get deploy orders -n $P -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name==\"DB_NAME\")].value}'" "ordersdb"
check_eq "orders ha DB_USER=orders" "oc get deploy orders -n $P -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name==\"DB_USER\")].value}'" "orders"
check_eq "orders definisce DB_PASSWORD" "oc get deploy orders -n $P -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name==\"DB_PASSWORD\")].name}'" "DB_PASSWORD"
check_eq "route orders in HTTP (senza TLS)" "oc get route orders -n $P -o jsonpath='{.spec.tls.termination}'" ""

check_match "orders-db usa l'immagine PostgreSQL 16" "oc get deploy orders-db -n $P -o jsonpath='{.spec.template.spec.containers[0].image}'" 'postgresql-16|/orders-db(@sha256|:)'
check_eq "orders-db ha POSTGRESQL_USER=orders" "oc get deploy orders-db -n $P -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name==\"POSTGRESQL_USER\")].value}'" "orders"
check_eq "orders-db ha POSTGRESQL_DATABASE=ordersdb" "oc get deploy orders-db -n $P -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name==\"POSTGRESQL_DATABASE\")].value}'" "ordersdb"
check_match "Deployment orders-db ha 1 replica pronta" "oc get deploy orders-db -n $P -o jsonpath='{.status.readyReplicas}'" '^1$'
check_match "Service orders-db espone la porta 5432" "oc get svc orders-db -n $P -o jsonpath='{.spec.ports[*].port}'" '(^| )5432( |$)'

URL="$(route_url orders "$P")"
if [ -n "$URL" ]; then
  check_http "orders risponde con il messaggio 'Ordini'" "$URL/" '"message": *"Ordini"'
  check_http "orders raggiunge il database (/db)" "$URL/db" '"db": *"raggiungibile"'
else
  ko "route orders esiste"
fi

# --- label -------------------------------------------------------------------
titolo "Label team=shop"
for r in bc/catalog bc/orders deploy/catalog deploy/orders deploy/orders-db svc/catalog svc/orders svc/orders-db; do
  check_eq "$r ha la label team=shop" "oc get $r -n $P -o jsonpath='{.metadata.labels.team}'" "shop"
done

riepilogo
