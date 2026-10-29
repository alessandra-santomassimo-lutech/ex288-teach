#!/usr/bin/env bash
# Funzioni comuni agli script "rompi-N.sh" del modulo 05.
# Non eseguire direttamente: viene incluso dagli script degli scenari.

set -euo pipefail

_M05_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "${LAB:-}" ] || [ -z "${GIT_REPO:-}" ]; then
  # shellcheck disable=SC1091
  [ -f "$_M05_HERE/../../env.sh" ] && source "$_M05_HERE/../../env.sh"
fi
: "${LAB:?Variabile LAB non impostata: esegui 'source env.sh' dalla root del repository ex288-teach}"
: "${GIT_REPO:?Variabile GIT_REPO non impostata: esegui 'source env.sh' dalla root del repository ex288-teach}"
GIT_BRANCH="${GIT_BRANCH:-main}"

NS="${LAB}-m05"

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
    echo "Per ricrearlo da zero: oc delete bc,is,secret -l scenario=$2 -n $NS"
    exit 0
  fi
}

fine() {
  echo "Scenario creato in $NS. Osserva con: oc get builds -w   (Ctrl+C per uscire)"
}
