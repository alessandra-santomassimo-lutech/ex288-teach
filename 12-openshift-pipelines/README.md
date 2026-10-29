# Modulo 12 — OpenShift Pipelines: CI/CD con Tekton

> **Obiettivi EX288 coperti**
> - *Work with OpenShift Pipelines* → Understanding CI/CD process inside of OpenShift
> - *Work with OpenShift Pipelines* → Understand and work with standard Tekton custom resource definitions (CRDs) for defining CI/CD pipelines
> - *Work with OpenShift Pipelines* → Design and define, and troubleshoot CI/CD workflows for applications
> - *Work with OpenShift Pipelines* → Configure and trigger Pipeline workflows for applications
>
> **Durata stimata:** 6-7 ore · **Prerequisiti:** moduli 00-08 (in particolare 05 e 08), Operator OpenShift Pipelines installato, CLI `tkn` · **Richiede cluster-admin:** no (l'installazione dell'Operator sì: compito dell'amministratore)
>
> **Progetti usati:** `${LAB}-m12`, `${LAB}-m12-exam`

---

## 1. Perché e quando

Nei moduli 05 e 06 hai costruito immagini con le **BuildConfig** (S2I, Docker, trigger, webhook, build hook). OpenShift Pipelines aggiunge un motore CI/CD generico, basato sul progetto open source **Tekton**, in cui ogni passo gira in un container del cluster. Le tre famiglie di strumenti non si escludono: scegli in base a cosa deve fare il flusso.

| Ti serve… | Usa | Perché |
|---|---|---|
| Costruire un'immagine dal sorgente e rideployare quando cambia il codice o l'immagine base | **BuildConfig** + trigger (modulo 05) | Poche righe, nessun Operator aggiuntivo; il flusso è "build → image stream → trigger del Deployment" |
| Un flusso con più passi eterogenei: clone, test, analisi, build, push, deploy, notifiche | **Pipeline Tekton** | Ogni passo è un container con la sua immagine (Node.js per i test, buildah per la build, `oc` per il deploy); i passi si compongono, si riusano, si parametrizzano |
| Fermare il rilascio se i test falliscono, saltare un passo in base a un parametro, eseguire sempre una pulizia/notifica | Pipeline con `runAfter`, `when`, `finally` | Le BuildConfig hanno solo il post-commit hook; le Pipeline modellano dipendenze e condizioni |
| Avviare la CI a ogni push su Git | **Tekton Triggers** (EventListener) oppure **Pipelines as Code** | L'EventListener riceve il webhook e crea una PipelineRun; PaC legge le pipeline direttamente da `.tekton/` nel repository |
| Mantenere il cluster allineato a manifest versionati in Git (deploy continuo dichiarativo) | **GitOps** (OpenShift GitOps / Argo CD, Operator separato) | Il "deploy" diventa una sincronizzazione Git → cluster; tipicamente la Pipeline fa CI (test e immagine) e GitOps fa CD |
| Pipeline `JenkinsPipeline` dentro una BuildConfig | **Non usarla** | Strategia deprecata: usa OpenShift Pipelines |

**Regola pratica per l'esame:** se il testo parla di Task, Pipeline, PipelineRun, workspace, EventListener, sei in questo modulo; se parla di BuildConfig, `oc start-build` e image stream trigger, sei nel modulo 05.

---

## 2. Concetti essenziali

### 2.1 Le risorse Tekton (CRD installate dall'Operator)

```bash
oc api-resources --api-group=tekton.dev            # tasks, taskruns, pipelines, pipelineruns, stepactions, ...
oc api-resources --api-group=triggers.tekton.dev   # eventlisteners, triggerbindings, triggertemplates, triggers, ...
```

| Risorsa | Cosa rappresenta | Diventa sul cluster |
|---|---|---|
| **Task** | Sequenza ordinata di **step**; modello riutilizzabile | niente, finché non viene eseguita |
| **TaskRun** | Un'esecuzione di una Task con valori concreti | **un pod**; ogni step è **un container** del pod, eseguito in ordine |
| **Pipeline** | Grafo di Task (ordine con `runAfter`, condizioni `when`, task `finally`) | niente, finché non viene eseguita |
| **PipelineRun** | Un'esecuzione della Pipeline | una TaskRun (quindi un pod) per ogni task del grafo |
| **StepAction** | Uno step riutilizzabile, richiamato con `ref:` dentro una Task | container dentro il pod della Task |

Elementi che collegano le Task tra loro:

- **params**: valori in ingresso (`$(params.NOME)`), con `type` (`string`, `array`, `object`) e `default` facoltativo. Un parametro senza default è **obbligatorio**.
- **workspaces**: spazio su disco condiviso, dichiarato dalla Task/Pipeline e **fornito** da chi la esegue (TaskRun/PipelineRun). È il modo per passare *file* (es. il codice clonato) da una task all'altra.
- **results**: piccoli valori stringa prodotti da una task (`$(results.NOME.path)`) e letti dalle successive (`$(tasks.<task>.results.NOME)`). Usare un result crea anche una dipendenza implicita.
- **when**: condizione su `input`/`operator` (`in`, `notin`)/`values`; se falsa la task è **Skipped**. Il `when` protegge **solo quella task**: le task che la seguono soltanto tramite `runAfter` vengono eseguite comunque, mentre vengono saltate quelle che usano i suoi `results` (non disponibili).
- **finally**: task eseguite al termine, sia in caso di successo sia di fallimento; possono leggere `$(tasks.status)` (stato aggregato: `Succeeded`, `Failed`, `Completed` se alcune task sono state saltate) e `$(tasks.<nome>.status)`.

YAML minimo annotato (la Task del passo 3.3):

```yaml
apiVersion: tekton.dev/v1         # API stabile: usala sempre
kind: Task
metadata:
  name: hello
spec:
  params:
  - name: NAME
    default: EX288                # con default -> parametro facoltativo
  results:
  - name: greeting
  steps:                          # ogni step = un container dello stesso pod
  - name: say-hello
    image: registry.access.redhat.com/ubi9/ubi-minimal
    script: |
      echo "Ciao $(params.NAME)"
      printf "Ciao $(params.NAME)" > $(results.greeting.path)
```

### 2.2 Binding dei workspace: cosa scegliere

| Binding nella PipelineRun | Dati condivisi tra task diverse? | Usalo per |
|---|---|---|
| `volumeClaimTemplate` | Sì (una PVC nuova per ogni run, cancellata con la run) | Il caso standard: clone → test → build |
| `persistentVolumeClaim: {claimName: x}` | Sì, e persistono tra run diverse | Cache (es. dipendenze Maven/npm) |
| `emptyDir: {}` | **No**: è cancellato a fine TaskRun | Dati temporanei di una sola task |
| `configMap` / `secret` | Sola lettura | Configurazione, credenziali (`.gitconfig`, `.docker/config.json`) |

> Con una PVC `ReadWriteOnce` le TaskRun che la usano vengono schedulate sullo stesso nodo. Il `volumeClaimTemplate` richiede una **StorageClass di default** sul cluster (`oc get storageclass`).

### 2.3 Versioni e cose cambiate (importante se studi su materiale vecchio)

> **Nota di versione:** su OCP 4.22 sono supportati OpenShift Pipelines **1.22, 1.23 e 1.24** (la 1.24 include Tekton Pipelines 1.15, Triggers 0.37, `tkn` 0.46). La versione usata all'esame non è dichiarata: controlla la tua con `tkn version`.

| Prima | Ora | Cosa fare |
|---|---|---|
| `apiVersion: tekton.dev/v1beta1` | `tekton.dev/v1` | Usa `v1` per Task, TaskRun, Pipeline, PipelineRun, StepAction |
| `spec.serviceAccountName` nella PipelineRun | `spec.taskRunTemplate.serviceAccountName` | Il SA (e il `podTemplate`) vanno sotto `taskRunTemplate` |
| **ClusterTask** (`taskRef: {kind: ClusterTask, name: buildah}`) | **Rimosse dalla 1.17**; Task nel namespace `openshift-pipelines` richiamate con il **cluster resolver** | `taskRef: {resolver: cluster, params: [kind, name, namespace]}` |
| Parametri minuscoli (`url`, `revision`, `PATH_CONTEXT`) | Parametri **MAIUSCOLI** (`URL`, `REVISION`, `CONTEXT`) | Leggi sempre i nomi dal cluster (sezione 3.2) |
| Il `workingDir` di default era `/workspace` | Dalla 1.6 non più | Imposta `workingDir` esplicitamente, es. `$(workspaces.source.path)` |

### 2.4 Il service account `pipeline`

L'Operator crea in ogni progetto (esclusi `openshift-*` e `kube-*`) il service account **`pipeline`**, con permessi sufficienti per costruire e fare push di immagini nel registry interno **del progetto** e per gestire le risorse applicative (ruolo `edit` nel progetto). Le PipelineRun lo usano di default. Se usi un SA diverso senza permessi, buildah fallisce al push e `oc` fallisce al deploy.

### 2.5 Triggers: dal webhook alla PipelineRun

```
push su Git ──HTTP POST JSON──▶ Route el-<nome> ─▶ Service el-<nome> ─▶ pod EventListener
                                                               │ per ogni trigger:
                                     TriggerBinding (estrae $(body.xxx)) + TriggerTemplate (crea risorse)
                                                               ▼
                                                          PipelineRun
```

- **TriggerBinding**: mappa campi del payload (`$(body.repository.html_url)`, `$(body.head_commit.id)`) o degli header (`$(header.X)`) su parametri.
- **TriggerTemplate**: dichiara parametri e `resourcetemplates` (di solito una PipelineRun con `generateName`); i parametri si usano come `$(tt.params.nome)`.
- **EventListener**: lista di trigger (binding + template, eventuali **interceptor** GitHub/GitLab/Bitbucket/CEL per filtrare e validare); l'Operator crea Deployment e Service `el-<nome>`; l'esposizione all'esterno (Route) la fai tu.
- **Trigger** (facoltativo): coppia binding + template come risorsa a sé, riutilizzabile con `triggerRef`.

> **Da verificare sul tuo cluster:** la documentazione Pipelines 1.20-1.24 mostra i manifest Triggers con `apiVersion: triggers.tekton.dev/v1`, ma nessuna release note annuncia la v1 e la `ClusterTriggerBinding` installata è `v1beta1`. I file di questo modulo usano **`v1beta1`**, servita con certezza. Verifica con `oc api-resources --api-group=triggers.tekton.dev -o wide` (lo stampa anche `00-setup/controlla-ambiente.sh`).

**Pipelines as Code (solo concetto):** le PipelineRun vivono nel repository in `.tekton/`, con annotazioni che indicano su quali eventi partire (push, pull request); nel progetto crei una CR `Repository` (`pipelinesascode.tekton.dev/v1alpha1`, `spec.url`) e configuri la GitHub App o il webhook (`tkn pac`). È l'approccio consigliato da Red Hat per i progetti reali; per l'esame è sufficiente sapere cos'è.

---

## 3. Laboratorio guidato

```bash
source env.sh                 # dalla root del repository ex288-teach
oc new-project ${LAB}-m12 --display-name="EX288 m12 - pipelines"
cd $EX288_HOME/12-openshift-pipelines/lab
```

### 3.1 Verificare l'ambiente

```bash
tkn version                                  # client e (se leggibile) versione di Pipelines sul cluster
oc api-resources --api-group=tekton.dev      # le CRD esistono? (se no: Operator non installato)
oc get sa pipeline                           # creato dall'Operator nel tuo nuovo progetto
oc auth can-i create deployments --as=system:serviceaccount:${LAB}-m12:pipeline   # yes
oc get storageclass                          # serve una StorageClass con "(default)"
```

### 3.2 Esplorare le Task fornite (abitudine da esame)

```bash
oc get tasks -n openshift-pipelines          # git-clone, buildah, openshift-client, s2i-nodejs, ... e copie versionate
tkn task describe git-clone -n openshift-pipelines
#  Params: URL, REVISION, REFSPEC, SUBMODULES, DEPTH, SUBDIRECTORY, DELETE_EXISTING, ...
#  Workspaces: output (obbligatorio), ssh-directory, basic-auth, ssl-ca-directory (facoltativi)
#  Results: COMMIT, URL, COMMITTER_DATE

# Leggere nomi, default e descrizioni dei parametri direttamente dalla definizione:
oc get task buildah -n openshift-pipelines -o yaml | less
oc get task buildah -n openshift-pipelines \
  -o jsonpath='{range .spec.params[*]}{.name}{"\t"}{.default}{"\n"}{end}'
oc get task buildah -n openshift-pipelines -o jsonpath='{.spec.workspaces[*].name}{"\n"}'   # source dockerconfig rhel-entitlement
oc get task buildah -n openshift-pipelines -o jsonpath='{.spec.results[*].name}{"\n"}'      # IMAGE_DIGEST IMAGE_URL
oc get task openshift-client -n openshift-pipelines -o jsonpath='{.spec.params[*].name}{"\n"}'  # SCRIPT VERSION
```

> **Abitudine da esame:** non scrivere mai a memoria il nome di un parametro di una Task fornita. Leggilo dal cluster con `tkn task describe` o `oc get task ... -o yaml`: i nomi sono cambiati tra le versioni e un parametro scritto male fa fallire la PipelineRun.

> **Da verificare sul tuo cluster:** la documentazione 1.24 riporta per buildah il parametro `TLS_VERIFY`, ma un esempio usa `TLSVERIFY`. In questo modulo **non lo impostiamo**: il default (`true`) funziona con il registry interno. Se ti serve, usa il nome che vedi nel comando sopra.

### 3.3 Prima Task e prima TaskRun

```bash
oc apply -f 01-task-hello.yaml
tkn task list
tkn task describe hello                       # params, results, steps

# Esecuzione dichiarativa (generateName => oc create, non oc apply)
oc create -f 01-taskrun-hello.yaml
tkn taskrun list
tkn taskrun logs -f <nome-taskrun>            # oppure: tkn taskrun logs --last -f
oc get pods                                   # hello-run-xxxxx-pod  Completed
oc get taskrun <nome-taskrun> -o jsonpath='{.status.results[*].value}{"\n"}'   # Ciao Alessandra

# Esecuzione imperativa con tkn, mostrando subito i log
tkn task start hello -p NAME=EX288 --showlog
tkn task start hello --use-param-defaults --showlog   # nessuna domanda interattiva: usa i default
```

Osserva: la TaskRun ha creato **un pod**; lo step `say-hello` è un container di quel pod. Il pod resta in `Completed` per farti leggere i log.

> **Trappola: `$(...)` nei commenti dello script.** Tekton sostituisce e **valida** ogni riferimento `$(params.X)`, `$(results.X.path)`, `$(workspaces.X.path)` presente nello `script`, **anche nelle righe di commento** (`# ...`). Un riferimento a un parametro o result non dichiarato, persino in un commento, fa rifiutare la risorsa all'`oc apply` con `admission webhook "validation.webhook.pipeline.tekton.dev" denied the request: validation failed: non-existent variable in "..."`. Il messaggio riporta lo script e il campo (`spec.steps[0].script`): cerca il `$(...)` che non corrisponde a nessun `params`/`results`/`workspaces` dichiarato, oppure toglilo dai commenti. Le variabili della shell scrivile come `${VAR}` (con le graffe): Tekton non le tocca.

### 3.4 Task personalizzata `npm-test`

Leggi `02-task-npm-test.yaml`: dichiara il workspace `source`, il parametro `APP_DIR` (default `hello-node`) usato nel `workingDir`, il parametro `FAIL_TESTS` passato come variabile d'ambiente allo step, e il result `outcome`.

```bash
oc apply -f 02-task-npm-test.yaml
tkn task describe npm-test
```

> **Perché `FAIL_TESTS` è un parametro?** `test.js` fallisce se trova `FAIL_TESTS=true` nell'ambiente. Lo step di una Task ha **solo** le variabili che dichiari in `env`: per poterla controllare dall'esterno la esponi come parametro e la mappi in `env`. La userai nel troubleshooting.

### 3.5 La Pipeline `hello-pipeline`

Apri `03-pipeline-hello.yaml` e segui il grafo:

```
fetch-source (git-clone) ─▶ run-tests (npm-test) ─▶ build-image (buildah) ─▶ deploy (openshift-client, when DEPLOY=="true")
finally: report (stampa $(tasks.status))
```

Punti chiave:

- le Task fornite si richiamano con `taskRef.resolver: cluster` e i parametri `kind`/`name`/`namespace`;
- il workspace della Pipeline si chiama `shared`; ogni task lo collega al **proprio** nome di workspace (`output` per git-clone, `source` per npm-test e buildah);
- l'immagine finisce nel registry interno **del progetto in cui gira la PipelineRun**: `image-registry.openshift-image-registry.svc:5000/$(context.pipelineRun.namespace)/hello-node:<tag>`; il push crea automaticamente l'image stream `hello-node`;
- buildah riceve `DOCKERFILE=./hello-node/Dockerfile` e `CONTEXT=./hello-node`, entrambi relativi alla radice del workspace;
- il deploy usa il result `IMAGE_DIGEST` di buildah: riferirsi all'immagine per digest garantisce un nuovo rollout a ogni build;
- `run-tests` è una barriera: se fallisce, `build-image` e `deploy` non partono.

```bash
oc apply -f 03-pipeline-hello.yaml
tkn pipeline describe hello-pipeline          # params con default, workspace, task in ordine
```

### 3.6 Avvio con `tkn pipeline start`

```bash
tkn pipeline start hello-pipeline \
  -p GIT_URL=$GIT_REPO \
  -p GIT_REVISION=$GIT_BRANCH \
  -w name=shared,volumeClaimTemplateFile=04-pvc-template.yaml \
  --use-param-defaults \
  --showlog
# -p           valore di un parametro (ripetibile)
# -w           binding del workspace: volumeClaimTemplateFile=<file|url>, claimName=<pvc>, emptyDir=""
# --use-param-defaults  non chiede i parametri con default
# --showlog    segue i log di tutte le task
```

Output atteso (abbreviato): i log di `fetch-source` (commit clonato), `run-tests` (`TEST OK: / e /healthz rispondono 200`), `build-image` (build e `Writing manifest`/push), `deploy` (`deployment "hello-node" successfully rolled out`), `report` (`Esito complessivo delle task: Succeeded`).

```bash
oc get deploy,svc,route hello-node
curl -s http://$(oc get route hello-node -o jsonpath='{.spec.host}')/ | head -5
oc get is hello-node                          # creato dal push di buildah
tkn pipeline start hello-pipeline --last --showlog   # rilancia con gli stessi parametri e workspace
```

> Se `tkn` chiede interattivamente il service account o altri valori, aggiungi `-s pipeline` e verifica i flag con `tkn pipeline start --help`.

### 3.7 Avvio dichiarativo con una PipelineRun YAML

```bash
sed "s|GIT_REPO_DA_SOSTITUIRE|$GIT_REPO|" 04-pipelinerun-hello.yaml | oc create -f -
tkn pipelinerun list                          # alias: tkn pr list
tkn pipelinerun logs -f <nome-pipelinerun>    # oppure: tkn pr logs --last -f
tkn pipelinerun describe <nome-pipelinerun>   # stato di ogni task, durata, parametri, eventuale messaggio d'errore
oc get pipelineruns,taskruns,pods             # 1 PipelineRun -> N TaskRun -> N pod
oc get istag hello-node:v1                    # il tag scelto nella PipelineRun
```

Esegui ora la stessa Pipeline **senza deploy**:

```bash
tkn pipeline start hello-pipeline -p GIT_URL=$GIT_REPO -p DEPLOY=false -p IMAGE_TAG=nodeploy \
  -w name=shared,volumeClaimTemplateFile=04-pvc-template.yaml --use-param-defaults --showlog
tkn pr describe --last                        # deploy: Skipped (when), report: "Completed"
```

> **Abitudine da esame:** `oc apply` su un file con `generateName` fallisce; usa `oc create`. Se il testo chiede una PipelineRun con un **nome preciso**, usa `metadata.name` (e allora vanno bene sia `create` sia `apply`).

Pulizia delle esecuzioni (le PVC dei `volumeClaimTemplate` vengono cancellate con le PipelineRun): `tkn pipelinerun delete --keep 3`.

### 3.8 Triggers: avviare la Pipeline con un webhook

```bash
oc api-resources --api-group=triggers.tekton.dev -o wide | grep -i eventlistener   # verifica la versione servita

oc apply -f 05-triggerbinding.yaml -f 05-triggertemplate.yaml -f 05-eventlistener.yaml
tkn eventlistener list
oc get pods,svc -l eventlistener=hello-listener        # pod e Service el-hello-listener
oc expose svc el-hello-listener                        # Route el-hello-listener
EL=http://$(oc get route el-hello-listener -o jsonpath='{.spec.host}')
```

> **Da verificare sul tuo cluster:** se il Service `el-hello-listener` espone più di una porta, crea la route sulla porta HTTP del listener: `oc get svc el-hello-listener -o yaml` e `oc expose svc el-hello-listener --port=<nome-porta>`.

Simula un push GitHub con `curl` (payload in `05-payload-push.json`):

```bash
COMMIT=$(git -C $EX288_WORK/ex288-apps rev-parse HEAD)
sed -e "s|GIT_REPO_DA_SOSTITUIRE|$GIT_REPO|g" -e "s|COMMIT_DA_SOSTITUIRE|$COMMIT|g" 05-payload-push.json \
  | curl -s -X POST -H 'Content-Type: application/json' -H 'X-GitHub-Event: push' --data-binary @- $EL
# Risposta JSON con eventListener, namespace ed eventID: l'evento è stato accettato

tkn pipelinerun list                          # hello-pipeline-trigger-xxxxx  Running
tkn pr logs --last -f
tkn eventlistener logs hello-listener         # log del pod EventListener (errori di binding/template)
oc get pipelinerun -l triggers.tekton.dev/eventlistener=hello-listener   # le run create dal listener hanno questa label
```

**Facoltativo — Trigger separato:** `oc apply -f 05-trigger-opzionale.yaml` crea la risorsa `Trigger` `hello-push-trigger` e un secondo EventListener che la richiama con `triggerRef`. Utile quando più listener condividono la stessa logica.

**Facoltativo — webhook reale da GitHub.** Nel repository `ex288-apps` → *Settings* → *Webhooks* → *Add webhook*: Payload URL = `$EL`, Content type `application/json`, evento *push*, un *secret*. Per validare la firma aggiungi al trigger l'interceptor GitHub (dalla documentazione Pipelines 1.24):

```yaml
  triggers:
  - name: hello-push
    interceptors:
    - ref:
        name: "github"
      params:
      - name: "secretRef"
        value:
          secretName: github-webhook-secret   # oc create secret generic github-webhook-secret --from-literal=secretToken=<secret>
          secretKey: secretToken
      - name: "eventTypes"
        value: ["push"]
    bindings:
    - ref: hello-binding
    template:
      ref: hello-template
```

Il webhook funziona solo se GitHub raggiunge la route del cluster (spesso non vero per cluster aziendali): in quel caso resta il test con `curl`.

### 3.9 Alternativa S2I con la Task `s2i-nodejs`

La Task `s2i-nodejs` fa la build S2I senza Dockerfile, ma prende l'immagine builder dall'image stream `openshift/nodejs:<VERSION>` (fornito dal Cluster Samples Operator, **deprecato** in 4.20-4.22).

```bash
oc get is nodejs -n openshift -o jsonpath='{.spec.tags[*].name}{"\n"}' || echo "image stream assente: usa buildah"
tkn task describe s2i-nodejs -n openshift-pipelines   # IMAGE, CONTEXT, VERSION, ENV_VARS, ...
```

Se l'image stream esiste, nella Pipeline puoi sostituire `build-image` con `s2i-nodejs` (`CONTEXT=hello-node`, `VERSION=22-ubi9`, stesso `IMAGE`). Altrimenti resta su buildah con il Dockerfile, come in questo laboratorio.

---

## 4. Esercizi

### 4.1 Esercizio guidato

Nel progetto `${LAB}-m12` crea una copia di `hello-pipeline` chiamata `hello-pipeline-v2` che:

1. dopo `fetch-source` esegue una task `print-commit` che usa la Task `hello` passando come `NAME` il commit clonato;
2. tagga l'immagine con il valore `v2`;
3. viene eseguita con successo con `tkn`.

<details><summary>Suggerimenti</summary>

- Il commit clonato è il result `COMMIT` di git-clone: `$(tasks.fetch-source.results.COMMIT)`.
- Usare un result di un'altra task crea già la dipendenza; `runAfter` è facoltativo.
- Per il tag basta passare il parametro `IMAGE_TAG` all'avvio, senza toccare la Pipeline.
</details>

<details><summary>Soluzione</summary>

```bash
oc get pipeline hello-pipeline -o yaml > $EX288_WORK/m12/v2.yaml
# In $EX288_WORK/m12/v2.yaml: metadata.name -> hello-pipeline-v2; rimuovi uid, resourceVersion, creationTimestamp, status;
# aggiungi in spec.tasks:
#  - name: print-commit
#    taskRef:
#      name: hello
#    params:
#    - name: NAME
#      value: $(tasks.fetch-source.results.COMMIT)
oc apply -f $EX288_WORK/m12/v2.yaml
tkn pipeline start hello-pipeline-v2 -p GIT_URL=$GIT_REPO -p IMAGE_TAG=v2 \
  -w name=shared,volumeClaimTemplateFile=$EX288_HOME/12-openshift-pipelines/lab/04-pvc-template.yaml \
  --use-param-defaults --showlog
tkn pr describe --last          # print-commit Succeeded
oc get istag hello-node:v2
```
</details>

### 4.2 Esercizio semi-guidato

Crea la Pipeline `hello-commit` che produce un'immagine taggata con lo **SHA del commit** clonato (non con un parametro) e la rilascia nel Deployment `hello-commit`. Nella task `finally` stampa anche il digest dell'immagine prodotta.

<details><summary>Suggerimenti</summary>

- I result si possono usare nei `params` di una task, quindi anche dentro il valore di `IMAGE` di buildah.
- Una task `finally` può leggere i result delle task normali (se sono state eseguite).
- Il nome del Deployment nel `SCRIPT` di `openshift-client` deriva da `IMAGE_NAME`.
</details>

<details><summary>Soluzione (aprila solo dopo aver provato)</summary>

Grafo: `fetch-source` (git-clone, result `COMMIT`) → `run-tests` (npm-test) → `build-image` (buildah, tag = `COMMIT`) → `deploy` (openshift-client, stesso riferimento); `finally`: `report` (stato) e `print-digest` (digest).

```yaml
# $EX288_WORK/m12/hello-commit.yaml
apiVersion: tekton.dev/v1
kind: Pipeline
metadata:
  name: hello-commit
spec:
  description: Immagine taggata con lo SHA del commit clonato, rilasciata nel Deployment hello-commit.
  params:
  - name: GIT_URL
    type: string
  - name: GIT_REVISION
    type: string
    default: main
  - name: APP_DIR
    type: string
    default: hello-node
  - name: IMAGE_REGISTRY
    type: string
    default: image-registry.openshift-image-registry.svc:5000
  - name: IMAGE_NAME
    type: string
    description: Nome dell'immagine, del Deployment, del Service e della Route
    default: hello-commit
  # niente IMAGE_TAG: il tag è il result COMMIT di git-clone
  workspaces:
  - name: shared
  tasks:
  - name: fetch-source
    taskRef:
      resolver: cluster
      params:
      - name: kind
        value: task
      - name: name
        value: git-clone
      - name: namespace
        value: openshift-pipelines
    workspaces:
    - name: output
      workspace: shared
    params:
    - name: URL
      value: $(params.GIT_URL)
    - name: REVISION
      value: $(params.GIT_REVISION)
    - name: DELETE_EXISTING
      value: "true"
  - name: run-tests                    # facoltativo, ma tiene il "gate" dei test (riusa npm-test del passo 3.4)
    runAfter:
    - fetch-source
    taskRef:
      name: npm-test
    workspaces:
    - name: source
      workspace: shared
    params:
    - name: APP_DIR
      value: $(params.APP_DIR)
  - name: build-image
    runAfter:
    - run-tests
    taskRef:
      resolver: cluster
      params:
      - name: kind
        value: task
      - name: name
        value: buildah
      - name: namespace
        value: openshift-pipelines
    workspaces:
    - name: source
      workspace: shared
    params:
    - name: IMAGE                      # il result COMMIT usato dentro il valore di un parametro
      value: $(params.IMAGE_REGISTRY)/$(context.pipelineRun.namespace)/$(params.IMAGE_NAME):$(tasks.fetch-source.results.COMMIT)
    - name: DOCKERFILE
      value: ./$(params.APP_DIR)/Dockerfile
    - name: CONTEXT
      value: ./$(params.APP_DIR)
  - name: deploy
    runAfter:
    - build-image
    taskRef:
      resolver: cluster
      params:
      - name: kind
        value: task
      - name: name
        value: openshift-client
      - name: namespace
        value: openshift-pipelines
    params:
    - name: SCRIPT
      value: |
        set -e
        APP="$(params.IMAGE_NAME)"
        IMG="$(params.IMAGE_REGISTRY)/$(context.pipelineRun.namespace)/$(params.IMAGE_NAME):$(tasks.fetch-source.results.COMMIT)"
        echo "Rilascio di ${IMG}"
        if oc get deployment "${APP}" >/dev/null 2>&1; then
          oc set image deployment/"${APP}" '*'="${IMG}"
        else
          oc create deployment "${APP}" --image="${IMG}" --port=8080
          oc expose deployment "${APP}" --port=8080
          oc expose service "${APP}"
        fi
        oc rollout status deployment/"${APP}" --timeout=180s
  finally:
  - name: report                       # nessun result: gira sempre, anche se la build fallisce
    params:
    - name: AGGREGATE
      value: $(tasks.status)
    taskSpec:
      params:
      - name: AGGREGATE
        type: string
      steps:
      - name: print
        image: registry.access.redhat.com/ubi9/ubi-minimal
        script: |
          #!/usr/bin/env bash
          echo "Esito complessivo delle task: $(params.AGGREGATE)"
  - name: print-digest                 # legge i result: viene saltata se non sono disponibili
    params:
    - name: COMMIT
      value: $(tasks.fetch-source.results.COMMIT)
    - name: DIGEST
      value: $(tasks.build-image.results.IMAGE_DIGEST)
    taskSpec:
      params:
      - name: COMMIT
        type: string
      - name: DIGEST
        type: string
      steps:
      - name: print
        image: registry.access.redhat.com/ubi9/ubi-minimal
        script: |
          #!/usr/bin/env bash
          echo "Commit:  $(params.COMMIT)"
          echo "Digest:  $(params.DIGEST)"
```

> Se crei il file con un heredoc, usa `cat > $EX288_WORK/m12/hello-commit.yaml <<'EOF'` (con **EOF tra apici**): altrimenti la shell prova a espandere `$(params...)` e `$(tasks...)` come sostituzioni di comando.

```bash
oc project ${LAB}-m12
oc get task npm-test                       # deve esistere (passo 3.4)
oc apply -f $EX288_WORK/m12/hello-commit.yaml
tkn pipeline describe hello-commit         # params senza IMAGE_TAG, 4 task + 2 finally

# Avvio imperativo
tkn pipeline start hello-commit \
  -p GIT_URL=$GIT_REPO -p GIT_REVISION=$GIT_BRANCH \
  -w name=shared,volumeClaimTemplateFile=$EX288_HOME/12-openshift-pipelines/lab/04-pvc-template.yaml \
  --use-param-defaults --showlog
# [build-image : push] ... Writing manifest to image destination
# [deploy : oc] Rilascio di image-registry.openshift-image-registry.svc:5000/<LAB>-m12/hello-commit:3f9c1e...
# [deploy : oc] deployment "hello-commit" successfully rolled out
# [report : print] Esito complessivo delle task: Succeeded
# [print-digest : print] Commit:  3f9c1e...
# [print-digest : print] Digest:  sha256:...
```

In alternativa, avvio dichiarativo (nome generato ⇒ `oc create`, non `oc apply`):

```yaml
# $EX288_WORK/m12/hello-commit-run.yaml
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  generateName: hello-commit-run-
spec:
  pipelineRef:
    name: hello-commit
  taskRunTemplate:
    serviceAccountName: pipeline
  params:
  - name: GIT_URL
    value: GIT_REPO_DA_SOSTITUIRE
  workspaces:
  - name: shared
    volumeClaimTemplate:
      spec:
        accessModes:
        - ReadWriteOnce
        resources:
          requests:
            storage: 500Mi
```

```bash
sed "s|GIT_REPO_DA_SOSTITUIRE|$GIT_REPO|" $EX288_WORK/m12/hello-commit-run.yaml | oc create -f -
tkn pr logs --last -f
```

Verifica: il tag dell'immagine è lo SHA del commit in testa al branch.

```bash
COMMIT=$(git ls-remote "$GIT_REPO" "refs/heads/$GIT_BRANCH" | cut -f1); echo $COMMIT
oc get is hello-commit -o jsonpath='{.status.tags[*].tag}{"\n"}'          # contiene $COMMIT
oc get istag hello-commit:$COMMIT -o jsonpath='{.image.metadata.name}{"\n"}'   # sha256:... = digest stampato da print-digest
oc get deploy hello-commit -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'   # ...:<COMMIT>
PR=$(oc get pr -l tekton.dev/pipeline=hello-commit --sort-by=.metadata.creationTimestamp -o name | tail -1 | cut -d/ -f2)
oc get tr -l tekton.dev/pipelineRun=$PR,tekton.dev/pipelineTask=fetch-source \
  -o jsonpath='{.items[0].status.results[?(@.name=="COMMIT")].value}{"\n"}'  # stesso SHA
curl -s http://$(oc get route hello-commit -o jsonpath='{.spec.host}')/ | head -3
```

**Perché funziona:** un result (`$(tasks.fetch-source.results.COMMIT)`) si può usare in qualsiasi valore di parametro, quindi anche nel tag di `IMAGE`; usarlo crea anche la dipendenza da `fetch-source`. Il deploy costruisce lo **stesso** riferimento `<registry>/<progetto>/hello-commit:<COMMIT>` e il nome del Deployment viene da `IMAGE_NAME`. Rilanciare sullo stesso commit non cambia il riferimento, quindi niente nuovo rollout (comportamento idempotente); un commit nuovo produce un tag nuovo e un rollout. Il digest è nel result `IMAGE_DIGEST` di buildah e lo legge una task `finally`.

**Perché due task `finally`:** una task `finally` che usa result non prodotti (ad esempio perché i test o la build sono falliti) non viene eseguita. Tenendo lo stato aggregato in `report` (senza result) e il digest in `print-digest`, il report arriva sempre.

> **Da verificare sul tuo cluster:** con i test o la build falliti, `tkn pr describe --last` deve mostrare `print-digest` come saltata (il motivo indicato dipende dalla versione di Pipelines) e `report` eseguita: provalo con una run che passa a `run-tests` il parametro `FAIL_TESTS=true` (aggiungilo alla Pipeline come in `hello-pipeline`). Verifica anche che il digest dell'istag coincida con `IMAGE_DIGEST` (`oc get istag hello-commit:$COMMIT -o jsonpath='{.image.metadata.name}'`): se il registry convertisse il formato del manifest, potrebbero differire.
</details>

### 4.3 Esercizio senza aiuti

Crea un secondo EventListener `hello-dev-listener` esposto con una Route, che avvia `hello-pipeline` con `DEPLOY=false` e `IMAGE_TAG=dev`. Invia un evento con `curl` e dimostra che: la PipelineRun è stata creata dal listener (label), l'immagine `hello-node:dev` esiste, la task `deploy` risulta *Skipped*.

---

## 5. Verifiche pratiche con `oc`

| Domanda | Comando |
|---|---|
| Pipelines è installato? Quali API Triggers sono servite? | `oc api-resources --api-group=tekton.dev` · `oc api-resources --api-group=triggers.tekton.dev -o wide` |
| Quali parametri/workspace/result ha una Task fornita? | `tkn task describe <t> -n openshift-pipelines` · `oc get task <t> -n openshift-pipelines -o yaml` |
| Com'è fatta la mia Pipeline? | `tkn pipeline describe <p>` · `oc get pipeline <p> -o jsonpath='{.spec.tasks[*].name}'` |
| La PipelineRun è finita bene? Quale task è fallita? | `tkn pr describe <pr>` · `oc get pr <pr> -o jsonpath='{.status.conditions[0].reason}: {.status.conditions[0].message}'` |
| Log di tutte le task / di una task | `tkn pr logs <pr> -a` · `tkn tr logs <taskrun>` · `oc logs <pod> -c step-<nome-step>` |
| Che pod ha creato una TaskRun? | `oc get pods -l tekton.dev/taskRun=<taskrun>` · `oc get tr <taskrun> -o jsonpath='{.status.podName}'` |
| Che valore ha un result? | `oc get tr <taskrun> -o jsonpath='{.status.results}'` |
| Il SA può fare il deploy/push? | `oc auth can-i create deployments --as=system:serviceaccount:<prog>:pipeline` |
| L'EventListener è pronto ed esposto? | `tkn el describe <el>` · `oc get deploy,svc,route -l eventlistener=<el>` |
| Cosa è successo all'arrivo dell'evento? | `tkn eventlistener logs <el>` · `oc get pr -l triggers.tekton.dev/eventlistener=<el>` |
| Eventi del progetto (PVC, pod) | `oc get events --sort-by=.lastTimestamp` |

---

## 6. Troubleshooting intenzionale

Lavora nel progetto `${LAB}-m12` dopo aver completato il laboratorio (servono `hello-pipeline`, `npm-test` e `hello-binding`). I file contengono il segnaposto `GIT_REPO_DA_SOSTITUIRE`: applicali con questa funzione.

```bash
oc project ${LAB}-m12
applica() { sed "s|GIT_REPO_DA_SOSTITUIRE|$GIT_REPO|g" "$1" | oc apply -f -; }
cd $EX288_HOME/12-openshift-pipelines/troubleshooting
```

### Scenario 1 — Pipeline "vecchio stile"

`applica rotto-1-clustertask.yaml`

**Sintomo:** a seconda della versione, `oc apply` rifiuta la Pipeline `ts1-pipeline`, oppure la PipelineRun `ts1-run` fallisce subito senza che parta alcun pod.

<details><summary>Indagine e soluzione</summary>

```bash
tkn pr describe ts1-run                     # messaggio: impossibile ottenere/risolvere la task (ClusterTask)
oc get pipeline ts1-pipeline -o jsonpath='{.spec.tasks[0].taskRef}{"\n"}'   # {"kind":"ClusterTask","name":"git-clone"}
oc api-resources --api-group=tekton.dev | grep -i clustertask                # nessun risultato
oc get tasks -n openshift-pipelines | grep git-clone
```
**Causa:** `kind: ClusterTask` non esiste più da OpenShift Pipelines 1.17.
**Fix:** sostituisci `taskRef` con il cluster resolver (`oc edit pipeline ts1-pipeline`):
```yaml
    taskRef:
      resolver: cluster
      params:
      - {name: kind, value: task}
      - {name: name, value: git-clone}
      - {name: namespace, value: openshift-pipelines}
```
poi rilancia: `tkn pipeline start ts1-pipeline -p GIT_URL=$GIT_REPO -w name=shared,volumeClaimTemplateFile=$EX288_HOME/12-openshift-pipelines/lab/04-pvc-template.yaml --showlog`.
**Lezione:** molti esempi su Internet usano ancora i ClusterTask: riconoscili e convertili. Se il resolver stesso non funziona, l'amministratore può controllare `enable-cluster-resolver` nella ConfigMap `resolvers-feature-flags` in `openshift-pipelines`.
</details>

### Scenario 2 — Parametri con il nome sbagliato

`applica rotto-2-param-minuscoli.yaml`

**Sintomo:** la PipelineRun `ts2-run` fallisce subito; nessun log dallo step di git-clone.

<details><summary>Indagine e soluzione</summary>

```bash
tkn pr describe ts2-run                     # messaggio sui parametri: URL mancante / parametri non dichiarati
tkn task describe git-clone -n openshift-pipelines | sed -n '/Params/,/Results/p'
```
**Causa:** la Pipeline passa `url` e `revision` (nomi dei vecchi ClusterTask); la Task attuale dichiara `URL` e `REVISION`, e `URL` non ha default: il parametro obbligatorio manca.
**Fix:** `oc edit pipeline ts2-pipeline` → `name: URL` e `name: REVISION`; poi rilancia con `tkn pipeline start ts2-pipeline --last --showlog` oppure ricrea la PipelineRun (`oc delete pr ts2-run` e `applica` di nuovo).
**Lezione:** i nomi dei parametri sono case-sensitive. Leggili dal cluster prima di scrivere la Pipeline.
</details>

### Scenario 3 — Workspace non fornito

`applica rotto-3-workspace-mancante.yaml`

**Sintomo:** `ts3-run` fallisce immediatamente, nessuna TaskRun creata.

<details><summary>Indagine e soluzione</summary>

```bash
tkn pr describe ts3-run                     # "pipeline requires workspace with name "shared" be provided by pipelinerun"
oc get pr ts3-run -o jsonpath='{.spec.workspaces}{"\n"}'    # vuoto
```
**Causa:** la Pipeline dichiara il workspace `shared`, ma la PipelineRun non lo collega a nessun volume.
**Fix:** una PipelineRun non si "ripara": creane una nuova con il workspace, ad esempio `tkn pipeline start hello-pipeline -p GIT_URL=$GIT_REPO -p DEPLOY=false -w name=shared,volumeClaimTemplateFile=$EX288_HOME/12-openshift-pipelines/lab/04-pvc-template.yaml --use-param-defaults --showlog`.
**Lezione:** la Pipeline *dichiara* i workspace, la PipelineRun li *fornisce*. Un workspace può essere marcato `optional: true` solo se le task lo prevedono.
</details>

### Scenario 4 — Il codice "sparisce" tra una task e l'altra

`applica rotto-4-emptydir.yaml`

**Sintomo:** `fetch-source` termina con successo, ma `run-tests` fallisce con un errore di npm su `package.json` non trovato.

<details><summary>Indagine e soluzione</summary>

```bash
tkn pr logs ts4-run -a | tail -20          # in run-tests: "ls" mostra una directory vuota, npm: enoent ... package.json
oc get pr ts4-run -o jsonpath='{.spec.workspaces}{"\n"}'    # [{"emptyDir":{},"name":"shared"}]
```
**Causa:** un `emptyDir` vive solo per la durata del pod di **una** TaskRun. git-clone ha scritto in un `emptyDir`, npm-test ha ricevuto un altro `emptyDir`, vuoto.
**Fix:** rilancia con un `volumeClaimTemplate` (o una PVC esistente: `-w name=shared,claimName=<pvc>`).
**Lezione:** per passare file tra task diverse serve un volume persistente; `emptyDir` va bene solo dentro una singola task.
</details>

### Scenario 5 — Push dell'immagine negato

`applica rotto-5-push-negato.yaml`

**Sintomo:** clone e build vanno avanti, poi la task `build` di `ts5-run` fallisce alla fine.

<details><summary>Indagine e soluzione</summary>

```bash
tkn pr logs ts5-run -a | tail -20          # errore di autorizzazione/denied nel push verso .../openshift/hello-node:ts5
oc get pr ts5-run -o jsonpath='{.spec.params}{"\n"}'
oc auth can-i update imagestreams --subresource=layers -n openshift --as=system:serviceaccount:${LAB}-m12:pipeline   # no
oc auth can-i update imagestreams --subresource=layers --as=system:serviceaccount:${LAB}-m12:pipeline                 # yes
```
**Causa:** `IMAGE` punta al progetto `openshift`; il SA `pipeline` può fare push solo nel registry del **proprio** progetto.
**Fix:** rilancia con `IMAGE=image-registry.openshift-image-registry.svc:5000/${LAB}-m12/hello-node:ts5` (in generale usa `$(context.pipelineRun.namespace)`). Se il push in un altro progetto è davvero voluto, un admin di quel progetto deve concedere `system:image-builder` al SA (`oc policy add-role-to-user system:image-builder system:serviceaccount:${LAB}-m12:pipeline -n <altro>`).
**Lezione:** leggi il messaggio finale della task buildah: "denied/unauthorized" = permessi o progetto sbagliato, non un problema del Dockerfile.
</details>

### Scenario 6 — Test che falliscono

`applica rotto-6-test-fallito.yaml`

**Sintomo:** `ts6-run` è *Failed*, `hello-node:ts6` non esiste e il Deployment `hello-node` non è cambiato.

<details><summary>Indagine e soluzione</summary>

```bash
tkn pr describe ts6-run                    # run-tests Failed, build-image e deploy non eseguite, report Succeeded
tkn pr logs ts6-run -a | grep -E 'TEST|Esito'   # TEST FALLITO: FAIL_TESTS=true ... / Esito complessivo: Failed
oc get pr ts6-run -o jsonpath='{.spec.params}{"\n"}'   # FAIL_TESTS=true
```
**Causa:** la PipelineRun ha passato `FAIL_TESTS=true`, che arriva come variabile d'ambiente allo step di `npm-test`: i test falliscono e la Pipeline si ferma prima della build. È il comportamento voluto.
**Fix:** nella realtà si corregge il codice; qui rilancia con `FAIL_TESTS=false`.
**Lezione:** i test sono un *gate*: solo il codice che passa i test diventa un'immagine. La task `finally` gira comunque ed è il posto giusto per notifiche e report.
</details>

### Scenario 7 — L'EventListener risponde, ma non parte nulla

`oc apply -f rotto-7-eventlistener.yaml && oc expose svc el-ts7-listener`, poi invia il payload del passo 3.8 alla route `el-ts7-listener`.

**Sintomo:** `curl` riceve la risposta con l'`eventID`, ma non compare nessuna PipelineRun in esecuzione (o ne compare una già fallita).

<details><summary>Indagine e soluzione</summary>

```bash
tkn eventlistener logs ts7-listener        # eventuali errori di creazione risorse
oc get pr -l triggers.tekton.dev/eventlistener=ts7-listener
tkn pr describe <ts7-run-xxxxx>            # Pipeline "hello-pipline" non trovata
oc get triggertemplate ts7-template -o jsonpath='{.spec.resourcetemplates[0].spec.pipelineRef.name}{"\n"}'
```
**Causa:** il TriggerTemplate crea una PipelineRun che riferisce la Pipeline `hello-pipline` (refuso). L'EventListener accetta l'evento in ogni caso: gli errori emergono dopo.
**Fix:** `oc edit triggertemplate ts7-template` → `pipelineRef.name: hello-pipeline`; invia di nuovo l'evento.
**Lezione:** "202/eventID" significa solo "evento ricevuto". Controlla sempre i log del listener e lo stato della PipelineRun creata.
</details>

Pulizia: `oc delete pipeline,pipelinerun,triggertemplate,eventlistener -l 'scenario in (m12-1,m12-2,m12-3,m12-4,m12-5,m12-6,m12-7)'` e `oc delete route el-ts7-listener`. A fine modulo: `oc delete project ${LAB}-m12`.

---

## 7. Esercizio finale (stile EX288)

> Lavora come all'esame: niente soluzioni, solo documentazione ufficiale, `--help`, `oc explain` e `tkn ... describe`. Tempo indicativo: **75 minuti**.

**Requisiti**

1. Esiste il progetto `${LAB}-m12-exam`.
2. Nel progetto esiste una Task **`unit-test`** che:
   - dichiara un workspace chiamato `source`;
   - dichiara un parametro `APP_DIR` con default `hello-node`;
   - esegue `npm test` nella directory `APP_DIR` del workspace, usando l'immagine `registry.access.redhat.com/ubi9/nodejs-22`.
3. Nel progetto esiste una Pipeline **`ci-hello`** con:
   - parametri `GIT_URL` (senza default), `GIT_REVISION` (default `main`), `IMAGE_TAG` (default `v1`);
   - un solo workspace chiamato `shared`;
   - esattamente quattro task, in quest'ordine e con questi nomi: `clone` (Task `git-clone` fornita da OpenShift Pipelines), `test` (Task `unit-test`), `build` (Task `buildah` fornita), `deploy` (Task `openshift-client` fornita); ogni task parte solo dopo il completamento della precedente;
   - una task `finally` chiamata `report`;
   - nessun riferimento a `ClusterTask`.
4. La task `build` produce l'immagine `image-registry.openshift-image-registry.svc:5000/${LAB}-m12-exam/hello-ci:<IMAGE_TAG>` a partire da `hello-node/Dockerfile` del repository `$GIT_REPO`.
5. La task `deploy` crea o aggiorna il Deployment **`hello-ci`** (1 replica) in modo che usi l'immagine appena prodotta **riferita per digest** (`...hello-ci@sha256:...`). L'applicazione è esposta dalla route **`hello-ci`**.
6. Almeno una PipelineRun di `ci-hello` avviata con il default di `IMAGE_TAG` è terminata con successo, con il workspace `shared` fornito tramite `volumeClaimTemplate`.
7. Esiste un EventListener **`ci-listener`**, esposto all'esterno dalla route **`el-ci-listener`**, che a ogni evento push (payload in stile GitHub, con `repository.html_url` e `head_commit.id`) avvia `ci-hello` con `IMAGE_TAG=latest` sul commit ricevuto.
8. Almeno una PipelineRun creata da `ci-listener` è terminata con successo.

**Risultato atteso**

- L'image stream `hello-ci` contiene i tag `v1` e `latest`.
- `curl http://<host-route-hello-ci>/` restituisce il JSON di hello-node (`"app": "hello-node"`).
- `oc get pipelinerun -l triggers.tekton.dev/eventlistener=ci-listener` mostra almeno una run *Succeeded*.

```bash
bash $EX288_HOME/12-openshift-pipelines/verifica.sh
```

---

## 8. Riferimenti ufficiali (OpenShift Pipelines 1.24 / OCP 4.22)

- About OpenShift Pipelines → *Understanding OpenShift Pipelines*: https://docs.redhat.com/en/documentation/red_hat_openshift_pipelines/1.24/html/about_openshift_pipelines/understanding-openshift-pipelines
- Creating CI/CD pipelines (Task, Pipeline, workspace, when, finally, triggers): https://docs.redhat.com/en/documentation/red_hat_openshift_pipelines/1.24/html/creating_cicd_pipelines/index
- Creating CI/CD pipelines → *Migrating from OpenShift Pipelines ClusterTask to cluster resolver*: https://docs.redhat.com/en/documentation/red_hat_openshift_pipelines/1.24/html/creating_cicd_pipelines/migrate-from-clustertask-to-cluster-resolver
- Pipelines CLI (tkn) reference: https://docs.redhat.com/en/documentation/red_hat_openshift_pipelines/1.24/html/pipelines_cli_tkn_reference/op-tkn-reference
- Securing OpenShift Pipelines → *Authenticating pipelines with repositories using secrets*: https://docs.redhat.com/en/documentation/red_hat_openshift_pipelines/1.24/html/securing_openshift_pipelines/authenticating-pipelines-repos-using-secrets
- Pipelines as Code: https://docs.redhat.com/en/documentation/red_hat_openshift_pipelines/1.24/html/pipelines_as_code/
- Release notes 1.24 (matrice di compatibilità): https://docs.redhat.com/en/documentation/red_hat_openshift_pipelines/1.24/html/release_notes/op-release-notes-1-24
- Learning path Red Hat Developer *Using OpenShift Pipelines*: https://developers.redhat.com/learn/openshift/using-openshift-pipelines
