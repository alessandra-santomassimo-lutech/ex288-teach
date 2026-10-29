#!/usr/bin/env bash
# Scenario 4 (modulo 06): la build "t4-url" fallisce.
# Non correggere questo script: eseguilo, indaga e correggi sul cluster con oc.
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/_comune.sh"
prepara_progetto
gia_creato t4-url m06-4
oc apply -n "$NS" -f - <<YAML
apiVersion: image.openshift.io/v1
kind: ImageStream
metadata:
  name: t4-url
  labels: {scenario: m06-4}
---
apiVersion: build.openshift.io/v1
kind: BuildConfig
metadata:
  name: t4-url
  labels: {scenario: m06-4}
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
      scripts: "image:///usr/lib/s2i"
  output:
    to:
      kind: ImageStreamTag
      name: t4-url:latest
  triggers:
  - type: ConfigChange
YAML
fine
