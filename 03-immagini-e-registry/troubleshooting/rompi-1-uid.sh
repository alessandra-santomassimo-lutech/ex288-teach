#!/usr/bin/env bash
# Scenario 1 (modulo 03): l'app "broken" va in CrashLoopBackOff.
# Non correggere questo script: eseguilo, indaga e correggi sul cluster
# (e nel tuo repository Git, in un branch) come descritto nel README.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
if [ -z "${LAB:-}" ] || [ -z "${GIT_REPO:-}" ]; then
  # shellcheck disable=SC1091
  [ -f "$HERE/../../env.sh" ] && source "$HERE/../../env.sh"
fi
: "${LAB:?Variabile LAB non impostata: esegui 'source env.sh' dalla root del repository ex288-teach}"
: "${GIT_REPO:?Variabile GIT_REPO non impostata: esegui 'source env.sh' dalla root del repository ex288-teach}"
NS="${LAB}-m03"

oc get project "$NS" >/dev/null 2>&1 || { echo "Il progetto $NS non esiste: crealo (README, sezione 3)." >&2; exit 1; }
if oc get bc broken -n "$NS" >/dev/null 2>&1; then
  echo "Lo scenario 'broken' esiste già in $NS: niente da fare."
  echo "Per ricrearlo da zero: oc delete all,is -l app=broken -n $NS"
  exit 0
fi
# La cartella broken-image contiene un Dockerfile: strategia Docker rilevata automaticamente.
oc new-app "$GIT_REPO" --context-dir=broken-image --name=broken -n "$NS"
echo "Scenario creato. Osserva: oc logs -f bc/broken -n $NS ; oc get pods -l deployment=broken -n $NS -w"
