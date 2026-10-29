#!/usr/bin/env bash
# Scenario 3 (modulo 06): l'app "t3-app" funziona, ma qualcosa non va quando il pod si ferma.
# Dopo la build di t3-app esegui:  oc new-app --image-stream=t3-app --name=t3-app -l scenario=m06-3
# Non correggere questo script: eseguilo, indaga e correggi sul cluster con oc.
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/_comune.sh"
prepara_progetto
gia_creato t3-builder m06-3
DF='FROM registry.access.redhat.com/ubi9/nodejs-22
LABEL io.openshift.s2i.scripts-url="image:///usr/libexec/s2i-t3" \
      io.openshift.tags="builder,nodejs,scenario-t3"
USER 0
RUN mkdir -p /usr/libexec/s2i-t3 && \
    printf "#!/bin/bash\nexec /usr/libexec/s2i/assemble\n" > /usr/libexec/s2i-t3/assemble && \
    printf "#!/bin/bash\necho \"---> [t3] avvio applicazione\"\n/usr/libexec/s2i/run\necho \"---> [t3] applicazione terminata\"\n" > /usr/libexec/s2i-t3/run && \
    chmod 0755 /usr/libexec/s2i-t3/*
USER 1001'
crea_builder_e_app t3 m06-3 "$DF"
fine
echo "Quando t3-app:latest esiste: oc new-app --image-stream=t3-app --name=t3-app -l scenario=m06-3"
