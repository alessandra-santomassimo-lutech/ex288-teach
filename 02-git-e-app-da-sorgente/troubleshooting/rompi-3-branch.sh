#!/usr/bin/env bash
# Scenario 3 (modulo 02): la build "badbranch" non trova il codice.
# Non correggere questo script: eseguilo, indaga e correggi sul cluster con oc.
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/_comune.sh"
prepara_progetto
gia_creato badbranch m02-3
crea_bc_s2i badbranch "$GIT_REPO" "feature-inesistente" "hello-node" m02-3
