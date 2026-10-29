#!/usr/bin/env bash
# Controllo dell'ambiente di laboratorio (sola lettura).
# Uso: bash 00-setup/controlla-ambiente.sh

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../lib/verifica-lib.sh"
# shellcheck disable=SC1091
[ -f "$HERE/../env.sh" ] && source "$HERE/../env.sh"

titolo "Strumenti locali"
for t in oc helm tkn git curl; do
  if command -v "$t" >/dev/null 2>&1; then ok "$t presente ($(command -v "$t"))"; else ko "$t non trovato" "installalo (vedi README del modulo 00)"; fi
done
if command -v podman >/dev/null 2>&1; then ok "podman presente (opzionale)"; else info "podman non trovato: è opzionale (solo parte del modulo 03)"; fi
if command -v jq >/dev/null 2>&1; then ok "jq presente"; else info "jq non trovato: opzionale ma comodo"; fi

titolo "Cluster"
if ! oc whoami >/dev/null 2>&1; then
  ko "login al cluster" "esegui 'oc login' e rilancia lo script"
  riepilogo; exit 1
fi
ok "autenticata come $(oc whoami) su $(oc whoami --show-server)"
SERVER_VER="$(oc version -o json 2>/dev/null | grep -o '"openshiftVersion": *"[^"]*"' | cut -d'"' -f4)"
if [ -n "$SERVER_VER" ]; then
  ok "versione OpenShift del cluster: $SERVER_VER"
  case "$SERVER_VER" in 4.22*) ;; *) info "l'esame attuale è basato su OCP 4.22: con $SERVER_VER alcuni dettagli possono differire (vedi docs/versioni-e-differenze.md)";; esac
else
  # Gli utenti non amministratori spesso non possono leggere la ClusterVersion:
  # in quel caso oc mostra solo la versione Kubernetes (1.35 = OpenShift 4.22).
  KUBE_VER="$(oc version -o json 2>/dev/null | tr -d '\n' | grep -o '"serverVersion": *{[^}]*}' | grep -o '"gitVersion": *"[^"]*"' | cut -d'"' -f4)"
  if [ -n "$KUBE_VER" ]; then
    info "versione OpenShift non leggibile con il tuo utente; versione Kubernetes del server: $KUBE_VER (OpenShift 4.22 = Kubernetes 1.35)"
  else
    info "versione del server non leggibile (permessi limitati): esegui 'oc version'"
  fi
fi
if [ "$(oc whoami)" = "kube:admin" ]; then info "sei kube:admin: per i lab usa un utente normale, come all'esame"; fi
check_eq "puoi creare progetti (oc auth can-i create projectrequests)" "oc auth can-i create projectrequests" "yes"

titolo "API OpenShift (servite dall'OpenShift API server)"
# Le API image/build/route/project/template non sono servite dal kube-apiserver ma
# dall'OpenShift API server: se è giù rispondono 503 ServiceUnavailable, mentre
# pod e deployment continuano a funzionare. Gli endpoint di discovery sono
# leggibili da qualunque utente autenticato.
for g in image build route project template apps; do
  err="$(oc get --raw "/apis/$g.openshift.io/v1" 2>&1 >/dev/null)"
  if [ -z "$err" ]; then
    ok "$g.openshift.io/v1 risponde"
  elif grep -Eqi 'ServiceUnavailable|unable to handle the request|503' <<<"$err"; then
    ko "$g.openshift.io/v1 risponde" "503 ServiceUnavailable: l'OpenShift API server non è disponibile (aggiornamento o problema del cluster). Riprova tra qualche minuto; se persiste avvisa l'amministratore (oc get clusteroperator openshift-apiserver)"
  else
    ko "$g.openshift.io/v1 risponde" "$(head -c 200 <<<"$err")"
  fi
done

titolo "Variabili env.sh"
if [ -n "${LAB:-}" ] && [ "${LAB}" != "cambiami" ]; then ok "LAB=$LAB"; else ko "LAB non impostata" "cp env.example.sh env.sh, modifica e 'source env.sh' dalla root del repository ex288-teach"; fi
if [ -n "${GIT_REPO:-}" ] && ! printf '%s' "$GIT_REPO" | grep -q '<tuo-utente>'; then
  ok "GIT_REPO=$GIT_REPO"
  check "repository Git raggiungibile dalla postazione (git ls-remote)" git ls-remote --exit-code "$GIT_REPO" "${GIT_BRANCH:-main}"
else
  ko "GIT_REPO non impostata" "crea il repo delle app (passo 3) e imposta GIT_REPO in env.sh"
fi

titolo "Image stream builder (namespace openshift)"
if oc get istag -n openshift nodejs:22-ubi9 >/dev/null 2>&1; then
  ok "openshift/nodejs:22-ubi9 disponibile: puoi usare 'nodejs:22-ubi9' come builder"
elif oc get is -n openshift nodejs >/dev/null 2>&1; then
  info "image stream openshift/nodejs presente, tag disponibili: $(oc get is nodejs -n openshift -o jsonpath='{range .spec.tags[*]}{.name}{" "}{end}')"
else
  info "nessun image stream openshift/nodejs (Cluster Samples Operator deprecato o disabilitato): nei moduli importerai il builder nel tuo progetto con 'oc import-image'"
fi

titolo "OpenShift Pipelines"
# Rilevamento tramite "oc api-versions": non richiede permessi particolari e
# non dipende dal formato a colonne di "oc api-resources" (che su molti cluster
# termina con exit code 1 per un gruppo API aggregato non raggiungibile).
if api_disponibile tekton.dev/v1; then
  ok "API Tekton servite dal cluster (tekton.dev: $(versioni_api tekton.dev))"

  TK_VER="$(oc get configmap pipelines-info -n openshift-pipelines -o jsonpath='{.data.version}' 2>/dev/null)"
  [ -n "$TK_VER" ] && ok "versione del componente Tekton Pipelines: $TK_VER"

  TASK_ERR="$(oc get task git-clone -n openshift-pipelines -o name 2>&1 >/dev/null)"
  if [ -z "$TASK_ERR" ]; then
    ok "Task fornite dall'Operator leggibili in openshift-pipelines (git-clone, buildah, openshift-client, ...)"
  elif grep -qi 'forbidden' <<<"$TASK_ERR"; then
    info "le Task in openshift-pipelines esistono ma il tuo utente non può leggerle: le pipeline funzionano comunque (le risolve il cluster resolver), ma i parametri delle Task li trovi nella documentazione di OpenShift Pipelines (tabelle delle Task fornite); per leggerli dal cluster chiedi all'amministratore il ruolo view su openshift-pipelines"
  elif grep -Eqi 'not ?found' <<<"$TASK_ERR"; then
    ko "Task git-clone non trovata in openshift-pipelines" "Pipelines precedente alla 1.17 (usa ancora i ClusterTask) oppure profilo 'lite': chiedi all'amministratore Pipelines 1.22-1.24 con profilo 'all'"
  else
    info "impossibile leggere le Task in openshift-pipelines: $(head -c 200 <<<"$TASK_ERR")"
  fi

  TRIG="$(versioni_api triggers.tekton.dev)"
  if [ -n "$TRIG" ]; then
    ok "API Tekton Triggers servite: $TRIG (i manifest del modulo 12 usano v1beta1)"
    grep -qw v1beta1 <<<"$TRIG" || ko "triggers.tekton.dev/v1beta1 non servita" "adatta l'apiVersion dei manifest Triggers del modulo 12 a una di: $TRIG"
  else
    ko "API Tekton Triggers non servite" "il componente Triggers non è installato (profilo 'lite'?): serve per la parte EventListener dei moduli 12 e 14"
  fi
else
  ko "OpenShift Pipelines non rilevato (API tekton.dev/v1 assente)" "verifica con 'oc api-versions | grep tekton'; se l'Operator è appena stato installato attendi qualche minuto che crei le CRD"
fi

titolo "Storage"
SC_DEFAULT="$(oc get storageclass -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{" "}{end}' 2>/dev/null)"
if [ -n "$SC_DEFAULT" ]; then
  ok "StorageClass di default: $SC_DEFAULT (serve per i workspace delle pipeline e i PVC)"
elif oc get storageclass >/dev/null 2>&1; then
  ko "nessuna StorageClass di default" "i volumeClaimTemplate del modulo 12 e i PVC dei moduli 08-11 resteranno Pending: chiedi all'amministratore"
else
  info "StorageClass non leggibili con il tuo utente: verificherai creando un PVC nel modulo 08"
fi

titolo "Operator utilizzabili (modulo 13)"
if api_disponibile infinispan.org/v1; then
  ok "API infinispan.org/v1 servita: Red Hat Data Grid è installato (esempio guidato del modulo 13)"
else
  info "API di Red Hat Data Grid (infinispan.org/v1) non presente: nel modulo 13 userai la procedura generale con un altro Operator"
fi
CSV="$(oc get csv -n openshift --no-headers 2>/dev/null | awk '{print $1}' | head -20)"
if [ -n "$CSV" ]; then
  ok "ClusterServiceVersion visibili nel namespace openshift (Operator installati in All namespaces):"
  printf '%s\n' "$CSV" | sed 's/^/         - /'
else
  info "nessuna CSV visibile in 'openshift': verificherai gli Operator disponibili nel tuo progetto nel modulo 13"
fi

titolo "Registry interno"
if oc get route default-route -n openshift-image-registry >/dev/null 2>&1; then
  ok "route del registry esposta: $(oc get route default-route -n openshift-image-registry -o jsonpath='{.spec.host}')"
else
  info "route del registry non esposta o non visibile: nel modulo 03 userai le build binarie al posto di 'podman push'"
fi

riepilogo
