#!/usr/bin/env bash
# Scenario 3 (modulo 13): un'identità con ruolo "view" prova a creare un'istanza dell'Operator.
# Non correggere questo script: eseguilo, indaga e correggi sul cluster con oc.
# Idempotente. Uso: bash rompi-3-ruolo-view.sh [file-cr]   (default: ../lab/datagrid-cache.yaml)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
[ -z "${LAB:-}" ] && [ -f "$HERE/../../env.sh" ] && source "$HERE/../../env.sh"
: "${LAB:?Variabile LAB non impostata: esegui 'source env.sh' dalla root del repository ex288-teach}"
NS="${LAB}-m13"
CR_FILE="${1:-$HERE/../lab/datagrid-cache.yaml}"
SA="sola-lettura"

oc get project "$NS" >/dev/null 2>&1 || { echo "Il progetto $NS non esiste: crealo (passo 3.1)." >&2; exit 1; }
oc get sa "$SA" -n "$NS" >/dev/null 2>&1 || oc create sa "$SA" -n "$NS"
oc policy add-role-to-user view -z "$SA" -n "$NS" >/dev/null

echo "Il collega (service account $SA) prova a creare l'istanza con il SUO account:"
sed 's/^  name: cache$/  name: ts3-cache/' "$CR_FILE" \
  | oc create -n "$NS" --as="system:serviceaccount:$NS:$SA" -f -
echo "(exit code: $?)  Indaga: perché il collega non può creare l'istanza?"
