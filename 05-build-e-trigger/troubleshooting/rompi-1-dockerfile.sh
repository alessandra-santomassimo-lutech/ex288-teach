#!/usr/bin/env bash
# Scenario 1 (modulo 05): la build Docker "t1-docker" fallisce.
# Non correggere questo script: eseguilo, indaga e correggi sul cluster con oc.
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/_comune.sh"
prepara_progetto
gia_creato t1-docker m05-1
oc apply -n "$NS" -f - <<YAML
apiVersion: image.openshift.io/v1
kind: ImageStream
metadata:
  name: t1-docker
  labels: {scenario: m05-1}
---
apiVersion: build.openshift.io/v1
kind: BuildConfig
metadata:
  name: t1-docker
  labels: {scenario: m05-1}
spec:
  source:
    type: Git
    git:
      uri: "${GIT_REPO}"
      ref: "${GIT_BRANCH}"
    contextDir: hello-node
    dockerfile: |
      FROM registry.access.redhat.com/ubi9/nodejs-22-minimal
      WORKDIR /opt/app-root/src
      COPY package.json server.js ./
      RUN npm-install-tutto
      EXPOSE 8080
      CMD ["node", "server.js"]
  strategy:
    type: Docker
    dockerStrategy: {}
  output:
    to:
      kind: ImageStreamTag
      name: t1-docker:latest
  triggers:
  - type: ConfigChange
YAML
fine
