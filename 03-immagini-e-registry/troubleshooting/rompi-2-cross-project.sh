#!/usr/bin/env bash
# Scenario 2 (modulo 03): nel progetto ${LAB}-m03-other il Deployment "consumer2"
# usa un'immagine del progetto ${LAB}-m03 e resta in ImagePullBackOff.
# Non correggere questo script: eseguilo, indaga e correggi sul cluster con oc.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
if [ -z "${LAB:-}" ]; then
  # shellcheck disable=SC1091
  [ -f "$HERE/../../env.sh" ] && source "$HERE/../../env.sh"
fi
: "${LAB:?Variabile LAB non impostata: esegui 'source env.sh' dalla root del repository ex288-teach}"
SRC="${LAB}-m03"
DST="${LAB}-m03-other"
IMG="image-registry.openshift-image-registry.svc:5000/${SRC}/hello-bin:1.0"

if ! oc get istag hello-bin:1.0 -n "$SRC" >/dev/null 2>&1; then
  echo "Manca l'immagine hello-bin:1.0 in $SRC: esegui prima il passo 3.3 del README." >&2
  exit 1
fi
if ! oc get project "$DST" >/dev/null 2>&1; then
  # --skip-config-write: non cambia il progetto corrente
  oc new-project "$DST" --skip-config-write >/dev/null
fi
if oc get deployment consumer2 -n "$DST" >/dev/null 2>&1; then
  echo "Lo scenario esiste già in $DST: niente da fare."
  exit 0
fi
oc apply -n "$DST" -f - <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: consumer2
  labels:
    app: consumer2
spec:
  replicas: 1
  selector:
    matchLabels:
      app: consumer2
  template:
    metadata:
      labels:
        app: consumer2
    spec:
      containers:
      - name: hello
        image: ${IMG}
        ports:
        - containerPort: 8080
YAML
echo "Scenario creato. Osserva: oc get pods -l app=consumer2 -n $DST -w"
