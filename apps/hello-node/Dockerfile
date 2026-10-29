# Dockerfile per hello-node (usato con la strategia Docker nei moduli 02, 03, 05).
# Segue le linee guida OpenShift per le immagini (docs OCP 4.22, Images > Creating images):
#  - nessun processo in ascolto su porte < 1024
#  - file scrivibili dal gruppo root (GID 0), perché OpenShift esegue il container
#    con un UID arbitrario che appartiene sempre al gruppo 0
#  - un solo processo, log su stdout

FROM registry.access.redhat.com/ubi9/nodejs-22-minimal

# Metadati utili in OpenShift (mostrati nel catalogo e da `oc describe istag`)
LABEL io.k8s.description="hello-node: app didattica EX288" \
      io.k8s.display-name="hello-node" \
      io.openshift.tags="nodejs,ex288"

WORKDIR /opt/app-root/src

# Copia il codice assegnando il gruppo 0 (root group), non l'utente root
COPY --chown=1001:0 package.json server.js test.js ./

# Directory dati scrivibile da qualunque UID del gruppo 0
USER 0
RUN mkdir -p /opt/app-root/data && \
    chgrp -R 0 /opt/app-root/data /opt/app-root/src && \
    chmod -R g=u /opt/app-root/data /opt/app-root/src
USER 1001

ENV PORT=8080 \
    DATA_DIR=/opt/app-root/data

EXPOSE 8080

CMD ["node", "server.js"]
