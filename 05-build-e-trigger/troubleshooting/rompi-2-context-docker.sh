#!/usr/bin/env bash
# Scenario 2 (modulo 05): la build Docker "t2-ctx" fallisce subito.
# Non correggere questo script: eseguilo, indaga e correggi sul cluster con oc.
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/_comune.sh"
prepara_progetto
gia_creato t2-ctx m05-2
oc apply -n "$NS" -f - <<YAML
apiVersion: image.openshift.io/v1
kind: ImageStream
metadata:
  name: t2-ctx
  labels: {scenario: m05-2}
---
apiVersion: build.openshift.io/v1
kind: BuildConfig
metadata:
  name: t2-ctx
  labels: {scenario: m05-2}
spec:
  source:
    type: Git
    git:
      uri: "${GIT_REPO}"
      ref: "${GIT_BRANCH}"
    contextDir: hello-node-s2i
  strategy:
    type: Docker
    dockerStrategy: {}
  output:
    to:
      kind: ImageStreamTag
      name: t2-ctx:latest
  triggers:
  - type: ConfigChange
YAML
fine
