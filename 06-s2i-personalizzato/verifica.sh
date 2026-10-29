#!/usr/bin/env bash
# Verifica dell'esercizio finale del modulo 06 (sola lettura).
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../lib/verifica-lib.sh"
richiedi_login

P="${LAB}-m06-exam"
REPO_NORM="${GIT_REPO:-<GIT_REPO non impostata>}"; REPO_NORM="${REPO_NORM%.git}"
titolo "Modulo 06 - esercizio finale (progetto $P)"

check "il progetto $P esiste" oc get project "$P"
check "l'image stream tag nodejs:22-ubi9 esiste" oc get istag nodejs:22-ubi9 -n "$P"
check_match "nodejs:22-ubi9 importato da ubi9/nodejs-22" "oc get is nodejs -n $P -o jsonpath='{.spec.tags[?(@.name==\"22-ubi9\")].from.name}'" 'registry\.access\.redhat\.com/ubi9/nodejs-22'

# --- Builder nodejs-corp ----------------------------------------------------------------
titolo "Builder nodejs-corp"
B=nodejs-corp
check "la BuildConfig $B esiste" oc get bc "$B" -n "$P"
check_eq "$B usa la strategia Docker" "oc get bc $B -n $P -o jsonpath='{.spec.strategy.type}'" "Docker"
check_eq "$B: sorgente \$GIT_REPO" "oc get bc $B -n $P -o jsonpath='{.spec.source.git.uri}' | sed 's/\\.git\$//'" "$REPO_NORM"
REF="$(oc get bc "$B" -n "$P" -o jsonpath='{.spec.source.git.ref}' 2>/dev/null)"
oc get bc "$B" -n "$P" >/dev/null 2>&1 && case "$REF" in
  ""|main|refs/heads/main) ok "$B: branch main (ref='${REF:-default}')";;
  *) ko "$B: branch main" "ref trovato: $REF";;
esac
check_match "$B: cartella builder-nodejs-ex288" "oc get bc $B -n $P -o jsonpath='{.spec.source.contextDir}'" '^/?builder-nodejs-ex288/?$'
check_eq "$B: immagine base da ImageStreamTag" "oc get bc $B -n $P -o jsonpath='{.spec.strategy.dockerStrategy.from.kind}'" "ImageStreamTag"
check_match "$B: immagine base nodejs:22-ubi9" "oc get bc $B -n $P -o jsonpath='{.spec.strategy.dockerStrategy.from.name}'" '^nodejs:22-ubi9$'
check_match "$B: trigger ImageChange presente" "oc get bc $B -n $P -o jsonpath='{.spec.triggers[*].type}'" 'ImageChange'
check_eq "$B: output nodejs-corp:1.0" "oc get bc $B -n $P -o jsonpath='{.spec.output.to.name}'" "nodejs-corp:1.0"
check "l'image stream tag nodejs-corp:1.0 esiste" oc get istag nodejs-corp:1.0 -n "$P"
LBL="oc get istag nodejs-corp:1.0 -n $P -o jsonpath"
check_eq "label io.k8s.display-name" "$LBL='{.image.dockerImageMetadata.Config.Labels.io\.k8s\.display-name}'" "Node.js 22 Corp"
check_eq "label io.openshift.tags" "$LBL='{.image.dockerImageMetadata.Config.Labels.io\.openshift\.tags}'" "builder,nodejs,corp"
check_eq "label io.openshift.s2i.scripts-url" "$LBL='{.image.dockerImageMetadata.Config.Labels.io\.openshift\.s2i\.scripts-url}'" "image:///usr/libexec/s2i-ex288"
NB="$(oc get builds -n "$P" -l openshift.io/build-config.name=$B -o jsonpath='{range .items[?(@.status.phase=="Complete")]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -c .)"
if [ "${NB:-0}" -ge 2 ]; then ok "$B ha almeno 2 build completate ($NB)"; else ko "$B ha almeno 2 build completate" "trovate: ${NB:-0}"; fi

# --- BuildConfig inventory ----------------------------------------------------------------
titolo "BuildConfig inventory"
A=inventory
check "la BuildConfig $A esiste" oc get bc "$A" -n "$P"
check_eq "$A usa la strategia Source" "oc get bc $A -n $P -o jsonpath='{.spec.strategy.type}'" "Source"
check_eq "$A: builder ImageStreamTag" "oc get bc $A -n $P -o jsonpath='{.spec.strategy.sourceStrategy.from.kind}'" "ImageStreamTag"
check_match "$A: builder nodejs-corp:1.0" "oc get bc $A -n $P -o jsonpath='{.spec.strategy.sourceStrategy.from.name}'" '^nodejs-corp:1\.0$'
check_eq "$A: sorgente \$GIT_REPO" "oc get bc $A -n $P -o jsonpath='{.spec.source.git.uri}' | sed 's/\\.git\$//'" "$REPO_NORM"
check_eq "$A: branch exam-s2i" "oc get bc $A -n $P -o jsonpath='{.spec.source.git.ref}'" "exam-s2i"
check_match "$A: cartella hello-node-s2i" "oc get bc $A -n $P -o jsonpath='{.spec.source.contextDir}'" '^/?hello-node-s2i/?$'
check_eq "$A: variabile di build APP_TIER=exam" "oc get bc $A -n $P -o jsonpath='{.spec.strategy.sourceStrategy.env[?(@.name==\"APP_TIER\")].value}'" "exam"
check_eq "$A: build incrementali abilitate" "oc get bc $A -n $P -o jsonpath='{.spec.strategy.sourceStrategy.incremental}'" "true"
check_match "$A: trigger ImageChange presente" "oc get bc $A -n $P -o jsonpath='{.spec.triggers[*].type}'" 'ImageChange'
ICFROM="$(oc get bc "$A" -n "$P" -o jsonpath='{.spec.triggers[?(@.type=="ImageChange")].imageChange.from.name}' 2>/dev/null)"
HASIC="$(oc get bc "$A" -n "$P" -o jsonpath='{.spec.triggers[*].type}' 2>/dev/null | grep -c ImageChange)"
if [ "${HASIC:-0}" -eq 0 ]; then
  : # già segnalato dal controllo precedente
elif [ -z "$ICFROM" ] || [ "$ICFROM" = "nodejs-corp:1.0" ]; then
  ok "$A: il trigger ImageChange osserva nodejs-corp:1.0"
else
  ko "$A: il trigger ImageChange osserva nodejs-corp:1.0" "osserva invece: $ICFROM"
fi

# L'ultima build Complete di inventory deve usare il digest attuale di nodejs-corp:1.0
DCORP="$(oc get istag nodejs-corp:1.0 -n "$P" -o jsonpath='{.image.metadata.name}' 2>/dev/null)"
LASTFROM="$(oc get builds -n "$P" -l openshift.io/build-config.name=$A --sort-by=.metadata.creationTimestamp \
  -o jsonpath='{range .items[?(@.status.phase=="Complete")]}{.spec.strategy.sourceStrategy.from.name}{"\n"}{end}' 2>/dev/null | tail -1)"
if [ -n "$DCORP" ] && printf '%s' "$LASTFROM" | grep -q "$DCORP"; then
  ok "l'ultima build completata di $A usa l'immagine attuale di nodejs-corp:1.0"
else
  ko "l'ultima build completata di $A usa l'immagine attuale di nodejs-corp:1.0" "builder usato: '${LASTFROM:-<nessuna build completata>}' - attuale: '${DCORP:-?}'"
fi

# Immagine prodotta
check "l'image stream tag inventory:latest esiste" oc get istag inventory:latest -n "$P"
check_match "inventory:latest contiene APP_MESSAGE=Inventario S2I" "oc get istag inventory:latest -n $P -o jsonpath='{.image.dockerImageMetadata.Config.Env}'" 'APP_MESSAGE=Inventario S2I'
check_match "inventory:latest contiene APP_TIER=exam" "oc get istag inventory:latest -n $P -o jsonpath='{.image.dockerImageMetadata.Config.Env}'" 'APP_TIER=exam'

# --- Deployment --------------------------------------------------------------------------
titolo "Deployment inventory"
DINV="$(oc get istag inventory:latest -n "$P" -o jsonpath='{.image.metadata.name}' 2>/dev/null)"
check_eq "inventory ha 1 replica pronta" "oc get deploy $A -n $P -o jsonpath='{.status.readyReplicas}'" "1"
if [ -n "$DINV" ]; then
  check_match "il Deployment esegue l'immagine attuale di inventory:latest" "oc get deploy $A -n $P -o jsonpath='{.spec.template.spec.containers[0].image}'" "@${DINV}\$"
fi
oc get deploy "$A" -n "$P" >/dev/null 2>&1 && check_eq "il Deployment non definisce APP_MESSAGE né APP_TIER" "oc get deploy $A -n $P -o jsonpath='{.spec.template.spec.containers[*].env[*].name}' | tr ' ' '\n' | grep -cE '^(APP_MESSAGE|APP_TIER)$'" "0"

URL="$(route_url "$A" "$P")"
if [ -n "$URL" ]; then
  check_http "/ restituisce il messaggio Inventario S2I" "$URL/" '"message": *"Inventario S2I"'
  check_http "/env mostra APP_TIER=exam" "$URL/env" '"APP_TIER": *"exam"'
  check_http "/env mostra APP_BUILT_WITH=s2i-custom-scripts" "$URL/env" '"APP_BUILT_WITH": *"s2i-custom-scripts"'
  check_http "/build-info indica il builder personalizzato ex288" "$URL/build-info" 'builder personalizzato ex288'
  BI="$(curl -sk --max-time 10 "$URL/build-info" 2>/dev/null)"
  if printf '%s' "$BI" | grep -q '\.s2i/bin'; then
    ko "/build-info NON proviene dagli script .s2i/bin del repository" "trovato: $(printf '%s' "$BI" | head -c 120)"
  else
    ok "/build-info NON proviene dagli script .s2i/bin del repository"
  fi
else
  ko "la route inventory esiste"
fi

riepilogo
