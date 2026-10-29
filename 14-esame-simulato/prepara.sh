#!/usr/bin/env bash
# Prepara il progetto ${LAB}-ex-fix per il task 11 dell'esame simulato.
# Crea VOLUTAMENTE risorse con errori. Idempotente: puoi rilanciarlo per ripartire.
# Non leggere questo file prima dell'esame: contiene la descrizione dei guasti.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../lib/verifica-lib.sh"
richiedi_login

P="${LAB}-ex-fix"
if ! oc get project "$P" >/dev/null 2>&1; then
  oc new-project "$P" --display-name="Exam Fix" >/dev/null
fi

# Builder per la BuildConfig "report"
oc import-image nodejs:22-ubi9 --from=registry.access.redhat.com/ubi9/nodejs-22 --confirm -n "$P" >/dev/null

oc apply -n "$P" -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: legacy-secret
type: Opaque
stringData:
  tokne: "s3cr3t-legacy"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: legacy
  labels:
    app: legacy
spec:
  replicas: 1
  selector:
    matchLabels:
      app: legacy
  template:
    metadata:
      labels:
        app: legacy
    spec:
      containers:
      - name: web
        image: registry.access.redhat.com/ubi9/httpd-42
        ports:
        - containerPort: 8080
        env:
        - name: LEGACY_TOKEN
          valueFrom:
            secretKeyRef:
              name: legacy-secret
              key: token
        readinessProbe:
          tcpSocket:
            port: 8081
          periodSeconds: 5
---
apiVersion: v1
kind: Service
metadata:
  name: legacy
  labels:
    app: legacy
spec:
  selector:
    app: legacy
  ports:
  - name: http
    port: 8080
    targetPort: 8080
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: legacy
  labels:
    app: legacy
spec:
  to:
    kind: Service
    name: legacy-svc
  port:
    targetPort: http
---
apiVersion: image.openshift.io/v1
kind: ImageStream
metadata:
  name: report
---
apiVersion: build.openshift.io/v1
kind: BuildConfig
metadata:
  name: report
  labels:
    app: report
spec:
  source:
    type: Git
    git:
      uri: ${GIT_REPO}
      ref: ${GIT_BRANCH:-main}
    contextDir: hello-nod
  strategy:
    type: Source
    sourceStrategy:
      from:
        kind: ImageStreamTag
        name: nodejs:22-ubi9
  output:
    to:
      kind: ImageStreamTag
      name: report:latest
EOF

oc start-build report -n "$P" >/dev/null 2>&1 || true

echo "Progetto $P preparato. Avvia il timer e inizia l'esame."
