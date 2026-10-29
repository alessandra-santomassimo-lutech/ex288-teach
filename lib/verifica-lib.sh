#!/usr/bin/env bash
# Libreria comune per gli script di verifica (verifica.sh) dei moduli.
# Uso: source "$(dirname "$0")/../../lib/verifica-lib.sh"
#
# Gli script di verifica NON modificano nulla sul cluster: eseguono solo
# letture (oc get / oc describe / curl) e stampano [OK] / [KO].

# NOTA: niente "set -o pipefail" qui. Su un cluster reale molti comandi di
# discovery (oc api-resources, oc api-versions) terminano con exit code 1
# anche quando l'output è corretto (basta un gruppo API aggregato non
# raggiungibile, es. metrics.k8s.io), e "grep -q" chiude la pipe in anticipo.
# Con pipefail queste pipeline risulterebbero fallite anche se il dato c'è.
# I controlli si basano quindi sull'OUTPUT dei comandi, non sul loro exit code.

# Directory di lavoro del corso (vedi env.example.sh): valore di riserva se env.sh
# è stato creato da una versione precedente che non la definiva.
EX288_WORK="${EX288_WORK:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/work}"

_PASS=0
_FAIL=0

if [ -t 1 ]; then
  _G=$'\e[32m'; _R=$'\e[31m'; _Y=$'\e[33m'; _B=$'\e[1m'; _N=$'\e[0m'
else
  _G=""; _R=""; _Y=""; _B=""; _N=""
fi

titolo() { printf "\n%s== %s ==%s\n" "$_B" "$*" "$_N"; }
ok()     { printf "  %s[OK]%s %s\n" "$_G" "$_N" "$1"; _PASS=$((_PASS + 1)); }
ko()     { printf "  %s[KO]%s %s\n" "$_R" "$_N" "$1"; [ -n "${2:-}" ] && printf "       -> %s\n" "$2"; _FAIL=$((_FAIL + 1)); }
info()   { printf "  %s[..]%s %s\n" "$_Y" "$_N" "$*"; }

# check "descrizione" comando [argomenti...]
#   OK se il comando termina con exit code 0.
check() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$desc"; else ko "$desc"; fi
}

# check_eq "descrizione" "comando shell" "valore atteso"
#   OK se l'output (senza spazi iniziali/finali) è uguale al valore atteso.
check_eq() {
  local desc="$1" cmd="$2" expected="$3" actual
  actual="$(eval "$cmd" 2>/dev/null | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  if [ "$actual" = "$expected" ]; then ok "$desc"; else ko "$desc" "atteso: '$expected' - trovato: '${actual:-<vuoto>}'"; fi
}

# check_match "descrizione" "comando shell" "regex estesa"
check_match() {
  local desc="$1" cmd="$2" regex="$3" actual
  actual="$(eval "$cmd" 2>/dev/null)"
  if grep -Eq -- "$regex" <<<"$actual"; then ok "$desc"; else ko "$desc" "nessuna corrispondenza con /$regex/ - trovato: '$(printf '%s' "$actual" | head -c 200)'"; fi
}

# check_http "descrizione" URL [regex-sul-body] [codice-http-atteso=200]
check_http() {
  local desc="$1" url="$2" regex="${3:-}" code="${4:-200}" body status
  body="$(curl -sk --max-time 10 -w '\n%{http_code}' "$url" 2>/dev/null)"
  status="$(printf '%s' "$body" | tail -n1)"
  body="$(printf '%s' "$body" | sed '$d')"
  if [ "$status" != "$code" ]; then
    ko "$desc" "HTTP $status su $url (atteso $code)"
  elif [ -n "$regex" ] && ! grep -Eq -- "$regex" <<<"$body"; then
    ko "$desc" "risposta senza /$regex/: $(printf '%s' "$body" | head -c 200)"
  else
    ok "$desc"
  fi
}

# route_url <nome-route> <namespace> -> stampa http(s)://host[/path]
route_url() {
  local host tls path
  host="$(oc get route "$1" -n "$2" -o jsonpath='{.spec.host}' 2>/dev/null)" || return 1
  [ -z "$host" ] && return 1
  tls="$(oc get route "$1" -n "$2" -o jsonpath='{.spec.tls.termination}' 2>/dev/null)"
  path="$(oc get route "$1" -n "$2" -o jsonpath='{.spec.path}' 2>/dev/null)"
  if [ -n "$tls" ]; then printf 'https://%s%s' "$host" "$path"; else printf 'http://%s%s' "$host" "$path"; fi
}

# api_disponibile <gruppo/versione>  es. api_disponibile tekton.dev/v1
#   Usa "oc api-versions" (solo elenco dei gruppi, nessun permesso speciale)
#   e ignora l'exit code: conta solo se la versione compare nell'output.
api_disponibile() {
  local versions
  versions="$(oc api-versions 2>/dev/null || true)"
  grep -qx -- "$1" <<<"$versions"
}

# versioni_api <gruppo>  es. versioni_api triggers.tekton.dev -> "v1alpha1 v1beta1"
versioni_api() {
  local versions
  versions="$(oc api-versions 2>/dev/null || true)"
  grep "^$1/" <<<"$versions" | sed "s#^$1/##" | tr '\n' ' ' | sed 's/ $//'
}

richiedi_login() {
  if ! oc whoami >/dev/null 2>&1; then
    printf "%sNon sei autenticata sul cluster: esegui prima 'oc login'.%s\n" "$_R" "$_N"
    exit 2
  fi
  if [ -z "${LAB:-}" ]; then
    local here; here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    # shellcheck disable=SC1091
    [ -f "$here/env.sh" ] && source "$here/env.sh"
  fi
  if [ -z "${LAB:-}" ]; then
    printf "%sVariabile LAB non impostata: esegui 'source env.sh' dalla root del repository ex288-teach (vedi 00-setup).%s\n" "$_R" "$_N"
    exit 2
  fi
}

riepilogo() {
  local tot=$((_PASS + _FAIL))
  printf "\n%sRisultato: %d/%d controlli superati%s\n" "$_B" "$_PASS" "$tot" "$_N"
  if [ "$_FAIL" -eq 0 ]; then
    printf "%sTutti i requisiti risultano soddisfatti.%s\n" "$_G" "$_N"
  else
    printf "%sCi sono %d requisiti non soddisfatti: rileggi i requisiti e indaga con oc describe / oc get events / oc logs.%s\n" "$_R" "$_FAIL" "$_N"
  fi
  [ "$_FAIL" -eq 0 ]
}
