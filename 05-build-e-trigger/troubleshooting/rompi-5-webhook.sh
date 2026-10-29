#!/usr/bin/env bash
# Scenario 5 (modulo 05): il webhook di "t5-hook" non avvia build.
# Non correggere questo script: eseguilo, indaga e correggi sul cluster con oc.
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/_comune.sh"
prepara_progetto
gia_creato t5-hook m05-5
oc apply -n "$NS" -f - <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: t5-webhook
  labels: {scenario: m05-5}
type: Opaque
stringData:
  WebhookSecret: segreto-t5
---
apiVersion: image.openshift.io/v1
kind: ImageStream
metadata:
  name: t5-hook
  labels: {scenario: m05-5}
---
apiVersion: build.openshift.io/v1
kind: BuildConfig
metadata:
  name: t5-hook
  labels: {scenario: m05-5}
spec:
  source:
    type: Git
    git:
      uri: "${GIT_REPO}"
      ref: "${GIT_BRANCH}"
    contextDir: hello-node
  strategy:
    type: Source
    sourceStrategy:
      from:
        kind: ImageStreamTag
        name: nodejs:22-ubi9
  output:
    to:
      kind: ImageStreamTag
      name: t5-hook:latest
  triggers:
  - type: Generic
    generic:
      secretReference:
        name: t5-webhook
YAML
echo "Scenario creato in $NS."
echo "Il valore del secret del webhook è: segreto-t5"
echo "Prova a invocare il webhook generico di t5-hook con curl (vedi README, sezione 6)."
