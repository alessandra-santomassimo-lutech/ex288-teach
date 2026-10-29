#!/usr/bin/env bash
# Estrae gli esempi di CR (annotazione alm-examples) dalla ClusterServiceVersion di un Operator
# e li salva, uno per file, nella directory indicata. Solo letture sul cluster.
#
# Uso:  bash estrai-alm-examples.sh <nome-csv> [directory-destinazione]
# Lavora nel progetto corrente (oc project).
# Esempio:
#   oc get csv                                   # trova il nome della CSV
#   bash estrai-alm-examples.sh datagrid-operator.v8.5.x ./esempi
set -euo pipefail

CSV="${1:-}"; DEST="${2:-./alm-examples}"
if [ -z "$CSV" ]; then
  echo "Uso: $0 <nome-csv> [directory]" >&2
  echo "CSV visibili nel progetto corrente:" >&2
  oc get csv -o custom-columns=NAME:.metadata.name,DISPLAY:.spec.displayName,PHASE:.status.phase >&2 || true
  exit 1
fi

JSON="$(oc get csv "$CSV" -o jsonpath='{.metadata.annotations.alm-examples}')"
if [ -z "$JSON" ]; then
  echo "La CSV $CSV non ha l'annotazione alm-examples (o non è leggibile)." >&2
  exit 1
fi
mkdir -p "$DEST"

if command -v jq >/dev/null 2>&1; then
  n="$(printf '%s' "$JSON" | jq 'length')"
  for i in $(seq 0 $((n - 1))); do
    kind="$(printf '%s' "$JSON" | jq -r ".[$i].kind")"
    f="$DEST/$(printf '%02d' "$i")-$(printf '%s' "$kind" | tr '[:upper:]' '[:lower:]').json"
    printf '%s' "$JSON" | jq ".[$i]" > "$f"
    echo "salvato $f  ($(printf '%s' "$JSON" | jq -r ".[$i].apiVersion") $kind)"
  done
elif command -v python3 >/dev/null 2>&1; then
  printf '%s' "$JSON" | python3 -c '
import json, sys, os
dest = sys.argv[1]
for i, obj in enumerate(json.load(sys.stdin)):
    kind = obj.get("kind", "risorsa")
    f = os.path.join(dest, "%02d-%s.json" % (i, kind.lower()))
    with open(f, "w") as fh:
        json.dump(obj, fh, indent=2)
    print("salvato %s  (%s %s)" % (f, obj.get("apiVersion"), kind))
' "$DEST"
else
  echo "Servono jq o python3: salvo l'array JSON completo in $DEST/alm-examples.json" >&2
  printf '%s\n' "$JSON" > "$DEST/alm-examples.json"
fi

cat <<MSG

I file JSON sono manifest validi: puoi modificarli e applicarli con 'oc apply -f <file>.json'.
Per averli in YAML (richiede che l'API sia servita dal cluster):
  oc create --dry-run=client -o yaml -f <file>.json > <file>.yaml
Prima di applicarli: cambia metadata.name, rimuovi eventuale metadata.namespace, leggi i campi con
  oc explain <kind>.spec
MSG
