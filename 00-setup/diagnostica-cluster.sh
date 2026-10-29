#!/usr/bin/env bash
# Diagnostica (sola lettura) delle assunzioni che gli script del corso fanno sul cluster.
# Stampa l'output GREZZO dei comandi e il loro exit code, così puoi capire
# (o incollare a chi ti aiuta) perché un controllo non si comporta come previsto.
# Non stampa token né contenuti di Secret.
#
# Uso: bash 00-setup/diagnostica-cluster.sh > diagnostica.txt 2>&1

run() {
  echo
  echo "\$ $*"
  "$@" 2>&1 | head -40
  echo "[exit code: ${PIPESTATUS[0]}]"
}

echo "=== Diagnostica corso EX288 - $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "bash: $BASH_VERSION  sistema: $(uname -sr)"
run oc version --client
run oc whoami
run oc whoami --show-server
run oc version -o json

echo; echo "=== API OpenShift (OpenShift API server): un 503 qui indica un problema del cluster"
run oc get pods -o name
for g in image build route project template; do run sh -c "oc get --raw /apis/$g.openshift.io/v1 >/dev/null && echo risponde"; done

echo; echo "=== Discovery delle API (OpenShift Pipelines, Triggers, Operator)"
run oc api-resources --api-group=tekton.dev
run sh -c "oc api-versions | grep -E 'tekton|infinispan|image.openshift|build.openshift|template.openshift|route.openshift'"

echo; echo "=== OpenShift Pipelines"
run oc get configmap pipelines-info -n openshift-pipelines -o jsonpath='{.data.version}'
run oc auth can-i get tasks.tekton.dev -n openshift-pipelines
run oc get tasks.tekton.dev -n openshift-pipelines -o name
run oc get clustertriggerbindings.triggers.tekton.dev -o name
command -v tkn >/dev/null 2>&1 && run tkn version

echo; echo "=== Permessi dell'utente"
run oc auth can-i create projectrequests
run oc auth can-i get clusterversions.config.openshift.io

echo; echo "=== Image stream e template di esempio (Cluster Samples Operator)"
run oc get istag nodejs:22-ubi9 -n openshift -o name
run oc get templates -n openshift -o name

echo; echo "=== Storage"
run oc get storageclass

echo; echo "=== Registry interno"
run oc get route default-route -n openshift-image-registry -o jsonpath='{.spec.host}'

echo; echo "=== Strumenti locali"
for t in helm tkn git podman jq curl python3; do
  printf '%-8s ' "$t"; command -v "$t" || echo "(assente)"
done
command -v helm >/dev/null 2>&1 && run helm version --short
echo; echo "=== Fine diagnostica"
