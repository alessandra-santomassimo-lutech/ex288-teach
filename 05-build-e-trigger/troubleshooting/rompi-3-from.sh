#!/usr/bin/env bash
# Scenario 3 (modulo 05): la BuildConfig "t3-from" non produce build utili.
# Non correggere questo script: eseguilo, indaga e correggi sul cluster con oc.
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/_comune.sh"
prepara_progetto
gia_creato t3-from m05-3
oc apply -n "$NS" -f - <<YAML
apiVersion: image.openshift.io/v1
kind: ImageStream
metadata:
  name: t3-from
  labels: {scenario: m05-3}
---
apiVersion: build.openshift.io/v1
kind: BuildConfig
metadata:
  name: t3-from
  labels: {scenario: m05-3}
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
        name: nodejs:16-ubi8
  output:
    to:
      kind: ImageStreamTag
      name: t3-from:latest
  triggers:
  - type: ConfigChange
  - type: ImageChange
    imageChange: {}
YAML
fine
