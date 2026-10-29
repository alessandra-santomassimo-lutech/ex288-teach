# Modulo 04 — Image stream: tag, trigger e promozione tra ambienti

> **Obiettivi EX288 coperti**
> - *Work with image streams* → Create custom image streams to deploy applications
> - *Work with image streams* → Trigger updates on image stream changes
> - *Work with image streams* → Debug minor issues with application deployment
>
> **Durata stimata:** 4 ore · **Prerequisiti:** moduli 01-03 · **Richiede cluster-admin:** no
>
> **Progetti usati:** `${LAB}-m04`, `${LAB}-m04-dev`, `${LAB}-m04-prod`, `${LAB}-m04-exam`, `${LAB}-m04-exam-prod`

---

## 1. Perché e quando

Un **ImageStream** non contiene immagini: è un oggetto del progetto che mantiene una tabella *tag → immagine (digest sha256)*, con la storia di ogni tag. Le immagini restano nel registry (interno o esterno). In cambio ottieni nomi stabili, trigger automatici e promozioni con un solo comando.

| Ti serve… | Usa | Perché |
|---|---|---|
| Rideployare automaticamente quando esce una nuova immagine | Image stream + **trigger** (`oc set triggers --from-image`) | Il Deployment segue un tag: quando il tag punta a un nuovo digest parte il rollout |
| Accorgerti degli aggiornamenti di un'immagine esterna (es. patch di sicurezza UBI) | `oc import-image --scheduled=true` | Il cluster reimporta periodicamente il tag (default ogni 15 minuti) |
| Nomi brevi e stabili (`hello:prod`) invece di `registry/.../hello@sha256:...` | Tag + `oc set image-lookup` | Il Deployment usa un nome logico, risolto dal cluster in un digest |
| Promuovere la **stessa** immagine da dev a prod senza ricostruirla | `oc tag dev/hello:latest prod/hello:prod` | Promuovi il digest già testato: nessuna nuova build, nessuna sorpresa |
| Tornare alla versione precedente | `oc tag` verso un digest della storia | La storia del tag conserva i digest precedenti |
| Proteggere i nodi da un registry esterno lento o non raggiungibile | `--reference-policy=local` | I pod scaricano dal registry interno, che fa da proxy (pull-through) |

**Quando NON servono:** manifest che devono funzionare su qualsiasi Kubernetes (chart Helm pubblici, Kustomize portabili), flussi GitOps in cui il digest è scritto nel repository e versionato, immagini che non cambiano mai. In quei casi usa direttamente il riferimento completo `registry/repo@sha256:...` o `:tag`.

---

## 2. Concetti essenziali

### 2.1 Tre modi di riferirsi a un'immagine

| Riferimento | Esempio | Significato |
|---|---|---|
| `ImageStreamTag` (`istag`) | `hello:1.0` | "L'immagine a cui punta **ora** il tag `1.0`" (può cambiare) |
| `ImageStreamImage` (`isimage`) | `hello@sha256:3f1a...` | Un'immagine precisa della storia dello stream (immutabile, creato automaticamente) |
| `DockerImage` | `registry.access.redhat.com/ubi9/httpd-24:latest` | Riferimento diretto a un registry, senza image stream |

### 2.2 Anatomia di un ImageStream

```yaml
apiVersion: image.openshift.io/v1
kind: ImageStream
metadata:
  name: tools
spec:
  lookupPolicy:
    local: true                       # i nomi "tools:<tag>" si risolvono nei Deployment (oc set image-lookup)
  tags:                               # SPEC = cosa vuoi (lo scrivi tu / oc tag / oc import-image)
  - name: httpd
    from:
      kind: DockerImage               # sorgente esterna...
      name: registry.access.redhat.com/ubi9/httpd-24:latest
    importPolicy:
      scheduled: true                 # ...reimportata periodicamente (--scheduled)
    referencePolicy:
      type: Local                     # i pod scaricano dal registry interno (--reference-policy=local)
  - name: stable
    from:
      kind: ImageStreamTag            # alias: segue un altro tag dello stesso stream (--alias)
      name: httpd
status:                               # STATUS = cosa è successo (scritto dal cluster)
  dockerImageRepository: image-registry.openshift-image-registry.svc:5000/<progetto>/tools
  tags:
  - tag: httpd
    items:                            # storia: il primo elemento è quello corrente
    - image: sha256:...               # digest
      dockerImageReference: registry.access.redhat.com/ubi9/httpd-24@sha256:...
```

> **Abitudine da esame:** quando un tag "non funziona", guarda **sia** `spec.tags` sia `status.tags`: `oc describe is <nome>` mostra gli errori di import proprio lì.

### 2.3 `oc tag`: permanente o alias

| Comando | Risultato in `spec.tags` | Comportamento |
|---|---|---|
| `oc tag hello:2.0 hello:stable` | `from: ImageStreamImage hello@sha256:...` | **Permanente**: `stable` resta sull'immagine di quel momento |
| `oc tag --alias=true hello:2.0 hello:stable` | `from: ImageStreamTag 2.0` | **Alias**: `stable` segue `2.0` anche quando cambia (solo nello stesso stream) |
| `oc tag registry.access.redhat.com/ubi9/httpd-24 tools:httpd` | `from: DockerImage ...` | Importa da un registry esterno |
| `oc tag progA/hello:latest progB/hello:prod` | `from: ImageStreamImage progA/hello@sha256:...` | Promozione tra progetti |
| `oc tag -d hello:stable` | tag rimosso | Equivale a `oc delete istag hello:stable` |

### 2.4 Trigger sulle risorse Kubernetes

Deployment, StatefulSet, DaemonSet, Job, CronJob e Pod non hanno un campo "trigger": OpenShift usa un'**annotazione**.

```yaml
metadata:
  annotations:
    image.openshift.io/triggers: '[{"from":{"kind":"ImageStreamTag","name":"hello:current"},"fieldPath":"spec.template.spec.containers[?(@.name==\"web\")].image","paused":false}]'
#                                     ^ tag osservato (campo opzionale "namespace" per un altro progetto)
#                                                                 ^ campo da aggiornare: il container DEVE chiamarsi "web"
#                                                                                                                    ^ true = trigger sospeso
```

`oc set triggers deploy/<d> --from-image=<is>:<tag> -c <container>` scrive l'annotazione per te. Quando il tag cambia, OpenShift aggiorna l'immagine del container (con il digest) e il Deployment esegue un normale rollout.

> **BuildConfig vs Deployment:** le BuildConfig hanno trigger `ImageChange` nel loro `spec` (modulo 05); i Deployment usano l'annotazione. I DeploymentConfig (deprecati dal 4.14) avevano un campo `triggers` proprio: non usarli.

---

## 3. Laboratorio guidato

```bash
source env.sh                 # dalla root del repository ex288-teach
oc new-project ${LAB}-m04 --display-name="EX288 m04 - image stream"
```

### 3.1 Creare image stream e importare immagini

```bash
oc create imagestream tools                  # image stream vuoto
oc get is tools                              # nessun tag

# Importa un tag da un registry esterno (--confirm crea/aggiorna il tag)
oc import-image tools:httpd --from=registry.access.redhat.com/ubi9/httpd-24 --confirm
oc describe is tools                         # tag httpd -> digest, data di import
oc get istag                                 # tools:httpd
oc get is tools -o yaml | sed -n '/^spec:/,$p'   # confronta spec.tags e status.tags

# ImageStreamImage: un'immagine precisa per digest
DIG=$(oc get istag tools:httpd -o jsonpath='{.image.metadata.name}')
echo $DIG                                    # sha256:...
oc get isimage tools@$DIG
```

Opzioni di import che devi conoscere (verifica con `oc import-image --help`):

```bash
# Reimport periodico + pull dal registry interno
oc import-image tools:httpd --from=registry.access.redhat.com/ubi9/httpd-24 --confirm \
  --scheduled=true --reference-policy=local
oc get is tools -o jsonpath='{.spec.tags[?(@.name=="httpd")].importPolicy}{" "}{.spec.tags[?(@.name=="httpd")].referencePolicy}{"\n"}'
# {"scheduled":true} {"type":"Local"}

# Altre opzioni (solo lettura, non eseguirle ora):
#   --all                       importa tutti i tag del repository (attenzione: possono essere molti)
#   --import-mode=PreserveOriginal   conserva la manifest list multi-architettura (default: Legacy)
```

### 3.2 Un image stream con versioni costruite da te

Costruiamo due versioni di `hello-node` che differiscono solo per `APP_VERSION` (visibile in `GET /`). Usiamo una cartella di lavoro fuori dal repo Git e la build binaria del modulo 03.

```bash
mkdir -p $EX288_WORK/m04/hello-m04
cp $EX288_WORK/ex288-apps/hello-node/{Dockerfile,package.json,server.js,test.js} $EX288_WORK/m04/hello-m04/
echo 'ENV APP_VERSION=1.0.0' >> $EX288_WORK/m04/hello-m04/Dockerfile      # l'ultima ENV vince

oc new-build --strategy=docker --binary --name=hello          # output: hello:latest
oc start-build hello --from-dir=$EX288_WORK/m04/hello-m04 --follow
oc tag hello:latest hello:1.0                                 # fotografa la versione 1.0

echo 'ENV APP_VERSION=2.0.0' >> $EX288_WORK/m04/hello-m04/Dockerfile
oc start-build hello --from-dir=$EX288_WORK/m04/hello-m04 --follow
oc tag hello:latest hello:2.0

oc get istag                         # hello:1.0, hello:2.0, hello:latest (= 2.0)
oc get istag hello:1.0 -o jsonpath='{.image.dockerImageMetadata.Config.Env}{"\n"}' | tr ',' '\n' | grep APP_VERSION
```

### 3.3 Tag permanenti, alias e storia

```bash
oc tag hello:2.0 hello:stable                  # permanente
oc tag --alias=true hello:latest hello:edge    # alias: segue latest
oc get is hello -o jsonpath='{range .spec.tags[*]}{.name}{" <- "}{.from.kind}{" "}{.from.name}{"\n"}{end}'
# 1.0    <- ImageStreamImage hello@sha256:...
# 2.0    <- ImageStreamImage hello@sha256:...
# stable <- ImageStreamImage hello@sha256:...
# edge   <- ImageStreamTag latest
# (latest non ha spec: è scritto dalla build)

# Nuova build: latest cambia
echo 'ENV APP_VERSION=3.0.0' >> $EX288_WORK/m04/hello-m04/Dockerfile
oc start-build hello --from-dir=$EX288_WORK/m04/hello-m04 --follow

oc get istag | grep hello      # edge = latest (3.0.0); stable resta su 2.0.0
oc describe is hello           # sotto "latest" vedi la storia: 3 digest, il primo è il corrente
oc tag -d hello:edge           # rimuove il tag
```

### 3.4 Deployment che segue un tag

```bash
oc tag hello:1.0 hello:current                 # il tag che il Deployment seguirà
oc set image-lookup hello                      # permette di scrivere "hello:current" nei Deployment

oc create deployment web --image=hello:current --port=8080
oc get deploy web -o jsonpath='{.spec.template.spec.containers[0].name}{"\n"}'   # nome del container: hello

# Trigger: quando hello:current cambia, aggiorna il container "hello"
oc set triggers deployment/web --from-image=hello:current -c hello
oc get deploy web -o jsonpath='{.metadata.annotations.image\.openshift\.io/triggers}{"\n"}'
oc get deploy web -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
# image-registry.openshift-image-registry.svc:5000/${LAB}-m04/hello@sha256:...   <- risolto dal trigger

oc expose deployment web --port=8080 && oc expose service web
URL=http://$(oc get route web -o jsonpath='{.spec.host}')
curl -s $URL/ | grep version                   # "version": "1.0.0"
```

Ora aggiorna l'applicazione **solo spostando il tag**:

```bash
oc tag hello:2.0 hello:current
oc rollout status deployment/web               # parte da solo
curl -s $URL/ | grep version                   # "version": "2.0.0"
oc rollout history deployment/web              # una revisione per ogni cambio di tag
```

Sospendere e riattivare il trigger (verifica i flag con `oc set triggers --help`):

```bash
oc set triggers deployment/web --manual        # imposta "paused": true
oc set triggers deployment/web                 # elenca i trigger: colonna AUTO = false
oc tag hello:latest hello:current              # nessun rollout: il trigger è sospeso
curl -s $URL/ | grep version                   # ancora 2.0.0
oc set triggers deployment/web --auto          # riattiva: il trigger allinea subito l'immagine
oc rollout status deployment/web && curl -s $URL/ | grep version   # 3.0.0
```

### 3.5 Rollback ritaggando un digest

```bash
oc describe is hello            # cerca il blocco "current": storia con digest e date (il primo è il corrente)
# oppure in forma compatta:
oc get is hello -o jsonpath='{range .status.tags[?(@.tag=="current")].items[*]}{.image}{"  "}{.created}{"\n"}{end}'

PREV=<digest della versione 2.0.0, es. sha256:...>
oc tag hello@$PREV hello:current               # permanente, per digest
oc rollout status deployment/web && curl -s $URL/ | grep version   # 2.0.0
```

> Con un trigger attivo la "fonte di verità" dell'immagine è il **tag**. Per tornare indietro in modo duraturo ritagga: un `oc rollout undo` riporterebbe il pod template alla revisione precedente, ma il trigger potrebbe riallinearlo al contenuto del tag.
>
> **Da verificare sul tuo cluster:** prova `oc rollout undo deployment/web` e osserva con `oc get deploy web -o jsonpath='{..image}'` se il trigger riporta l'immagine al digest del tag.

### 3.6 Promozione dev → prod

```bash
# --- Ambiente dev: build e Deployment che segue hello:latest -------------------
oc new-project ${LAB}-m04-dev
mkdir -p $EX288_WORK/m04/hello-dev
cp $EX288_WORK/ex288-apps/hello-node/{Dockerfile,package.json,server.js,test.js} $EX288_WORK/m04/hello-dev/
echo 'ENV APP_VERSION=1.0.0' >> $EX288_WORK/m04/hello-dev/Dockerfile
oc new-build --strategy=docker --binary --name=hello
oc start-build hello --from-dir=$EX288_WORK/m04/hello-dev --follow
oc new-app --image-stream=hello:latest --name=hello      # Deployment con trigger su hello:latest
oc expose service/hello

# --- Ambiente prod --------------------------------------------------------------
oc new-project ${LAB}-m04-prod

# I pod di prod dovranno scaricare l'immagine dal repository di dev: permesso di pull
oc policy add-role-to-group system:image-puller system:serviceaccounts:${LAB}-m04-prod -n ${LAB}-m04-dev

# Promozione: il tag prod/hello:prod punta al digest ATTUALE di dev/hello:latest
oc tag ${LAB}-m04-dev/hello:latest ${LAB}-m04-prod/hello:prod

oc new-app --image-stream=hello:prod --name=hello -n ${LAB}-m04-prod
oc expose service/hello -n ${LAB}-m04-prod
PROD=http://$(oc get route hello -n ${LAB}-m04-prod -o jsonpath='{.spec.host}')
curl -s $PROD/ | grep version                            # 1.0.0
```

**Perché serve `system:image-puller`?** Guarda dove punta il tag promosso:

```bash
oc get istag hello:prod -n ${LAB}-m04-prod -o jsonpath='{.image.dockerImageReference}{"\n"}'
# image-registry.openshift-image-registry.svc:5000/<lab>-m04-dev/hello@sha256:...
```

Il tag in prod è un *puntatore* all'immagine che sta nel repository di **dev**: i pod di prod la scaricano da `.../<lab>-m04-dev/hello`, quindi il loro service account deve poter leggere quel progetto. Senza il permesso: `ImagePullBackOff`. Il ruolo `edit`/`admin` che **tu** hai su entrambi i progetti serve per eseguire `oc tag`, non per il pull dei pod.

> **Da verificare sul tuo cluster:** con `oc tag --reference-policy=local ...` il pull avviene dal percorso del progetto prod (`.../<lab>-m04-prod/hello@sha256:...`) e il registry interno serve i layer in pull-through; verifica con il comando sopra se in quel caso il permesso cross-project è ancora necessario. All'esame la soluzione sicura e documentata è `system:image-puller`.

Nuova versione in dev e nuova promozione:

```bash
echo 'ENV APP_VERSION=2.0.0' >> $EX288_WORK/m04/hello-dev/Dockerfile
oc start-build hello --from-dir=$EX288_WORK/m04/hello-dev --follow -n ${LAB}-m04-dev
# dev si aggiorna da solo (trigger su latest); prod NO
curl -s $PROD/ | grep version                            # ancora 1.0.0

oc tag ${LAB}-m04-dev/hello:latest ${LAB}-m04-prod/hello:prod
oc rollout status deployment/hello -n ${LAB}-m04-prod
curl -s $PROD/ | grep version                            # 2.0.0
```

Rollback di prod alla 1.0.0, per digest:

```bash
oc describe is hello -n ${LAB}-m04-prod                  # storia del tag prod: due digest
V1=<digest più vecchio>
oc tag ${LAB}-m04-prod/hello@$V1 ${LAB}-m04-prod/hello:prod
oc rollout status deployment/hello -n ${LAB}-m04-prod && curl -s $PROD/ | grep version   # 1.0.0
```

### 3.7 Pulizia

Tieni `${LAB}-m04` per la sezione 6. A fine modulo: `oc delete project ${LAB}-m04 ${LAB}-m04-dev ${LAB}-m04-prod`.

---

## 4. Esercizi

### 4.1 Esercizio guidato

Nel progetto `${LAB}-m04`:

1. crea l'image stream `ubi` con il tag `minimal` importato da `registry.access.redhat.com/ubi9/ubi-minimal`, con import periodico;
2. crea il tag `ubi:prod` che **segue** `ubi:minimal`;
3. verifica in `spec.tags` la differenza tra i due tag.

<details><summary>Suggerimenti</summary>

- `oc import-image ... --scheduled=true --confirm`.
- Un tag che "segue" un altro è un alias.
</details>

<details><summary>Soluzione</summary>

```bash
oc project ${LAB}-m04
oc import-image ubi:minimal --from=registry.access.redhat.com/ubi9/ubi-minimal --confirm --scheduled=true
oc tag --alias=true ubi:minimal ubi:prod
oc get is ubi -o jsonpath='{range .spec.tags[*]}{.name}{" "}{.from.kind}{" "}{.from.name}{" scheduled="}{.importPolicy.scheduled}{"\n"}{end}'
# minimal DockerImage registry.access.redhat.com/ubi9/ubi-minimal scheduled=true
# prod    ImageStreamTag minimal scheduled=
```
</details>

### 4.2 Esercizio semi-guidato

1. Nel progetto `${LAB}-m04` crea un Deployment `canary` (container `app`) che segue `hello:2.0` tramite trigger.
2. Senza fare build, fai in modo che `canary` passi all'immagine della versione 3.0.0.
3. Spiega perché il Deployment `web` del passo 3.4 non è cambiato.

<details><summary>Suggerimenti</summary>

- `oc create deployment` usa come nome del container il nome dell'immagine: per avere `app` scrivi lo YAML (`--dry-run=client -o yaml`) o rinomina il container prima di impostare il trigger.
- Quale tag punta già alla 3.0.0? Spostalo con `oc tag`.
</details>

<details><summary>Soluzione (aprila solo dopo aver provato)</summary>

```bash
oc project ${LAB}-m04

# Situazione di partenza (dopo i passi 3.2-3.5)
oc get is hello -o jsonpath='{range .spec.tags[*]}{.name}{" <- "}{.from.kind}{" "}{.from.name}{"\n"}{end}'
# 1.0     <- ImageStreamImage hello@sha256:...
# 2.0     <- ImageStreamImage hello@sha256:...
# stable  <- ImageStreamImage hello@sha256:...
# current <- ImageStreamImage hello@sha256:...      (rollback del passo 3.5: 2.0.0)
oc get is hello -o jsonpath='{.spec.lookupPolicy.local}{"\n"}'    # true (passo 3.4)
D20=$(oc get istag hello:2.0 -o jsonpath='{.image.metadata.name}')  # digest originale della 2.0.0, per dopo

# --- 1. Deployment canary, container "app", trigger su hello:2.0 -----------------
oc create deployment canary --image=hello:2.0 --port=8080 --dry-run=client -o yaml > $EX288_WORK/m04/canary.yaml
grep -n 'name: hello' $EX288_WORK/m04/canary.yaml          # l'unica occorrenza è il nome del container
sed -i.bak 's/name: hello$/name: app/' $EX288_WORK/m04/canary.yaml && rm $EX288_WORK/m04/canary.yaml.bak
oc apply -f $EX288_WORK/m04/canary.yaml
# (alternativa: crea il Deployment e poi rinomina il container con
#  oc patch deployment canary --type=json -p '[{"op":"replace","path":"/spec/template/spec/containers/0/name","value":"app"}]')

oc set triggers deployment/canary --from-image=hello:2.0 -c app
oc set triggers deployment/canary                # trigger su hello:2.0, AUTO = true
oc get deploy canary -o jsonpath='{.spec.template.spec.containers[0].name}{" "}{.spec.template.spec.containers[0].image}{"\n"}'
# app image-registry.openshift-image-registry.svc:5000/<lab>-m04/hello@sha256:...   <- digest di hello:2.0

oc expose deployment canary --port=8080 && oc expose service canary
CANARY=http://$(oc get route canary -o jsonpath='{.spec.host}')
curl -s $CANARY/ | grep version                 # "version": "2.0.0"

# --- 2. Passare alla 3.0.0 senza build: si sposta il TAG ---------------------------
# La 3.0.0 è l'ultima build: è in hello:latest
oc get istag hello:latest -o jsonpath='{.image.dockerImageMetadata.Config.Env}{"\n"}' | tr ',' '\n' | grep APP_VERSION
# "APP_VERSION=3.0.0"
oc tag hello:latest hello:2.0                   # hello:2.0 ora punta al digest della 3.0.0
oc rollout status deployment/canary             # il trigger ha avviato il rollout
curl -s $CANARY/ | grep version                 # "version": "3.0.0"
oc rollout history deployment/canary            # una revisione in più

# --- 3. web non è cambiato ---------------------------------------------------------
oc set triggers deployment/web                  # web osserva hello:current, non hello:2.0
oc get is hello -o jsonpath='{range .spec.tags[?(@.name=="current")]}{.name}{" <- "}{.from.kind}{" "}{.from.name}{"\n"}{end}'
# current <- ImageStreamImage hello@sha256:...    <- digest fisso, non un alias
URL=http://$(oc get route web -o jsonpath='{.spec.host}')     # come nel passo 3.4
curl -s $URL/ | grep version                    # web: ancora "2.0.0"
oc get istag hello:stable -o jsonpath='{.image.dockerImageMetadata.Config.Env}{"\n"}' | tr ',' '\n' | grep APP_VERSION
# "APP_VERSION=2.0.0"   <- anche stable (tag permanente) non è cambiato

# (Facoltativo) Ridai a hello:2.0 il suo significato originale, utile nell'esercizio 4.3.
# Attenzione: canary seguirà il tag e tornerà alla 2.0.0.
# oc tag hello@$D20 hello:2.0
```

**Perché si sposta il tag e non si tocca il Deployment:** il trigger lega `canary` al tag `hello:2.0`, non a un'immagine. `oc tag hello:latest hello:2.0` riscrive `spec.tags` di `2.0` con il digest a cui punta ora `latest` (la 3.0.0): il tag cambia, il trigger aggiorna l'immagine del container `app` con il nuovo digest e il Deployment fa un normale rollout. Nessuna build. Il nome del tag ora non corrisponde alla versione: in pratica si spostano tag logici (`current`, `prod`), qui lo fai per esercizio.

**Perché `web` non è cambiato:** `web` ha un trigger su `hello:current`, e `current` è un tag **permanente** (`ImageStreamImage hello@sha256:...`), creato con `oc tag` e ritaggato per digest nel passo 3.5. Un tag permanente copia il digest nel momento in cui lo crei e non segue più il tag di origine: spostare `hello:2.0` cambia solo l'image stream tag `2.0`, quindi `current` (e con lui `web`) resta sulla 2.0.0. Lo stesso vale per `stable`. Solo un alias (`oc tag --alias=true hello:2.0 hello:current`) avrebbe seguito il cambiamento.
</details>

### 4.3 Esercizio senza aiuti

Riproduci nel progetto `${LAB}-m04` un flusso a tre stadi con un solo image stream: tag `dev`, `test`, `prod`, ciascuno seguito da un Deployment diverso (`app-dev`, `app-test`, `app-prod`). Promuovi la versione 1.0.0 fino a prod, poi la 2.0.0 solo fino a test. Dimostra con `curl` che i tre ambienti espongono le versioni attese, poi esegui un rollback di test alla 1.0.0.

---

## 5. Verifiche pratiche con `oc`

| Domanda | Comando |
|---|---|
| Quali tag ha lo stream e a quale digest puntano? | `oc get istag` · `oc describe is <is>` |
| Il tag è permanente, alias o esterno? | `oc get is <is> -o jsonpath='{range .spec.tags[*]}{.name} {.from.kind} {.from.name}{"\n"}{end}'` |
| L'import è andato a buon fine? | `oc describe is <is>` (messaggi di errore sotto il tag) · `oc get is <is> -o jsonpath='{.status.tags[*].conditions}'` |
| Import periodico e reference policy? | `oc get is <is> -o yaml` (`importPolicy.scheduled`, `referencePolicy.type`) |
| Lookup locale attivo? | `oc set image-lookup --list` |
| Che trigger ha un Deployment? È sospeso? | `oc set triggers deployment/<d>` · annotazione `image.openshift.io/triggers` |
| Come si chiama il container? | `oc get deploy <d> -o jsonpath='{.spec.template.spec.containers[*].name}'` |
| Il Deployment usa il digest atteso? | `oc get deploy <d> -o jsonpath='{..image}'` vs `oc get istag <is>:<tag> -o jsonpath='{.image.metadata.name}'` |
| Da dove scaricano i pod l'immagine promossa? | `oc get istag <is>:<tag> -o jsonpath='{.image.dockerImageReference}'` |

---

## 6. Troubleshooting intenzionale

Ogni file crea il proprio image stream (`s1-web`… `s5-web`) e un Deployment rotto (`t1`… `t5`).

```bash
oc project ${LAB}-m04
for f in $EX288_HOME/04-image-stream/troubleshooting/rotto-*.yaml; do oc apply -f $f; done
```

### Scenario 1 — `t1` in ImagePullBackOff

**Sintomo:** il pod di `t1` è in `ErrImagePull`/`ImagePullBackOff`, ma `oc get istag s1-web:2.4` esiste.

<details><summary>Indagine e soluzione</summary>

```bash
oc describe pod -l app=t1 | sed -n '/Events/,$p'
# Failed to pull image "s1-web:2.4": ... (tentativo su un registry esterno, tipicamente docker.io, o errore di short name)
oc get is s1-web -o jsonpath='{.spec.lookupPolicy.local}{"\n"}'     # false
```
**Causa:** il Deployment usa il nome breve `s1-web:2.4`, ma senza lookup locale il runtime lo interpreta come immagine esterna.
**Fix:** `oc set image-lookup s1-web` e poi `oc rollout restart deployment/t1` (i pod già creati non vengono riscritti).
**Lezione:** `nome:tag` di un image stream funziona in un Deployment solo con `lookupPolicy.local: true`, oppure con un trigger che scrive il riferimento completo.
</details>

### Scenario 2 — `t2` non si aggiorna

**Riproduci:** `oc tag registry.access.redhat.com/ubi9/nginx-124:latest s2-web:v1` (il tag ora punta a un'immagine diversa).
**Sintomo:** nessun nuovo rollout: `oc rollout history deployment/t2` ha una sola revisione e il pod gira ancora httpd.

<details><summary>Indagine e soluzione</summary>

```bash
oc get deploy t2 -o jsonpath='{.metadata.annotations.image\.openshift\.io/triggers}{"\n"}'
# ... containers[?(@.name==\"web\")].image ...
oc get deploy t2 -o jsonpath='{.spec.template.spec.containers[*].name}{"\n"}'     # httpd
```
**Causa:** il trigger punta al container `web`, ma il container si chiama `httpd`: il `fieldPath` non corrisponde a nulla e il trigger non ha effetto (senza errori evidenti).
**Fix:** `oc set triggers deployment/t2 --remove-all` e poi `oc set triggers deployment/t2 --from-image=s2-web:v1 -c httpd` (oppure `oc annotate deployment/t2 image.openshift.io/triggers='...' --overwrite` con il nome giusto). Il rollout parte e il pod usa nginx.
**Lezione:** `-c` di `oc set triggers` deve essere il nome **del container**, non del Deployment né dell'immagine.
</details>

### Scenario 3 — `t3` non parte

**Sintomo:** il pod di `t3` è in `ImagePullBackOff` su `s3-web:v2`.

<details><summary>Indagine e soluzione</summary>

```bash
oc get istag | grep s3-web          # esiste solo s3-web:v1
oc describe is s3-web
oc get deploy t3 -o jsonpath='{.metadata.annotations.image\.openshift\.io/triggers}{"\n"}'   # osserva s3-web:v2
```
**Causa:** il Deployment e il suo trigger fanno riferimento al tag `v2`, che non esiste: il trigger non ha nulla da applicare e il lookup non può risolvere il nome.
**Fix:** se il requisito è "usa v1": `oc set triggers deployment/t3 --remove-all && oc set triggers deployment/t3 --from-image=s3-web:v1 -c httpd`. Se il requisito è "usa v2": crea il tag (`oc tag s3-web:v1 s3-web:v2`): il trigger scatta da solo.
**Lezione:** un trigger su un tag inesistente non segnala errori: resta in attesa che il tag compaia.
</details>

### Scenario 4 — `t4` ignora i nuovi tag

**Riproduci:** `oc tag registry.access.redhat.com/ubi9/nginx-124:latest s4-web:v1`
**Sintomo:** nessun rollout, come nello scenario 2, ma il nome del container è corretto.

<details><summary>Indagine e soluzione</summary>

```bash
oc set triggers deployment/t4                # colonna AUTO: false
oc get deploy t4 -o jsonpath='{.metadata.annotations.image\.openshift\.io/triggers}{"\n"}'   # "paused":true
oc get deploy t4 -o jsonpath='{.spec.paused}{"\n"}'     # vuoto: il Deployment in sé NON è in pausa
```
**Causa:** il trigger è sospeso (`"paused": true`).
**Fix:** `oc set triggers deployment/t4 --auto` (oppure reimposta il trigger con `--from-image ... -c httpd`).
**Lezione:** esistono due "pause" diverse: quella del trigger (annotazione, `oc set triggers --manual/--auto`) e quella del Deployment (`spec.paused`, `oc rollout pause/resume`). Controllale entrambe.
</details>

### Scenario 5 — `s5-web` è vuoto

**Sintomo:** il pod di `t5` è in `ImagePullBackOff`; `oc get istag | grep s5-web` non mostra nulla.

<details><summary>Indagine e soluzione</summary>

```bash
oc describe is s5-web
# latest
#   tagged from registry.access.redhat.com/ubi9/httpd-42
#   ! error: Import failed (NotFound): ... not found
```
**Causa:** l'import del tag fallisce perché l'immagine sorgente non esiste (`httpd-42` invece di `httpd-24`).
**Fix:** `oc import-image s5-web:latest --from=registry.access.redhat.com/ubi9/httpd-24 --confirm` (oppure `oc tag registry.access.redhat.com/ubi9/httpd-24:latest s5-web:latest`). Appena il tag ha un'immagine, il trigger di `t5` aggiorna il Deployment.
**Lezione:** un image stream con import fallito esiste ma non ha immagini: l'errore è visibile solo in `oc describe is`.
</details>

Pulizia: `oc delete project ${LAB}-m04`

---

## 7. Esercizio finale (stile EX288)

> Lavora come all'esame: niente soluzioni, solo documentazione ufficiale, `oc --help` e `oc explain`. Tempo indicativo: **50 minuti**.

**Requisiti**

1. Esistono i progetti `${LAB}-m04-exam` e `${LAB}-m04-exam-prod`.
2. Nel progetto `${LAB}-m04-exam` l'image stream **`tools`** ha il tag **`httpd`** importato da `registry.access.redhat.com/ubi9/httpd-24`, con **import periodico** e **reference policy locale**.
3. Nel progetto `${LAB}-m04-exam` la BuildConfig **`hello`** (strategia Docker, applicazione `hello-node`) ha prodotto le immagini dell'image stream **`hello`**:
   - il tag `hello:1.0` contiene un'immagine con `APP_VERSION=1.0.0`;
   - il tag `hello:2.0` contiene un'immagine con `APP_VERSION=2.0.0`.
4. Il tag **`hello:stable`** segue `hello:2.0`: se `hello:2.0` cambia, `hello:stable` cambia di conseguenza.
5. Nei Deployment del progetto `${LAB}-m04-exam` si può usare il nome breve `hello:<tag>`.
6. Nel progetto `${LAB}-m04-exam` il Deployment **`web`** ha 2 repliche pronte, un container chiamato **`web`** e si aggiorna automaticamente quando cambia `hello:stable`. È esposto via HTTP dalla route `web`.
7. Nel progetto `${LAB}-m04-exam-prod`:
   - l'image stream `hello` ha il tag **`prod`**, che punta alla **stessa immagine** (stesso digest) di `${LAB}-m04-exam/hello:1.0`;
   - il Deployment **`web`** (1 replica pronta, container `web`) si aggiorna automaticamente quando cambia `hello:prod` ed è esposto via HTTP dalla route `web`;
   - i service account di `${LAB}-m04-exam-prod` possono scaricare le immagini di `${LAB}-m04-exam` ma non pubblicarle.
8. Applica nel progetto `${LAB}-m04-exam` il file `$EX288_HOME/04-image-stream/lab/esame-legacy.yaml`. Il Deployment **`legacy`** che crea non funziona come richiesto: senza eliminarlo, fai in modo che abbia 1 replica pronta e che si aggiorni automaticamente quando cambia `tools:httpd`.

**Risultato atteso**

- `http://<route web in ${LAB}-m04-exam>/` restituisce `"version": "2.0.0"`.
- `http://<route web in ${LAB}-m04-exam-prod>/` restituisce `"version": "1.0.0"`.
- Il pod di `legacy` è `Running` con l'immagine di `tools:httpd`.

```bash
bash $EX288_HOME/04-image-stream/verifica.sh
```

---

## 8. Riferimenti ufficiali (OCP 4.22)

- Images → *Managing image streams* (tag, `oc tag`, alias, import, `--scheduled`, `--reference-policy`, `--import-mode`): https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/images/managing-image-streams
- Images → *Using image streams with Kubernetes resources* (`oc set image-lookup`): https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/images/using-imagestreams-with-kube-resources
- Images → *Triggering updates on image stream changes* (annotazione `image.openshift.io/triggers`, `oc set triggers`): https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/images/triggering-updates-on-imagestream-changes
- Images → *Managing images* (pull tra progetti, `system:image-puller`): https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/images/managing-images
- Building applications → *Deployments* (Deployment vs DeploymentConfig, rollout): https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/building_applications/deployments
- CLI tools → *OpenShift CLI developer command reference* (`oc tag`, `oc import-image`, `oc set triggers`): https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/cli_tools/openshift-cli-oc
