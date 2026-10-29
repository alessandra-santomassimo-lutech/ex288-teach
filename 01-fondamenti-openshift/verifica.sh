#!/usr/bin/env bash
# Verifica dell'esercizio finale del modulo 01 (sola lettura).
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../lib/verifica-lib.sh"
richiedi_login

P="${LAB}-m01-exam"

# check_label "descrizione" <deployment> <jsonpath> <valore-atteso> "suggerimento"
check_label() {
  local val
  val="$(oc get deploy "$2" -n "$P" -o jsonpath="$3" 2>/dev/null)"
  if [ "$val" = "$4" ]; then ok "$1"; else ko "$1" "trovato: '${val:-<assente>}' - $5"; fi
}
titolo "Modulo 01 - esercizio finale (progetto $P)"

check "il progetto $P esiste" oc get project "$P"
check_eq "display name 'Negozio online'" "oc get project $P -o jsonpath='{.metadata.annotations.openshift\.io/display-name}'" "Negozio online"

# storefront
check "deployment storefront esiste" oc get deploy storefront -n "$P"
check_match "storefront usa l'immagine ubi9/httpd-24" "oc get deploy storefront -n $P -o jsonpath='{.spec.template.spec.containers[*].image}'" 'ubi9/httpd-24'
check_eq "storefront ha 3 repliche pronte" "oc get deploy storefront -n $P -o jsonpath='{.status.readyReplicas}'" "3"
check_eq "il deployment storefront ha label tier=frontend" "oc get deploy storefront -n $P -o jsonpath='{.metadata.labels.tier}'" "frontend"
check_label "i pod di storefront (template) hanno label tier=frontend" storefront '{.spec.template.metadata.labels.tier}' frontend \
  "la label va anche in spec.template.metadata.labels: 'oc label deployment' agisce solo sui metadati del Deployment"
check_eq "il Service storefront ha 3 endpoint" "oc get endpoints storefront -n $P -o jsonpath='{range .subsets[*].addresses[*]}{.ip}{\"\\n\"}{end}' | grep -c ." "3"

# route
check "route storefront esiste" oc get route storefront -n "$P"
check_eq "route storefront con terminazione edge" "oc get route storefront -n $P -o jsonpath='{.spec.tls.termination}'" "edge"
check_eq "nessun'altra route punta a storefront in HTTP" "oc get route -n $P -o jsonpath='{range .items[?(@.spec.to.name==\"storefront\")]}{.spec.tls.termination}{\"\\n\"}{end}' | grep -vc edge" "0"
URL="$(route_url storefront "$P")"
if [ -n "$URL" ]; then
  code="$(curl -sk --max-time 10 -o /dev/null -w '%{http_code}' "$URL")"
  case "$code" in 200|403) ok "storefront risponde via HTTPS ($code)";; *) ko "storefront risponde via HTTPS" "HTTP $code su $URL";; esac
fi

# inventory
check "deployment inventory esiste" oc get deploy inventory -n "$P"
check_eq "inventory ha 1 replica pronta" "oc get deploy inventory -n $P -o jsonpath='{.status.readyReplicas}'" "1"
check_label "il deployment inventory ha label tier=backend" inventory '{.metadata.labels.tier}' backend \
  "manca la label nei metadati del Deployment (es. oc label deployment)"
check_label "i pod di inventory (template) hanno label tier=backend" inventory '{.spec.template.metadata.labels.tier}' backend \
  "la label va anche in spec.template.metadata.labels: 'oc label deployment' agisce solo sui metadati del Deployment"
check_match "il Service inventory espone la porta 8080" "oc get svc inventory -n $P -o jsonpath='{.spec.ports[*].port}'" '(^| )8080( |$)'
check_eq "il Service inventory ha 1 endpoint" "oc get endpoints inventory -n $P -o jsonpath='{range .subsets[*].addresses[*]}{.ip}{\"\\n\"}{end}' | grep -c ." "1"
check_eq "nessuna route verso inventory" "oc get route -n $P -o jsonpath='{range .items[?(@.spec.to.name==\"inventory\")]}{.metadata.name}{\"\\n\"}{end}' | grep -c ." "0"

# auditor
check "service account auditor esiste" oc get sa auditor -n "$P"
check_eq "auditor può leggere i pod" "oc auth can-i get pods -n $P --as=system:serviceaccount:$P:auditor" "yes"
check_eq "auditor NON può cancellare i pod" "oc auth can-i delete pods -n $P --as=system:serviceaccount:$P:auditor" "no"

riepilogo
