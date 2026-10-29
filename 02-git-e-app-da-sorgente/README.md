# Modulo 02 — Git e applicazioni da sorgente

> **Obiettivi EX288 coperti**
> - *Work with Red Hat OpenShift Container Platform* → Understand basic Git usage and work with Git in the context of deploying applications in OpenShift
> - *Work with Red Hat OpenShift Container Platform* → Create and deploy single container and multi-container applications (seconda parte: da codice sorgente)
> - *Work with image streams* → Pull applications from existing Git repositories
> - *Work with the source-to-image (S2I) framework* → Build and deploy applications using S2I framework (introduzione; approfondimento nel modulo 06)
>
> **Durata stimata:** 4-5 ore · **Prerequisiti:** moduli 00 e 01, clone locale `$EX288_WORK/ex288-apps` con remote `$GIT_REPO` · **Richiede cluster-admin:** no
>
> **Progetti usati:** `${LAB}-m02`, `${LAB}-m02-exam`

---

## 1. Perché e quando

All'esame ti verrà chiesto di "deployare un'applicazione dal repository Git X, dalla cartella Y, dal branch Z". OpenShift può costruire l'immagine **dentro il cluster** partendo dal sorgente: non serve un registry esterno né Docker sulla tua postazione. La domanda vera è *quale strategia* usare.

| Situazione | Cosa usi | Perché |
|---|---|---|
| Hai solo il codice (nessun Dockerfile) in un linguaggio supportato | **S2I** (`oc new-app <builder>~<repo>`) | Il builder sa già come installare dipendenze e avviare l'app; non scrivi né mantieni un Dockerfile |
| Il repo contiene un Dockerfile e vuoi controllare ogni layer | **Docker** (rilevata automaticamente o `--strategy=docker`) | L'immagine è esattamente quella descritta dal Dockerfile, costruita con Buildah nel cluster |
| Il repo contiene un Dockerfile **ma** vuoi S2I | `--strategy=source` oppure `builder~repo` | Il rilevamento automatico sceglierebbe Docker: va forzato |
| L'immagine esiste già in un registry | `oc new-app --image=...` (modulo 01) | Non c'è nulla da costruire |
| Il codice è sul tuo PC e non vuoi fare push | Build binaria (`oc start-build --from-dir`, modulo 03) | Utile per prove rapide; niente trigger automatici |
| Il repo è privato | Source secret (`--source-secret`, `oc set build-secret --source`) | La build gira **nel cluster**: le credenziali devono stare nel cluster, non sul tuo PC |

**Regola d'oro:** il cluster costruisce **quello che c'è sul remoto Git**, non quello che c'è nella tua cartella locale. Un `git commit` senza `git push` è invisibile a OpenShift.

---

## 2. Concetti essenziali

### 2.1 Git: il minimo indispensabile per l'esame

| Comando | Cosa fa | Quando ti serve |
|---|---|---|
| `git clone <url>` | Copia locale di un repo remoto | Primo contatto con il repo dell'esame |
| `git status` | File modificati, branch corrente, commit non pushati ("ahead of") | **Sempre**, prima e dopo ogni modifica |
| `git add <file>` / `git add .` | Mette le modifiche nell'area di staging | Prima di ogni commit |
| `git commit -m "msg"` | Registra un commit **locale** | Dopo `add` |
| `git push [-u origin <branch>]` | Invia i commit al remoto (`-u` imposta l'upstream) | Prima di avviare una build |
| `git branch` / `git switch -c <nuovo>` / `git checkout <branch>` | Elenca / crea e passa / passa a un branch | Lavorare su un branch richiesto dall'esame |
| `git tag -a v1.0 -m "..."` + `git push origin v1.0` | Crea e pubblica un tag | Build di una versione precisa |
| `git log --oneline -5` | Ultimi commit con hash abbreviato | Confrontare con il commit usato dalla build |
| `git diff` / `git diff --staged` | Differenze non in staging / in staging | Controllare cosa stai per committare |
| `git remote -v` | URL del remoto | Verificare che l'URL usato in `oc new-app` sia lo stesso |
| `git ls-remote origin` | Branch e tag **presenti sul remoto** | Verificare che il push sia arrivato |

### 2.2 Come OpenShift legge un riferimento Git

```
https://github.com/utente/ex288-apps.git#feature-msg    --context-dir=hello-node
└──────────── URL (clonato DAL CLUSTER) ──┘ └── ref ──┘  └ sottocartella usata come radice ┘
```

- `#<ref>` può essere un branch, un tag o un commit. Senza ref la build fa un clone superficiale (`--depth=1`) del branch di default.
- `--context-dir` indica la sottocartella: tutto ciò che sta fuori viene ignorato. Il rilevamento della strategia guarda **dentro** il context dir.

Nella BuildConfig diventano:

```yaml
spec:
  source:
    type: Git
    git:
      uri: https://github.com/utente/ex288-apps.git
      ref: feature-msg          # branch, tag o commit
    contextDir: hello-node      # sottocartella
    sourceSecret:               # solo per repo privati
      name: git-cred
```

### 2.3 Rilevamento della strategia di `oc new-app`

Se passi solo l'URL del repo, `oc new-app` ispeziona il context dir:

1. c'è un `Jenkinsfile` → strategia Pipeline (deprecata, non usarla);
2. c'è un `Dockerfile` → strategia **Docker**;
3. altrimenti → strategia **Source** (S2I), e il builder viene scelto in base ai file (es. `package.json` ⇒ Node.js) cercando image stream con un'annotazione `supports` corrispondente o con il nome del linguaggio.

Con la sintassi `builder~repo` (es. `nodejs:22-ubi9~$GIT_REPO`) **rilevamento di strategia e linguaggio vengono saltati**: si usa S2I con quel builder. Puoi sempre forzare con `--strategy=docker|source`.

> **Attenzione:** il rilevamento avviene **sul tuo PC**: `oc new-app` clona il repo localmente per ispezionarlo, quindi serve `git` installato e il repo deve essere raggiungibile anche dalla tua postazione.

`apps/hello-node` contiene un `Dockerfile`: `oc new-app $GIT_REPO --context-dir=hello-node` produce quindi una build **Docker**.

### 2.4 Cosa crea `oc new-app` da sorgente

```
                 ┌───────────────── BuildConfig ──────────────────┐
 Git (remoto) ──▶│ source: git uri/ref/contextDir                 │
                 │ strategy: Source (from: nodejs:22-ubi9)        │──▶ Build hello-1 (pod di build)
                 │           oppure Docker (from: base del FROM)  │          │ clone, build, push
                 │ output: ImageStreamTag hello:latest            │          ▼
                 │ triggers: ConfigChange, ImageChange, webhook   │   registry interno ─▶ ImageStream hello:latest
                 └────────────────────────────────────────────────┘                          │ cambia il tag
                                                                                             ▼
                 Deployment hello (annotazione image.openshift.io/triggers) ──▶ nuovo rollout ──▶ Pod
                 Service hello (porte dichiarate nell'immagine)
```

| Risorsa | Chi la crea | A cosa serve |
|---|---|---|
| `BuildConfig` | new-app | Ricetta della build (sorgente, strategia, output, trigger) |
| `ImageStream` di output (es. `hello`) | new-app | Riceve l'immagine prodotta |
| `ImageStream` del builder / del `FROM` | new-app, se non esiste già | Permette di ricostruire automaticamente quando il builder si aggiorna |
| `Build` (`hello-1`, `hello-2`…) | il trigger `ConfigChange` o `oc start-build` | Singola esecuzione della build, con il suo pod e il suo log |
| `Deployment` con trigger sull'image stream | new-app | Ad ogni nuova immagine su `hello:latest` parte un rollout |
| `Service` | new-app | Solo se l'immagine dichiara porte (`EXPOSE`) |
| `Route` | **tu** (`oc expose`) | new-app non espone mai all'esterno |

### 2.5 Variabili d'ambiente: build o runtime?

| Opzione | Dove finisce | Effetto |
|---|---|---|
| `-e VAR=val` / `--env-file` | `Deployment` | Visibile all'app in esecuzione; **non** entra nella BuildConfig |
| `--build-env VAR=val` / `--build-env-file` | `BuildConfig` (`strategy.*.env`) | Visibile durante la build (es. `BUILD_LOGLEVEL`) |
| `oc set env deployment/x` / `oc set env bc/x` | Rispettivamente Deployment / BuildConfig | Modifica successiva |

---

## 3. Laboratorio guidato

```bash
source env.sh                 # dalla root del repository ex288-teach
```

### 3.1 Git: allenamento rapido sul tuo clone

```bash
cd $EX288_WORK/ex288-apps
git remote -v                     # deve mostrare $GIT_REPO
git status                        # "nothing to commit, working tree clean" + branch main
git log --oneline -3              # ultimi commit
git ls-remote origin              # cosa c'è DAVVERO sul remoto (HEAD, refs/heads/main...)
```

Crea un tag per la versione attuale e pubblicalo (lo userai nell'esercizio 4.1):

```bash
git tag -a v1.0 -m "Prima versione per il corso"
git push origin v1.0              # i tag NON vengono inviati da un semplice "git push"
git ls-remote --tags origin       # refs/tags/v1.0
```

### 3.2 Progetto e builder Node.js

```bash
oc new-project ${LAB}-m02 --display-name="EX288 m02 - app da sorgente"

# Image stream locale del builder S2I Node.js 22 (UBI 9).
# Crea l'image stream "nodejs" con il tag "22-ubi9" nel progetto corrente.
oc import-image nodejs:22-ubi9 --from=registry.access.redhat.com/ubi9/nodejs-22 --confirm
oc get istag nodejs:22-ubi9
```

> **Nota di versione:** sui cluster che hanno il Cluster Samples Operator esiste già `openshift/nodejs:22-ubi9` (namespace `openshift`). Il Samples Operator è però *Deprecated* in 4.20-4.22: non darlo per scontato. Controlla con `oc get istag -n openshift nodejs:22-ubi9`; se esiste puoi scrivere `openshift/nodejs:22-ubi9~...`.

### 3.3 Prima di creare: guarda cosa verrebbe creato (`-o yaml`)

```bash
# Nessuna risorsa viene creata: new-app stampa gli oggetti che creerebbe.
oc new-app $GIT_REPO --context-dir=hello-node --name=hello-docker -o yaml > $EX288_WORK/m02/hello-docker.yaml

grep -n 'kind:' $EX288_WORK/m02/hello-docker.yaml          # ImageStream (x2), BuildConfig, Deployment, Service
grep -n -A4 'strategy:' $EX288_WORK/m02/hello-docker.yaml  # dockerStrategy: from = nodejs-22-minimal:latest
```

**Perché Docker?** In `hello-node/` c'è un `Dockerfile`: il rilevamento automatico sceglie la strategia Docker. Il secondo image stream (`nodejs-22-minimal`) corrisponde al `FROM` del Dockerfile: new-app lo crea per ricostruire l'app quando l'immagine base cambia.

> **Abitudine da esame:** quando il testo chiede una strategia precisa, controlla con `-o yaml` (o, dopo la creazione, con `oc get bc`, colonna `TYPE`) che sia quella giusta. Un'app che funziona ma è costruita con la strategia sbagliata non soddisfa il requisito.

### 3.4 App con strategia Docker

```bash
oc new-app $GIT_REPO --context-dir=hello-node --name=hello-docker
# --> Found container image ... "registry.access.redhat.com/ubi9/nodejs-22-minimal"
# --> Creating resources ... imagestream "nodejs-22-minimal", imagestream "hello-docker",
#     buildconfig "hello-docker", deployment "hello-docker", service "hello-docker"

oc get bc                         # TYPE = Docker, FROM = Git
oc logs -f bc/hello-docker        # segue il log della build in corso (Ctrl+C per uscire)
# Se risponde "no builds found", la build non è ancora partita: riprova dopo qualche secondo
```

Nel log riconosci le fasi: `Cloning "https://..."` → `STEP 1/..: FROM ...` → `Pushing image image-registry.openshift-image-registry.svc:5000/${LAB}-m02/hello-docker:latest` → `Push successful`.

```bash
oc get builds                     # hello-docker-1   Docker   Git@<commit>   Complete
oc get is hello-docker            # ora ha il tag latest
oc rollout status deployment/hello-docker

# Il Deployment "segue" l'image stream grazie all'annotazione dei trigger:
oc get deployment hello-docker \
  -o jsonpath='{.metadata.annotations.image\.openshift\.io/triggers}{"\n"}'
# [{"from":{"kind":"ImageStreamTag","name":"hello-docker:latest"},"fieldPath":"spec.template.spec.containers[?(@.name==\"hello-docker\")].image"}]

oc expose service/hello-docker    # new-app non crea mai la route
curl -s http://$(oc get route hello-docker -o jsonpath='{.spec.host}')/
# { "app": "hello-node", "version": "1.0.0", "message": "Ciao da OpenShift!", ... }
```

### 3.5 Stessa app con S2I: confronto

```bash
oc new-app "nodejs:22-ubi9~$GIT_REPO" \
  --context-dir=hello-node \
  --name=hello-s2i \
  -l tier=web \
  -e APP_MESSAGE="Ciao da S2I" \
  --build-env=BUILD_LOGLEVEL=2
# nodejs:22-ubi9~  -> builder esplicito: niente rilevamento, strategia Source
# -l tier=web      -> label aggiunta a TUTTE le risorse create
# -e               -> variabile nel Deployment (runtime)
# --build-env      -> variabile nella BuildConfig (log di build più verboso)

oc logs -f bc/hello-s2i           # nota: "STEP ... assemble", "npm install", poi il push
oc expose service/hello-s2i
curl -s http://$(oc get route hello-s2i -o jsonpath='{.spec.host}')/
```

Ora confronta le due app:

```bash
oc get bc                                             # TYPE: Docker vs Source
oc get bc hello-s2i -o jsonpath='{.spec.strategy.sourceStrategy.from.name}{"\n"}'   # nodejs:22-ubi9
oc set env bc/hello-s2i --list                        # BUILD_LOGLEVEL=2 (build)
oc set env deployment/hello-s2i --list                # APP_MESSAGE=Ciao da S2I (runtime)
oc get all -l tier=web                                # solo le risorse di hello-s2i
oc exec deployment/hello-s2i -- id                    # UID arbitrario, gruppo 0 (come per Docker)
```

| | `hello-docker` | `hello-s2i` |
|---|---|---|
| Chi decide come costruire | Il `Dockerfile` del repo | Gli script `assemble`/`run` del builder |
| Immagine base | `nodejs-22-minimal` (solo runtime, più piccola) | `nodejs-22` (builder completo, più grande) |
| Quando sceglierla | Controllo totale, immagini minime | Nessun Dockerfile da mantenere, convenzioni standard |

### 3.6 Build da un branch

Simula una richiesta tipica: "deploya la versione del branch `feature-msg`".

```bash
cd $EX288_WORK/ex288-apps
git switch -c feature-msg                     # crea il branch e ci passa
# Cambia il messaggio di default (sintassi di sed compatibile con macOS e Linux)
sed -i.bak 's/Ciao da OpenShift!/Ciao dal branch feature-msg!/' hello-node/server.js && rm hello-node/server.js.bak
git diff                                      # controlla la modifica
git commit -am "Messaggio di default per feature-msg"
git push -u origin feature-msg                # SENZA questo il cluster non vede il branch
git ls-remote origin feature-msg              # conferma: il branch esiste sul remoto
git switch main                               # torna su main per non sbagliare dopo
```

```bash
oc new-app "nodejs:22-ubi9~$GIT_REPO#feature-msg" --context-dir=hello-node --name=hello-feature
oc logs -f bc/hello-feature
oc get bc hello-feature -o jsonpath='{.spec.source.git.ref}{"\n"}'    # feature-msg
oc describe build hello-feature-1 | grep -iE 'commit|ref'             # commit usato dalla build
oc expose service/hello-feature
curl -s http://$(oc get route hello-feature -o jsonpath='{.spec.host}')/ | grep message
# "message": "Ciao dal branch feature-msg!"
```

> **Perché le virgolette:** `~` e `#` sono caratteri speciali per alcune shell. Con zsh (la shell di default su macOS) e l'opzione `EXTENDED_GLOB` attiva, `~` e `#` diventano operatori di pattern e il comando viene rifiutato dalla shell con "no matches found" prima ancora di arrivare a `oc`. Tra virgolette doppie la variabile `$GIT_REPO` viene comunque espansa e il resto arriva a `oc` intatto. Abitudine utile anche all'esame.
>
> **Se il branch non è quello atteso**, controlla in quest'ordine:
>
> 1. Cosa riceve davvero `oc`, senza creare nulla: `oc new-app "nodejs:22-ubi9~$GIT_REPO#feature-msg" --context-dir=hello-node --name=prova -o yaml | grep -A4 'git:'` (deve comparire `ref: feature-msg`).
> 2. Cosa c'è nella BuildConfig creata: `oc get bc hello-feature -o jsonpath='{.spec.source.git.ref}{"\n"}'`.
> 3. Se il branch esiste sul remoto **con il commit giusto**: `git ls-remote "$GIT_REPO" feature-msg` deve mostrare lo stesso hash di `git rev-parse feature-msg` nel tuo clone (altrimenti manca il `git push`).
> 4. Quale commit ha usato la build: `oc describe build hello-feature-1 | grep -iE 'commit|ref'`.
> 5. Che stai interrogando la route giusta (`hello-feature`, non `hello`).
>
> Se la BuildConfig è già stata creata con il ref sbagliato non serve ricrearla: correggi `spec.source.git.ref` con `oc patch` (come sotto) e avvia una nuova build.

Per ricostruire dopo un nuovo push: `oc start-build hello-feature --follow`. Per cambiare branch su una BuildConfig esistente:

```bash
oc patch bc/hello-feature --type=merge -p '{"spec":{"source":{"git":{"ref":"v1.0"}}}}'
oc start-build hello-feature --follow         # ora costruisce il tag v1.0 (messaggio originale)

# Riporta la BuildConfig sul branch feature-msg (serve nello scenario 5 della sezione 6)
oc patch bc/hello-feature --type=merge -p '{"spec":{"source":{"git":{"ref":"feature-msg"}}}}'
oc start-build hello-feature --follow
```

> `oc start-build` accetta anche `--commit=<hash>` per costruire un commit preciso senza modificare la BuildConfig (verifica con `oc start-build --help`).

### 3.7 Repository privati: source secret

Le build clonano il codice **dal cluster**: se il repo è privato servono credenziali salvate in un Secret del progetto. Con GitHub/GitLab si usa un **token** (personal access token in sola lettura) come password.

```bash
# Secret di tipo basic-auth: username + token
oc create secret generic git-cred \
  --from-literal=username=<tuo-utente-git> \
  --from-literal=password=<token> \
  --type=kubernetes.io/basic-auth
```

Tre modi per usarlo:

```bash
# 1) Alla creazione dell'app
oc new-app nodejs:22-ubi9~https://github.com/<utente>/<repo-privato>.git \
  --context-dir=hello-node --name=hello-priv --source-secret=git-cred

# 2) Su una BuildConfig già esistente (poi rilancia la build)
oc set build-secret --source bc/hello-priv git-cred
oc get bc hello-priv -o jsonpath='{.spec.source.sourceSecret.name}{"\n"}'

# 3) Associazione automatica per URL: ogni BuildConfig creata DOPO, con URL che corrisponde,
#    riceve automaticamente il secret (il secret deve esistere prima della BuildConfig)
oc annotate secret git-cred \
  'build.openshift.io/source-secret-match-uri-1=https://github.com/<utente>/*'
```

Per SSH si usa invece un secret `kubernetes.io/ssh-auth` con chiave `ssh-privatekey` (chiave senza passphrase) e URL `git@...`.

> Se il tuo `$GIT_REPO` è pubblico, puoi provare questa sezione creando un secondo repository **privato** con lo stesso contenuto. Altrimenti limita il passo alla creazione del secret e al comando `oc set build-secret` su `hello-feature`: la build continuerà a funzionare (il secret non dà fastidio su un repo pubblico).

### 3.8 Applicazione multi-componente: app + PostgreSQL

Due componenti separati (due Deployment, due Service) che si parlano via DNS del Service.

```bash
# Database da immagine Red Hat (scaricata grazie al pull secret globale del cluster)
oc new-app --image=$POSTGRES_IMAGE --name=db \
  -e POSTGRESQL_USER=app \
  -e POSTGRESQL_PASSWORD=app123 \
  -e POSTGRESQL_DATABASE=appdb
# Nota il warning sul VOLUME /var/lib/pgsql/data: new-app usa un emptyDir,
# i dati si perdono quando il pod viene ricreato (storage persistente nel modulo 08).

oc get svc db                                 # porta 5432
oc rollout status deployment/db
oc logs deployment/db | tail -3               # "... database system is ready to accept connections"
```

```bash
# Frontend: riusa l'immagine già costruita da hello-s2i (nessuna nuova build!)
oc new-app --image-stream=hello-s2i --name=frontend \
  -e DB_HOST=db -e DB_PORT=5432 -e DB_NAME=appdb \
  -e DB_USER=app -e DB_PASSWORD=app123
oc expose service/frontend
curl -s http://$(oc get route frontend -o jsonpath='{.spec.host}')/db
# { "db": "raggiungibile", "host": "db", "port": 5432, "name": "appdb", "user": "app" }
```

> La stessa immagine può alimentare più Deployment: `frontend` segue `hello-s2i:latest` e verrà aggiornato ad ogni nuova build di `hello-s2i`. In alternativa avresti potuto creare il frontend da sorgente (`oc new-app nodejs:22-ubi9~$GIT_REPO --context-dir=hello-node --name=frontend -e ...`), con una build separata.

**Credenziali in chiaro:** `oc set env deployment/db --list` mostra la password. È accettabile solo in laboratorio: nel modulo 07 sposterai le credenziali in un Secret.

> **Due container nello stesso pod?** `oc new-app` supporta anche `--group=a+b` per mettere più componenti nello **stesso** pod. Per app + database è sbagliato (non puoi scalarli separatamente e il riavvio dell'uno coinvolge l'altro): usa componenti separati. I pod multi-container veri (sidecar) li vedi nel modulo 08.

### 3.9 Dalla web console: Import from Git

1. Apri la console (`oc whoami --show-console`) e seleziona il progetto `${LAB}-m02`.
2. Se è abilitata la prospettiva *Developer*: **+Add → Import from Git**. Altrimenti usa il pulsante **+** in alto (quick create) → *Import from Git*.
3. *Git Repo URL* = `$GIT_REPO`; apri *Show advanced Git options*: *Git reference* = `main`, *Context dir* = `/hello-node`, eventuale *Source Secret*.
4. La console rileva il `Dockerfile` e propone la strategia *Dockerfile*: con *Edit Import Strategy* puoi scegliere *Builder Image* → Node.js.
5. *Name* = `hello-console`, *Resource type* = Deployment, lascia selezionato *Create a route*. Crea.

> **Da verificare sul tuo cluster:** la posizione esatta di *Import from Git* dipende dalla configurazione della console (dal 4.19 la prospettiva *Developer* non è abilitata di default). Se non la trovi, chiedi all'amministratore di abilitarla o usa la CLI.

Verifica: `oc get bc,deploy,svc,route -l app=hello-console`. Nota che la console **crea la route** (new-app no).

### 3.10 Pulizia

Tieni il progetto `${LAB}-m02` per la sezione 6. Al termine del modulo: `oc delete project ${LAB}-m02`.

---

## 4. Esercizi

### 4.1 Esercizio guidato

Nel progetto `${LAB}-m02`:

1. crea l'app `hello-v1` con S2I a partire dal **tag** `v1.0` del tuo repository (cartella `hello-node`);
2. tutte le risorse devono avere la label `release=v1`;
3. il Deployment deve avere `APP_MESSAGE=Versione 1`;
4. esponila con una route edge chiamata `hello-v1`.

<details><summary>Suggerimenti</summary>

- Un tag si indica come un branch: `repo#v1.0`.
- `-l` di `oc new-app` etichetta tutte le risorse create.
- La route edge si crea con `oc create route edge`.
</details>

<details><summary>Soluzione</summary>

```bash
oc project ${LAB}-m02
oc new-app "nodejs:22-ubi9~$GIT_REPO#v1.0" --context-dir=hello-node --name=hello-v1 \
  -l release=v1 -e APP_MESSAGE="Versione 1"
oc logs -f bc/hello-v1
oc create route edge hello-v1 --service=hello-v1
oc get bc,deploy,svc,is -l release=v1
curl -sk https://$(oc get route hello-v1 -o jsonpath='{.spec.host}')/ | grep message
```
</details>

### 4.2 Esercizio semi-guidato

1. Crea l'app `hello-forced` dalla cartella `hello-node` del branch `main` **forzando** la strategia S2I senza usare la notazione `~`.
2. Dimostra che la BuildConfig è di tipo `Source` e quale builder ha scelto `oc new-app`.
3. Cosa succede se nel progetto non esiste nessun image stream `nodejs`? (Prova in un progetto nuovo, poi eliminalo.)

<details><summary>Suggerimenti</summary>

- Guarda le opzioni `--strategy` e `--image-stream` in `oc new-app --help`.
- Prima di creare, usa `-o yaml` per vedere `sourceStrategy.from`.
- Senza image stream adatti, new-app cerca un'immagine con il nome del linguaggio su Docker Hub: leggi attentamente i messaggi `-->`.
</details>

<details><summary>Soluzione (aprila solo dopo aver provato)</summary>

```bash
oc project ${LAB}-m02

# --- 1. Strategia S2I forzata, senza "~" -------------------------------------------
# Prima di tutto: la variabile è caricata? (se è vuota, l'argomento diventa solo "#main")
echo "$GIT_REPO"                                # deve stampare l'URL del tuo repository

# Anteprima: nessuna risorsa creata. --strategy=source scavalca il Dockerfile di hello-node.
#   -i     = image stream da usare come builder (senza la notazione "~")
#   --code = dichiara esplicitamente che l'argomento è il repository dei sorgenti
oc new-app -i nodejs:22-ubi9 --code="$GIT_REPO#main" --context-dir=hello-node \
  --name=hello-forced --strategy=source -o yaml > $EX288_WORK/m02/hello-forced.yaml
grep -n -A5 'sourceStrategy:' $EX288_WORK/m02/hello-forced.yaml
#   sourceStrategy:
#     from:
#       kind: ImageStreamTag
#       name: nodejs:22-ubi9
#       namespace: <lab>-m02

# Se l'anteprima va bene, crea davvero (stessa riga senza -o yaml)
oc new-app -i nodejs:22-ubi9 --code="$GIT_REPO#main" --context-dir=hello-node \
  --name=hello-forced --strategy=source

oc logs -f bc/hello-forced                      # fasi S2I: assemble, npm install, push

# --- 2. Prova: BuildConfig di tipo Source e builder scelto -------------------------
oc get bc hello-forced                          # TYPE = Source, FROM = Git@main
oc get bc hello-forced -o jsonpath='{.spec.strategy.type}{"\n"}'
# Source
oc get bc hello-forced -o jsonpath='{.spec.strategy.sourceStrategy.from.kind}{" "}{.spec.strategy.sourceStrategy.from.namespace}{"/"}{.spec.strategy.sourceStrategy.from.name}{"\n"}'
# ImageStreamTag <lab>-m02/nodejs:22-ubi9      (se ha scelto l'image stream del passo 3.2)
oc get bc hello-forced -o jsonpath='{.spec.source.git.ref}{" "}{.spec.source.contextDir}{"\n"}'
# main hello-node

# --- 3. Progetto senza image stream "nodejs" ----------------------------------------
oc new-project ${LAB}-m02-nobuilder             # diventa il progetto corrente
oc get is                                       # No resources found: nessun builder locale
oc get is nodejs -n openshift                   # esiste il builder "di sistema" (Samples Operator)?

# Qui NON indichiamo il builder (-i): vogliamo vedere cosa sceglie new-app da solo
oc new-app --code="$GIT_REPO#main" --context-dir=hello-node --name=hello-forced --strategy=source
# Caso A - esiste openshift/nodejs:
#   --> Found image ... in image stream "openshift/nodejs" under tag "..." for "nodejs"
#   la BuildConfig usa from.namespace=openshift e la build funziona
# Caso B - nessun image stream adatto (né qui né in openshift):
#   new-app cerca un'immagine chiamata "nodejs" su un registry esterno (Docker Hub);
#   se non la trova termina con un errore e NON crea nulla
oc get bc,is                                    # caso A: bc/hello-forced; caso B: nessuna risorsa
oc get bc hello-forced -o jsonpath='{.spec.strategy.sourceStrategy.from}{"\n"}'   # solo nel caso A

# Pulizia
oc project ${LAB}-m02
oc delete project ${LAB}-m02-nobuilder
```

> **Errore "--strategy is specified and none of the arguments provided could be classified as a source code location":** `oc new-app` non ha riconosciuto l'argomento come repository di sorgenti. Le cause tipiche sono due: `$GIT_REPO` è vuota (nuovo terminale senza `source env.sh`: l'argomento diventa solo `#main`), oppure l'URL passato "nudo" non viene riconosciuto come repository Git dalla tua postazione (ad esempio repository privato o non raggiungibile dal PC). Con `--code=` dichiari tu che è codice sorgente, quindi la classificazione automatica non serve; verifica comunque che `git ls-remote "$GIT_REPO" main` funzioni dal tuo PC, perché `oc new-app` legge il repository anche localmente per rilevare linguaggio e strategia.
>
> **Da verificare sul tuo cluster:** quale tag sceglie `oc new-app` senza builder esplicito. L'image stream `nodejs` del passo 3.2 ha solo il tag `22-ubi9` (niente `latest`), mentre `openshift/nodejs`, se esiste, ha più tag: il risultato dipende da cosa trova nei due namespace. Controlla sempre con `grep -A5 'sourceStrategy:' $EX288_WORK/m02/hello-forced.yaml` prima di creare. Anche il messaggio esatto del caso B (e se su Docker Hub esista un'immagine con quel nome) va letto sul tuo cluster: guarda le righe `-->` e l'eventuale `error:`.

**Perché `--strategy=source`:** in `hello-node` c'è un `Dockerfile`, quindi senza opzioni new-app sceglierebbe la strategia Docker (passo 3.3). `--strategy=source` forza S2I; a quel punto new-app rileva il linguaggio dai file del context dir (`package.json` ⇒ `nodejs`) e cerca un builder: prima image stream tag con annotazione `supports` corrispondente o image stream con il nome del linguaggio (nel progetto corrente e in `openshift`), poi un'immagine con quel nome su Docker Hub. Il builder scelto si legge in `spec.strategy.sourceStrategy.from`.

**Cosa succede senza image stream `nodejs`:** se il cluster ha `openshift/nodejs`, new-app usa quello e tutto funziona (ma il tag non l'hai scelto tu). Se non esiste nessun image stream adatto, new-app ripiega sulla ricerca esterna per nome: nel migliore dei casi fallisce senza creare nulla, nel peggiore usa un'immagine non Red Hat. Per questo all'esame indica sempre il builder (`builder~repo` oppure `-i builder --code repo`) e verifica con `-o yaml`.
</details>

> **Da verificare sul tuo cluster:** con `--strategy=source` e senza builder esplicito, il tag scelto dipende dagli image stream presenti (annotazione `supports` o nome uguale al linguaggio). Controlla sempre con `-o yaml`; all'esame preferisci la forma esplicita `builder~repo`.

### 4.3 Esercizio senza aiuti

Nel progetto `${LAB}-m02` crea un secondo ambiente "staging" composto da: un database PostgreSQL `staging-db` (utente `stg`, database `stgdb`) e un'app `staging-web` costruita con strategia **Docker** dal branch `feature-msg`, collegata al database. `staging-web` deve essere raggiungibile solo via HTTPS e l'endpoint `/db` deve rispondere `raggiungibile`. Tutte le risorse devono avere la label `env=staging`.

---

## 5. Verifiche pratiche con `oc`

| Domanda | Comando |
|---|---|
| Che strategia usa la build? | `oc get bc` (colonna TYPE) · `oc get bc <bc> -o jsonpath='{.spec.strategy.type}'` |
| Da quale repo/branch/cartella costruisce? | `oc describe bc <bc>` (URL, Ref, ContextDir) |
| Che builder usa (S2I)? | `oc get bc <bc> -o jsonpath='{.spec.strategy.sourceStrategy.from}'` |
| La build è finita? Con che esito? | `oc get builds` · `oc describe build <bc>-<n>` (Status, Reason) |
| Quale commit è stato costruito? | `oc describe build <bc>-<n>` (Commit) · confronta con `git ls-remote origin <branch>` |
| Log della build | `oc logs -f bc/<bc>` · `oc logs build/<bc>-<n>` |
| Il Deployment segue l'image stream? | `oc get deploy <d> -o jsonpath='{.metadata.annotations.image\.openshift\.io/triggers}'` |
| Env di build vs runtime | `oc set env bc/<bc> --list` · `oc set env deployment/<d> --list` |
| Che source secret usa? | `oc get bc <bc> -o jsonpath='{.spec.source.sourceSecret.name}'` |
| Il commit locale è sul remoto? | `git status` ("ahead of 'origin/...' by N commits" = push mancante) |

---

## 6. Troubleshooting intenzionale

Gli scenari 1-3 si creano con gli script in `troubleshooting/` (idempotenti: se la risorsa esiste già non la ricreano). Gli scenari 4-5 si riproducono con i comandi indicati.

```bash
oc project ${LAB}-m02
bash $EX288_HOME/02-git-e-app-da-sorgente/troubleshooting/rompi-1-context-dir.sh
bash $EX288_HOME/02-git-e-app-da-sorgente/troubleshooting/rompi-2-repo-url.sh
bash $EX288_HOME/02-git-e-app-da-sorgente/troubleshooting/rompi-3-branch.sh
```

### Scenario 1 — `ctx` non costruisce

**Sintomo:** `oc get builds` mostra `ctx-1` in stato `Failed`; nessun pod applicativo parte.

<details><summary>Indagine e soluzione</summary>

```bash
oc get builds                       # ctx-1  Source  Git  Failed (...)
oc describe build ctx-1 | grep -iE 'status|reason|context'
oc logs build/ctx-1                 # ... context directory "hello" does not exist / not found
oc describe bc ctx | grep -i 'context'
```
**Causa:** `--context-dir=hello` invece di `hello-node`: la cartella non esiste nel repo.
**Fix:** `oc patch bc/ctx --type=merge -p '{"spec":{"source":{"contextDir":"hello-node"}}}'` e poi `oc start-build ctx --follow`.
**Lezione:** il context dir è la radice della build. Se lo sbagli **senza** builder esplicito (`oc new-app $GIT_REPO --context-dir=...`), il problema emerge prima: new-app non trova né Dockerfile né file noti e risponde con un errore di rilevamento ("No language matched..."), oppure sceglie una strategia diversa da quella attesa (ad esempio context dir `hello-node` ⇒ Docker invece di S2I). Controlla sempre la colonna TYPE.
</details>

### Scenario 2 — `badrepo` fallisce subito

**Sintomo:** la build `badrepo-1` è `Failed` dopo pochi secondi.

<details><summary>Indagine e soluzione</summary>

```bash
oc get build badrepo-1 -o jsonpath='{.status.reason}{"\n"}'   # FetchSourceFailed
oc logs build/badrepo-1             # Cloning "https://github.com/ex288-repo-inesistente/..." ... error / not found / authentication
oc describe bc badrepo | grep -i url
```
**Causa:** URL del repository errato (o repo non raggiungibile dal cluster: proxy, firewall, DNS interno). Un repo inesistente su GitHub risponde spesso come un repo privato (richiesta di credenziali), perché GitHub non rivela se il repo esiste.
**Fix:** `oc patch bc/badrepo --type=merge -p "{\"spec\":{\"source\":{\"git\":{\"uri\":\"$GIT_REPO\"}}}}"` e `oc start-build badrepo --follow`.
**Lezione:** `FetchSourceFailed` = il problema è **prima** della build vera: URL, ref, credenziali, rete. Se l'URL è giusto ma il repo è privato, serve un source secret (sezione 3.7). Verifica dal tuo PC con `git ls-remote <url>`; ricorda però che il cluster potrebbe non raggiungere ciò che raggiungi tu.
</details>

### Scenario 3 — `badbranch` non trova il codice

**Sintomo:** la build `badbranch-1` è `Failed`.

<details><summary>Indagine e soluzione</summary>

```bash
oc logs build/badbranch-1           # ... Remote branch feature-inesistente not found / couldn't find remote ref
oc get bc badbranch -o jsonpath='{.spec.source.git.ref}{"\n"}'
git ls-remote --heads origin        # i branch che esistono davvero sul remoto
```
**Causa:** il ref `feature-inesistente` non esiste sul remoto (errore di battitura, oppure branch creato solo in locale e mai pushato).
**Fix:** `oc patch bc/badbranch --type=merge -p '{"spec":{"source":{"git":{"ref":"feature-msg"}}}}'` e `oc start-build badbranch --follow`.
**Lezione:** `git branch` mostra i branch locali; ciò che conta per il cluster è `git ls-remote --heads origin`.
</details>

### Scenario 4 — Repository privato senza secret (solo se hai un repo privato)

**Riproduci:** `oc new-app nodejs:22-ubi9~<url-repo-privato> --context-dir=hello-node --name=nosecret`
**Sintomo:** build `Failed`, motivo `FetchSourceFailed`.

<details><summary>Indagine e soluzione</summary>

```bash
oc logs build/nosecret-1            # ... could not read Username / Authentication failed
oc get bc nosecret -o jsonpath='{.spec.source.sourceSecret}{"\n"}'     # vuoto
```
**Causa:** il cluster non ha credenziali per clonare.
**Fix:** crea il secret basic-auth con il token (sezione 3.7), `oc set build-secret --source bc/nosecret git-cred`, `oc start-build nosecret --follow`.
**Lezione:** le credenziali Git della tua postazione (keychain, SSH agent) non esistono nel pod di build.
</details>

### Scenario 5 — "Ho modificato il codice ma il pod mostra la versione vecchia"

**Riproduci:**

```bash
cd $EX288_WORK/ex288-apps && git switch feature-msg
sed -i.bak 's/Ciao dal branch feature-msg!/Messaggio v2 dal branch/' hello-node/server.js && rm hello-node/server.js.bak
git commit -am "Messaggio v2"       # ... e NON fare push
oc start-build hello-feature --follow
curl -s http://$(oc get route hello-feature -o jsonpath='{.spec.host}')/ | grep message
```
**Sintomo:** la build è `Complete`, il rollout avviene, ma il messaggio non è cambiato.

<details><summary>Indagine e soluzione</summary>

```bash
git status                          # Your branch is ahead of 'origin/feature-msg' by 1 commit
git log --oneline -1                # hash del commit locale
oc describe build hello-feature-2 | grep -i commit    # hash DIVERSO: il cluster ha usato il commit remoto
```
(Se `hello-feature` punta ancora al tag `v1.0`, riportala a `feature-msg` come nel passo 3.6.)

**Causa:** push dimenticato. Il cluster clona il remoto, che non contiene il nuovo commit.
**Fix:** `git push`, poi `oc start-build hello-feature --follow`. Torna su `main` con `git switch main`.
**Lezione:** prima di ogni `oc start-build` esegui `git status`. Confronta sempre il *Commit* della build con `git log`.
</details>

Pulizia: `oc delete project ${LAB}-m02`

---

## 7. Esercizio finale (stile EX288)

> Lavora come all'esame: niente soluzioni, solo documentazione ufficiale, `oc --help` e `oc explain`. Tempo indicativo: **40 minuti**.

**Requisiti**

1. Esiste il progetto `${LAB}-m02-exam`.
2. Nel tuo repository `$GIT_REPO` esiste il branch **`exam-v2`**, presente sul remoto, in cui il messaggio di default dell'app `hello-node` (quello restituito quando `APP_MESSAGE` non è impostata) è **`Catalogo v2`**.
3. Nel progetto gira l'applicazione **`catalog`**:
   - costruita con strategia **Source (S2I)** con il builder Node.js 22 UBI 9;
   - sorgente: `$GIT_REPO`, branch `exam-v2`, cartella `hello-node`;
   - la BuildConfig ha la variabile di build `BUILD_LOGLEVEL=2`;
   - il Deployment ha la variabile `APP_VERSION=2.0.0` e **non** imposta `APP_MESSAGE`: il messaggio `Catalogo v2` deve arrivare dal **codice** del branch `exam-v2` (requisito 2), non da una variabile d'ambiente;
   - l'ultima build è completata e corrisponde all'ultimo commit del branch `exam-v2` sul remoto;
   - è raggiungibile solo via HTTPS tramite la route `catalog` con terminazione edge.
4. Nel progetto gira l'applicazione **`orders`**:
   - costruita con strategia **Docker** dal branch `main`, cartella `hello-node`;
   - il Deployment ha `APP_MESSAGE=Ordini`;
   - è raggiungibile via HTTP tramite la route `orders`.
5. Nel progetto gira il database **`orders-db`** dall'immagine `$POSTGRES_IMAGE`, con utente `orders` e database `ordersdb`, raggiungibile da `orders` tramite il Service `orders-db` sulla porta 5432. `orders` è configurata con `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_PASSWORD` coerenti.
6. Le BuildConfig di `catalog` e `orders`, e i Deployment e i Service di `catalog`, `orders` e `orders-db`, hanno la label `team=shop`.

**Risultato atteso**

- `https://<route catalog>/` restituisce `"message": "Catalogo v2"` (valore di default scritto nel codice del branch `exam-v2`) e `"version": "2.0.0"` (variabile del Deployment).
- `http://<route orders>/` restituisce `"message": "Ordini"`.
- `http://<route orders>/db` restituisce HTTP 200 con `"db": "raggiungibile"`.

```bash
bash $EX288_HOME/02-git-e-app-da-sorgente/verifica.sh
```

---

## 8. Riferimenti ufficiali (OCP 4.22)

- Building applications → *Creating applications* → *Creating an application by using the CLI* (`oc new-app`, rilevamento strategia e linguaggio, `~`, `#ref`, `--context-dir`, `--source-secret`, `--group`): https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/building_applications/creating-applications
- Builds using BuildConfig → *Creating build inputs* (Git source, source clone secrets, `source-secret-match-uri`): https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/builds_using_buildconfig/creating-build-inputs
- Builds using BuildConfig → *Understanding image builds* e *Using build strategies* (Docker, S2I): https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/builds_using_buildconfig/build-strategies
- Builds using BuildConfig → *Performing and configuring basic builds* (`oc start-build`, `oc logs`, `BUILD_LOGLEVEL`): https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/builds_using_buildconfig/basic-build-operations
- Images → *Triggering updates on image stream changes* (annotazione `image.openshift.io/triggers`): https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/images/triggering-updates-on-imagestream-changes
- Release notes OCP 4.22 (deprecazione di DeploymentConfig e Cluster Samples Operator): https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/release_notes/ocp-4-22-release-notes
