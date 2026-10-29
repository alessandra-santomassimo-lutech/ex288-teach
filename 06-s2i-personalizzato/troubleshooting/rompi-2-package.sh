#!/usr/bin/env bash
# Scenario 2 (modulo 06): la build "t2-nopkg" con il builder nodejs-ex288 fallisce.
# Richiede il builder nodejs-ex288:1.0 (passo 3.8 del README).
# Non correggere questo script: eseguilo, indaga e correggi sul cluster con oc.
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/_comune.sh"
prepara_progetto
if ! oc get istag nodejs-ex288:1.0 -n "$NS" >/dev/null 2>&1; then
  echo "Manca nodejs-ex288:1.0 in $NS: esegui prima il passo 3.8 del README." >&2
  exit 1
fi
gia_creato t2-nopkg m06-2
oc apply -n "$NS" -f - <<YAML
apiVersion: image.openshift.io/v1
kind: ImageStream
metadata:
  name: t2-nopkg
  labels: {scenario: m06-2}
---
apiVersion: build.openshift.io/v1
kind: BuildConfig
metadata:
  name: t2-nopkg
  labels: {scenario: m06-2}
spec:
  source:
    type: Git
    git:
      uri: "${GIT_REPO}"
      ref: "${GIT_BRANCH}"
    contextDir: builder-nodejs-ex288
  strategy:
    type: Source
    sourceStrategy:
      from:
        kind: ImageStreamTag
        name: nodejs-ex288:1.0
  output:
    to:
      kind: ImageStreamTag
      name: t2-nopkg:latest
  triggers:
  - type: ConfigChange
YAML
fine
