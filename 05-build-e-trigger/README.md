# Modulo 05 — Build, BuildConfig, trigger e build hook

> **Obiettivi EX288 coperti**
> - *Work with container images in OpenShift Container Platform* → Understand and work with image builds and image build configurations
> - *Work with build hooks and build triggers* → Create a build hook that runs a provided script
> - *Work with build hooks and build triggers* → Test and confirm proper operation of the hook
> - *Work with build hooks and build triggers* → Manage and trigger application builds
> - *Troubleshoot application builds and deployment issues* → Diagnose and correct minor issues with build process
>
> **Durata stimata:** 5-6 ore · **Prerequisiti:** moduli 02-04 (branch `exam-v2` creato nell'esercizio finale del modulo 02) · **Richiede cluster-admin:** no (il RoleBinding per i webhook non autenticati, passo 3.10, potrebbe richiedere l'amministratore: è indicata un'alternativa)
>
> **Progetti usati:** `${LAB}-m05`, `${LAB}-m05-altro` (troubleshooting), `${LAB}-m05-exam`

---

## 1. Perché e quando

Nei moduli 02-04 hai lasciato che `oc new-app` creasse la BuildConfig per te. All'esame ti verrà chiesto di **modificarla**: cambiare il tag di output, aggiungere un trigger, un hook di test, una variabile di build, capire perché una build fallisce. Per farlo devi conoscerne l'anatomia campo per campo.

| Ti serve… | Usa | Perché |
|---|---|---|
| App completa (build + Deployment + Service) da Git | `oc new-app` | Crea tutto in un comando, trigger compresi |
| Solo l'immagine (builder, base aziendale, immagine da promuovere) | `oc new-build` | Crea image stream + BuildConfig, **nessun** Deployment |
| Controllo totale e ripetibile, revisione in Git | BuildConfig **YAML** + `oc apply` | Ogni campo è esplicito; parti da `oc new-build ... -o yaml` |
| Ricostruire quando cambia il codice | Trigger **webhook** (GitHub, GitLab, Bitbucket, Generic) | Il sistema Git notifica il cluster a ogni push |
| Ricostruire quando esce una patch dell'immagine builder/base | Trigger **ImageChange** | Le correzioni di sicurezza della base arrivano nell'app senza intervento umano |
| Una prima build subito dopo la creazione | Trigger **ConfigChange** | Scatta **solo** alla creazione della BuildConfig |
| Un sistema esterno (CI, script, scheduler) che avvia build | Webhook **Generic** + `curl` | Basta una POST HTTP; niente `oc` né token se il progetto lo consente |
| Bloccare la pubblicazione di un'immagine che non passa i test | **Post-commit build hook** | Gira sull'immagine appena costruita, **prima** del push: se fallisce, l'immagine non esiste |
| Test complessi, più stadi, approvazioni | OpenShift Pipelines (modulo 12) | L'hook è un singolo comando; una pipeline orchestra più passi |
| Codice sul PC, prove rapide | Build **binaria** (`--from-dir`, `--from-file`) | Nessun push su Git; ma nessun trigger automatico |

---

## 2. Concetti essenziali

### 2.1 BuildConfig, Build e pod di build

- **BuildConfig** (`bc`) è la ricetta; **Build** (`hello-1`, `hello-2`…) è una singola esecuzione, con fasi `New` → `Pending` → `Running` → `Complete` | `Failed` | `Error` | `Cancelled`.
- Il **pod di build** (`hello-1-build`) esegue clone, build e push con il service account **`builder`** del progetto:

```
oc start-build / trigger ──▶ Build hello-N ──▶ pod hello-N-build ──▶ clone ▶ build ▶ [post-commit hook] ▶ push ──▶ ImageStreamTag
```

### 2.2 Anatomia di una BuildConfig

Il file `lab/hello-build.yaml` contiene una BuildConfig completa e commentata. I blocchi principali:

| Campo | Significato | Note |
|---|---|---|
| `spec.source` | Da dove viene il codice: `git` (`uri`, `ref`), `contextDir`, `dockerfile` inline, `binary`, `images`, `secrets`, `configMaps` | Tutto ciò che sta fuori da `contextDir` è ignorato |
| `spec.strategy.type` | `Source` (S2I), `Docker`, `Custom`, `JenkinsPipeline` | Vedi 2.3 |
| `spec.strategy.*Strategy.from` | Immagine builder (S2I) o sostituto dell'**ultimo** `FROM` (Docker) | `ImageStreamTag`, `ImageStreamImage` o `DockerImage` |
| `spec.strategy.*Strategy.env` | Variabili di build | Restano anche nell'immagine prodotta |
| `spec.output.to` | `ImageStreamTag` (registry interno) o `DockerImage` (registry esterno, con `pushSecret`) | Output vuoto = nessun push |
| `spec.output.imageLabels` | Label aggiunte all'immagine prodotta | Utile per metadati senza toccare il Dockerfile |
| `spec.triggers` | `ConfigChange`, `ImageChange`, `GitHub`, `GitLab`, `Bitbucket`, `Generic` | Vedi 2.5 |
| `spec.postCommit` | Build hook: `script` **oppure** `command`/`args` | Vedi 2.6 |
| `spec.runPolicy` | `Serial` (default), `SerialLatestOnly`, `Parallel` | Come gestire build concorrenti |
| `spec.successfulBuildsHistoryLimit` / `failedBuildsHistoryLimit` | Quante build vecchie conservare | Le più vecchie vengono eliminate automaticamente |
| `spec.resources` | `requests`/`limits` del pod di build | Necessarie se il progetto ha una quota senza LimitRange |
| `spec.completionDeadlineSeconds` | Tempo massimo di esecuzione | Oltre, la build viene terminata |

Un esempio di strategia Docker (campi che userai):

```yaml
strategy:
  type: Docker
  dockerStrategy:
    dockerfilePath: Dockerfile          # relativo a contextDir (default "Dockerfile")
    from: {kind: ImageStreamTag, name: "nodejs-22-minimal:latest"}   # opzionale: sostituisce l'ULTIMO FROM
    env: [{name: APP_VERSION, value: "2.0.0"}]                         # ENV di build, restano nell'immagine
    buildArgs: [{name: NPM_FLAGS, value: "--omit=dev"}]                # valori per le istruzioni ARG
```

> **Abitudine da esame:** non ricordi un campo? `oc explain bc.spec.strategy.sourceStrategy`, `oc explain bc.spec.triggers.generic`, `oc explain bc.spec.postCommit`. È documentazione ufficiale sempre disponibile.

### 2.3 Strategie

| Strategia | Quando | Note |
|---|---|---|
| `Source` (S2I) | Codice senza Dockerfile, linguaggio con builder disponibile | Modulo 06 per la personalizzazione |
| `Docker` | Il repo ha un Dockerfile o vuoi controllare ogni layer | Eseguita con Buildah nel pod di build |
| `Custom` | Logica di build interamente tua in un'immagine builder | Gira con privilegi elevati: **non disponibile agli utenti di default**. Solo un cenno |
| `JenkinsPipeline` | — | **Deprecata** in OpenShift 4: "Equivalent and improved functionality is present in the OpenShift Container Platform Pipelines based on Tekton" (modulo 12) |

> **Nota di versione:** in 4.22 la documentazione ha anche un libro separato *Builds using Shipwright*. L'EX288 riguarda le BuildConfig: Shipwright non serve per l'esame.

### 2.4 Input della build

Ordine di precedenza documentato quando ne combini più di uno: Dockerfile inline, contenuto da immagini, Git, binario, secret di input, artefatti esterni. **Git e Binary si escludono a vicenda.**

| Input | YAML | CLI |
|---|---|---|
| Git + ref + sottocartella | `source.git.uri`, `source.git.ref`, `source.contextDir` | `oc new-build <repo>#<ref> --context-dir=<dir>` |
| Dockerfile inline (sovrascrive quello del repo) | `source.dockerfile: "FROM ...\nRUN ..."` | `oc new-build -D $'FROM ...\nRUN ...'` |
| Binario (file dal tuo PC) | `source.type: Binary` | `oc new-build --binary` + `oc start-build --from-dir` / `--from-file` / `--from-archive` / `--from-repo` |
| ConfigMap / Secret copiati nel contesto di build | `source.configMaps[].configMap.name` + `destinationDir`, `source.secrets[]...` | `oc new-build ... --build-config-map "settings:.m2" --build-secret "cred:.ssh"` |
| Credenziali Git | `source.sourceSecret.name` | `oc set build-secret --source bc/x <secret>` (modulo 02) |

> Con S2I i secret di input vengono troncati a 0 byte dopo `assemble`: non finiscono nell'immagine. Le variabili d'ambiente di build invece **restano** nell'immagine e compaiono in chiaro nel log: non usarle per password.

### 2.5 Trigger

| Tipo | Scatta quando | YAML minimo |
|---|---|---|
| `ConfigChange` | La BuildConfig viene **creata** (non quando la modifichi) | `- type: ConfigChange` |
| `ImageChange` | Il tag dell'immagine `from` (o di quella indicata) punta a una nuova immagine | `- type: ImageChange` + `imageChange: {}` |
| `Generic` | Una POST HTTP sull'URL del webhook | `generic: {secretReference: {name: s}, allowEnv: true}` |
| `GitHub` / `GitLab` / `Bitbucket` | Il servizio Git chiama l'URL a ogni push | `github: {secretReference: {name: s}}` |

- Il Secret dei webhook deve contenere la chiave **`WebHookSecretKey`**; il suo valore fa parte dell'URL. Trova l'URL con `oc describe bc <nome>`:
  `https://<api>:6443/apis/build.openshift.io/v1/namespaces/<ns>/buildconfigs/<nome>/webhooks/<secret>/generic`
- `oc new-app` e `oc new-build` creano automaticamente trigger ConfigChange, ImageChange e webhook GitHub + Generic.
- Le build **binarie** non partono mai da trigger.

> **Nota di versione (4.16+):** gli utenti **non autenticati** (GitHub, un `curl` senza token) non hanno più accesso al ruolo `system:webhook` per default. Per ricevere webhook da sistemi esterni serve in ogni progetto un RoleBinding che leghi il ClusterRole `system:webhook` al gruppo `system:unauthenticated` (`lab/webhook-rolebinding.yaml`). La documentazione indica la procedura come attività da `cluster-admin`; spesso l'admin del progetto può crearlo da sé. Se ricevi `forbidden`, chiedilo all'amministratore.

### 2.6 Post-commit build hook

- Gira in un **container temporaneo** creato dall'immagine appena costruita, dopo il commit dell'ultimo layer e **prima del push**. Directory di lavoro = `WORKDIR` dell'immagine (per le immagini S2I Node.js, `/opt/app-root/src`, dove c'è il codice).
- Exit code diverso da zero ⇒ build `Failed` e immagine **non pubblicata**: il Deployment resta sulla versione precedente.
- Le modifiche fatte dall'hook **non** restano nell'immagine (puoi installare dipendenze di test senza appesantirla).
- Vede le variabili d'ambiente dell'immagine, quindi anche quelle di build.

```yaml
postCommit: {script: "npm test"}        # forma "script": eseguito con /bin/sh -ic
# in alternativa, forma "command" (senza shell, args opzionali):
# postCommit: {command: ["npm", "test"], args: ["--", "--verbose"]}
```

`script` e `command` insieme sono **invalidi**.

---

## 3. Laboratorio guidato

```bash
source env.sh                 # dalla root del repository ex288-teach
```

### 3.1 Progetto e builder

```bash
oc new-project ${LAB}-m05 --display-name="EX288 m05 - build e trigger"
oc import-image nodejs:22-ubi9 --from=registry.access.redhat.com/ubi9/nodejs-22 --confirm   # builder nel progetto (modulo 02)
```

### 3.2 Una BuildConfig scritta a mano

Leggi `lab/hello-build.yaml` con attenzione, poi applicalo. Il Secret del webhook va creato **prima**, perché la BuildConfig lo referenzia.

```bash
oc apply -f $EX288_HOME/05-build-e-trigger/lab/hello-webhook-secret.yaml

# Sostituisce i segnaposto con le tue variabili e invia il risultato a oc apply
sed -e "s|__GIT_REPO__|$GIT_REPO|g" -e "s|__GIT_BRANCH__|$GIT_BRANCH|g" \
  $EX288_HOME/05-build-e-trigger/lab/hello-build.yaml | oc apply -f -

oc get bc hello                     # TYPE Source, FROM Git@main, LATEST 1
oc get builds                       # hello-1 Running: l'ha avviata il trigger alla creazione
oc describe build hello-1 | grep -iA1 'cause'   # chi ha avviato la build
oc logs -f bc/hello                 # log dell'ultima build di hello
```

Con trigger ConfigChange **e** ImageChange insieme, la prima build può risultare causata dall'uno o dall'altro: in ogni caso parte una sola build iniziale. Nota che `hello-node` contiene un `Dockerfile`, ma la strategia è scritta nella BuildConfig (`Source`): il rilevamento automatico riguarda solo `oc new-app`/`oc new-build`.

### 3.3 Deployment che segue l'output

```bash
oc new-app --image-stream=hello:latest --name=hello   # Deployment con trigger su hello:latest + Service
oc expose service/hello
URL=http://$(oc get route hello -o jsonpath='{.spec.host}')
curl -s $URL/ | grep -E 'version|message'
oc rollout history deployment/hello                   # REVISION 1
```

### 3.4 Gestire le build

```bash
oc start-build hello                  # avvia e ritorna subito: build/hello-2 started
oc start-build hello --follow         # avvia e mostra il log fino alla fine
oc start-build hello --wait; echo $?  # attende la fine; exit code != 0 se la build fallisce

oc get builds                         # elenco con TYPE, FROM (commit), STATUS, DURATION
oc get pods                           # i pod hello-N-build in stato Completed
oc describe build hello-2             # commit, autore, durata, causa, eventi
oc logs build/hello-2                 # log di una build precisa
oc logs --version=2 bc/hello          # stessa cosa, per numero di versione
oc logs -f bc/hello                   # log dell'ULTIMA build (anche in corso)

# Rilanciare, annullare, cambiare verbosità
oc start-build --from-build=hello-2 --follow   # stessa build di hello-2 (stesso commit)
oc start-build hello -e APP_NOTE=una-tantum    # variabile valida solo per questa build
oc start-build hello --build-loglevel=5        # log molto dettagliato (0-5) solo per questa build
oc cancel-build hello-7                        # annulla una build (nome a scelta tra quelle in corso)
oc cancel-build bc/hello                       # annulla le build in corso/in coda di hello
oc set env bc/hello BUILD_LOGLEVEL=3           # verbosità permanente (sourceStrategy.env)
oc get builds -l buildconfig=hello             # history limit: al massimo 3 Complete e 2 fallite/annullate
```

> `oc delete bc hello` elimina anche tutte le build; `oc delete --cascade=false bc hello` le conserva.

### 3.5 runPolicy: build concorrenti

```bash
oc patch bc/hello --type=merge -p '{"spec":{"runPolicy":"SerialLatestOnly"}}'
for i in 1 2 3; do oc start-build hello; done
oc get builds -w      # la prima gira; delle due in coda resta solo l'ultima, l'altra va in Cancelled
oc patch bc/hello --type=merge -p '{"spec":{"runPolicy":"Serial"}}'
```

`Serial` (default) esegue una build alla volta, in ordine; `SerialLatestOnly` annulla le build in coda superate da una più recente (utile con molti push ravvicinati); `Parallel` le esegue tutte insieme, senza garanzia sull'ordine di completamento.

### 3.6 `oc new-build` e altri tipi di input

```bash
# 1) Come 3.2 in un comando: solo ImageStream + BuildConfig (con trigger), nessun Deployment/Service.
#    Con -o yaml non crea nulla: ottimo punto di partenza per un file da modificare e applicare.
oc new-build "nodejs:22-ubi9~$GIT_REPO" --context-dir=hello-node --name=hello-nb -o yaml | less

# 2) Dockerfile inline (Docker strategy, nessun Git)
oc new-build --name=inline -D $'FROM registry.access.redhat.com/ubi9/ubi-minimal\nRUN echo "costruita da Dockerfile inline" > /tmp/info.txt\nCMD ["cat", "/tmp/info.txt"]'
oc logs -f bc/inline && oc get bc inline -o jsonpath='{.spec.source.dockerfile}{"\n"}'
oc run inline-test --image=$(oc get is inline -o jsonpath='{.status.dockerImageRepository}'):latest --restart=Never
oc logs inline-test; oc delete pod inline-test        # costruita da Dockerfile inline

# 3) Build binaria S2I da una cartella locale (anche senza commit)
oc new-build --binary --image-stream=nodejs:22-ubi9 --name=hello-local
oc start-build hello-local --from-dir=$EX288_WORK/ex288-apps/hello-node --follow   # Uploading directory ...

# 4) Build binaria Docker da UN file (deve chiamarsi Dockerfile)
mkdir -p $EX288_WORK/m05/onefile && printf 'FROM registry.access.redhat.com/ubi9/ubi-minimal\nLABEL ex288.demo="from-file"\n' > $EX288_WORK/m05/onefile/Dockerfile
oc new-build --binary --strategy=docker --name=onefile
oc start-build onefile --from-file=$EX288_WORK/m05/onefile/Dockerfile --follow
```

### 3.7 Variabili di build

```bash
oc set env bc/hello APP_BUILD_NOTE="impostata nella BuildConfig"
oc set env bc/hello --list            # BUILD_LOGLEVEL, APP_BUILD_NOTE
oc start-build hello --follow
oc exec deployment/hello -- printenv APP_BUILD_NOTE    # presente anche a runtime: è nell'immagine
oc set env bc/hello APP_BUILD_NOTE-   # rimuove la variabile
```

All'atto della creazione: `oc new-app ... --build-env=VAR=val` / `oc new-build ... --build-env=VAR=val` (non confonderle con `-e`, che finisce nel Deployment).

### 3.8 Trigger ConfigChange: solo alla creazione

```bash
oc get bc hello -o jsonpath='{.status.lastVersion}{"\n"}'      # annota il numero dell'ultima build
oc set env bc/hello DEMO=1; sleep 10                          # modifica la BuildConfig...
oc get bc hello -o jsonpath='{.status.lastVersion}{"\n"}'      # ...stesso numero: nessuna build
oc set env bc/hello DEMO-
```

Modificare la BuildConfig (anche `source.git.ref`) **non** avvia una build: serve `oc start-build` o un altro trigger.

### 3.9 Trigger ImageChange: la catena completa

Simuliamo una "patch" del builder Node.js: un'immagine derivata con una label in più, poi spostiamo il tag `nodejs:22-ubi9` su di essa.

```bash
# 1) Il builder "patchato" (build Docker con Dockerfile inline)
oc new-build --name=builder-patch --to=nodejs-patch:1 \
  -D $'FROM registry.access.redhat.com/ubi9/nodejs-22\nLABEL ex288.patch="1"'
oc logs -f bc/builder-patch

# 2) Situazione prima
oc get istag nodejs:22-ubi9 -o jsonpath='{.image.metadata.name}{"\n"}'          # digest attuale del builder
oc get bc hello -o jsonpath='{.status.imageChangeTriggers[*].lastTriggeredImageID}{"\n"}'
oc rollout history deployment/hello | tail -2

# 3) Il tag del builder punta alla nuova immagine
oc tag nodejs-patch:1 nodejs:22-ubi9

# 4) Osserva la catena: build di hello (causa Image change) -> nuovo hello:latest -> rollout
oc get builds -w                                       # Ctrl+C quando hello-N è Complete
oc describe build $(oc get bc hello -o jsonpath='hello-{.status.lastVersion}') | grep -iA2 cause
oc rollout status deployment/hello
oc rollout history deployment/hello | tail -2          # una revisione in più
# Catena: nodejs:22-ubi9 cambia -> [ImageChange bc hello] -> build -> hello:latest cambia -> [trigger Deployment] -> rollout

# 5) Ripristina il builder originale (anche questo cambio avvia una build)
oc import-image nodejs:22-ubi9 --from=registry.access.redhat.com/ubi9/nodejs-22 --confirm
```

> In produzione la "patch" la pubblica Red Hat: con `oc import-image ... --scheduled=true` (modulo 04) il tag del builder si aggiorna da solo e le app si ricostruiscono automaticamente.

### 3.10 Webhook generico

```bash
oc describe bc hello | grep -A2 'Webhook Generic'     # URL: https://api...:6443/apis/.../buildconfigs/hello/webhooks/<secret>/generic

# <secret> è il VALORE della chiave WebHookSecretKey: leggilo e costruisci l'URL
SECRET=$(oc extract secret/hello-webhook --keys=WebHookSecretKey --to=-)
HOOK="$(oc whoami --show-server)/apis/build.openshift.io/v1/namespaces/$(oc project -q)/buildconfigs/hello/webhooks/$SECRET/generic"
echo "$HOOK"

# Invocazione senza autenticazione, come farebbe un sistema esterno
curl -s -X POST -k "$HOOK"
```

Se la risposta contiene `"code": 403` e `User "system:anonymous" cannot create resource "buildconfigs/webhooks"`, nel progetto manca il RoleBinding (cambiamento 4.16+):

```bash
oc auth can-i create rolebindings              # yes = puoi crearlo tu
oc apply -f $EX288_HOME/05-build-e-trigger/lab/webhook-rolebinding.yaml
#   oppure: oc create rolebinding webhook-access-unauthenticated --clusterrole=system:webhook --group=system:unauthenticated
curl -s -X POST -k "$HOOK"
oc get builds -l buildconfig=hello | tail -1   # nuova build
oc describe build $(oc get bc hello -o jsonpath='hello-{.status.lastVersion}') | grep -iA2 cause   # Generic WebHook
```

> **Da verificare sul tuo cluster:** se ricevi `forbidden` anche creando il RoleBinding, chiedilo all'amministratore. Nel frattempo puoi invocare il webhook **da utente autenticato**: `curl -s -X POST -k -H "Authorization: Bearer $(oc whoami -t)" "$HOOK"`.

Con un payload JSON (il `ref` deve corrispondere al branch della BuildConfig, altrimenti la build non parte; `env` è accettato solo con `allowEnv: true`):

```bash
curl -s -X POST -k -H "Content-Type: application/json" \
  --data-binary @$EX288_HOME/05-build-e-trigger/lab/webhook-payload.json "$HOOK"
oc describe build $(oc get bc hello -o jsonpath='hello-{.status.lastVersion}') | grep -iE 'message|author|BUILD_LOGLEVEL'
```

> La documentazione precisa che il webhook generico avvia la build anche con un payload non valido: un `200` non prova che il payload sia stato letto. Verifica sempre nella build.

### 3.11 (Opzionale) Webhook GitHub

Solo se il repository è su GitHub **e** l'API del cluster è raggiungibile da Internet. `oc set triggers bc/hello --from-github` aggiunge un trigger GitHub con un secret generato; l'URL è in `oc describe bc hello` (*Webhook GitHub*) e il secret in `oc get bc hello -o jsonpath='{.spec.triggers[?(@.type=="GitHub")].github}'`. Su GitHub: *Settings → Webhooks → Add webhook*, *Payload URL* = URL con il secret sostituito, *Content type* = `application/json`. Poi `git push` e `oc get builds -w`.

### 3.12 Gestire i trigger con `oc set triggers`

```bash
oc set triggers bc/hello                                   # elenco: TYPE, VALUE, AUTO
oc set triggers bc/hello --from-webhook                    # aggiunge un webhook Generic (secret generato)
oc set triggers bc/hello --from-webhook --remove           # rimuove i webhook Generic
oc set triggers bc/hello --from-github --remove            # rimuove il webhook GitHub
oc set triggers bc/hello --from-image=nodejs:22-ubi9 --remove   # rimuove il trigger ImageChange
oc set triggers bc/hello --from-image=nodejs:22-ubi9       # lo rimette
oc get bc hello -o yaml | sed -n '/triggers:/,/^status/p'  # controlla sempre il risultato nello YAML
```

> **Da verificare sul tuo cluster:** `--manual`, `--auto` e `--remove-all` esistono (`oc set triggers --help`), ma il loro effetto sulle BuildConfig (rimozione o sospensione dei trigger) va controllato nello YAML dopo l'uso. Ricorda di ripristinare il webhook Generic con secret `hello-webhook` se lo hai rimosso (riapplica `lab/hello-build.yaml`).

### 3.13 Post-commit build hook

```bash
# 1) Hook che esegue lo script di test fornito con l'app (test.js, via npm test)
oc set build-hook bc/hello --post-commit --script="npm test"
oc get bc hello -o jsonpath='{.spec.postCommit}{"\n"}'     # {"script":"npm test"}
oc start-build hello --follow                              # nel log: TEST OK: / e /healthz rispondono 200
```

Dimostra che un test fallito **blocca** la pubblicazione:

```bash
DIG_PRIMA=$(oc get istag hello:latest -o jsonpath='{.image.metadata.name}')
REV_PRIMA=$(oc get deploy hello -o jsonpath='{.metadata.annotations.deployment\.kubernetes\.io/revision}')

oc set env bc/hello FAIL_TESTS=true          # test.js fallisce se FAIL_TESTS=true
oc start-build hello --follow --wait; echo "exit code: $?"   # TEST FALLITO: ... / exit code: 1
oc get builds -l buildconfig=hello | tail -1   # Failed (PostCommitHookFailed)
# Immagine e Deployment non sono cambiati
[ "$(oc get istag hello:latest -o jsonpath='{.image.metadata.name}')" = "$DIG_PRIMA" ] && echo "hello:latest invariato"
[ "$(oc get deploy hello -o jsonpath='{.metadata.annotations.deployment\.kubernetes\.io/revision}')" = "$REV_PRIMA" ] && echo "nessun rollout"

oc set env bc/hello FAIL_TESTS-               # rimuove la variabile
oc start-build hello --follow                 # Complete: push e rollout
```

Le altre forme e la rimozione (YAML equivalente della prima forma: `spec.postCommit.script: "npm test"`):

```bash
oc set build-hook bc/hello --post-commit --command -- npm test
oc get bc hello -o jsonpath='{.spec.postCommit}{"\n"}'     # {"command":["npm","test"]} (e niente "script")
oc set build-hook bc/hello --post-commit --remove
oc get bc hello -o jsonpath='{.spec.postCommit}{"\n"}'     # {}
```

### 3.14 Pulizia

Tieni `${LAB}-m05` per la sezione 6. A fine modulo: `oc delete project ${LAB}-m05 ${LAB}-m05-altro`.

---

## 4. Esercizi

### 4.1 Esercizio guidato

Nel progetto `${LAB}-m05`, **scrivendo uno YAML** (non con `new-app`/`new-build`):

1. crea l'image stream `hello-docker` e la BuildConfig `hello-docker` con strategia **Docker**, sorgente `$GIT_REPO` branch `main`, cartella `hello-node`;
2. l'output è `hello-docker:1.0`; vengono conservate al massimo 2 build riuscite e 1 fallita;
3. l'unico trigger è ConfigChange; la build deve completarsi.

<details><summary>Suggerimenti</summary>

- Parti da `lab/hello-build.yaml`: cambia `strategy` (`type: Docker`, `dockerStrategy: {}`), `output` e `triggers`.
- Con `dockerStrategy: {}` viene usato il `Dockerfile` di `contextDir` con il suo `FROM`.
</details>

<details><summary>Soluzione</summary>

```bash
oc create imagestream hello-docker
cat > $EX288_WORK/m05/hello-docker.yaml <<EOF
apiVersion: build.openshift.io/v1
kind: BuildConfig
metadata:
  name: hello-docker
spec:
  successfulBuildsHistoryLimit: 2
  failedBuildsHistoryLimit: 1
  source:
    type: Git
    git: {uri: "$GIT_REPO", ref: main}
    contextDir: hello-node
  strategy:
    type: Docker
    dockerStrategy: {}
  output:
    to: {kind: ImageStreamTag, name: "hello-docker:1.0"}
  triggers:
  - type: ConfigChange
EOF
oc apply -f $EX288_WORK/m05/hello-docker.yaml
oc logs -f bc/hello-docker
oc get istag hello-docker:1.0
```
</details>

### 4.2 Esercizio semi-guidato

1. Alla BuildConfig `hello-docker` aggiungi un post-commit hook in forma **command** che esegue `node test.js`.
2. Aggiungi un webhook Generic che usa un Secret `docker-hook` creato da te, poi avvia una build **solo** tramite `curl`.
3. Dimostra (comandi e output) che la build è stata avviata dal webhook e che l'hook è stato eseguito.

<details><summary>Suggerimenti</summary>

- `oc set build-hook ... --command -- node test.js`.
- Il Secret deve avere la chiave `WebHookSecretKey`; per il trigger con `secretReference` usa `oc edit bc/hello-docker` (oppure `oc patch`).
- La causa della build è in `oc describe build`; l'output dell'hook è nel log della build.
</details>

<details><summary>Soluzione (aprila solo dopo aver provato)</summary>

```bash
oc project ${LAB}-m05

# 1) Hook in forma "command": eseguito senza shell, nella WORKDIR dell'immagine (/opt/app-root/src)
oc set build-hook bc/hello-docker --post-commit --command -- node test.js
oc get bc hello-docker -o jsonpath='{.spec.postCommit}{"\n"}'     # {"command":["node","test.js"]}

# 2a) Secret del webhook: la chiave DEVE chiamarsi WebHookSecretKey
oc create secret generic docker-hook --from-literal=WebHookSecretKey=ex288-docker-hook

# 2b) Trigger Generic che referenzia il Secret, aggiunto in coda alla lista dei trigger
oc patch bc/hello-docker --type=json \
  -p '[{"op":"add","path":"/spec/triggers/-","value":{"type":"Generic","generic":{"secretReference":{"name":"docker-hook"}}}}]'
oc get bc hello-docker -o jsonpath='{.spec.triggers}{"\n"}'
# [{"type":"ConfigChange"},{"generic":{"secretReference":{"name":"docker-hook"}},"type":"Generic"}]
oc set triggers bc/hello-docker                                    # ora elenca anche il webhook generico

# 2c) I non autenticati possono chiamare i webhook del progetto? (RoleBinding del passo 3.10)
oc get rolebinding -o wide | grep system:webhook                   # se non compare nulla, crealo:
oc create rolebinding webhook-access-unauthenticated --clusterrole=system:webhook --group=system:unauthenticated

# 2d) URL del webhook: oc describe mostra <secret> al posto del valore
oc describe bc hello-docker | grep -A1 'Webhook Generic'
#   URL: https://api.<cluster>:6443/apis/build.openshift.io/v1/namespaces/<lab>-m05/buildconfigs/hello-docker/webhooks/<secret>/generic
PRIMA=$(oc get bc hello-docker -o jsonpath='{.status.lastVersion}')    # numero dell'ultima build prima del curl
SECRET=$(oc extract secret/docker-hook --keys=WebHookSecretKey --to=-)
HOOK="$(oc whoami --show-server)/apis/build.openshift.io/v1/namespaces/$(oc project -q)/buildconfigs/hello-docker/webhooks/$SECRET/generic"
curl -s -X POST -k "$HOOK"            # nessun "code": 403 nella risposta = richiesta accettata

# 3) Prove: una build NUOVA, causata dal webhook, con l'hook eseguito
echo "prima: $PRIMA - ora: $(oc get bc hello-docker -o jsonpath='{.status.lastVersion}')"   # ora = prima + 1
B=hello-docker-$(oc get bc hello-docker -o jsonpath='{.status.lastVersion}')
oc logs -f build/$B                                                # attendi la fine
oc describe build $B | grep -iA1 'cause'                           # Build trigger cause: Generic WebHook
oc get build $B -o jsonpath='{.spec.triggeredBy[*].message}{"\n"}' # Generic WebHook
oc get build $B -o jsonpath='{.spec.postCommit}{"\n"}'             # {"command":["node","test.js"]}: la build aveva l'hook
oc logs build/$B | grep 'TEST OK'                                  # TEST OK: / e /healthz rispondono 200  <- output dell'hook
oc get build $B -o jsonpath='{.status.phase}{"\n"}'                # Complete
oc get istag hello-docker:1.0                                      # immagine pubblicata dopo l'hook

# Controprova facoltativa (dopo la build del webhook): un test fallito blocca il push
oc start-build hello-docker -e FAIL_TESTS=true --follow --wait; echo "exit code: $?"   # TEST FALLITO: ... / exit code: 1
oc get build -l buildconfig=hello-docker -o jsonpath='{range .items[*]}{.metadata.name} {.status.phase} {.status.reason}{"\n"}{end}'
# ... Failed PostCommitHookFailed
```

**Perché la forma `command`:** `--command -- node test.js` produce `postCommit.command` (forma exec, senza `/bin/sh`), mentre `--script` userebbe la shell. `test.js` è un percorso relativo: funziona perché l'hook gira nella `WORKDIR` del Dockerfile (`/opt/app-root/src`), dove il `COPY` ha messo il file.

**Perché `oc patch` e non `oc set triggers --from-webhook`:** `--from-webhook` aggiunge un trigger Generic con un secret **generato** da `oc`, non un riferimento al tuo Secret `docker-hook`; e secondo la documentazione, aggiungere un webhook già esistente **rigenera** il secret. Il requisito chiede il Secret creato da te, quindi serve `secretReference`: con `oc patch --type=json` (operazione `add` su `/spec/triggers/-`) o con `oc edit bc/hello-docker`.

**Perché la build è partita "solo tramite curl":** né `oc set build-hook` né `oc patch` avviano build (il trigger ConfigChange scatta solo alla **creazione** della BuildConfig). Quindi l'unica build nuova (`PRIMA + 1`) è quella del webhook, e la sua causa `Generic WebHook` lo conferma. L'hook è dimostrato da due fatti: la build porta con sé `spec.postCommit` e nel suo log compare la riga `TEST OK` stampata da `test.js`; la controprova con `FAIL_TESTS=true` mostra che, se l'hook fallisce, l'immagine non viene pubblicata.

> **Da verificare sul tuo cluster:** il corpo della risposta del `curl` riuscito e le righe che il log della build Docker stampa attorno all'hook dipendono dalla versione. Contano `oc describe build $B | grep -iA1 cause` e `oc logs build/$B | grep 'TEST OK'`. Se il `curl` restituisce `forbidden` anche dopo il RoleBinding, prova da utente autenticato: `curl -s -X POST -k -H "Authorization: Bearer $(oc whoami -t)" "$HOOK"` (passo 3.10).
</details>

### 4.3 Esercizio senza aiuti

Costruisci nel progetto `${LAB}-m05` una catena di tre anelli: una BuildConfig `base` (Docker, Dockerfile inline) che produce `nodejs-base:1` partendo da `nodejs:22-ubi9`; una BuildConfig `app` che usa `nodejs-base:1` come builder S2I per `hello-node`; un Deployment `app` che segue `app:latest`. Dimostra che un `oc start-build base` porta, senza altri comandi, a un nuovo rollout di `app`.

---

## 5. Verifiche pratiche con `oc`

| Domanda | Comando |
|---|---|
| Strategia, sorgente, output, trigger, variabili | `oc describe bc <bc>` · `oc get bc <bc> -o yaml` · `oc set env bc/<bc> --list` |
| Che builder / immagine base usa? | `oc get bc <bc> -o jsonpath='{.spec.strategy.*.from}'` |
| Che trigger ha? | `oc set triggers bc/<bc>` |
| URL e secret dei webhook | `oc describe bc <bc>` (*Webhook Generic/GitHub*) · `oc extract secret/<s> --keys=WebHookSecretKey --to=-` |
| I non autenticati possono chiamare i webhook? | `oc get rolebinding -o wide \| grep system:webhook` |
| Quale hook è configurato? | `oc get bc <bc> -o jsonpath='{.spec.postCommit}'` |
| Perché è partita una build? | `oc describe build <build>` (*Build trigger cause*) · `oc get build <b> -o jsonpath='{.spec.triggeredBy[*].message}'` |
| Esito e motivo | `oc get builds` (STATUS) · `oc get build <b> -o jsonpath='{.status.phase} {.status.reason} {.status.message}'` |
| Log | `oc logs build/<b>` · `oc logs -f bc/<bc>` |
| Il pod di build è bloccato? | `oc get pod <b>-build` · `oc describe pod <b>-build` (Events) |
| Il Deployment si è aggiornato? | `oc rollout history deployment/<d>` · digest in `oc get deploy <d> -o jsonpath='{..image}'` vs `oc get istag` |

---

## 6. Troubleshooting intenzionale

```bash
oc project ${LAB}-m05
for n in 1-dockerfile 2-context-docker 3-from 4-hook 5-webhook 6-risorse 7-push; do
  bash $EX288_HOME/05-build-e-trigger/troubleshooting/rompi-$n.sh
done
```

Gli script sono idempotenti. Lo scenario 7 crea anche il progetto `${LAB}-m05-altro`.

### Scenario 1 — `t1-docker`: la build Docker fallisce

**Sintomo:** `t1-docker-1` è `Failed` dopo il clone.

<details><summary>Indagine e soluzione</summary>

```bash
oc get build t1-docker-1 -o jsonpath='{.status.reason}{"\n"}'   # DockerBuildFailed
oc logs build/t1-docker-1 | tail -5     # STEP ...: RUN npm-install-tutto / command not found / exit status 127
oc get bc t1-docker -o jsonpath='{.spec.source.dockerfile}'      # c'è un Dockerfile INLINE
```
**Causa:** la BuildConfig contiene un Dockerfile inline (ha la precedenza su quello del repo) con un comando inesistente.
**Fix:** se il requisito è usare il Dockerfile del repository, rimuovi quello inline: `oc patch bc/t1-docker --type=json -p '[{"op":"remove","path":"/spec/source/dockerfile"}]'`, poi `oc start-build t1-docker --follow` (in alternativa correggi la riga con `oc edit bc/t1-docker`).
**Lezione:** il log indica lo **STEP** che fallisce e l'exit code (127 = comando non trovato). Un errore di sintassi (es. `FRM`) fallisce ancora prima, nel parsing del Dockerfile.
</details>

### Scenario 2 — `t2-ctx`: Docker senza Dockerfile

**Sintomo:** `t2-ctx-1` è `Failed` pochi secondi dopo il clone.

<details><summary>Indagine e soluzione</summary>

```bash
oc logs build/t2-ctx-1               # ... Dockerfile ... no such file or directory
oc get bc t2-ctx -o jsonpath='{.spec.source.contextDir} {.spec.strategy.type}{"\n"}'   # hello-node-s2i Docker
```
**Causa:** strategia Docker con `contextDir: hello-node-s2i`, cartella senza `Dockerfile` (è pensata per S2I).
**Fix:** a seconda del requisito, `oc patch bc/t2-ctx --type=merge -p '{"spec":{"source":{"contextDir":"hello-node"}}}'`, oppure passa a S2I con `oc edit bc/t2-ctx` (`type: Source`, `sourceStrategy.from: nodejs:22-ubi9`, togli `dockerStrategy`). Poi `oc start-build t2-ctx --follow`.
**Lezione:** `contextDir` e `dockerfilePath` dicono dove cercare il Dockerfile; la strategia scritta nella BuildConfig non viene più "rilevata".
</details>

### Scenario 3 — `t3-from`: nessuna build utile

**Sintomo:** `oc get builds -l buildconfig=t3-from` non mostra build, oppure una build ferma in `New`.

<details><summary>Indagine e soluzione</summary>

```bash
oc get bc t3-from -o jsonpath='{.spec.strategy.sourceStrategy.from}{"\n"}'   # nodejs:16-ubi8
oc get istag nodejs:16-ubi8                    # NotFound
oc start-build t3-from                         # errore che cita l'image stream tag mancante
oc get build -l buildconfig=t3-from -o jsonpath='{range .items[*]}{.metadata.name} {.status.phase} {.status.reason}{"\n"}{end}'
```
**Causa:** l'immagine `from` punta a un tag inesistente: la build non viene creata, oppure resta `New` con motivo `InvalidImageReference`; il trigger ImageChange aspetta in silenzio che il tag compaia.
**Fix:** `oc patch bc/t3-from --type=merge -p '{"spec":{"strategy":{"sourceStrategy":{"from":{"kind":"ImageStreamTag","name":"nodejs:22-ubi9"}}}}}'`, `oc cancel-build bc/t3-from` (se c'è una build bloccata), `oc start-build t3-from --follow`.
**Lezione:** quando "non succede niente", verifica con `oc get istag` che l'immagine `from` esista. Quale dei due sintomi vedi dipende da quale trigger agisce per primo (**da verificare sul tuo cluster**).
</details>

### Scenario 4 — `t4-hook`: fallisce dopo una build riuscita

**Sintomo:** il log mostra l'`assemble` completato, ma `t4-hook-1` è `Failed` e `t4-hook:latest` non esiste.

<details><summary>Indagine e soluzione</summary>

```bash
oc get build t4-hook-1 -o jsonpath='{.status.reason}{"\n"}'     # PostCommitHookFailed
oc logs build/t4-hook-1 | tail -8       # npm error Missing script: "test:unit"
oc get bc t4-hook -o jsonpath='{.spec.postCommit}{"\n"}'       # {"script":"npm run test:unit"}
```
**Causa:** l'hook esegue uno script npm che non esiste in `package.json` (esiste solo `test`).
**Fix:** `oc set build-hook bc/t4-hook --post-commit --script="npm test"` e `oc start-build t4-hook --follow`.
**Lezione:** `PostCommitHookFailed` = immagine costruita ma hook con exit code != 0, quindi nessun push. Leggi le **ultime** righe del log.
</details>

### Scenario 5 — `t5-hook`: il webhook non avvia build

**Riproduci:** `HOOK5="$(oc whoami --show-server)/apis/build.openshift.io/v1/namespaces/${LAB}-m05/buildconfigs/t5-hook/webhooks/segreto-t5/generic"; curl -s -X POST -k "$HOOK5"` (se nel passo 3.10 hai già creato il RoleBinding, vedrai solo il problema del secret).
**Sintomo:** la risposta è un `Status` di errore e non compare nessuna build.

<details><summary>Indagine e soluzione</summary>

```bash
curl -s -X POST -k "$HOOK5" | grep -E '"(message|code)"'
oc get rolebinding -o wide | grep system:webhook                # 1) RoleBinding per system:unauthenticated?
oc get bc t5-hook -o jsonpath='{.spec.triggers[?(@.type=="Generic")]}{"\n"}'   # secretReference t5-webhook
oc get secret t5-webhook -o jsonpath='{.data}{"\n"}'            # 2) chiave "WebhookSecret", non "WebHookSecretKey"
```
**Cause (spesso entrambe):** `403` con `system:anonymous cannot create resource "buildconfigs/webhooks"` = manca il RoleBinding (passo 3.10); messaggio di secret non accettato = il Secret non ha la chiave `WebHookSecretKey` (qui si chiama `WebhookSecret`), oppure nell'URL c'è un valore diverso o il nome del Secret.
**Fix:** crea il RoleBinding (o chiedilo all'amministratore) e ricrea il Secret con la chiave giusta: `oc create secret generic t5-webhook --from-literal=WebHookSecretKey=segreto-t5 --dry-run=client -o yaml | oc apply -f -`; ripeti il `curl`.
**Lezione:** nell'URL va il **valore** di `WebHookSecretKey`. Il codice HTTP per secret errato (401 o 403) può variare: conta il messaggio.
</details>

### Scenario 6 — `t6-res`: la build non parte mai

**Sintomo:** `t6-res-1` resta `New` o `Pending` per minuti.

<details><summary>Indagine e soluzione</summary>

```bash
oc get build t6-res-1 -o jsonpath='{.status.phase} {.status.reason} {.status.message}{"\n"}'
oc describe pod t6-res-1-build | sed -n '/Events/,$p'     # FailedScheduling ... Insufficient cpu / memory
oc get bc t6-res -o jsonpath='{.spec.resources}{"\n"}'     # 64 CPU, 512Gi
oc describe quota; oc describe limitrange                  # vincoli del progetto (se presenti)
```
**Causa:** il pod di build chiede risorse che nessun nodo offre. Con una **ResourceQuota** o un **LimitRange** il pod può essere rifiutato già alla creazione (`exceeded quota`, `maximum ... per Container`); con una quota su CPU/memoria e senza LimitRange anche una build **senza** `resources` viene rifiutata (`must specify limits...`).
**Fix:** `oc patch bc/t6-res --type=merge -p '{"spec":{"resources":{"requests":{"cpu":"100m","memory":"256Mi"},"limits":{"cpu":"1","memory":"1Gi"}}}}'`, `oc cancel-build t6-res-1`, `oc start-build t6-res --follow`.
**Lezione:** build ferma in `New`/`Pending` = problema di **pod** (scheduling, quota, limiti), non di codice.
</details>

### Scenario 7 — `t7-push`: push negato

**Sintomo:** la build arriva a `Pushing image ...` e poi è `Failed`.

<details><summary>Indagine e soluzione</summary>

```bash
oc get build t7-push-1 -o jsonpath='{.status.reason}{"\n"}'   # PushImageToRegistryFailed
oc logs build/t7-push-1 | tail -5     # authentication required / requested access to the resource is denied
oc get bc t7-push -o jsonpath='{.spec.output.to}{"\n"}'      # namespace <lab>-m05-altro
oc auth can-i update imagestreams --subresource=layers -n ${LAB}-m05-altro --as=system:serviceaccount:${LAB}-m05:builder   # no
```
**Causa:** l'output è un image stream di **un altro progetto** e il service account `builder` di `${LAB}-m05` non può pubblicare lì.
**Fix:** `oc policy add-role-to-user system:image-builder system:serviceaccount:${LAB}-m05:builder -n ${LAB}-m05-altro`, poi `oc start-build t7-push --follow`.
**Lezione:** le build pubblicano con il SA `builder`. "requested access to the resource is denied" può indicare anche una **quota sulle immagini** superata (Troubleshooting builds: `oc describe quota`).
</details>

> **Da verificare sul tuo cluster:** i valori di `status.reason` citati (`DockerBuildFailed`, `PostCommitHookFailed`, `PushImageToRegistryFailed`, `InvalidImageReference`) sono quelli tipici: leggili sempre con `oc get build <b> -o jsonpath='{.status.reason}'`.

Pulizia: `oc delete project ${LAB}-m05 ${LAB}-m05-altro`

---

## 7. Esercizio finale (stile EX288)

> Lavora come all'esame: niente soluzioni, solo documentazione ufficiale, `oc --help` e `oc explain`. Tempo indicativo: **50 minuti**.

**Requisiti**

1. Esiste il progetto `${LAB}-m05-exam`, con l'image stream tag `nodejs:22-ubi9` importato da `registry.access.redhat.com/ubi9/nodejs-22`.
2. Esiste la BuildConfig **`shop-api`** con queste caratteristiche:
   - strategia **Source** con builder `nodejs:22-ubi9`;
   - sorgente `$GIT_REPO`, branch **`exam-v2`**, cartella `hello-node`;
   - pubblica l'immagine nel tag **`shop-api:2.0`** dell'image stream `shop-api`;
   - variabile di build `BUILD_LOGLEVEL=2`;
   - se arrivano più richieste di build ravvicinate, deve essere eseguita solo l'ultima in coda;
   - conserva al massimo **3** build riuscite e **2** fallite.
3. Un post-commit build hook esegue lo script di test fornito con l'applicazione (`test.js`): se i test falliscono, l'immagine non deve essere pubblicata.
4. Esiste almeno una build di `shop-api` **fallita a causa dell'hook** (esegui i test con la variabile di build `FAIL_TESTS=true`). Al termine dell'esercizio la BuildConfig **non** contiene più `FAIL_TESTS`.
5. `shop-api` si ricostruisce automaticamente:
   - quando cambia l'immagine del builder `nodejs:22-ubi9`;
   - quando viene invocato il suo webhook **generico**, protetto dal Secret **`shop-api-hook`** il cui valore è `ex288-hook-2026`.
6. Il webhook di `shop-api` può essere invocato da sistemi esterni **senza autenticazione**.
7. Almeno una build **completata** di `shop-api` è stata avviata dal webhook generico.
8. Il Deployment **`shop-api`** (container `shop-api`, 1 replica pronta, variabile `APP_VERSION=2.0.0`) esegue l'immagine attuale di `shop-api:2.0`, si aggiorna automaticamente quando il tag cambia ed è già stato aggiornato almeno una volta da una nuova build (almeno 2 revisioni). È raggiungibile via HTTP dalla route `shop-api`.

**Risultato atteso**

- `http://<route shop-api>/` restituisce `"message": "Catalogo v2"` e `"version": "2.0.0"`.
- `oc get builds` mostra build `Complete` e almeno una `Failed` con motivo legato all'hook.

```bash
bash $EX288_HOME/05-build-e-trigger/verifica.sh
```

---

## 8. Riferimenti ufficiali (OCP 4.22)

- Builds using BuildConfig → *Understanding image builds* e *Understanding build configurations*: https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/builds_using_buildconfig/understanding-image-builds
- Builds using BuildConfig → *Creating build inputs* (Git, Dockerfile inline, binary, secret e ConfigMap di input): https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/builds_using_buildconfig/creating-build-inputs
- Builds using BuildConfig → *Managing build output* (`output.to`, `imageLabels`): https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/builds_using_buildconfig/managing-build-output
- Builds using BuildConfig → *Using build strategies* (Docker, S2I, Custom, Pipeline deprecata): https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/builds_using_buildconfig/build-strategies
- Builds using BuildConfig → *Performing and configuring basic builds* (`oc start-build`, `oc cancel-build`, log, `BUILD_LOGLEVEL`): https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/builds_using_buildconfig/basic-build-operations
- Builds using BuildConfig → *Triggering and modifying builds* (webhook, `system:webhook` 4.16+, ImageChange, ConfigChange, post-commit hook): https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/builds_using_buildconfig/triggering-builds-build-hooks
- Builds using BuildConfig → *Performing advanced builds* (risorse, `completionDeadlineSeconds`, build concatenate, history limit, `runPolicy`): https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/builds_using_buildconfig/advanced-build-operations
- Builds using BuildConfig → *Troubleshooting builds*: https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/builds_using_buildconfig/troubleshooting-builds_build-configuration
- CLI tools → *OpenShift CLI developer command reference* (`oc new-build`, `oc start-build`, `oc set triggers`, `oc set build-hook`): https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/cli_tools/openshift-cli-oc
