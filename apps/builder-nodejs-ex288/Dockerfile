# Builder S2I personalizzato (modulo 06): parte dal builder UBI Node.js 22
# ufficiale e ne sostituisce gli script S2I tramite la label
# io.openshift.s2i.scripts-url (docs OCP 4.22, Builds using BuildConfig > S2I).
FROM registry.access.redhat.com/ubi9/nodejs-22

LABEL io.k8s.description="Builder S2I Node.js 22 personalizzato per il corso EX288" \
      io.k8s.display-name="Node.js 22 (ex288)" \
      io.openshift.tags="builder,nodejs,ex288" \
      io.openshift.s2i.scripts-url="image:///usr/libexec/s2i-ex288"

USER 0
COPY s2i/bin/ /usr/libexec/s2i-ex288/
RUN chmod 0755 /usr/libexec/s2i-ex288/*
USER 1001
