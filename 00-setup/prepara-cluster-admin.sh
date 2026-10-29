#!/usr/bin/env bash
# Prepara un cluster per il corso EX288. DA ESEGUIRE COME CLUSTER-ADMIN
# (su OpenShift Local: utente kubeadmin; su un cluster aziendale: l'amministratore).
#
# Uso:
#   bash 00-setup/prepara-cluster-admin.sh [opzioni]
#
# Opzioni (senza opzioni equivale a --pipelines --registry):
#   --pipelines          installa Red Hat OpenShift Pipelines (moduli 12 e 14)
#   --registry           espone la route di default del registry interno (modulo 03, passo 3.7)
#   --datagrid           installa Red Hat Data Grid in "All namespaces" (esempio del modulo 13)
#   --developer-console  abilita la prospettiva Developer della web console
#   --all                tutte le opzioni precedenti
#
# Lo script è idempotente: puoi rilanciarlo. Usa il canale di default di ogni Operator
# letto dal catalogo del cluster (oc get packagemanifest), quindi non dipende da versioni
# scritte qui dentro.

set -uo pipefail

DO_PIPELINES=0; DO_REGISTRY=0; DO_DATAGRID=0; DO_DEVCONSOLE=0
[ $# -eq 0 ] && { DO_PIPELINES=1; DO_REGISTRY=1; }
for a in "$@"; do
  case "$a" in
    --pipelines) DO_PIPELINES=1 ;;
    --registry) DO_REGISTRY=1 ;;
    --datagrid) DO_DATAGRID=1 ;;
    --developer-console) DO_DEVCONSOLE=1 ;;
    --all) DO_PIPELINES=1; DO_REGISTRY=1; DO_DATAGRID=1; DO_DEVCONSOLE=1 ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) echo "Opzione sconosciuta: $a (usa --help)" >&2; exit 1 ;;
  esac
done

msg()  { printf '\n==> %s\n' "$*"; }
fail() { printf 'ERRORE: %s\n' "$*" >&2; exit 1; }

oc whoami >/dev/null 2>&1 || fail "non sei autenticato: esegui 'oc login' come cluster-admin"
[ "$(oc auth can-i '*' '*' --all-namespaces 2>/dev/null)" = "yes" ] \
  || fail "l'utente $(oc whoami) non è cluster-admin. Su OpenShift Local usa kubeadmin (crc console --credentials)."

# install_operator <package> <nome-subscription>: Subscription nel namespace
# openshift-operators (OperatorGroup globale = modalità "All namespaces").
install_operator() {
  local pkg="$1" sub="$2" channel csv i
  if ! oc get packagemanifest "$pkg" -n openshift-marketplace >/dev/null 2>&1; then
    fail "pacchetto '$pkg' non presente nel catalogo (cluster disconnesso o catalogo redhat-operators non disponibile)"
  fi
  channel="$(oc get packagemanifest "$pkg" -n openshift-marketplace -o jsonpath='{.status.defaultChannel}')"
  echo "    pacchetto $pkg, canale di default: $channel"
  oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${sub}
  namespace: openshift-operators
spec:
  channel: ${channel}
  name: ${pkg}
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF
  echo "    attendo che l'Operator sia installato (max 10 minuti)..."
  for i in $(seq 1 60); do
    csv="$(oc get subscription "$sub" -n openshift-operators -o jsonpath='{.status.installedCSV}' 2>/dev/null)"
    if [ -n "$csv" ] && [ "$(oc get csv "$csv" -n openshift-operators -o jsonpath='{.status.phase}' 2>/dev/null)" = "Succeeded" ]; then
      echo "    OK: $csv Succeeded"; return 0
    fi
    sleep 10
  done
  fail "timeout: controlla con 'oc get subscription,installplan,csv -n openshift-operators'"
}

if [ "$DO_PIPELINES" = 1 ]; then
  msg "Red Hat OpenShift Pipelines"
  install_operator openshift-pipelines-operator-rh openshift-pipelines-operator-rh
  echo "    attendo le Task fornite in openshift-pipelines (git-clone, buildah, ...)"
  for i in $(seq 1 60); do
    oc get task git-clone -n openshift-pipelines >/dev/null 2>&1 && { echo "    OK: Task disponibili"; break; }
    sleep 10
  done
  oc get task git-clone -n openshift-pipelines >/dev/null 2>&1 || echo "    ATTENZIONE: Task non ancora presenti, ricontrolla tra qualche minuto"
fi

if [ "$DO_REGISTRY" = 1 ]; then
  msg "Route di default del registry interno"
  oc patch configs.imageregistry.operator.openshift.io/cluster --type=merge \
    -p '{"spec":{"defaultRoute":true}}'
  for i in $(seq 1 30); do
    HOST="$(oc get route default-route -n openshift-image-registry -o jsonpath='{.spec.host}' 2>/dev/null)"
    [ -n "$HOST" ] && break; sleep 5
  done
  echo "    route del registry: ${HOST:-<non ancora creata>}"
fi

if [ "$DO_DATAGRID" = 1 ]; then
  msg "Red Hat Data Grid (modulo 13)"
  install_operator datagrid datagrid
fi

if [ "$DO_DEVCONSOLE" = 1 ]; then
  msg "Prospettiva Developer della web console"
  oc patch console.operator.openshift.io/cluster --type=merge \
    -p '{"spec":{"customization":{"perspectives":[{"id":"dev","visibility":{"state":"Enabled"}}]}}}'
  echo "    la console si ricarica entro qualche minuto"
fi

msg "Fatto. Ora esegui il login con l'utente dei laboratori (non cluster-admin) e lancia:"
echo "    bash 00-setup/controlla-ambiente.sh"
