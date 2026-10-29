#!/usr/bin/env bash
# Scenario 6 (modulo 05): la build "t6-res" non parte mai.
# Non correggere questo script: eseguilo, indaga e correggi sul cluster con oc.
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/_comune.sh"
prepara_progetto
gia_creato t6-res m05-6
oc apply -n "$NS" -f - <<YAML
apiVersion: image.openshift.io/v1
kind: ImageStream
metadata:
  name: t6-res
  labels: {scenario: m05-6}
---
apiVersion: build.openshift.io/v1
kind: BuildConfig
metadata:
  name: t6-res
  labels: {scenario: m05-6}
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
  resources:
    requests:
      cpu: "64"
      memory: 512Gi
    limits:
      cpu: "64"
      memory: 512Gi
  output:
    to:
      kind: ImageStreamTag
      name: t6-res:latest
  triggers:
  - type: ConfigChange
YAML
fine
