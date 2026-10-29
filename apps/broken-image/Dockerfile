# ATTENZIONE: Dockerfile VOLUTAMENTE SBAGLIATO (modulo 03, troubleshooting).
# Funziona con `podman run` sul tuo PC (dove gira come UID 1001 o root),
# ma in OpenShift il pod va in CrashLoopBackOff. Trova il perché e correggilo
# seguendo le linee guida "Support arbitrary user ids" della documentazione.
FROM registry.access.redhat.com/ubi9/nodejs-22-minimal

USER 0
WORKDIR /opt/app-root/src
COPY package.json server.js ./
RUN mkdir -p /opt/app-root/data && chown 1001:1001 /opt/app-root/data && chmod 700 /opt/app-root/data

USER 1001
ENV PORT=8080 \
    DATA_DIR=/opt/app-root/data
EXPOSE 8080
CMD ["node", "server.js"]
