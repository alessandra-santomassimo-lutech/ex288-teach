#!/usr/bin/env bash
# Scenario 2 (modulo 02): la build "badrepo" fallisce subito.
# Non correggere questo script: eseguilo, indaga e correggi sul cluster con oc.
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/_comune.sh"
prepara_progetto
gia_creato badrepo m02-2
crea_bc_s2i badrepo "https://github.com/ex288-repo-inesistente/ex288-apps-inesistente.git" "main" "hello-node" m02-2
