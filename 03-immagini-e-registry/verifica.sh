#!/usr/bin/env bash
# Verifica dell'esercizio finale del modulo 03 (sola lettura).
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../lib/verifica-lib.sh"
richiedi_login

P1="${LAB}-m03-exam"
P2="${LAB}-m03-exam-run"
INT="image-registry.openshift-image-registry.svc:5000"
SA="system:serviceaccount:${P2}:default"
titolo "Modulo 03 - esercizio finale (progetti $P1 e $P2)"

check "il progetto $P1 esiste" oc get project "$P1"
check "il progetto $P2 esiste" oc get project "$P2"

# --- Build e immagine ---------------------------------------------------------
titolo "Build e immagine in $P1"
check "BuildConfig hello-exam esiste" oc get bc hello-exam -n "$P1"
check_eq "hello-exam usa la strategia Docker" "oc get bc hello-exam -n $P1 -o jsonpath='{.spec.strategy.type}'" "Docker"
check "l'image stream tag hello-exam:1.0 esiste" oc get istag hello-exam:1.0 -n "$P1"
check_eq "l'immagine ha USER 1001" "oc get istag hello-exam:1.0 -n $P1 -o jsonpath='{.image.dockerImageMetadata.Config.User}'" "1001"
check_match "label io.openshift.tags contiene ex288-exam" "oc get istag hello-exam:1.0 -n $P1 -o jsonpath='{.image.dockerImageMetadata.Config.Labels.io\.openshift\.tags}'" 'ex288-exam'
check_match "l'immagine ha DATA_DIR=/opt/app-root/cache" "oc get istag hello-exam:1.0 -n $P1 -o jsonpath='{.image.dockerImageMetadata.Config.Env}'" 'DATA_DIR=/opt/app-root/cache'
check_match "l'immagine ha APP_MESSAGE=Immagine esame m03" "oc get istag hello-exam:1.0 -n $P1 -o jsonpath='{.image.dockerImageMetadata.Config.Env}'" 'APP_MESSAGE=Immagine esame m03'
check_match "l'immagine deriva da ubi9/nodejs-22-minimal (label ereditate dalla base)" "oc get istag hello-exam:1.0 -n $P1 -o jsonpath='{.image.dockerImageMetadata.Config.Labels}'" 'nodejs-22-minimal'
LASTV="$(oc get bc hello-exam -n "$P1" -o jsonpath='{.status.lastVersion}' 2>/dev/null)"
if [ -n "$LASTV" ] && [ "$LASTV" != "0" ]; then
  check_eq "l'ultima build hello-exam-$LASTV è Complete" "oc get build hello-exam-$LASTV -n $P1 -o jsonpath='{.status.phase}'" "Complete"
fi

# --- Deployment nel secondo progetto -----------------------------------------
titolo "Deployment in $P2"
check "Deployment hello-exam esiste" oc get deploy hello-exam -n "$P2"
check_match "usa l'immagine $INT/$P1/hello-exam:1.0" "oc get deploy hello-exam -n $P2 -o jsonpath='{.spec.template.spec.containers[0].image}'" "^${INT//./\\.}/${P1}/hello-exam:1\\.0\$"
check_eq "2 repliche pronte" "oc get deploy hello-exam -n $P2 -o jsonpath='{.status.readyReplicas}'" "2"
# I pod devono eseguire l'immagine ATTUALE di hello-exam:1.0 (dopo una nuova build il tag
# punta a un nuovo digest; con un tag diverso da "latest" la pull policy di default è
# IfNotPresent e un nodo può riusare la copia vecchia in cache).
DIG="$(oc get istag hello-exam:1.0 -n "$P1" -o jsonpath='{.image.metadata.name}' 2>/dev/null)"
IDS="$(oc get pods -n "$P2" -l app=hello-exam --field-selector=status.phase=Running -o jsonpath='{range .items[*]}{.status.containerStatuses[0].imageID}{"\n"}{end}' 2>/dev/null)"
if [ -n "$DIG" ] && [ -n "$IDS" ] && ! grep -qv -- "$DIG" <<<"$IDS"; then
  ok "i pod eseguono il digest attuale di hello-exam:1.0 (${DIG:7:12})"
else
  ko "i pod eseguono il digest attuale di hello-exam:1.0" "atteso ${DIG:-<istag non trovato>}; nei pod: $(tr '\n' ' ' <<<"${IDS:-<nessun pod Running>}" | head -c 200) - dopo una nuova build i pod vanno ricreati e devono riscaricare l'immagine (imagePullPolicy)"
fi
check_eq "i pod hanno la label app=hello-exam" "oc get deploy hello-exam -n $P2 -o jsonpath='{.spec.template.metadata.labels.app}'" "hello-exam"
check_eq "nessun image stream in $P2" "oc get is -n $P2 -o name | grep -c ." "0"
check_match "i pod girano con la SCC restricted-v2" "oc get pods -n $P2 -l app=hello-exam -o jsonpath='{.items[*].metadata.annotations.openshift\.io/scc}'" '^restricted-v2( restricted-v2)*$'
check_match "i log confermano DATA_DIR scrivibile con UID arbitrario" "oc logs deploy/hello-exam -n $P2 --tail=-1" 'DATA_DIR /opt/app-root/cache scrivibile'
check_match "il processo NON gira come UID 1001 né come root" "oc logs deploy/hello-exam -n $P2 --tail=-1 | grep -o 'uid=[0-9]*' | head -1" '^uid=([2-9][0-9]{3,}|1[0-9]{4,})$'

# --- Permessi minimi ----------------------------------------------------------
titolo "Permessi del service account default di $P2 su $P1"
_prima=$_FAIL
check_eq "può scaricare le immagini (get imagestreams, subresource layers)" "oc auth can-i get imagestreams --subresource=layers -n $P1 --as=$SA" "yes"
if [ "$_FAIL" -gt "$_prima" ]; then
  info "rolebinding presenti in $P1 (ruolo -> soggetti). Il soggetto atteso è il service account '$P2/default' (o il gruppo system:serviceaccounts:$P2):"
  oc get rolebindings -n "$P1" -o jsonpath='{range .items[*]}{.roleRef.name}{" -> "}{range .subjects[*]}{.kind}:{.namespace}/{.name}{"  "}{end}{"\n"}{end}' 2>/dev/null \
    | grep -Ei 'image-puller|registry-|image-builder' | sed 's/^/         /'
fi
check_eq "NON può pubblicare immagini (update imagestreams, subresource layers)" "oc auth can-i update imagestreams --subresource=layers -n $P1 --as=$SA" "no"
check_eq "NON può creare Deployment in $P1" "oc auth can-i create deployments -n $P1 --as=$SA" "no"
check_eq "NON può modificare BuildConfig in $P1" "oc auth can-i update buildconfigs -n $P1 --as=$SA" "no"

# --- Route --------------------------------------------------------------------
titolo "Route"
URL="$(route_url hello-exam "$P2")"
if [ -n "$URL" ]; then
  check_eq "la route hello-exam è HTTP (senza TLS)" "oc get route hello-exam -n $P2 -o jsonpath='{.spec.tls.termination}'" ""
  check_http "la route risponde con 'Immagine esame m03'" "$URL/" '"message": *"Immagine esame m03"'
else
  ko "route hello-exam esiste in $P2"
fi

riepilogo
