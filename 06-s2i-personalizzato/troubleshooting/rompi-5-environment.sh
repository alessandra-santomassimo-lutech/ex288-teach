#!/usr/bin/env bash
# Scenario 5 (modulo 06): l'immagine "t5-env" non contiene il messaggio previsto.
# Build BINARIA da una copia di apps/hello-node-s2i con un .s2i/environment modificato
# (il tuo repository Git non viene toccato).
# Non correggere questo script: eseguilo, indaga e correggi sul cluster con oc.
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/_comune.sh"
prepara_progetto
gia_creato t5-env m06-5
SRC="$_M06_HERE/../../apps/hello-node-s2i"
[ -d "$SRC" ] || { echo "Non trovo $SRC" >&2; exit 1; }
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cp -R "$SRC/." "$TMP/"
cat > "$TMP/.s2i/environment" <<'ENV'
APP_MESSAGE: Messaggio dello scenario 5
APP_TEAM=ex288
ENV
oc apply -n "$NS" -f - <<YAML
apiVersion: image.openshift.io/v1
kind: ImageStream
metadata:
  name: t5-env
  labels: {scenario: m06-5}
---
apiVersion: build.openshift.io/v1
kind: BuildConfig
metadata:
  name: t5-env
  labels: {scenario: m06-5}
spec:
  source:
    type: Binary
  strategy:
    type: Source
    sourceStrategy:
      from:
        kind: ImageStreamTag
        name: nodejs:22-ubi9
  output:
    to:
      kind: ImageStreamTag
      name: t5-env:latest
YAML
oc start-build t5-env -n "$NS" --from-dir="$TMP" --wait >/dev/null || true
echo "Build t5-env eseguita. Requisito: l'immagine t5-env:latest deve avere APP_MESSAGE='Messaggio dello scenario 5'."
