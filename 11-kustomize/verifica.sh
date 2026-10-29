#!/usr/bin/env bash
# Verifica dell'esercizio finale del modulo 11 (sola lettura).
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../lib/verifica-lib.sh"
richiedi_login

P="${LAB}-m11-exam"
EXAM_DIR="${EXAM_DIR:-$EX288_WORK/m11-exam}"
titolo "Modulo 11 - esercizio finale (progetto $P)"

check "il progetto $P esiste" oc get project "$P"
check "l'image stream tag hello-node:1.0 esiste in $P" oc get istag hello-node:1.0 -n "$P"

# --- File locali ------------------------------------------------------------------------------
titolo "Overlay in $EXAM_DIR"
if [ -d "$EXAM_DIR/base" ] && [ -f "$EXAM_DIR/overlays/prod/kustomization.yaml" ]; then
  ok "esistono $EXAM_DIR/base e $EXAM_DIR/overlays/prod/kustomization.yaml"
  BASE_ORIG="$HERE/lab/esame-base"
  if diff -r "$BASE_ORIG" "$EXAM_DIR/base" >/dev/null 2>&1; then
    ok "la base non è stata modificata"
  else
    ko "la base non è stata modificata" "differenze: diff -r $BASE_ORIG $EXAM_DIR/base"
  fi
  check_match "l'overlay usa la base come risorsa" "cat '$EXAM_DIR/overlays/prod/kustomization.yaml'" '\.\./\.\./base'
  if oc kustomize "$EXAM_DIR/overlays/prod" >/dev/null 2>&1; then
    ok "oc kustomize overlays/prod produce un output valido"
    check_match "l'output dell'overlay usa il namespace $P" "oc kustomize '$EXAM_DIR/overlays/prod' | grep -E '^  namespace:' | sort -u" "^ *namespace: *$P *\$"
  else
    ko "oc kustomize overlays/prod produce un output valido"
  fi
else
  ko "esistono $EXAM_DIR/base e $EXAM_DIR/overlays/prod/kustomization.yaml" "se hai usato un'altra cartella: EXAM_DIR=/percorso bash $0"
fi

# --- Oggetti nel cluster ---------------------------------------------------------------------------
titolo "Oggetti con prefisso prod- e label env=prod"
for r in deploy/prod-web deploy/prod-db svc/prod-web svc/prod-db route/prod-web; do
  check "$r esiste" oc get "$r" -n "$P"
  check_eq "$r ha la label env=prod" "oc get $r -n $P -o jsonpath='{.metadata.labels.env}'" "prod"
done
for d in prod-web prod-db; do
  check_eq "i pod di $d hanno la label env=prod" "oc get deploy $d -n $P -o jsonpath='{.spec.template.metadata.labels.env}'" "prod"
done
check_eq "nessun oggetto senza prefisso (deploy/web assente)" "oc get deploy web -n $P -o name 2>/dev/null | grep -c ." "0"

CM="$(oc get deploy prod-web -n "$P" -o jsonpath='{.spec.template.spec.volumes[*].configMap.name}' 2>/dev/null)"
check_match "prod-web monta una ConfigMap generata (prod-web-config-<hash>)" "printf '%s' '$CM'" '^prod-web-config-[a-z0-9]{6,}$'
if [ -n "$CM" ]; then
  check_eq "la ConfigMap $CM ha la label env=prod" "oc get cm $CM -n $P -o jsonpath='{.metadata.labels.env}'" "prod"
  check_match "app.properties contiene ambiente=produzione" "oc get cm $CM -n $P -o jsonpath='{.data.app\.properties}'" '(^|[[:space:]])ambiente=produzione([[:space:]]|$)'
  check_match "app.properties contiene livello.log=warn" "oc get cm $CM -n $P -o jsonpath='{.data.app\.properties}'" '(^|[[:space:]])livello\.log=warn([[:space:]]|$)'
  check_eq "app.properties NON contiene più ambiente=base" "oc get cm $CM -n $P -o jsonpath='{.data.app\.properties}' | grep -c 'ambiente=base'" "0"
fi
SEC="$(oc get deploy prod-db -n "$P" -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="POSTGRESQL_PASSWORD")].valueFrom.secretKeyRef.name}' 2>/dev/null)"
check_match "prod-db usa un Secret generato (prod-db-credentials-<hash>)" "printf '%s' '$SEC'" '^prod-db-credentials-[a-z0-9]{6,}$'
if [ -n "$SEC" ]; then
  check_eq "password del database = Prod-2026-ex288" "oc get secret $SEC -n $P -o jsonpath='{.data.database-password}' | base64 --decode" "Prod-2026-ex288"
  check_eq "utente del database invariato (web)" "oc get secret $SEC -n $P -o jsonpath='{.data.database-user}' | base64 --decode" "web"
  check_eq "nome del database invariato (webdb)" "oc get secret $SEC -n $P -o jsonpath='{.data.database-name}' | base64 --decode" "webdb"
fi

titolo "Deployment prod-web"
check_eq "prod-web ha 3 repliche pronte" "oc get deploy prod-web -n $P -o jsonpath='{.status.readyReplicas}'" "3"
check_eq "prod-db ha 1 replica pronta" "oc get deploy prod-db -n $P -o jsonpath='{.status.readyReplicas}'" "1"
check_match "prod-web usa il tag 1.0 di hello-node" "oc get deploy prod-web -n $P -o jsonpath='{.spec.template.spec.containers[0].image}'" 'hello-node(:1\.0|@sha256:[0-9a-f]+)$'
DIG="$(oc get istag hello-node:1.0 -n "$P" -o jsonpath='{.image.metadata.name}' 2>/dev/null)"
if [ -n "$DIG" ]; then
  check_match "i pod di prod-web eseguono l'immagine di hello-node:1.0" "oc get pods -n $P -l app=web -o jsonpath='{.items[*].status.containerStatuses[*].imageID}'" "$DIG"
fi
check_eq "limite di memoria 512Mi" "oc get deploy prod-web -n $P -o jsonpath='{.spec.template.spec.containers[0].resources.limits.memory}'" "512Mi"
check_eq "richiesta di CPU 100m" "oc get deploy prod-web -n $P -o jsonpath='{.spec.template.spec.containers[0].resources.requests.cpu}'" "100m"
check_eq "richiesta di memoria 128Mi" "oc get deploy prod-web -n $P -o jsonpath='{.spec.template.spec.containers[0].resources.requests.memory}'" "128Mi"
check_eq "Route prod-web punta al Service prod-web" "oc get route prod-web -n $P -o jsonpath='{.spec.to.name}'" "prod-web"
check_eq "Route prod-web con terminazione edge" "oc get route prod-web -n $P -o jsonpath='{.spec.tls.termination}'" "edge"

URL="$(route_url prod-web "$P")"
if [ -n "$URL" ]; then
  check_http "/ risponde 'Produzione EX288'" "$URL/" '"message": *"Produzione EX288"'
  check_http "/config contiene ambiente=produzione" "$URL/config" 'ambiente=produzione'
  check_http "/db: database raggiungibile" "$URL/db" '"db": *"raggiungibile"'
  check_http "/db: host prod-db" "$URL/db" '"host": *"prod-db"'
else
  ko "la route prod-web ha un host"
fi

riepilogo
