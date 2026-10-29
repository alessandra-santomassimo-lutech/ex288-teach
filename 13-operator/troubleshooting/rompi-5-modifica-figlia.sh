#!/usr/bin/env bash
# Scenario 5 (modulo 13): qualcuno "sistema a mano" una risorsa creata dall'Operator.
# Non correggere questo script: eseguilo, osserva, indaga.
# Uso: bash rompi-5-modifica-figlia.sh [KIND] [NOME-CR]     (default: Infinispan cache)
# Trova uno StatefulSet o Deployment posseduto dal CR e lo scala a 0 repliche.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
[ -z "${LAB:-}" ] && [ -f "$HERE/../../env.sh" ] && source "$HERE/../../env.sh"
: "${LAB:?Variabile LAB non impostata: esegui 'source env.sh' dalla root del repository ex288-teach}"
NS="${LAB}-m13"
KIND="${1:-Infinispan}"
CR="${2:-cache}"

TARGET="$(oc get statefulset,deployment -n "$NS" \
  -o jsonpath='{range .items[*]}{.kind}/{.metadata.name}{" "}{.metadata.ownerReferences[*].kind}/{.metadata.ownerReferences[*].name}{"\n"}{end}' 2>/dev/null \
  | awk -v o="$KIND/$CR" '$2==o {print $1; exit}')"
if [ -z "$TARGET" ]; then
  echo "Nessuno StatefulSet/Deployment posseduto da $KIND/$CR in $NS (completa prima il passo 3.5)." >&2
  exit 1
fi
echo "Scalo a 0 la risorsa figlia $TARGET (il CR chiede ancora le sue repliche)..."
oc scale "$(printf '%s' "$TARGET" | tr '[:upper:]' '[:lower:]')" --replicas=0 -n "$NS"
echo "Ora osserva per un minuto: oc get pods -w -n $NS"
