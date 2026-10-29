#!/usr/bin/env bash
# Scenario 7 (modulo 05): la build "t7-push" arriva fino alla fine ma fallisce.
# Crea anche il progetto ${LAB}-m05-altro.
# Non correggere questo script: eseguilo, indaga e correggi sul cluster con oc.
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/_comune.sh"
prepara_progetto
gia_creato t7-push m05-7
ALTRO="${LAB}-m05-altro"
if ! oc get project "$ALTRO" >/dev/null 2>&1; then
  oc new-project "$ALTRO" --display-name="EX288 m05 - progetto altro" >/dev/null
  oc project "$NS" >/dev/null
fi
oc create imagestream hello -n "$ALTRO" --dry-run=client -o yaml | oc apply -n "$ALTRO" -f -
oc apply -n "$NS" -f - <<YAML
apiVersion: build.openshift.io/v1
kind: BuildConfig
metadata:
  name: t7-push
  labels: {scenario: m05-7}
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
      namespace: "${ALTRO}"
      name: hello:latest
  triggers:
  - type: ConfigChange
YAML
fine
