#!/usr/bin/env bash
# Verifica dell'esercizio finale del modulo 00 (sola lettura).
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../lib/verifica-lib.sh"
richiedi_login

P="${LAB}-m00"
titolo "Modulo 00 - verifica ambiente"
check "utente diverso da kube:admin" test "$(oc whoami)" != "kube:admin"
if [ "$LAB" != "cambiami" ]; then ok "LAB impostata ($LAB)"; else ko "LAB vale ancora 'cambiami'"; fi
check "GIT_REPO raggiungibile sul branch ${GIT_BRANCH:-main}" git ls-remote --exit-code "$GIT_REPO" "${GIT_BRANCH:-main}"

TMP="$(mktemp -d)"
if git clone -q --depth 1 -b "${GIT_BRANCH:-main}" "$GIT_REPO" "$TMP/repo" 2>/dev/null; then
  for d in hello-node hello-node-s2i builder-nodejs-ex288 broken-image; do
    check "il repo contiene la cartella $d" test -d "$TMP/repo/$d"
  done
  check "hello-node-s2i/.s2i/bin/assemble è eseguibile nel repo" test -x "$TMP/repo/hello-node-s2i/.s2i/bin/assemble"
else
  ko "clone del repository" "impossibile clonare $GIT_REPO"
fi
rm -rf "$TMP"

check "il progetto $P esiste" oc get project "$P"
check_eq "display name del progetto $P" "oc get project $P -o jsonpath='{.metadata.annotations.openshift\.io/display-name}'" "EX288 - setup"

riepilogo
