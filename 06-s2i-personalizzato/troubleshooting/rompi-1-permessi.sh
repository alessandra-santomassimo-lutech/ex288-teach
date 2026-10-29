#!/usr/bin/env bash
# Scenario 1 (modulo 06): l'app "t1-app", costruita con il builder "t1-builder", non si costruisce.
# Non correggere questo script: eseguilo, indaga e correggi sul cluster con oc.
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/_comune.sh"
prepara_progetto
gia_creato t1-builder m06-1
DF='FROM registry.access.redhat.com/ubi9/nodejs-22
LABEL io.openshift.s2i.scripts-url="image:///usr/libexec/s2i-t1" \
      io.openshift.tags="builder,nodejs,scenario-t1"
USER 0
RUN mkdir -p /usr/libexec/s2i-t1 && \
    printf "#!/bin/bash\necho \"---> [t1] assemble\"\nexec /usr/libexec/s2i/assemble\n" > /usr/libexec/s2i-t1/assemble && \
    printf "#!/bin/bash\nexec /usr/libexec/s2i/run\n" > /usr/libexec/s2i-t1/run
USER 1001'
crea_builder_e_app t1 m06-1 "$DF"
fine
