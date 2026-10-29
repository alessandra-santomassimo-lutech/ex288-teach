#!/usr/bin/env bash
# Scenario 6 (modulo 08): un aggiornamento di t6 non termina mai.
# Non correggere questo script: eseguilo, indaga e correggi sul cluster con oc.
# Crea t6 (revisione 1, funzionante), attende il rollout, poi applica una modifica
# che rende la nuova versione incapace di diventare "ready" (revisione 2).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
if [ -z "${LAB:-}" ]; then
  # shellcheck disable=SC1091
  [ -f "$HERE/../../env.sh" ] && source "$HERE/../../env.sh"
fi
: "${LAB:?Variabile LAB non impostata: esegui 'source env.sh' dalla root del repository ex288-teach}"
NS="${LAB}-m08"

oc get project "$NS" >/dev/null 2>&1 || { echo "Il progetto $NS non esiste: crealo (README, passo 3.1)." >&2; exit 1; }
oc get istag hello:latest -n "$NS" >/dev/null 2>&1 || { echo "Manca hello:latest in $NS: completa il passo 3.1." >&2; exit 1; }
if oc get deploy t6 -n "$NS" >/dev/null 2>&1; then
  echo "Lo scenario 't6' esiste già in $NS: niente da fare."
  echo "Per ricrearlo da zero: oc delete deploy,svc -l scenario=m08-6 -n $NS"
  exit 0
fi

oc apply -n "$NS" -f - <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: t6
  labels:
    app: t6
    scenario: m08-6
  annotations:
    kubernetes.io/change-cause: "v1: versione stabile"
spec:
  replicas: 2
  progressDeadlineSeconds: 60
  selector:
    matchLabels:
      app: t6
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  template:
    metadata:
      labels:
        app: t6
    spec:
      containers:
      - name: hello
        image: hello:latest
        ports:
        - containerPort: 8080
        env:
        - name: APP_MESSAGE
          value: "t6 versione 1"
        readinessProbe:
          httpGet:
            path: /ready
            port: 8080
          periodSeconds: 5
---
apiVersion: v1
kind: Service
metadata:
  name: t6
  labels:
    app: t6
    scenario: m08-6
spec:
  selector:
    app: t6
  ports:
  - name: http
    port: 8080
    targetPort: 8080
YAML

echo "Attendo il rollout della versione 1..."
oc rollout status deployment/t6 -n "$NS" --timeout=180s

# Revisione 2: la nuova versione non diventerà mai pronta
oc set env deployment/t6 -n "$NS" APP_MESSAGE="t6 versione 2" READY_DELAY_SECONDS=100000
oc annotate deployment/t6 -n "$NS" kubernetes.io/change-cause="v2: nuovo messaggio" --overwrite
echo "Scenario creato in $NS. Osserva: oc rollout status deployment/t6 ; oc get pods -l app=t6 -w"
