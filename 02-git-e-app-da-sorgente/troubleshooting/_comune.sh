#!/usr/bin/env bash
# Funzioni comuni agli script "rompi-N.sh" del modulo 02.
# Non eseguire direttamente: viene incluso dagli script degli scenari.

set -euo pipefail

_M02_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "${LAB:-}" ] || [ -z "${GIT_REPO:-}" ]; then
  # shellcheck disable=SC1091
  [ -f "$_M02_HERE/../../env.sh" ] && source "$_M02_HERE/../../env.sh"
fi
: "${LAB:?Variabile LAB non impostata: esegui 'source env.sh' dalla root del repository ex288-teach}"
: "${GIT_REPO:?Variabile GIT_REPO non impostata: esegui 'source env.sh' dalla root del repository ex288-teach}"

NS="${LAB}-m02"

prepara_progetto() {
  if ! oc get project "$NS" >/dev/null 2>&1; then
    echo "Il progetto $NS non esiste: crealo seguendo il passo 3.2 del README." >&2
    exit 1
  fi
  # Builder S2I locale (stesso comando del passo 3.2)
  if ! oc get istag nodejs:22-ubi9 -n "$NS" >/dev/null 2>&1; then
    oc import-image nodejs:22-ubi9 -n "$NS" \
      --from=registry.access.redhat.com/ubi9/nodejs-22 --confirm >/dev/null
  fi
}

# gia_creato <nome-bc>: termina con successo se lo scenario esiste già (idempotenza)
gia_creato() {
  if oc get bc "$1" -n "$NS" >/dev/null 2>&1; then
    echo "Lo scenario '$1' esiste già in $NS: niente da fare."
    echo "Per ricrearlo da zero: oc delete bc,is -l scenario=$2 -n $NS"
    exit 0
  fi
}

# crea_bc_s2i <nome> <uri> <ref> <contextDir> <label-scenario>
# Crea ImageStream + BuildConfig S2I con trigger ConfigChange (la prima build parte subito).
crea_bc_s2i() {
  local name="$1" uri="$2" ref="$3" ctx="$4" scen="$5"
  oc apply -n "$NS" -f - <<YAML
apiVersion: image.openshift.io/v1
kind: ImageStream
metadata:
  name: ${name}
  labels:
    app: ${name}
    scenario: ${scen}
---
apiVersion: build.openshift.io/v1
kind: BuildConfig
metadata:
  name: ${name}
  labels:
    app: ${name}
    scenario: ${scen}
spec:
  source:
    type: Git
    git:
      uri: "${uri}"
      ref: "${ref}"
    contextDir: "${ctx}"
  strategy:
    type: Source
    sourceStrategy:
      from:
        kind: ImageStreamTag
        name: "nodejs:22-ubi9"
  output:
    to:
      kind: ImageStreamTag
      name: "${name}:latest"
  triggers:
  - type: ConfigChange
YAML
  echo "Scenario creato in $NS. Osserva: oc get builds -w"
}
