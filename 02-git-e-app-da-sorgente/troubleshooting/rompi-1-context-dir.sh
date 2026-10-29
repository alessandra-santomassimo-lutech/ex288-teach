#!/usr/bin/env bash
# Scenario 1 (modulo 02): la build "ctx" fallisce.
# Non correggere questo script: eseguilo, indaga e correggi sul cluster con oc.
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/_comune.sh"
prepara_progetto
gia_creato ctx m02-1
crea_bc_s2i ctx "$GIT_REPO" "${GIT_BRANCH:-main}" "hello" m02-1
