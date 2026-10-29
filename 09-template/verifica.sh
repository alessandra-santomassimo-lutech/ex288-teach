#!/usr/bin/env bash
# Verifica dell'esercizio finale del modulo 09 (sola lettura).
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../lib/verifica-lib.sh"
richiedi_login

P="${LAB}-m09-exam"
T="inventory-app"
A="stock"
titolo "Modulo 09 - esercizio finale (progetto $P)"

check "il progetto $P esiste" oc get project "$P"
check "l'image stream tag nodejs:22-ubi9 esiste" oc get istag nodejs:22-ubi9 -n "$P"
check_match "nodejs:22-ubi9 importato da ubi9/nodejs-22" "oc get is nodejs -n $P -o jsonpath='{.spec.tags[?(@.name==\"22-ubi9\")].from.name}'" 'registry\.access\.redhat\.com/ubi9/nodejs-22'

# --- Template salvato nel progetto ---------------------------------------------------
titolo "Template $T"
check "il template $T esiste nel progetto" oc get template "$T" -n "$P"
check_eq "display name 'Inventory App'" "oc get template $T -n $P -o jsonpath='{.metadata.annotations.openshift\.io/display-name}'" "Inventory App"
check_match "il template ha una descrizione" "oc get template $T -n $P -o jsonpath='{.metadata.annotations.description}'" '.+'
check_match "il template ha il tag ex288" "oc get template $T -n $P -o jsonpath='{.metadata.annotations.tags}'" '(^|,) *ex288 *(,|$)'
check_eq "label di template app.kubernetes.io/part-of=inventory" "oc get template $T -n $P -o jsonpath='{.labels.app\.kubernetes\.io/part-of}'" "inventory"

par() { oc get template "$T" -n "$P" -o jsonpath="{.parameters[?(@.name==\"$1\")].$2}" 2>/dev/null; }
for p in APP_NAME APP_MESSAGE REPLICAS GIT_URI DB_NAME DB_USER DB_PASSWORD MEMORY_LIMIT; do
  check_eq "parametro $p dichiarato" "oc get template $T -n $P -o jsonpath='{.parameters[?(@.name==\"$p\")].name}'" "$p"
done
check_eq "APP_NAME: default 'inventory'" "par APP_NAME value" "inventory"
check_eq "APP_NAME: obbligatorio" "par APP_NAME required" "true"
check_eq "APP_MESSAGE: default 'Inventario attivo'" "par APP_MESSAGE value" "Inventario attivo"
check_eq "REPLICAS: default '2'" "par REPLICAS value" "2"
check_eq "GIT_URI: obbligatorio" "par GIT_URI required" "true"
check_eq "GIT_URI: nessun valore di default" "par GIT_URI value" ""
check_eq "DB_NAME: default 'inventorydb'" "par DB_NAME value" "inventorydb"
check_eq "DB_USER: default 'inventory'" "par DB_USER value" "inventory"
check_eq "MEMORY_LIMIT: default '256Mi'" "par MEMORY_LIMIT value" "256Mi"
check_eq "DB_PASSWORD: generata (generate: expression)" "par DB_PASSWORD generate" "expression"
check_eq "DB_PASSWORD: 12 caratteri alfanumerici" "par DB_PASSWORD from" "[a-zA-Z0-9]{12}"

KINDS="$(oc get template "$T" -n "$P" -o jsonpath='{range .objects[*]}{.kind}{"\n"}{end}' 2>/dev/null | sort | tr '\n' ' ')"
for k in BuildConfig ConfigMap ImageStream Route Secret; do
  if printf '%s' "$KINDS" | grep -qw "$k"; then ok "il template contiene un oggetto $k"; else ko "il template contiene un oggetto $k" "oggetti trovati: ${KINDS:-<nessuno>}"; fi
done
check_eq "il template contiene 2 Deployment" "printf '%s' '$KINDS' | tr ' ' '\n' | grep -cx Deployment" "2"
check_eq "il template contiene 2 Service" "printf '%s' '$KINDS' | tr ' ' '\n' | grep -cx Service" "2"
check_match "nel template replicas usa la sintassi non-stringa \${{REPLICAS}}" "oc get template $T -n $P -o yaml" 'replicas: .?\$\{\{REPLICAS\}\}'

# --- Istanza 'stock' ---------------------------------------------------------------------
titolo "Applicazione $A creata dal template"
check "ImageStream $A" oc get is "$A" -n "$P"
check_eq "BuildConfig $A usa la strategia Source" "oc get bc $A -n $P -o jsonpath='{.spec.strategy.type}'" "Source"
check_eq "BuildConfig $A usa il builder nodejs:22-ubi9" "oc get bc $A -n $P -o jsonpath='{.spec.strategy.sourceStrategy.from.name}'" "nodejs:22-ubi9"
check_eq "BuildConfig $A usa la context dir hello-node" "oc get bc $A -n $P -o jsonpath='{.spec.source.contextDir}'" "hello-node"
REPO_NORM="${GIT_REPO:-<GIT_REPO non impostata>}"; REPO_NORM="${REPO_NORM%.git}"
check_eq "BuildConfig $A punta al tuo GIT_REPO" "oc get bc $A -n $P -o jsonpath='{.spec.source.git.uri}' | sed 's/\\.git\$//'" "$REPO_NORM"
check_match "almeno una build di $A completata" "oc get builds -n $P -l buildconfig=$A -o jsonpath='{.items[*].status.phase}'" 'Complete'
check_match "Deployment $A ha un trigger su $A:latest" "oc get deploy $A -n $P -o jsonpath='{.metadata.annotations.image\.openshift\.io/triggers}'" "\"name\":\"$A:latest\""
check_eq "Deployment $A ha 3 repliche pronte" "oc get deploy $A -n $P -o jsonpath='{.status.readyReplicas}'" "3"
check_eq "limite di memoria del container di $A = 256Mi" "oc get deploy $A -n $P -o jsonpath='{.spec.template.spec.containers[0].resources.limits.memory}'" "256Mi"
check_eq "readiness probe di $A su /ready" "oc get deploy $A -n $P -o jsonpath='{.spec.template.spec.containers[0].readinessProbe.httpGet.path}'" "/ready"
check_eq "liveness probe di $A su /healthz" "oc get deploy $A -n $P -o jsonpath='{.spec.template.spec.containers[0].livenessProbe.httpGet.path}'" "/healthz"
DBVOL="$(oc get deploy "$A-db" -n "$P" -o jsonpath='{.spec.template.spec.containers[0].volumeMounts[?(@.mountPath=="/var/lib/pgsql/data")].name}' 2>/dev/null)"
check_match "Deployment $A-db: /var/lib/pgsql/data su un volume emptyDir" "oc get deploy $A-db -n $P -o jsonpath='{.spec.template.spec.volumes[?(@.name==\"${DBVOL:-<nessuno>}\")].emptyDir}'" '^\{'
check_eq "Deployment $A-db ha 1 replica pronta" "oc get deploy $A-db -n $P -o jsonpath='{.status.readyReplicas}'" "1"
check_match "Deployment $A-db usa l'immagine PostgreSQL 16" "oc get deploy $A-db -n $P -o jsonpath='{.spec.template.spec.containers[*].image}'" 'rhel9/postgresql-16'
check_match "Service $A espone la porta 8080" "oc get svc $A -n $P -o jsonpath='{.spec.ports[*].port}'" '(^| )8080( |$)'
check_match "Service $A-db espone la porta 5432" "oc get svc $A-db -n $P -o jsonpath='{.spec.ports[*].port}'" '(^| )5432( |$)'
check_eq "Route $A con terminazione edge" "oc get route $A -n $P -o jsonpath='{.spec.tls.termination}'" "edge"
check_eq "Secret $A-db: database-name = inventorydb" "oc get secret $A-db -n $P -o jsonpath='{.data.database-name}' | base64 --decode" "inventorydb"
check_eq "Secret $A-db: database-user = inventory" "oc get secret $A-db -n $P -o jsonpath='{.data.database-user}' | base64 --decode" "inventory"
check_match "Secret $A-db: password generata di 12 caratteri alfanumerici" "oc get secret $A-db -n $P -o jsonpath='{.data.database-password}' | base64 --decode" '^[a-zA-Z0-9]{12}$'
check_match "ConfigMap $A-config contiene inventory.name=$A" "oc get cm $A-config -n $P -o jsonpath='{.data.app\.properties}'" "inventory\.name=$A"
for r in "deploy/$A" "deploy/$A-db" "svc/$A" "svc/$A-db" "route/$A" "secret/$A-db" "cm/$A-config" "bc/$A" "is/$A"; do
  check_eq "$r ha la label app.kubernetes.io/part-of=inventory" "oc get $r -n $P -o jsonpath='{.metadata.labels.app\.kubernetes\.io/part-of}'" "inventory"
done

URL="$(route_url "$A" "$P")"
if [ -n "$URL" ]; then
  check_http "/ risponde con il messaggio 'Magazzino centrale'" "$URL/" '"message": *"Magazzino centrale"'
  check_http "/config mostra inventory.name=$A" "$URL/config" "inventory\.name=$A"
  check_http "/db: database raggiungibile (inventorydb, utente inventory)" "$URL/db" '"db": *"raggiungibile"'
  check_http "/db mostra il database inventorydb" "$URL/db" '"name": *"inventorydb"'
else
  ko "la route $A esiste e ha un host"
fi

riepilogo
