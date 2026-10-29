#!/usr/bin/env bash
# Verifica dell'esercizio finale del modulo 04 (sola lettura).
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../lib/verifica-lib.sh"
richiedi_login

P="${LAB}-m04-exam"
PP="${LAB}-m04-exam-prod"
titolo "Modulo 04 - esercizio finale (progetti $P e $PP)"

check "il progetto $P esiste" oc get project "$P"
check "il progetto $PP esiste" oc get project "$PP"

# --- tools:httpd ------------------------------------------------------------------
titolo "Image stream tools"
check "l'image stream tag tools:httpd esiste" oc get istag tools:httpd -n "$P"
check_match "tools:httpd importato da ubi9/httpd-24" "oc get is tools -n $P -o jsonpath='{.spec.tags[?(@.name==\"httpd\")].from.name}'" 'registry\.access\.redhat\.com/ubi9/httpd-24'
check_eq "tools:httpd con import periodico" "oc get is tools -n $P -o jsonpath='{.spec.tags[?(@.name==\"httpd\")].importPolicy.scheduled}'" "true"
check_eq "tools:httpd con reference policy Local" "oc get is tools -n $P -o jsonpath='{.spec.tags[?(@.name==\"httpd\")].referencePolicy.type}'" "Local"

# --- hello ---------------------------------------------------------------------------
titolo "Image stream hello e BuildConfig"
check "BuildConfig hello esiste" oc get bc hello -n "$P"
check_eq "hello usa la strategia Docker" "oc get bc hello -n $P -o jsonpath='{.spec.strategy.type}'" "Docker"
check_match "hello:1.0 contiene APP_VERSION=1.0.0" "oc get istag hello:1.0 -n $P -o jsonpath='{.image.dockerImageMetadata.Config.Env}'" 'APP_VERSION=1\.0\.0'
check_match "hello:2.0 contiene APP_VERSION=2.0.0" "oc get istag hello:2.0 -n $P -o jsonpath='{.image.dockerImageMetadata.Config.Env}'" 'APP_VERSION=2\.0\.0'
check_match "hello:1.0 è stata prodotta dalla BuildConfig hello" "oc get istag hello:1.0 -n $P -o jsonpath='{.image.dockerImageMetadata.Config.Env}'" 'OPENSHIFT_BUILD_NAME=hello-[0-9]+'
check_match "hello:2.0 è stata prodotta dalla BuildConfig hello" "oc get istag hello:2.0 -n $P -o jsonpath='{.image.dockerImageMetadata.Config.Env}'" 'OPENSHIFT_BUILD_NAME=hello-[0-9]+'
check_eq "hello:stable è un alias (ImageStreamTag)" "oc get is hello -n $P -o jsonpath='{.spec.tags[?(@.name==\"stable\")].from.kind}'" "ImageStreamTag"
check_match "hello:stable segue hello:2.0" "oc get is hello -n $P -o jsonpath='{.spec.tags[?(@.name==\"stable\")].from.name}'" '^(hello:)?2\.0$'
check_eq "lookup locale attivo su hello" "oc get is hello -n $P -o jsonpath='{.spec.lookupPolicy.local}'" "true"

D20="$(oc get istag hello:2.0 -n "$P" -o jsonpath='{.image.metadata.name}' 2>/dev/null)"
D10="$(oc get istag hello:1.0 -n "$P" -o jsonpath='{.image.metadata.name}' 2>/dev/null)"

# --- web (exam) ----------------------------------------------------------------------
titolo "Deployment web in $P"
check_eq "web ha 2 repliche pronte" "oc get deploy web -n $P -o jsonpath='{.status.readyReplicas}'" "2"
check_eq "web ha un container chiamato web" "oc get deploy web -n $P -o jsonpath='{.spec.template.spec.containers[*].name}'" "web"
check_match "web ha un trigger su hello:stable" "oc get deploy web -n $P -o jsonpath='{.metadata.annotations.image\.openshift\.io/triggers}'" '"name":"hello:stable"'
check_match "il trigger di web aggiorna il container web" "oc get deploy web -n $P -o jsonpath='{.metadata.annotations.image\.openshift\.io/triggers}'" '@\.name==\\"web\\"'
check_eq "il trigger di web non è sospeso" "oc get deploy web -n $P -o jsonpath='{.metadata.annotations.image\.openshift\.io/triggers}' | grep -c '\"paused\":true'" "0"
if [ -n "$D20" ]; then
  check_match "web esegue l'immagine di hello:2.0 ($D20)" "oc get deploy web -n $P -o jsonpath='{.spec.template.spec.containers[0].image}'" "@${D20}\$"
fi
URL="$(route_url web "$P")"
if [ -n "$URL" ]; then
  check_http "route web ($P) risponde con version 2.0.0" "$URL/" '"version": *"2\.0\.0"'
else
  ko "route web esiste in $P"
fi

# --- prod ------------------------------------------------------------------------------
titolo "Progetto $PP"
check "l'image stream tag hello:prod esiste in $PP" oc get istag hello:prod -n "$PP"
if [ -n "$D10" ]; then
  check_eq "hello:prod ha lo stesso digest di $P/hello:1.0" "oc get istag hello:prod -n $PP -o jsonpath='{.image.metadata.name}'" "$D10"
else
  ko "hello:1.0 esiste in $P (necessario per confrontare il digest)"
fi
check_eq "web (prod) ha 1 replica pronta" "oc get deploy web -n $PP -o jsonpath='{.status.readyReplicas}'" "1"
check_eq "web (prod) ha un container chiamato web" "oc get deploy web -n $PP -o jsonpath='{.spec.template.spec.containers[*].name}'" "web"
check_match "web (prod) ha un trigger su hello:prod" "oc get deploy web -n $PP -o jsonpath='{.metadata.annotations.image\.openshift\.io/triggers}'" '"name":"hello:prod"'
check_match "il trigger di web (prod) aggiorna il container web" "oc get deploy web -n $PP -o jsonpath='{.metadata.annotations.image\.openshift\.io/triggers}'" '@\.name==\\"web\\"'
check_eq "il trigger di web (prod) non è sospeso" "oc get deploy web -n $PP -o jsonpath='{.metadata.annotations.image\.openshift\.io/triggers}' | grep -c '\"paused\":true'" "0"
URL="$(route_url web "$PP")"
if [ -n "$URL" ]; then
  check_http "route web ($PP) risponde con version 1.0.0" "$URL/" '"version": *"1\.0\.0"'
else
  ko "route web esiste in $PP"
fi
SA="system:serviceaccount:${PP}:default"
check_eq "i SA di $PP possono scaricare da $P" "oc auth can-i get imagestreams --subresource=layers -n $P --as=$SA" "yes"
check_eq "i SA di $PP NON possono pubblicare in $P" "oc auth can-i update imagestreams --subresource=layers -n $P --as=$SA" "no"

# --- legacy ------------------------------------------------------------------------------
titolo "Deployment legacy in $P"
check "Deployment legacy esiste" oc get deploy legacy -n "$P"
check_eq "legacy ha 1 replica pronta" "oc get deploy legacy -n $P -o jsonpath='{.status.readyReplicas}'" "1"
check_match "legacy ha un trigger su tools:httpd" "oc get deploy legacy -n $P -o jsonpath='{.metadata.annotations.image\.openshift\.io/triggers}'" '"name":"tools:httpd"'
TRIG="$(oc get deploy legacy -n "$P" -o jsonpath='{.metadata.annotations.image\.openshift\.io/triggers}' 2>/dev/null)"
CNAMES="$(oc get deploy legacy -n "$P" -o jsonpath='{.spec.template.spec.containers[*].name}' 2>/dev/null)"
TNAME="$(printf '%s' "$TRIG" | sed -n 's/.*@\.name==\\"\([^\\]*\)\\".*/\1/p')"
if [ -n "$TNAME" ] && printf '%s\n' $CNAMES | grep -qx -- "$TNAME"; then
  ok "il trigger di legacy aggiorna un container esistente ($TNAME)"
else
  ko "il trigger di legacy aggiorna un container esistente" "trigger sul container '${TNAME:-<nessuno>}', container del Deployment: '${CNAMES:-<nessuno>}'"
fi
check_eq "il trigger di legacy non è sospeso" "oc get deploy legacy -n $P -o jsonpath='{.metadata.annotations.image\.openshift\.io/triggers}' | grep -c '\"paused\":true'" "0"
DT="$(oc get istag tools:httpd -n "$P" -o jsonpath='{.image.metadata.name}' 2>/dev/null)"
if [ -n "$DT" ]; then
  check_match "legacy esegue l'immagine corrente di tools:httpd" "oc get deploy legacy -n $P -o jsonpath='{.spec.template.spec.containers[*].image}'" "@${DT}"
fi

riepilogo
