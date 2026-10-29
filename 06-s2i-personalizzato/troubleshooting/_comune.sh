#!/usr/bin/env bash
# Funzioni comuni agli script "rompi-N.sh" del modulo 06.
# Non eseguire direttamente: viene incluso dagli script degli scenari.

set -euo pipefail

_M06_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "${LAB:-}" ] || [ -z "${GIT_REPO:-}" ]; then
  # shellcheck disable=SC1091
  [ -f "$_M06_HERE/../../env.sh" ] && source "$_M06_HERE/../../env.sh"
fi
: "${LAB:?Variabile LAB non impostata: esegui 'source env.sh' dalla root del repository ex288-teach}"
: "${GIT_REPO:?Variabile GIT_REPO non impostata: esegui 'source env.sh' dalla root del repository ex288-teach}"
GIT_BRANCH="${GIT_BRANCH:-main}"

NS="${LAB}-m06"

prepara_progetto() {
  if ! oc get project "$NS" >/dev/null 2>&1; then
    echo "Il progetto $NS non esiste: crealo seguendo il passo 3.1 del README." >&2
    exit 1
  fi
  if ! oc get istag nodejs:22-ubi9 -n "$NS" >/dev/null 2>&1; then
    oc import-image nodejs:22-ubi9 -n "$NS" \
      --from=registry.access.redhat.com/ubi9/nodejs-22 --confirm >/dev/null
  fi
}

# gia_creato <nome-bc> <label-scenario>: esce con successo se lo scenario esiste già
gia_creato() {
  if oc get bc "$1" -n "$NS" >/dev/null 2>&1; then
    echo "Lo scenario '$1' esiste già in $NS: niente da fare."
    echo "Per ricrearlo da zero: oc delete bc,is,deploy,svc -l scenario=$2 -n $NS"
    exit 0
  fi
}

# crea_builder_e_app <prefisso> <label-scenario> <dockerfile-inline>
# Crea il builder <prefisso>-builder:1 (Docker, Dockerfile inline) e la BuildConfig
# S2I <prefisso>-app che lo usa (cartella hello-node). La build dell'app parte da sola,
# tramite il trigger ImageChange, quando il builder è pronto.
crea_builder_e_app() {
  local p="$1" scen="$2" df="$3"
  oc apply -n "$NS" -f - <<YAML
apiVersion: image.openshift.io/v1
kind: ImageStream
metadata:
  name: ${p}-builder
  labels: {scenario: ${scen}}
---
apiVersion: image.openshift.io/v1
kind: ImageStream
metadata:
  name: ${p}-app
  labels: {scenario: ${scen}}
---
apiVersion: build.openshift.io/v1
kind: BuildConfig
metadata:
  name: ${p}-builder
  labels: {scenario: ${scen}}
spec:
  source:
    type: Dockerfile
    dockerfile: |
$(printf '%s\n' "$df" | sed 's/^/      /')
  strategy:
    type: Docker
    dockerStrategy: {}
  output:
    to:
      kind: ImageStreamTag
      name: ${p}-builder:1
  triggers:
  - type: ConfigChange
---
apiVersion: build.openshift.io/v1
kind: BuildConfig
metadata:
  name: ${p}-app
  labels: {scenario: ${scen}}
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
        name: ${p}-builder:1
  output:
    to:
      kind: ImageStreamTag
      name: ${p}-app:latest
  triggers:
  - type: ImageChange
    imageChange: {}
YAML
}

fine() {
  echo "Scenario creato in $NS. Osserva con: oc get builds -w   (Ctrl+C per uscire)"
}
