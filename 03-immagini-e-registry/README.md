# Modulo 03 — Immagini container e registry interno

> **Obiettivi EX288 coperti**
> - *Work with container images in OpenShift Container Platform* → Understand how to create container images based on pre-built images
> - *Work with container images in OpenShift Container Platform* → "Publish container images to a the OpenShift image registry" (testo ufficiale riportato così com'è, refuso incluso)
> - *Work with Red Hat OpenShift Container Platform* → Configure the OpenShift internal registry to meet specific requirements
>
> **Durata stimata:** 4-5 ore · **Prerequisiti:** moduli 01 e 02 · **Richiede cluster-admin:** no (l'esposizione della route del registry, sezione 3.7, è un'attività dell'amministratore ed è opzionale)
>
> **Progetti usati:** `${LAB}-m03`, `${LAB}-m03-run`, `${LAB}-m03-other` (troubleshooting), `${LAB}-m03-exam`, `${LAB}-m03-exam-run`

---

## 1. Perché e quando

In OpenShift quasi mai si parte da zero: si **estende** un'immagine Red Hat già pronta (UBI) e la si pubblica nel **registry interno** del cluster, da cui i pod la scaricano. Le decisioni da prendere:

| Ti serve… | Scelta | Perché |
|---|---|---|
| Un'immagine con runtime già pronto (Node.js, httpd…) | Immagine **UBI** (`ubi9/nodejs-22`, `ubi9/nodejs-22-minimal`, `ubi9/httpd-24`) + `FROM` | Supportate, aggiornate da Red Hat, già conformi alle regole OpenShift (UID non root, gruppo 0) |
| Solo runtime, immagine piccola | Variante `-minimal` | Niente compilatori né tool di build: superficie d'attacco e dimensioni ridotte |
| Costruire l'immagine senza Docker/Podman sul PC | **Build binaria Docker** nel cluster (`oc new-build --binary` + `oc start-build --from-dir`) | Funziona per utenti normali, non richiede accesso al registry dall'esterno |
| Costruire da Git automaticamente | BuildConfig da Git (modulo 02) | Trigger, webhook, storia delle build |
| Caricare un'immagine costruita sul PC | `podman push` sulla route del registry | Solo se l'amministratore ha esposto il registry (`defaultRoute`) |
| Far usare a un progetto le immagini di un altro | Ruolo `system:image-puller` | Permesso minimo: solo lettura dei layer |
| Scaricare da un registry esterno privato | Pull secret (`oc create secret docker-registry` + `oc secrets link`) | Il nodo deve autenticarsi verso quel registry |
| Usare `nome:tag` di un image stream in un Deployment | `oc set image-lookup` | Senza, `nome:tag` viene cercato su un registry esterno |

---

## 2. Concetti essenziali

### 2.1 Le regole OpenShift per le immagini

OpenShift esegue i container con la SCC `restricted-v2`: **UID arbitrario** (es. `1000680000`), sempre membro del **gruppo 0 (root)**, mai root. Le linee guida Red Hat (Images → *Creating images*) si riassumono così:

| Regola | Come la rispetti nel Dockerfile | Cosa succede se la ignori |
|---|---|---|
| Supporta UID arbitrari | File e directory scrivibili dal **gruppo 0**: `chgrp -R 0 <dir> && chmod -R g=u <dir>` | `EACCES` / `Permission denied` → CrashLoopBackOff |
| Non usare porte < 1024 | `EXPOSE 8080`, l'app ascolta su 8080 | Il bind fallisce (serve privilegio) |
| Un processo per container | `CMD ["node","server.js"]`, `exec` negli script wrapper | Segnali (SIGTERM) persi, zombie |
| Log su stdout/stderr | Niente file di log | `oc logs` non mostra nulla |
| Metadati | `LABEL io.k8s.description=... io.openshift.tags=...` | Nessun errore, ma catalogo e `oc describe` meno utili |
| Utente numerico | `USER 1001` (non un nome) | Le build S2I con builder senza USER numerico falliscono |
| Niente segreti nell'immagine | Credenziali via Secret (modulo 07) | Chiunque possa scaricare l'immagine le legge |

`chmod g=u` significa "dai al gruppo gli stessi permessi del proprietario": se il proprietario (1001) può scrivere, potrà farlo anche qualunque UID del gruppo 0.

### 2.2 Il Dockerfile di `hello-node`, riga per riga

```dockerfile
FROM registry.access.redhat.com/ubi9/nodejs-22-minimal      # (1) immagine base pronta: solo runtime Node.js 22

LABEL io.k8s.description="hello-node: app didattica EX288" \
      io.k8s.display-name="hello-node" \
      io.openshift.tags="nodejs,ex288"                       # (2) metadati letti da OpenShift

WORKDIR /opt/app-root/src                                    # (3) directory di lavoro standard delle UBI

COPY --chown=1001:0 package.json server.js test.js ./        # (4) file di proprietà 1001, GRUPPO 0

USER 0                                                       # (5) root solo per preparare i permessi
RUN mkdir -p /opt/app-root/data && \
    chgrp -R 0 /opt/app-root/data /opt/app-root/src && \
    chmod -R g=u /opt/app-root/data /opt/app-root/src        # (6) la regola d'oro degli UID arbitrari
USER 1001                                                    # (7) si torna a un utente NON root, numerico

ENV PORT=8080 \
    DATA_DIR=/opt/app-root/data                              # (8) configurazione di default

EXPOSE 8080                                                  # (9) porta > 1024; oc new-app la usa per il Service

CMD ["node", "server.js"]                                    # (10) un solo processo, forma exec (riceve SIGTERM)
```

1. `FROM` estende un'immagine Red Hat: eredita utente 1001, `/opt/app-root`, Node.js.
2. `io.k8s.description` e `io.openshift.tags` sono label documentate per le immagini OpenShift.
3. `WORKDIR` crea la directory (se manca) e la rende quella corrente.
4. `--chown=1001:0` evita file di proprietà di root dopo la copia.
5. Le immagini UBI girano come 1001: per `mkdir`/`chgrp` in posizioni di sistema serve temporaneamente root.
6. `DATA_DIR` deve essere scrivibile **da qualsiasi UID del gruppo 0**: all'avvio `server.js` ci scrive un file di prova e termina con errore se non ci riesce.
7. `USER 1001`: in OpenShift verrà comunque sostituito da un UID arbitrario, ma con Podman/Docker l'immagine non gira come root.
8. Le variabili `ENV` possono essere sovrascritte dal Deployment (`oc set env`).
9. `EXPOSE` è documentazione per gli umani **e** per `oc new-app`, che crea il Service con quelle porte.
10. Forma *exec* (array JSON): `node` è il PID 1 e riceve direttamente i segnali.

### 2.3 Registry interno e image stream

```
 BuildConfig ──push──▶ image-registry.openshift-image-registry.svc:5000/<progetto>/<nome>:<tag>
                                         ▲                              │
                         podman push via route (se esposta)             │ metadati
                                                                        ▼
                                                     ImageStream <nome> (tag ──▶ digest sha256)
                                                                        │
                                       Pod: image: image-registry...:5000/<progetto>/<nome>@sha256:...
```

- Indirizzo **interno** (dai pod e dai nodi): `image-registry.openshift-image-registry.svc:5000/<progetto>/<nome>:<tag>`.
- Un **ImageStream** è la "vista" OpenShift di un repository del registry: ogni push su `<progetto>/<nome>` crea o aggiorna l'image stream `<nome>` nel progetto `<progetto>`.
- Il percorso ha **esattamente due livelli**: `<progetto>/<nome>`. Il primo livello deve essere un progetto esistente su cui hai i permessi.
- `oc get is <nome>` mostra `IMAGE REPOSITORY` (interno) e, se il registry è esposto, `status.publicDockerImageRepository`.

### 2.4 Ruoli che riguardano il registry

| Ruolo | Permette | Assegnato di default a |
|---|---|---|
| `system:image-puller` | Scaricare (pull) le immagini del progetto | Gruppo `system:serviceaccounts:<progetto>` (binding `system:image-pullers`) |
| `system:image-builder` | Pull **e push** nel progetto | SA `builder` del progetto (binding `system:image-builders`) |
| `registry-viewer` | Pull per un utente (es. con Podman) | — |
| `registry-editor` | Pull e push per un utente | — |
| `edit` / `admin` | Includono già pull e push nel progetto | Chi crea il progetto è `admin` |

```bash
oc get rolebindings -n ${LAB}-m03     # system:image-pullers, system:image-builders, system:deployers, admin
```

### 2.5 Configurazione del registry: chi fa cosa

| Requisito | Chi | Come |
|---|---|---|
| Esporre il registry all'esterno (route `default-route`) | cluster-admin | `oc patch configs.imageregistry.operator.openshift.io/cluster --patch '{"spec":{"defaultRoute":true}}' --type=merge` |
| Consentire a un progetto il pull da un altro | admin del progetto sorgente | `oc policy add-role-to-user system:image-puller system:serviceaccount:<ns-dest>:default -n <ns-sorgente>` |
| Dare a un utente pull/push con Podman | admin del progetto | `oc policy add-role-to-user registry-viewer|registry-editor <utente> -n <progetto>` |
| Scaricare da un registry esterno privato | utente con `edit` | `oc create secret docker-registry` + `oc secrets link default <secret> --for=pull` |
| Usare `nome:tag` di un image stream nei Deployment | utente con `edit` | `oc set image-lookup <imagestream>` |

---

## 3. Laboratorio guidato

```bash
source env.sh                 # dalla root del repository ex288-teach
oc new-project ${LAB}-m03 --display-name="EX288 m03 - immagini e registry"
```

### 3.1 Ispezionare un'immagine UBI senza scaricarla

```bash
# oc image info legge i metadati direttamente dal registry (non serve Podman).
# Le UBI sono multi-architettura: va scelta la piattaforma.
oc image info registry.access.redhat.com/ubi9/nodejs-22-minimal --filter-by-os=linux/amd64
# Guarda: User 1001, WorkDir /opt/app-root/src, Env (NODE_VERSION...), Labels, Exposed Ports

oc image info registry.access.redhat.com/ubi9/httpd-24 --filter-by-os=linux/amd64 | grep -iE 'user|port'
```

| Immagine | Contenuto | Uso tipico |
|---|---|---|
| `ubi9/nodejs-22` | Node.js + npm + strumenti di build + script S2I | Builder S2I, build che compilano |
| `ubi9/nodejs-22-minimal` | Solo runtime Node.js (microdnf) | Base per Dockerfile di produzione |
| `ubi9/httpd-24` | Apache httpd su 8080/8443, S2I per contenuti statici | Siti statici, reverse proxy |

### 3.2 (Opzionale) Build ed esecuzione locale con Podman

Salta questo passo se non hai Podman. Serve a capire **perché** un'immagine che "funziona sul PC" può fallire in OpenShift.

```bash
cd $EX288_WORK/ex288-apps/hello-node
podman build -t hello-node:local .                # usa il Dockerfile della cartella
podman run --rm -d --name hn -p 8080:8080 hello-node:local
curl -s localhost:8080/ ; podman logs hn ; podman stop hn

# Simula OpenShift: UID arbitrario, gruppo 0
podman run --rm --user 1000680000:0 hello-node:local id
podman run --rm -d --name hn2 --user 1000680000:0 -p 8080:8080 hello-node:local
podman logs hn2            # "DATA_DIR /opt/app-root/data scrivibile dall'utente 1000680000"
podman stop hn2

# La stessa prova con l'immagine volutamente sbagliata
cd $EX288_WORK/ex288-apps/broken-image
podman build -t broken:local .
podman run --rm --user 1000680000:0 broken:local  # ERRORE: impossibile scrivere in DATA_DIR ... EACCES
```

### 3.3 Build in cluster con build binaria Docker

Il modo più semplice per pubblicare nel registry interno **da utente normale**: carichi la cartella con il Dockerfile e il cluster costruisce e pubblica l'immagine.

```bash
oc project ${LAB}-m03

# BuildConfig con strategia Docker e sorgente "Binary" (nessun Git).
# --to: image stream tag di destinazione (qui un tag specifico, non latest)
oc new-build --strategy=docker --binary --name=hello-bin --to=hello-bin:1.0
oc get bc hello-bin -o jsonpath='{.spec.source.type} {.spec.strategy.type} {.spec.output.to.name}{"\n"}'
# Binary Docker hello-bin:1.0

# Carica la cartella (inclusi Dockerfile e sorgenti) e segui la build
oc start-build hello-bin --from-dir=$EX288_WORK/ex288-apps/hello-node --follow
# Uploading directory ... as binary input for the build ...
# ... Pushing image image-registry.openshift-image-registry.svc:5000/${LAB}-m03/hello-bin:1.0 ...
# Push successful

oc get is hello-bin
oc get istag hello-bin:1.0
oc describe istag hello-bin:1.0 | grep -iE 'labels|io.openshift.tags|user|exposes'   # metadati del Dockerfile
```

> Le build binarie **non** partono da trigger automatici né dalla console: ogni nuova versione richiede `oc start-build --from-dir` (oppure `--from-file`, `--from-archive`, `--from-repo`).

### 3.4 Eseguire l'immagine pubblicata

```bash
oc new-app --image-stream=hello-bin:1.0 --name=hello-bin
oc expose service/hello-bin
curl -s http://$(oc get route hello-bin -o jsonpath='{.spec.host}')/

# L'immagine nel pod punta al registry interno, per digest
oc get pod -l deployment=hello-bin -o jsonpath='{.items[0].spec.containers[0].image}{"\n"}'
# image-registry.openshift-image-registry.svc:5000/${LAB}-m03/hello-bin@sha256:...

# UID arbitrario e gruppo 0 (shell interattiva: digita "id", poi "exit")
oc rsh $(oc get pod -l deployment=hello-bin -o name | head -1)
oc exec deployment/hello-bin -- sh -c 'id; ls -ld /opt/app-root/data'
# uid=1000680000(1000680000) gid=0(root) groups=0(root),1000680000
# drwxrwxr-x. ... root root ... /opt/app-root/data     <- gruppo root (0) con permessi rwx
oc get pod -l deployment=hello-bin -o jsonpath='{.items[0].metadata.annotations.openshift\.io/scc}{"\n"}'
# restricted-v2
```

### 3.5 Una variante: estendere un'immagine con un nuovo `FROM`

Costruisci una seconda versione che cambia messaggio e directory dati, partendo dalla tua immagine o da una UBI. Prepara una cartella di lavoro **fuori** dal repo Git:

```bash
mkdir -p $EX288_WORK/m03/hello-v2 && cp $EX288_WORK/ex288-apps/hello-node/{package.json,server.js} $EX288_WORK/m03/hello-v2/
cat > $EX288_WORK/m03/hello-v2/Dockerfile <<'EOF'
FROM registry.access.redhat.com/ubi9/nodejs-22-minimal
LABEL io.k8s.description="hello-node v2" io.openshift.tags="nodejs,ex288,v2"
WORKDIR /opt/app-root/src
COPY --chown=1001:0 package.json server.js ./
USER 0
RUN mkdir -p /opt/app-root/cache && chgrp -R 0 /opt/app-root/cache && chmod -R g=u /opt/app-root/cache
USER 1001
ENV PORT=8080 DATA_DIR=/opt/app-root/cache APP_MESSAGE="Versione 2 da Dockerfile"
EXPOSE 8080
CMD ["node", "server.js"]
EOF

# Riusa la stessa BuildConfig ma pubblica su un altro tag
oc patch bc/hello-bin --type=merge -p '{"spec":{"output":{"to":{"name":"hello-bin:2.0"}}}}'
oc start-build hello-bin --from-dir=$EX288_WORK/m03/hello-v2 --follow
oc get istag | grep hello-bin            # hello-bin:1.0 e hello-bin:2.0 con digest diversi
```

Il Deployment `hello-bin` resta su `1.0`: ha un trigger su `hello-bin:1.0`, non su `2.0`. Come spostarlo da un tag all'altro in modo controllato è il tema del modulo 04.

### 3.6 Indirizzi, image lookup e permessi nel progetto

```bash
oc get is hello-bin -o jsonpath='{.status.dockerImageRepository}{"\n"}'
# image-registry.openshift-image-registry.svc:5000/${LAB}-m03/hello-bin

# Un Deployment "puro" che usa il nome breve dell'image stream:
oc create deployment short --image=hello-bin:2.0 --port=8080
oc get pod -l app=short          # ErrImagePull: "hello-bin:2.0" viene cercato su un registry esterno

# Abilita la risoluzione locale dei nomi per questo image stream
oc set image-lookup hello-bin
oc set image-lookup --list        # mostra gli image stream con lookup locale
oc rollout restart deployment/short
oc get pod -l app=short -o jsonpath='{.items[*].spec.containers[0].image}{"\n"}'
# image-registry.openshift-image-registry.svc:5000/${LAB}-m03/hello-bin@sha256:...
oc delete deployment short
```

> **Abitudine da esame:** se un requisito dice "il Deployment deve usare l'immagine `nome:tag` dell'image stream", controlla che il lookup locale sia attivo (`oc get is nome -o jsonpath='{.spec.lookupPolicy.local}'` → `true`) oppure usa l'indirizzo completo del registry interno.

### 3.7 (Opzionale, richiede l'amministratore) Push dall'esterno con Podman

Il registry interno è raggiungibile da fuori solo se l'amministratore ha creato la route di default:

```bash
# ATTIVITÀ DA CLUSTER-ADMIN (non eseguirla da utente normale: riceverai "forbidden")
oc patch configs.imageregistry.operator.openshift.io/cluster \
  --patch '{"spec":{"defaultRoute":true}}' --type=merge
```

Da utente normale verifica se è già esposto (non puoi leggere le route del namespace `openshift-image-registry`, ma l'image stream te lo dice):

```bash
HOST=$(oc get is hello-bin -o jsonpath='{.status.publicDockerImageRepository}' | cut -d/ -f1)
echo "${HOST:-registry NON esposto}"
```

Se `HOST` non è vuoto:

```bash
# Il token della sessione oc fa da password; l'utente è il tuo username
podman login -u $(oc whoami) -p $(oc whoami -t) $HOST
# Se il certificato della route non è attendibile sul tuo PC: aggiungi --tls-verify=false (solo laboratorio)

podman tag hello-node:local $HOST/${LAB}-m03/hello-podman:1.0     # <host>/<progetto>/<nome>:<tag>
podman push $HOST/${LAB}-m03/hello-podman:1.0
oc get is hello-podman                                            # creato automaticamente dal push
```

**Se usi Docker al posto di Podman.** I comandi `login`, `tag` e `push` sono gli stessi, ma Docker **non ha l'opzione `--tls-verify`**: la fiducia nei registry si configura nel demone Docker, non nel singolo comando.

```bash
# Login: meglio passare il token da stdin che sulla riga di comando
oc whoami -t | docker login -u "$(oc whoami)" --password-stdin "$HOST"

# Mac con chip Apple (arm64): costruisci per l'architettura dei nodi del cluster
# (di solito amd64; con OpenShift Local su Mac Apple i nodi sono arm64: in quel caso ometti --platform),
# altrimenti il pod parte e muore con "exec format error"
docker build --platform linux/amd64 -t hello-node:local "$EX288_HOME/apps/hello-node"

# Con Docker crea PRIMA l'image stream di destinazione (vedi il riquadro sul 500 qui sotto)
oc create imagestream hello-podman -n ${LAB}-m03

docker tag hello-node:local "$HOST/${LAB}-m03/hello-podman:1.0"
docker push "$HOST/${LAB}-m03/hello-podman:1.0"
oc get is hello-podman
```

Se `docker login` o `docker push` falliscono con `x509: certificate signed by unknown authority`, il certificato della route non è attendibile sul tuo PC. Hai due possibilità:

- **Soluzione corretta:** fai considerare attendibile la CA del cluster. Chiedila all'amministratore (è la CA dell'ingress). Con Docker Desktop su macOS aggiungila al Portachiavi di sistema (*Sempre fidati*) oppure copiala in `~/.docker/certs.d/<HOST>/ca.crt`, poi riavvia Docker Desktop.
- **Solo per il laboratorio:** in Docker Desktop apri *Settings → Docker Engine* e aggiungi il registry agli `insecure-registries` (`"insecure-registries": ["<HOST>"]`), poi *Apply & restart*. È l'equivalente di `--tls-verify=false`, ma vale per tutti i comandi verso quel registry: rimuovilo a fine laboratorio.

> **Push che fallisce con HTTP 500 (`received unexpected HTTP status: 500 Internal Server Error`):** il 500 è un errore **del registry**, non del client. Il push autenticato è arrivato, ma il registry non è riuscito a completarlo. Cause tipiche, in ordine:
>
> 1. **L'image stream di destinazione non esiste ancora (caso tipico con Docker).** Prima di caricare, il client Docker controlla con una richiesta `HEAD /v2/<progetto>/<nome>/manifests/sha256:...` se il manifest è già presente. Se l'image stream non esiste, il registry risponde **500** invece di 404 e Docker interrompe il push. Nei log del registry compare `ImageStreamGetter:NotFound ... imagestreams.image.openshift.io "<nome>" not found` su una richiesta `HEAD`. Soluzione: crea prima l'image stream (`oc create imagestream <nome>`) e ripeti il push. Con Podman in genere l'image stream viene creato dal push stesso; se però vedi lo stesso errore, la soluzione è identica.
> 2. **L'API degli image stream non risponde.** A ogni push il registry crea o aggiorna l'image stream chiamando l'API `image.openshift.io`: se l'OpenShift API server è giù (`oc get is` restituisce `ServiceUnavailable`, vedi modulo 00), il push fallisce con 500. Riprova quando `oc get is` funziona.
> 3. **Formato dell'immagine non accettato.** Docker recente (con *buildx*) aggiunge di default attestazioni di provenienza e SBOM, e l'immagine diventa un *image index* OCI con voci "unknown/unknown". Ricostruisci senza: `docker build --platform linux/amd64 --provenance=false --sbom=false -t hello-node:local ...`.
> 4. **Storage del registry** pieno o non configurato correttamente: è un problema dell'amministratore. Lo riconosci perché falliscono anche le build sul cluster nella fase di push (passo 3.3, `oc start-build ... --follow`).
>
> Il motivo esatto è nei log del registry, leggibili solo dall'amministratore: `oc logs deployment/image-registry -n openshift-image-registry`.

> **Da verificare sul tuo cluster:** l'architettura dei nodi, con `oc get nodes -o jsonpath='{.items[*].status.nodeInfo.architecture}'` (richiede il permesso di leggere i nodi; in alternativa chiedila all'amministratore). Lo stesso vale con Podman su Mac: aggiungi `--platform linux/amd64` a `podman build`. Le build eseguite sul cluster (passo 3.3) non hanno questo problema, perché girano direttamente sui nodi.

Per dare a un collega la possibilità di fare pull o push con Podman nel tuo progetto:

```bash
oc policy add-role-to-user registry-viewer <utente> -n ${LAB}-m03   # solo pull
oc policy add-role-to-user registry-editor <utente> -n ${LAB}-m03   # pull e push
```

> `oc whoami -t` funziona solo se hai fatto login con token o password (non con un kubeconfig a certificato).

### 3.8 Usare un'immagine di un altro progetto

```bash
oc new-project ${LAB}-m03-run
INT=image-registry.openshift-image-registry.svc:5000

oc create deployment consumer --image=$INT/${LAB}-m03/hello-bin:1.0 --port=8080
oc get pods -l app=consumer -w            # ErrImagePull / ImagePullBackOff (Ctrl+C)
oc describe pod -l app=consumer | grep -iE 'failed|unauthorized|denied'
```

I pod di `${LAB}-m03-run` usano il service account `default` del **loro** progetto, che non ha permessi su `${LAB}-m03`. Concedi il permesso minimo, dal progetto che **possiede** l'immagine:

```bash
# Solo al service account default del progetto consumer (minimo indispensabile)
oc policy add-role-to-user system:image-puller \
  system:serviceaccount:${LAB}-m03-run:default -n ${LAB}-m03

# Alternativa: a TUTTI i service account del progetto consumer
# oc policy add-role-to-group system:image-puller system:serviceaccounts:${LAB}-m03-run -n ${LAB}-m03

oc auth can-i get imagestreams --subresource=layers -n ${LAB}-m03 --as=system:serviceaccount:${LAB}-m03-run:default     # yes
oc auth can-i update imagestreams --subresource=layers -n ${LAB}-m03 --as=system:serviceaccount:${LAB}-m03-run:default  # no (niente push)

oc rollout restart deployment/consumer -n ${LAB}-m03-run
oc get pods -l app=consumer -n ${LAB}-m03-run       # Running
```

> `oc auth can-i <get|update> imagestreams --subresource=layers` è il modo più rapido per verificare permessi di pull (`get`) e push (`update`) sul registry interno.

### 3.9 Pull secret per un registry esterno privato

Le immagini di `registry.redhat.io` (es. `$POSTGRES_IMAGE`) si scaricano grazie al **pull secret globale** configurato dall'amministratore. Per un registry privato tuo (es. un repository privato su Quay.io) servono credenziali nel progetto:

```bash
oc project ${LAB}-m03
oc create secret docker-registry quay-cred \
  --docker-server=quay.io \
  --docker-username=<utente-quay> \
  --docker-password=<password-o-token> \
  --docker-email=<email>

# Modo 1: collega il secret al service account usato dai pod (default)
oc secrets link default quay-cred --for=pull
oc get serviceaccount default -o yaml | grep -A3 imagePullSecrets

# Modo 2: dichiaralo nel pod template di un singolo Deployment
# spec.template.spec.imagePullSecrets: [{name: quay-cred}]

# Per le build che scaricano l'immagine base da quel registry: SA builder
oc secrets link builder quay-cred
```

> Se non hai un registry privato, esegui solo la creazione del secret e il link: il pull secret non disturba i pull da altri registry. Lo scenario 4 della sezione 6 mostra il sintomo di un pull senza credenziali.

### 3.10 Pulizia

Tieni `${LAB}-m03` e `${LAB}-m03-run` per la sezione 6. A fine modulo: `oc delete project ${LAB}-m03 ${LAB}-m03-run`.

---

## 4. Esercizi

### 4.1 Esercizio guidato

Nel progetto `${LAB}-m03` pubblica l'immagine `httpd-custom:1.0` costruita da un Dockerfile che parte da `registry.access.redhat.com/ubi9/httpd-24` e copia un file `index.html` con il testo `Ciao EX288` nella document root (`/var/www/html/`). Eseguila come Deployment `httpd-custom` ed esponila: la route deve rispondere `200` con il tuo testo.

<details><summary>Suggerimenti</summary>

- Prepara una cartella con `Dockerfile` e `index.html`.
- `oc new-build --strategy=docker --binary --to=...` e poi `oc start-build --from-dir`.
- L'immagine httpd gira già come utente non root: copia il file con `--chown=1001:0`.
</details>

<details><summary>Soluzione</summary>

```bash
mkdir -p $EX288_WORK/m03/httpd-custom && cd $EX288_WORK/m03/httpd-custom
echo 'Ciao EX288' > index.html
cat > Dockerfile <<'EOF'
FROM registry.access.redhat.com/ubi9/httpd-24
COPY --chown=1001:0 index.html /var/www/html/index.html
EOF
oc project ${LAB}-m03
oc new-build --strategy=docker --binary --name=httpd-custom --to=httpd-custom:1.0
oc start-build httpd-custom --from-dir=. --follow
oc new-app --image-stream=httpd-custom:1.0 --name=httpd-custom
oc expose service/httpd-custom --port=8080-tcp
curl -s http://$(oc get route httpd-custom -o jsonpath='{.spec.host}')/
```
</details>

### 4.2 Esercizio semi-guidato

1. Nel progetto `${LAB}-m03-run` esegui un Deployment `v2` con l'immagine `hello-bin:2.0` del progetto `${LAB}-m03`, usando l'indirizzo del registry interno.
2. Dimostra che il pod gira con un UID diverso da 1001 e che `DATA_DIR` punta a `/opt/app-root/cache`.
3. Revoca il permesso di pull concesso nel passo 3.8 e spiega perché i pod già in esecuzione non si fermano, mentre un nuovo pod su un altro nodo potrebbe fallire.

<details><summary>Suggerimenti</summary>

- Il permesso è già stato concesso al SA `default` nel passo 3.8.
- `oc exec ... -- printenv DATA_DIR`.
- Per revocare: `oc policy remove-role-from-user`. Pensa alla cache delle immagini sui nodi e a `imagePullPolicy`.
</details>

<details><summary>Soluzione (aprila solo dopo aver provato)</summary>

```bash
INT=image-registry.openshift-image-registry.svc:5000

# --- 1. Deployment v2 con l'immagine di un altro progetto ------------------------
oc project ${LAB}-m03-run
oc get istag hello-bin:2.0 -n ${LAB}-m03          # l'immagine esiste (passo 3.5)
oc create deployment v2 --image=$INT/${LAB}-m03/hello-bin:2.0 --port=8080
oc rollout status deployment/v2                   # nessun ImagePullBackOff: il SA "default" di
                                                  # ${LAB}-m03-run ha già system:image-puller (passo 3.8)
oc get pods -l app=v2 -o wide                     # Running + nome del NODO (serve al punto 3)

# --- 2. UID arbitrario e DATA_DIR ------------------------------------------------
oc exec deployment/v2 -- id
# uid=1000xxxxxx(1000xxxxxx) gid=0(root) groups=0(root),1000xxxxxx    <- NON 1001
oc get project ${LAB}-m03-run -o jsonpath='{.metadata.annotations.openshift\.io/sa\.scc\.uid-range}{"\n"}'
# 1000xxxxxx/10000     <- l'UID del pod è il primo dell'intervallo del progetto
oc get pod -l app=v2 -o jsonpath='{.items[0].metadata.annotations.openshift\.io/scc}{"\n"}'
# restricted-v2
oc exec deployment/v2 -- printenv DATA_DIR        # /opt/app-root/cache  (ENV del Dockerfile v2)
oc logs deployment/v2
# DATA_DIR /opt/app-root/cache scrivibile dall'utente 1000xxxxxx
# hello-node v1.0.0 in ascolto sulla porta 8080 (uid=1000xxxxxx, gid=0)

# --- 3. Revoca del permesso di pull ----------------------------------------------
# Si revoca nel progetto che POSSIEDE l'immagine, come per la concessione
oc policy remove-role-from-user system:image-puller \
  system:serviceaccount:${LAB}-m03-run:default -n ${LAB}-m03
oc auth can-i get imagestreams --subresource=layers -n ${LAB}-m03 \
  --as=system:serviceaccount:${LAB}-m03-run:default        # no
oc get rolebindings -n ${LAB}-m03 -o wide | grep ${LAB}-m03-run   # nessuna riga

oc get pods -l app=v2                             # ancora Running: nessuno li ha toccati
oc get deploy v2 -o jsonpath='{.spec.template.spec.containers[0].imagePullPolicy}{"\n"}'
# IfNotPresent   (default per un tag diverso da "latest")

# Per vedere il fallimento in modo prevedibile forza il pull a ogni nuovo pod
oc patch deployment/v2 --type=json \
  -p '[{"op":"replace","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"Always"}]'
oc get pods -l app=v2                             # vecchio pod Running + nuovo pod ErrImagePull/ImagePullBackOff
oc describe pod -l app=v2 | grep -iE 'failed|unauthorized|denied|authentication'
# il rolling update non termina il vecchio pod finché il nuovo non è pronto: l'app resta su

# Ripristina il permesso (serve a "consumer" e a "v2"); il kubelet ritenta il pull da solo
oc policy add-role-to-user system:image-puller \
  system:serviceaccount:${LAB}-m03-run:default -n ${LAB}-m03
oc rollout status deployment/v2                   # può richiedere qualche minuto (backoff dei tentativi)
```

> **Da verificare sul tuo cluster:** se un nuovo pod con `IfNotPresent` finisce su un nodo che ha **già** l'immagine in cache, di solito parte senza contattare il registry, quindi senza ricontrollare i permessi; il comportamento esatto dipende dalla versione e dalla configurazione del kubelet. Per osservarlo, dopo la revoca (con `imagePullPolicy` ancora `IfNotPresent`) esegui `oc delete pod -l app=v2` e guarda gli eventi con `oc get events --sort-by=.lastTimestamp | grep -iE 'pull|present'`: `Container image ... already present on machine` = cache usata, `Failed to pull image` = permesso ricontrollato. Su quale nodo finisce il pod non lo decidi tu (`oc get pods -o wide`).

**Perché il pod ha un UID diverso da 1001:** `USER 1001` nel Dockerfile è solo il default dell'immagine. Con la SCC `restricted-v2` OpenShift esegue il container con un UID preso dall'intervallo assegnato al progetto (annotazione `openshift.io/sa.scc.uid-range`) e sempre nel gruppo 0: per questo `/opt/app-root/cache` deve essere scrivibile dal gruppo (`chgrp 0` + `chmod g=u` del passo 3.5).

**Perché i pod già in esecuzione non si fermano:** il permesso `system:image-puller` viene controllato dal registry interno **solo quando un nodo scarica l'immagine**. Un container già avviato ha l'immagine sul disco del nodo e non parla più con il registry: revocare il ruolo non lo ferma. Un nuovo pod (rollout, riavvio, scale, nodo che va giù) deve invece avere l'immagine: se viene schedulato su un **altro nodo** che non la ha in cache, o se `imagePullPolicy` è `Always`, il kubelet tenta il pull, il registry rifiuta e il pod resta in `ErrImagePull`/`ImagePullBackOff`. Il guasto quindi non si vede subito ma al primo rollout o al primo cambio di nodo: dopo una modifica ai permessi di pull, verifica sempre con `oc auth can-i get imagestreams --subresource=layers ...`.
</details>

### 4.3 Esercizio senza aiuti

Correggi `broken-image` (vedi scenario 1 della sezione 6) in un branch Git `fix-uid`, costruiscila nel progetto `${LAB}-m03` con una BuildConfig da Git che usa quel branch e pubblica l'immagine come `broken:fixed`. Dimostra che con un UID arbitrario `DATA_DIR` è scrivibile.

---

## 5. Verifiche pratiche con `oc`

| Domanda | Comando |
|---|---|
| Che utente, porte e label ha un'immagine? | `oc image info <immagine> --filter-by-os=linux/amd64` · `oc describe istag <is>:<tag>` |
| Dove si trova l'immagine nel registry interno? | `oc get is <is> -o jsonpath='{.status.dockerImageRepository}'` |
| Il registry è esposto? Con che host? | `oc get is <is> -o jsonpath='{.status.publicDockerImageRepository}'` |
| Con che UID/SCC gira il pod? | `oc exec <pod> -- id` · `oc get pod <pod> -o jsonpath='{.metadata.annotations.openshift\.io/scc}'` |
| Una directory è scrivibile dal gruppo 0? | `oc debug deployment/<d> -- ls -ld <dir>` |
| Un SA può fare pull/push da un progetto? | `oc auth can-i get|update imagestreams --subresource=layers -n <prog> --as=system:serviceaccount:<ns>:<sa>` |
| Chi ha i ruoli sul registry nel progetto? | `oc get rolebindings -o wide -n <prog>` |
| Quali pull secret usa il SA? | `oc get sa default -o jsonpath='{.imagePullSecrets}'` |
| Il lookup locale è attivo? | `oc set image-lookup --list` · `oc get is <is> -o jsonpath='{.spec.lookupPolicy.local}'` |

---

## 6. Troubleshooting intenzionale

```bash
oc project ${LAB}-m03
bash $EX288_HOME/03-immagini-e-registry/troubleshooting/rompi-1-uid.sh          # app "broken"
bash $EX288_HOME/03-immagini-e-registry/troubleshooting/rompi-2-cross-project.sh # progetto ${LAB}-m03-other
oc apply -f $EX288_HOME/03-immagini-e-registry/troubleshooting/rotto-4-registry-privato.yaml
```

Lo scenario 2 richiede che esista `hello-bin:1.0` (passo 3.3). Lo scenario 3 richiede il registry esposto (passo 3.7).

### Scenario 1 — `broken` in CrashLoopBackOff

**Sintomo:** la build `broken-1` è `Complete`, ma il pod va in `CrashLoopBackOff`. Con Podman sul PC (UID 1001) l'immagine funziona.

<details><summary>Indagine e soluzione</summary>

```bash
oc get pods -l deployment=broken
oc logs deployment/broken          # ERRORE: impossibile scrivere in DATA_DIR=/opt/app-root/data come uid=1000680000 gid=0: EACCES
oc logs deployment/broken --previous   # log del container precedente, se quello attuale è appena ripartito

# oc rsh non funziona su un container che termina subito: usa oc debug,
# che crea una copia del pod con una shell, stesso UID arbitrario e stessa SCC
oc debug deployment/broken -- sh -c 'id; ls -ld /opt/app-root/data'
# uid=1000680000 gid=0(root) ...
# drwx------. 1001 1001 ... /opt/app-root/data     <- solo l'utente 1001 (può comparire come "default"), gruppo 1001
```
**Causa:** nel Dockerfile `chown 1001:1001` + `chmod 700`: la directory appartiene all'utente 1001 e al gruppo 1001. OpenShift esegue il container con un UID arbitrario del gruppo 0, che non ha alcun permesso.
**Fix:** correggi il Dockerfile in un branch e ricostruisci:

```bash
cd $EX288_WORK/ex288-apps && git switch -c fix-uid
# sostituisci la riga RUN con:
#   RUN mkdir -p /opt/app-root/data && chgrp -R 0 /opt/app-root/data && chmod -R g=u /opt/app-root/data
vi broken-image/Dockerfile
git commit -am "broken-image: supporto UID arbitrari" && git push -u origin fix-uid && git switch main
oc patch bc/broken --type=merge -p '{"spec":{"source":{"git":{"ref":"fix-uid"}}}}'
oc start-build broken --follow
oc get pods -l deployment=broken   # Running; oc logs: "DATA_DIR ... scrivibile dall'utente 1000680000"
```
**Lezione:** "funziona con Podman" non basta: prova sempre con `podman run --user <uid-alto>:0`. Il gruppo 0 con `g=u` è la regola. Non cercare di risolvere chiedendo la SCC `anyuid`: da utente normale non puoi, e all'esame non è la soluzione attesa.
</details>

### Scenario 2 — `consumer2` in ImagePullBackOff

**Sintomo:** nel progetto `${LAB}-m03-other` il pod di `consumer2` resta in `ImagePullBackOff`; l'immagine esiste (`oc get istag hello-bin:1.0 -n ${LAB}-m03`).

<details><summary>Indagine e soluzione</summary>

```bash
oc describe pod -l app=consumer2 -n ${LAB}-m03-other | sed -n '/Events/,$p'
# Failed to pull image "image-registry.openshift-image-registry.svc:5000/<lab>-m03/hello-bin:1.0":
#   ... authentication required / unauthorized
oc auth can-i get imagestreams --subresource=layers -n ${LAB}-m03 --as=system:serviceaccount:${LAB}-m03-other:default   # no
```
**Causa:** il service account `default` di `${LAB}-m03-other` non ha `system:image-puller` su `${LAB}-m03`.
**Fix:** `oc policy add-role-to-user system:image-puller system:serviceaccount:${LAB}-m03-other:default -n ${LAB}-m03`, poi `oc rollout restart deployment/consumer2 -n ${LAB}-m03-other`.
**Lezione:** per il registry interno "non trovata" e "non autorizzata" si somigliano: verifica prima l'esistenza (`oc get istag`), poi i permessi (`oc auth can-i`). Il permesso si concede **nel progetto che possiede l'immagine**.
</details>

### Scenario 3 — Push con troppi livelli (solo con registry esposto)

**Riproduci:** `podman push $HOST/${LAB}-m03/team/hello:1.0` (dopo il relativo `podman tag`).
**Sintomo:** il push fallisce con un errore di autenticazione/autorizzazione, anche se `podman login` è riuscito.

<details><summary>Indagine e soluzione</summary>

**Causa:** il registry interno accetta solo nomi a due livelli `<progetto>/<nome>` (il progetto corrisponde al namespace, il nome all'image stream). Un nome con più livelli viene rifiutato e la documentazione segnala che l'errore si presenta come problema di autenticazione.
**Fix:** `podman tag ... $HOST/${LAB}-m03/hello-team:1.0` e ripeti il push.
**Lezione:** se il push fallisce con "authentication required", prima di dubitare delle credenziali controlla il formato `host/progetto/nome:tag` e che il progetto esista e sia tuo.
</details>

### Scenario 4 — `private-app` in ErrImagePull

**Sintomo:** il pod di `private-app` non parte: `ErrImagePull` / `ImagePullBackOff`.

<details><summary>Indagine e soluzione</summary>

```bash
oc describe pod -l app=private-app | sed -n '/Events/,$p'
# Failed to pull image "quay.io/ex288-corso-privato/private-app:1.0": ... unauthorized: access to the requested resource is not authorized
oc get sa default -o jsonpath='{.imagePullSecrets}{"\n"}'     # nessun secret per quay.io
```
**Causa:** il registry risponde *unauthorized*. Su Quay.io (come su molti registry) questo accade sia per un repository **privato** senza credenziali, sia per un repository **inesistente**: il registry non rivela quale dei due.
**Fix:** se il repository è privato e tuo: crea il pull secret e collegalo (passo 3.9), poi `oc rollout restart deployment/private-app`. Se il nome è sbagliato: correggi l'immagine con `oc set image deployment/private-app app=<immagine-corretta>`. In questo scenario il repository non esiste: correggi con `oc set image deployment/private-app app=registry.access.redhat.com/ubi9/httpd-24`.
**Lezione:** `unauthorized` = credenziali mancanti **o** nome sbagliato; `manifest unknown` / `not found` = repository esistente ma tag sbagliato.
</details>

Pulizia: `oc delete project ${LAB}-m03 ${LAB}-m03-run ${LAB}-m03-other`

---

## 7. Esercizio finale (stile EX288)

> Lavora come all'esame: niente soluzioni, solo documentazione ufficiale, `oc --help` e `oc explain`. Tempo indicativo: **45 minuti**.

**Requisiti**

1. Esistono i progetti `${LAB}-m03-exam` e `${LAB}-m03-exam-run`.
2. Nel progetto `${LAB}-m03-exam` esiste la BuildConfig **`hello-exam`** con strategia **Docker**, che ha pubblicato nel registry interno l'immagine **`hello-exam:1.0`** (image stream `hello-exam`, tag `1.0`).
3. L'immagine `hello-exam:1.0`:
   - parte da `registry.access.redhat.com/ubi9/nodejs-22-minimal` ed esegue l'app `hello-node` (`server.js` e `package.json` di `apps/hello-node`);
   - ha l'utente `1001`;
   - ha la label `io.openshift.tags` che contiene `ex288-exam`;
   - ha le variabili `DATA_DIR=/opt/app-root/cache` e `APP_MESSAGE=Immagine esame m03`;
   - funziona con un UID arbitrario: `DATA_DIR` è scrivibile dal gruppo root.
4. Nel progetto `${LAB}-m03-exam-run` esiste il Deployment **`hello-exam`** con 2 repliche pronte, i cui pod hanno la label `app=hello-exam` e usano l'immagine `image-registry.openshift-image-registry.svc:5000/${LAB}-m03-exam/hello-exam:1.0`. Nel progetto `${LAB}-m03-exam-run` non esiste alcun image stream.
5. I pod girano con la SCC `restricted-v2` (nessuna SCC privilegiata).
6. Il service account `default` di `${LAB}-m03-exam-run` può **scaricare** le immagini di `${LAB}-m03-exam` ma **non** pubblicarle né modificare risorse in quel progetto.
7. L'app è raggiungibile via HTTP tramite la route `hello-exam` nel progetto `${LAB}-m03-exam-run`.

**Risultato atteso**

- `http://<route hello-exam>/` restituisce `"message": "Immagine esame m03"`.
- I log dei pod contengono `DATA_DIR /opt/app-root/cache scrivibile`.

```bash
bash $EX288_HOME/03-immagini-e-registry/verifica.sh
```

---

## 8. Riferimenti ufficiali (OCP 4.22)

- Images → *Creating images* (linee guida, supporto UID arbitrari, label OpenShift): https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/images/creating-images
- Images → *Managing images* (pull tra progetti con `system:image-puller`, pull secret, `oc secrets link`): https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/images/managing-images
- Images → *Using image streams with Kubernetes resources* (`oc set image-lookup`): https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/images/using-imagestreams-with-kube-resources
- Registry → *Accessing the registry* (indirizzo interno, ruoli `registry-viewer`/`registry-editor`, `podman login`): https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/registry/accessing-the-registry
- Registry → *Exposing the registry* (`defaultRoute`, attività di amministrazione): https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/registry/securing-exposing-registry
- Builds using BuildConfig → *Creating build inputs* (binary source, `oc start-build --from-dir`): https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/builds_using_buildconfig/creating-build-inputs
- Builds using BuildConfig → *Using build strategies* (strategia Docker): https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/builds_using_buildconfig/build-strategies
- CLI tools → *OpenShift CLI developer command reference* (`oc image info`, `oc new-build`, `oc debug`): https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/cli_tools/openshift-cli-oc
