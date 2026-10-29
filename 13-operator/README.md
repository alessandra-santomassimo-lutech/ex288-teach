# Modulo 13 — Operator: creare applicazioni dalle API fornite dagli Operator installati

> **Obiettivi EX288 coperti**
> - *Work with Operators accessible for users to run in their applications* → Creating applications from installed Operators
>
> **Durata stimata:** 3-4 ore · **Prerequisiti:** moduli 01, 07, 08 (e 12 per il piano B) · **Richiede cluster-admin:** no per usare gli Operator; **sì** per installarli (lo fa l'amministratore, vedi 3.0)
>
> **Progetti usati:** `${LAB}-m13`, `${LAB}-m13-exam`

---

## 1. Perché e quando

Un **Operator** è un'applicazione che gira nel cluster e "sa" gestire un software complesso (un database, una cache, un broker, la stessa OpenShift Pipelines) al posto di una persona. Aggiunge al cluster una **nuova API**: tu dichiari *cosa* vuoi (es. "una cache con 2 nodi") e l'Operator crea e mantiene *come* farlo (StatefulSet, Service, Secret, configurazione, upgrade).

| Ti serve… | Usa | Perché |
|---|---|---|
| Deployare la **tua** applicazione stateless | Deployment, Template, Helm, Kustomize (moduli 08-11) | Conosci e controlli tutti gli oggetti; nessuna logica operativa da automatizzare |
| Un servizio "di piattaforma" (database, cache, messaging) con operazioni del giorno 2: scaling ordinato, backup, upgrade, failover | **Istanza di una API fornita da un Operator** | L'Operator incorpora la conoscenza operativa del fornitore: tu scrivi poche righe di CR |
| Lo stesso servizio, ma una volta sola e senza manutenzione | Template o Helm chart del fornitore | Più semplice, ma upgrade e riparazioni restano a te |
| Installare/aggiornare un Operator nel cluster | **Lo fa l'amministratore** (Software Catalog/OLM) | Le CRD sono globali al cluster e richiedono privilegi elevati |
| Sapere cosa puoi creare nel tuo progetto | `oc get csv`, `oc api-resources`, `alm-examples`, `oc explain` | Gli Operator variano da cluster a cluster: la procedura di scoperta è sempre la stessa |

**Divisione dei compiti (fondamentale per l'esame):**

| Amministratore (cluster-admin) | Sviluppatore (ruolo `edit` sul progetto) |
|---|---|
| Sceglie l'Operator nel Software Catalog, il canale, la modalità di installazione (*All namespaces* o un namespace specifico), approva gli aggiornamenti | Scopre quali API sono disponibili nel suo progetto |
| Crea Subscription/OperatorGroup (OLM) | Crea, modifica e cancella le **istanze** (CR) |
| Gestisce l'Operator stesso (pod, log, RBAC) | Collega le proprie applicazioni ai servizi creati dall'Operator |

---

## 2. Concetti essenziali

### 2.1 CRD, CR, controller

- **CRD** (CustomResourceDefinition): definisce un nuovo tipo di risorsa (es. `Infinispan` nel gruppo `infinispan.org`). È **globale al cluster**: una volta installata, l'API esiste in tutti i progetti.
- **CR** (custom resource): un'istanza di quel tipo nel tuo progetto (es. `Infinispan/cache`). È solo un oggetto YAML con `spec` (desiderato) e `status` (osservato).
- **Controller**: il pod dell'Operator che osserva i CR e **riconcilia** continuamente lo stato reale con la `spec`: crea le risorse figlie, le corregge se qualcuno le modifica, aggiorna `status.conditions`.

```yaml
apiVersion: infinispan.org/v1     # <gruppo>/<versione> della CRD
kind: Infinispan                  # tipo definito dalla CRD
metadata:
  name: cache                     # nome dell'istanza (spesso diventa il prefisso delle risorse figlie)
spec:                             # ciò che chiedi tu
  replicas: 1
  service:
    type: DataGrid
status:                           # scritto SOLO dall'Operator
  conditions:
  - type: wellFormed              # ogni Operator ha le sue condizioni: leggile, non indovinarle
    status: "True"
```

Le risorse figlie hanno un **ownerReference** verso il CR: se cancelli il CR, il **garbage collector** di Kubernetes cancella anche le figlie.

### 2.2 OLM in breve (quello che ti serve leggere)

| Oggetto OLM | Chi lo crea | A cosa ti serve come sviluppatore |
|---|---|---|
| **ClusterServiceVersion (CSV)** | OLM, all'installazione | Descrive l'Operator installato: versione, fase (`Succeeded`), API fornite (`spec.customresourcedefinitions.owned`), esempi (`alm-examples`). È ciò che la console mostra in *Installed Operators* |
| Subscription, InstallPlan, OperatorGroup, CatalogSource | Amministratore | Di solito non li vedi; spiegano *dove* e *come* è installato l'Operator |

**Modalità di installazione** (decise dall'admin, nell'OperatorGroup):

- *All namespaces* (in `openshift-operators`): l'Operator gestisce i CR di **tutti** i progetti; la CSV viene copiata in ogni progetto e i permessi sulle sue API vengono aggregati ai ruoli `admin`/`edit`/`view`. **È la modalità da chiedere per questo corso.**
- *A specific namespace*: l'Operator gestisce solo il namespace scelto; dagli altri progetti la CSV non è visibile e normalmente non hai i permessi sulle sue API.

> **Nota di versione:** in OCP 4.22 è GA anche **OLM v1** (`ClusterExtension`, `ClusterCatalog`), gestito solo da CLI dall'amministratore e a livello di cluster. Le procedure per gli sviluppatori della documentazione 4.22 (*Operators → User tasks*) usano ancora le **CSV di OLM Classic**: è il flusso descritto qui. Nella console 4.22 il menu si chiama **Ecosystem → Installed Operators** (prima *Operators → Installed Operators*; il catalogo è **Ecosystem → Software Catalog**, prima *OperatorHub*).

### 2.3 Gli esempi pronti: `alm-examples`

Ogni CSV ha l'annotazione `alm-examples`: un array JSON con un CR di esempio per ogni API fornita. È esattamente ciò che la console usa per precompilare il form *Create instance*. All'esame, è la scorciatoia più affidabile per ottenere un CR valido: lo estrai, cambi nome e campi richiesti, lo applichi.

---

## 3. Laboratorio guidato

Il laboratorio ha due parti:

- **procedura generale** (3.1-3.4, 3.6-3.10), valida per qualunque Operator: la userai all'esame con l'Operator che troverai;
- **esempio guidato concreto** con l'Operator **Red Hat Data Grid** (API `Infinispan`), documentato da Red Hat e con un CR minimo adatto a uno sviluppatore. Se il tuo cluster non lo ha, usa il **piano B** (3.11) con OpenShift Pipelines, già richiesto dal corso, e ripeti la procedura generale con qualunque altro Operator applicativo disponibile.

### 3.0 Prerequisito (amministratore)

Chiedi all'amministratore del cluster di installare dal **Software Catalog** l'Operator **Data Grid** (pacchetto `datagrid`, catalogo `redhat-operators`, canale `8.5.x` secondo la documentazione Data Grid 8.5) in modalità **All namespaces**.

> **Da verificare sul tuo cluster:** la compatibilità di Data Grid 8.5 con OCP 4.22 e il canale disponibile. L'amministratore può controllarli con `oc get packagemanifests -n openshift-marketplace | grep -i datagrid` e `oc describe packagemanifest datagrid -n openshift-marketplace`.

### 3.1 Preparare il progetto e verificare i permessi

```bash
source env.sh                 # dalla root del repository ex288-teach
oc new-project ${LAB}-m13 --display-name="EX288 m13 - operator"
oc auth can-i create infinispans.infinispan.org    # yes = l'API esiste e il tuo ruolo può usarla
```

### 3.2 Scoprire gli Operator disponibili nel progetto

```bash
oc get csv
# NAME                                 DISPLAY                       VERSION   PHASE
# datagrid-operator.v8.5.x             Data Grid                     8.5.x     Succeeded
# openshift-pipelines-operator-rh.v1.24.x  Red Hat OpenShift Pipelines   1.24.x    Succeeded

CSV=$(oc get csv -o name | grep -i datagrid | cut -d/ -f2); echo $CSV
oc get csv $CSV -o jsonpath='{.status.phase}{"\n"}'                     # Succeeded = pronto all'uso
oc get csv $CSV -o jsonpath='{.spec.customresourcedefinitions.owned[*].kind}{"\n"}'
# Infinispan Backup Restore Batch Cache ...   <- le API che puoi creare
oc get csv $CSV -o jsonpath='{range .spec.customresourcedefinitions.owned[*]}{.kind}{"\t"}{.name}{"\t"}{.version}{"\n"}{end}'
oc api-resources --api-group=infinispan.org                          # nomi, shortname, namespaced, kind
```

> **Da verificare sul tuo cluster:** se `oc get csv` nel tuo progetto è vuoto anche se gli Operator sono installati, l'amministratore potrebbe aver disabilitato le *copied CSV*. Le API restano utilizzabili: scoprile con `oc api-resources` e `oc get csv -n openshift` (se leggibile).

Dalla console: **Ecosystem → Installed Operators** (progetto `${LAB}-m13`) → Data Grid → scheda *Details* (sezione **Provided APIs**).

### 3.3 Leggere gli esempi e i campi del CR

```bash
# Tutti gli esempi, leggibili
oc get csv $CSV -o jsonpath='{.metadata.annotations.alm-examples}' | jq .
# Solo l'esempio di un kind
oc get csv $CSV -o jsonpath='{.metadata.annotations.alm-examples}' | jq '.[] | select(.kind=="Infinispan")'

# Uno per file, con lo script del corso (usa jq o python3)
bash $EX288_HOME/13-operator/lab/estrai-alm-examples.sh $CSV $EX288_WORK/m13/esempi-m13
ls $EX288_WORK/m13/esempi-m13

# Documentazione dei campi direttamente dalla CRD
oc explain infinispan.spec
oc explain infinispan.spec.service --recursive | head -30
oc explain infinispan.status.conditions
```

> **Abitudine da esame:** `alm-examples` ti dà un CR che passa la validazione; `oc explain` ti dice cosa significa ogni campo e quali sono obbligatori. Non scrivere un CR da zero a memoria.

### 3.4 Creare un'istanza dalla console

1. **Ecosystem → Installed Operators** → Data Grid → scheda **Infinispan Cluster** (o *Provided APIs* → *Create instance*).
2. **Create Infinispan**: scegli **Form view** (campi guidati, generati dallo schema della CRD) oppure **YAML view** (precompilato da `alm-examples`).
3. Nome `console-cache`, repliche `1`, poi **Create**.
4. Apri l'istanza: scheda *Details* (status/conditions), scheda **Resources** (risorse create dall'Operator), scheda *Events*.
5. Verifica da CLI e cancellala: `oc get infinispan console-cache -o yaml` · `oc delete infinispan console-cache`.

### 3.5 Creare l'istanza da CLI (esempio Data Grid)

```bash
cat $EX288_HOME/13-operator/lab/datagrid-cache.yaml      # CR minimo, da docs Data Grid 8.5
oc apply -f $EX288_HOME/13-operator/lab/datagrid-cache.yaml
oc get infinispan                                         # oppure: oc get infinispans.infinispan.org
oc get pods -w                                            # cache-0 (+ eventuale pod "config-listener")
```

### 3.6 Osservare la riconciliazione: status e risorse figlie

```bash
# 1) Lo status del CR: è lì che l'Operator dice se l'istanza è pronta
oc get infinispan cache -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.message}{"\n"}{end}'
# wellFormed=True View: [cache-0]
oc wait --for condition=wellFormed --timeout=240s infinispan/cache     # comando della documentazione Data Grid

# 2) Le risorse create dall'Operator e il loro proprietario
oc get statefulset,svc,secret,configmap \
  -o custom-columns='KIND:.kind,NAME:.metadata.name,OWNER:.metadata.ownerReferences[*].kind,OWNER-NAME:.metadata.ownerReferences[*].name'
# StatefulSet cache                          Infinispan  cache
# Service     cache        (porta 11222)     Infinispan  cache
# Service     cache-admin / cache-ping       Infinispan  cache
# Secret      cache-generated-secret         Infinispan  cache   (credenziali utente "developer")
# Secret      cache-generated-operator-secret ...
oc get pods -l clusterName=cache --show-labels
oc describe infinispan cache | sed -n '/Status/,$p'
```

Procedura generale per **qualunque** Operator: (1) `oc get <kind> <nome> -o yaml` e leggi `status`; (2) elenca le risorse del progetto con la colonna `ownerReferences` come sopra; (3) `oc get events --sort-by=.lastTimestamp`.

### 3.7 Modificare il CR: l'Operator applica la modifica

```bash
oc patch infinispan cache --type=merge -p '{"spec":{"replicas":2}}'   # oppure: oc edit infinispan cache
oc get pods -l clusterName=cache -w                                    # compare cache-1
oc get statefulset cache -o jsonpath='{.spec.replicas}{"\n"}'          # 2: lo ha scritto l'Operator
oc wait --for condition=wellFormed --timeout=300s infinispan/cache
```

Non hai toccato lo StatefulSet: hai cambiato la **spec del CR** e il controller ha propagato la modifica.

### 3.8 Modificare a mano una risorsa figlia: l'Operator la ripristina

```bash
oc scale statefulset cache --replicas=1      # "correzione" manuale sbagliata
oc get statefulset cache -w                  # dopo pochi secondi torna a 2
```

L'Operator confronta continuamente lo stato reale con la spec del CR e annulla le differenze. **Regola:** le risorse create da un Operator si cambiano **solo** tramite il CR (o le opzioni che il CR espone).

> **Da verificare sul tuo cluster:** il tempo di reazione e il tipo di correzione dipendono dall'Operator; alcuni campi delle risorse figlie non sono gestiti e possono restare modificati. L'unica fonte affidabile è la documentazione dell'Operator (per Data Grid: *Data Grid Operator Guide → Resource reconciliation*).

### 3.9 Collegare hello-node al servizio creato dall'Operator

L'Operator ha creato il Service `cache` (porta 11222, documentazione Data Grid *Network services*) e il Secret `cache-generated-secret` con le credenziali dell'utente applicativo `developer` nel file `identities.yaml`.

```bash
# App hello-node (strategia Docker, come nel modulo 02)
oc new-app "$GIT_REPO#$GIT_BRANCH" --context-dir=hello-node --name=hello-node
oc logs -f bc/hello-node

# Credenziali generate dall'Operator (formato specifico di Data Grid)
oc get secret cache-generated-secret -o jsonpath='{.data.identities\.yaml}' | base64 -d
# credentials:
# - username: developer
#   password: <generata>
PASS=$(oc get secret cache-generated-secret -o jsonpath='{.data.identities\.yaml}' | base64 -d | awk '/password:/ {print $2; exit}')

# Secret "applicativo" con le chiavi che l'app si aspetta
oc create secret generic cache-client --from-literal=DB_USER=developer --from-literal=DB_PASSWORD="$PASS"
oc set env deployment/hello-node DB_HOST=cache DB_PORT=11222 DB_NAME=datagrid
oc set env deployment/hello-node --from=secret/cache-client
oc create route edge hello-node --service=hello-node
curl -sk https://$(oc get route hello-node -o jsonpath='{.spec.host}')/db
# {"db": "raggiungibile", "host": "cache", "port": 11222, "name": "datagrid", "user": "developer"}
curl -sk https://$(oc get route hello-node -o jsonpath='{.spec.host}')/env     # DB_PASSWORD impostata (mascherata)
```

> **Da verificare sul tuo cluster:** il formato di `identities.yaml` (nella documentazione è una lista `credentials` con `username`/`password`). Molti Operator di database generano invece un Secret con chiavi già pronte (`host`, `port`, `username`, `password`): in quel caso basta `oc set env deployment/<app> --from=secret/<secret> --prefix=DB_` (controlla i nomi con `oc get secret <s> -o jsonpath='{.data}'`).

Perché un Secret "applicativo" separato? Il Secret dell'Operator è una **risorsa figlia** (gestita e riscritta dall'Operator) e ha un formato pensato per il server, non per la tua app. Copiare i valori in un Secret tuo rende esplicito il contratto con l'applicazione.

### 3.10 Cancellare il CR: garbage collection

```bash
oc delete infinispan cache
oc get statefulset,svc,secret | grep cache            # spariscono (ownerReferences + garbage collector)
# resta solo ciò che hai creato tu: il Secret cache-client
curl -sk https://$(oc get route hello-node -o jsonpath='{.spec.host}')/db   # 503: "NON raggiungibile"
```

Ricrea l'istanza (`oc apply -f .../datagrid-cache.yaml`) per la sezione 6.

### 3.11 Piano B: OpenShift Pipelines come Operator

Se Data Grid non è disponibile, esegui la procedura di scoperta con l'Operator Pipelines, che il corso richiede comunque.

```bash
CSV=$(oc get csv -o name | grep -i pipelines | cut -d/ -f2)
oc get csv $CSV -o jsonpath='{.spec.customresourcedefinitions.owned[*].kind}{"\n"}'
# ad esempio TektonConfig, TektonPipeline, TektonTrigger, ...  <- API per l'AMMINISTRATORE (configurano l'Operator)
oc get csv $CSV -o jsonpath='{.metadata.annotations.alm-examples}' | jq '.[].kind'
oc api-resources --api-group=tekton.dev              # Task, TaskRun, Pipeline, ... <- API per lo SVILUPPATORE
```

Osserva: le API *possedute* dalla CSV sono di configurazione (cluster-scoped, per l'admin); le API che usi tu (`Task`, `Pipeline`…) sono CRD installate dai componenti dell'Operator. Creare risorse Tekton è già "usare API fornite da un Operator", e vale la stessa meccanica controller → risorse figlie → ownerReferences → garbage collection:

```bash
oc apply -f $EX288_HOME/13-operator/lab/pianob-taskrun.yaml
oc get pods -l tekton.dev/taskRun=osserva-owner \
  -o custom-columns='POD:.metadata.name,OWNER:.metadata.ownerReferences[*].kind,OWNER-NAME:.metadata.ownerReferences[*].name'
# osserva-owner-pod   TaskRun   osserva-owner
oc get taskrun osserva-owner -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}{"\n"}{end}'   # Succeeded=Unknown Running
oc delete taskrun osserva-owner
oc get pods -l tekton.dev/taskRun=osserva-owner       # il pod viene eliminato con la TaskRun
```

> Per l'esame il caso tipico resta un'**istanza applicativa** (database, cache, broker) da creare con la procedura generale: se in azienda trovi un altro Operator applicativo installato *All namespaces* (es. Streams for Apache Kafka, AMQ Broker, Red Hat build of Keycloak), ripeti 3.2-3.10 con quello.

---

## 4. Esercizi

### 4.1 Esercizio guidato

Nel progetto `${LAB}-m13` crea, **partendo da `alm-examples`**, un'istanza `Infinispan` chiamata `sessioni` con 2 repliche e storage effimero, con la label `team=web`. Attendi che sia pronta e trova il nome del Secret con le credenziali applicative.

<details><summary>Suggerimenti</summary>

- Estrai l'esempio con lo script del corso, poi cambia `metadata.name`, aggiungi `metadata.labels`.
- Lo storage effimero è un campo sotto `spec.service.container` (`oc explain infinispan.spec.service.container`).
- Il Secret applicativo si chiama `<nome-cluster>-generated-secret`.
</details>

<details><summary>Soluzione</summary>

```bash
bash $EX288_HOME/13-operator/lab/estrai-alm-examples.sh $CSV $EX288_WORK/m13/ex41
F=$(ls $EX288_WORK/m13/ex41/*-infinispan.json | head -1)
oc create --dry-run=client -o yaml -f $F > $EX288_WORK/m13/sessioni.yaml
vi $EX288_WORK/m13/sessioni.yaml
#   metadata: name: sessioni / labels: {team: web}   (rimuovi eventuale namespace)
#   spec.replicas: 2
#   spec.service.type: DataGrid
#   spec.service.container.ephemeralStorage: true
oc apply -f $EX288_WORK/m13/sessioni.yaml
oc wait --for condition=wellFormed --timeout=300s infinispan/sessioni
oc get infinispan sessioni --show-labels
oc get secret sessioni-generated-secret
```
</details>

### 4.2 Esercizio semi-guidato

Collega una seconda istanza di hello-node (`hello-sessioni`) al cluster `sessioni`, con `DB_PASSWORD` letta da un Secret tuo e `DB_HOST` scritto con il nome DNS completo del Service (`<svc>.<progetto>.svc`). Poi scala `sessioni` a 1 replica modificando **solo** il CR e dimostra che `/db` continua a rispondere.

<details><summary>Suggerimenti</summary>

- Ripassa 3.9: porta, nome del Service, formato di `identities.yaml`.
- Per scalare: patch del campo `spec.replicas` del CR; osserva lo StatefulSet.
</details>

<details><summary>Soluzione (aprila solo dopo aver provato)</summary>

```bash
oc project ${LAB}-m13
oc get infinispan sessioni                               # creata nell'esercizio 4.1 (2 repliche)
oc get svc sessioni -o jsonpath='{.spec.ports[*].port}{"\n"}'   # 11222: Service con lo stesso nome del cluster

# 1) Password dell'utente "developer" generata dall'Operator per il cluster sessioni
oc get secret sessioni-generated-secret -o jsonpath='{.data.identities\.yaml}' | base64 -d
PASS=$(oc get secret sessioni-generated-secret -o jsonpath='{.data.identities\.yaml}' | base64 -d | awk '/password:/ {print $2; exit}')
echo ${#PASS}                                            # lunghezza > 0 (non stampare la password)

# 2) Secret TUO, con le chiavi che si aspetta l'app
oc create secret generic sessioni-client --from-literal=DB_USER=developer --from-literal=DB_PASSWORD="$PASS"

# 3) Seconda istanza di hello-node dalla stessa immagine (image stream hello-node del passo 3.9)
IMG=$(oc get is hello-node -o jsonpath='{.status.dockerImageRepository}'):latest; echo $IMG
oc create deployment hello-sessioni --image=$IMG --port=8080
oc set env deployment/hello-sessioni DB_HOST=sessioni.${LAB}-m13.svc DB_PORT=11222 DB_NAME=datagrid
oc set env deployment/hello-sessioni --from=secret/sessioni-client    # DB_USER e DB_PASSWORD via secretKeyRef
oc set env deployment/hello-sessioni --list
# DB_HOST=sessioni.<LAB>-m13.svc
# DB_PORT=11222
# DB_NAME=datagrid
# # DB_USER from secret sessioni-client, key DB_USER
# # DB_PASSWORD from secret sessioni-client, key DB_PASSWORD
oc rollout status deployment/hello-sessioni
oc expose deployment hello-sessioni --port=8080
oc create route edge hello-sessioni --service=hello-sessioni
H=$(oc get route hello-sessioni -o jsonpath='{.spec.host}')
curl -sk https://$H/db
# {"db": "raggiungibile", "host": "sessioni.<LAB>-m13.svc", "port": 11222, "name": "datagrid", "user": "developer"}
curl -sk https://$H/env                                   # DB_PASSWORD: impostata (N caratteri)

# 4) Scalare a 1 replica modificando SOLO il CR
oc patch infinispan sessioni --type=merge -p '{"spec":{"replicas":1}}'
oc get statefulset sessioni -w                            # READY 2/2 -> 1/1 (Ctrl+C per uscire)
oc get pods -l clusterName=sessioni                       # resta solo sessioni-0
oc get statefulset sessioni -o jsonpath='{.spec.replicas}{"\n"}'   # 1: lo ha scritto l'Operator
oc wait --for condition=wellFormed --timeout=300s infinispan/sessioni
oc get endpointslices -l kubernetes.io/service-name=sessioni \
  -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]}{"\n"}{end}'   # un solo indirizzo
curl -sk https://$H/db                                    # ancora "raggiungibile"
```

Per vedere che `/db` non si interrompe **durante** lo scaling, lancia in un secondo terminale prima della patch:

```bash
source env.sh; oc project ${LAB}-m13
H=$(oc get route hello-sessioni -o jsonpath='{.spec.host}')
for i in $(seq 1 40); do curl -sk -o /dev/null -w '%{http_code} ' https://$H/db; sleep 3; done; echo
# 200 200 200 ... (un 503 isolato indica un'interruzione momentanea del Service)
```

**Perché funziona:** l'Operator crea per il cluster `sessioni` il Service `sessioni` (porta 11222) e il Secret `sessioni-generated-secret`; `sessioni.${LAB}-m13.svc` è il nome DNS del Service nel progetto (il nome completo è `sessioni.${LAB}-m13.svc.cluster.local`) e funziona anche da altri progetti. La password è copiata in un Secret tuo e arriva al container via `secretKeyRef`, mai in chiaro nel Deployment. Lo scaling passa dalla `spec.replicas` del CR: l'Operator aggiorna lo StatefulSet, il pod `sessioni-1` termina e il Service continua a inoltrare le connessioni a `sessioni-0`, quindi il controllo TCP di `/db` resta positivo.

> **Da verificare sul tuo cluster:** il comportamento dell'Operator Data Grid durante lo scale-down (rimozione ordinata del solo pod in eccesso o riavvio del cluster) dipende dalla versione: osservalo con `oc get pods -l clusterName=sessioni -w` e `oc get infinispan sessioni -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.message}{"\n"}{end}'`, e con il ciclo `curl` sopra. Se la password nel Secret dell'Operator venisse rigenerata, il Secret `sessioni-client` andrebbe riallineato (`/db` controlla solo la connessione TCP, quindi non se ne accorgerebbe).
</details>

### 4.3 Esercizio senza aiuti

Scegli un **altro** Operator applicativo installato sul tuo cluster (o il piano B). Usando solo `oc get csv`, `alm-examples`, `oc explain` e la console, crea un'istanza di una delle sue API nel progetto `${LAB}-m13`, individua la condizione di stato che indica "pronto", elenca le risorse figlie con il loro owner e dimostra che cancellando il CR spariscono.

---

## 5. Verifiche pratiche con `oc`

| Domanda | Comando |
|---|---|
| Quali Operator posso usare nel progetto? Sono pronti? | `oc get csv` (colonna PHASE = `Succeeded`) |
| Quali API fornisce un Operator? | `oc get csv <csv> -o jsonpath='{.spec.customresourcedefinitions.owned[*].kind}'` · `oc api-resources --api-group=<gruppo>` |
| Com'è fatto un CR valido? | `oc get csv <csv> -o jsonpath='{.metadata.annotations.alm-examples}' \| jq .` |
| Cosa significa un campo? È obbligatorio? | `oc explain <kind>.spec.<campo>` |
| Posso creare quel tipo di risorsa? | `oc auth can-i create <plurale>.<gruppo>` |
| L'istanza è pronta? Perché no? | `oc get <kind> <nome> -o jsonpath='{.status.conditions}'` · `oc describe <kind> <nome>` |
| Cosa ha creato l'Operator per me? | `oc get all,secret,cm,pvc -o custom-columns='KIND:.kind,NAME:.metadata.name,OWNER:.metadata.ownerReferences[*].kind'` |
| Come si collega l'app al servizio? | `oc get svc` (nome e porta) · `oc get secret <x> -o jsonpath='{.data}'` (chiavi) |
| Cosa è successo nel progetto? | `oc get events --sort-by=.lastTimestamp` |

---

## 6. Troubleshooting intenzionale

Lavora nel progetto `${LAB}-m13` con l'istanza `cache` del passo 3.5 attiva. Gli scenari 1, 2 e 4 usano l'API Data Grid; con un altro Operator riproducili cambiando `apiVersion`, un campo e la storage class nel CR del tuo Operator.

```bash
oc project ${LAB}-m13
cd $EX288_HOME/13-operator/troubleshooting
```

### Scenario 1 — "no matches for kind"

`oc apply -f rotto-1-api-sbagliata.yaml`

**Sintomo:** `error: resource mapping not found for name: "ts1-cache" ... no matches for kind "Infinispan" in version "infinispan.org/v2"` (o messaggio equivalente).

<details><summary>Indagine e soluzione</summary>

```bash
oc api-resources --api-group=infinispan.org -o wide     # colonna APIVERSION: infinispan.org/v1
oc get csv $CSV -o jsonpath='{.spec.customresourcedefinitions.owned[?(@.kind=="Infinispan")].version}{"\n"}'
oc get infinispanz                                       # -> error: the server doesn't have a resource type "infinispanz"
```
**Causa:** `apiVersion` errata: la CRD serve solo `v1`. Lo stesso tipo di errore (`no matches for kind` / `the server doesn't have a resource type`) compare quando l'Operator **non è installato** nel cluster: la CRD non esiste.
**Fix:** correggi `apiVersion: infinispan.org/v1` (copiala da `alm-examples`) e riapplica. Se la CRD non esiste, chiedi all'amministratore di installare l'Operator.
**Lezione:** `oc api-resources --api-group=<gruppo>` è il primo comando quando un CR non viene riconosciuto.

**Variante — Operator installato in un altro namespace (modalità *A specific namespace*).** Le CRD sono globali, quindi `oc api-resources` mostra l'API anche nel tuo progetto, ma: `oc get csv` nel tuo progetto non mostra l'Operator; `oc auth can-i create <plurale>.<gruppo>` risponde `no` e la creazione fallisce con *forbidden* (i permessi sulle API non sono aggregati al tuo ruolo); anche avendo i permessi, nessun controller osserva il tuo progetto e il CR resta **senza status**. Soluzione: l'admin reinstalla l'Operator in *All namespaces* (o include il tuo progetto nell'OperatorGroup).
</details>

### Scenario 2 — Validazione dello schema

`oc apply -f rotto-2-campo-errato.yaml`

**Sintomo:** `oc apply` fallisce con un messaggio del tipo `The Infinispan "ts2-cache" is invalid: spec.replicas: Invalid value: "string": spec.replicas in body must be of type integer: "string"`.

<details><summary>Indagine e soluzione</summary>

```bash
oc explain infinispan.spec.replicas        # FIELD: replicas <integer>
```
**Causa:** la CRD contiene uno schema OpenAPI: l'API server rifiuta il CR prima ancora che l'Operator lo veda. Qui `replicas` è una stringa (`"due"`).
**Fix:** `replicas: 2` e riapplica; poi `oc delete infinispan ts2-cache`.
**Lezione:** gli errori di schema arrivano subito da `oc apply` (anche i campi sconosciuti, ad esempio `spec.replica`, vengono segnalati come *unknown field*); usa `oc apply --dry-run=server -f <file>` per validare senza creare. Gli errori **semantici** (valori validi come tipo ma impossibili da realizzare) arrivano invece più tardi nello `status` (scenario 4).
</details>

### Scenario 3 — Il collega con ruolo `view`

`bash rompi-3-ruolo-view.sh`

**Sintomo:** lo script, che crea il CR impersonando il service account `sola-lettura`, termina con `Error from server (Forbidden): ... cannot create resource "infinispans" in API group "infinispan.org"`.

<details><summary>Indagine e soluzione</summary>

```bash
oc get rolebindings -o wide | grep sola-lettura                                   # ruolo view
oc auth can-i create infinispans.infinispan.org --as=system:serviceaccount:${LAB}-m13:sola-lettura   # no
oc auth can-i get infinispans.infinispan.org    --as=system:serviceaccount:${LAB}-m13:sola-lettura   # yes
```
**Causa:** il ruolo `view` permette di leggere le istanze ma non di crearle. Per gestire istanze di un Operator serve almeno `edit` sul progetto (documentazione OCP 4.22, *Creating applications from installed Operators*).
**Fix:** `oc policy add-role-to-user edit -z sola-lettura` e rilancia lo script (crea `ts3-cache`), poi `oc delete infinispan ts3-cache`.
**Lezione:** gli Operator installati *All namespaces* aggregano i permessi sulle loro API ai ruoli standard: `view` legge, `edit` crea/modifica/cancella.
</details>

### Scenario 4 — Il CR esiste ma non diventa mai pronto

`oc apply -f rotto-4-storageclass.yaml`

**Sintomo:** `oc get infinispan ts4-cache` esiste, ma la condizione `wellFormed` non diventa `True`; il pod `ts4-cache-0` resta `Pending`.

<details><summary>Indagine e soluzione</summary>

```bash
oc get infinispan ts4-cache -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.message}{"\n"}{end}'
oc get pods -l clusterName=ts4-cache
oc describe pod ts4-cache-0 | sed -n '/Events/,$p'     # pod has unbound immediate PersistentVolumeClaims
oc get pvc                                              # Pending
oc describe pvc | sed -n '/Events/,$p'                  # storageclass "classe-inesistente" not found
oc get storageclass
oc get events --sort-by=.lastTimestamp | tail
```
**Causa:** il CR è valido come schema, ma chiede una StorageClass inesistente: l'Operator crea StatefulSet e PVC, che non possono essere soddisfatti.
**Fix:** i campi di storage di un cluster Data Grid non sono pensati per essere cambiati dopo la creazione: cancella e ricrea l'istanza senza `storageClassName` (o con una classe esistente, o con `ephemeralStorage: true`).
**Lezione:** quando un CR non diventa pronto, leggi in quest'ordine: `status.conditions` del CR → risorse figlie (pod, PVC) → eventi del progetto. I log dell'Operator (`oc logs deployment/<operator> -n openshift-operators`) di solito **non** sono accessibili a un utente normale: chiedili all'admin solo se le informazioni sopra non bastano.
</details>

### Scenario 5 — "Ho scalato lo StatefulSet ma non cambia niente"

`bash rompi-5-modifica-figlia.sh` (default: `Infinispan` `cache`; con un altro Operator: `bash rompi-5-modifica-figlia.sh <Kind> <nome-cr>`)

**Sintomo:** lo script scala a 0 lo StatefulSet `cache`; per qualche secondo i pod terminano, poi ricompaiono.

<details><summary>Indagine e soluzione</summary>

```bash
oc get statefulset cache -o jsonpath='{.metadata.ownerReferences[*].kind}/{.metadata.ownerReferences[*].name}{"\n"}'   # Infinispan/cache
oc get infinispan cache -o jsonpath='{.spec.replicas}{"\n"}'          # il desiderato è ancora nel CR
oc get events --sort-by=.lastTimestamp | grep -i -E 'scal|cache' | tail
```
**Causa:** lo StatefulSet appartiene al CR: l'Operator riconcilia e riporta le repliche al valore di `spec.replicas`.
**Fix:** per cambiare le repliche modifica il CR (`oc patch infinispan cache --type=merge -p '{"spec":{"replicas":N}}'`). Per fermare un cluster Data Grid la documentazione indica proprio `spec.replicas: 0` nel CR.
**Lezione:** se una modifica "non prende" o viene annullata, controlla `ownerReferences`: stai modificando una risorsa gestita da un Operator.
</details>

Pulizia: `oc delete infinispan -l 'scenario in (m13-1,m13-2,m13-4)'`, `oc delete sa sola-lettura`. A fine modulo: `oc delete project ${LAB}-m13`.

---

## 7. Esercizio finale (stile EX288)

> Lavora come all'esame: niente soluzioni, solo documentazione ufficiale, console, `oc --help` e `oc explain`. Tempo indicativo: **40 minuti**.

L'esercizio è scritto per l'esempio Data Grid (API `Infinispan`). Se usi un altro Operator, sostituisci il kind, i nomi, il campo delle repliche, la condizione di "pronto", il Service e la porta, e imposta le variabili descritte sotto prima di lanciare la verifica.

**Requisiti**

1. Esiste il progetto `${LAB}-m13-exam`.
2. Nel progetto esiste un'istanza della API `Infinispan` (fornita dall'Operator Data Grid installato) chiamata **`exam-cache`**, con:
   - la label `app.kubernetes.io/part-of=negozio`;
   - **2** repliche richieste;
   - storage effimero.
3. L'istanza è pronta: la condizione `wellFormed` è `True` e il Service creato dall'Operator ha **2** endpoint.
4. Le risorse create dall'Operator per l'istanza (almeno lo StatefulSet) hanno come proprietario l'istanza `exam-cache`.
5. Esiste un Secret **`negozio-db`** che contiene la chiave `DB_PASSWORD` con la password dell'utente applicativo `developer` generata dall'Operator.
6. Nel progetto gira l'applicazione **`negozio`** (codice `hello-node` del repository `$GIT_REPO`), 1 replica pronta, configurata con:
   - `DB_HOST` = nome del Service creato dall'Operator per l'istanza;
   - `DB_PORT` = porta di quel Service (11222);
   - `DB_USER` = `developer`;
   - `DB_PASSWORD` letta dal Secret `negozio-db` (non scritta in chiaro nel Deployment).
7. `negozio` è raggiungibile dall'esterno via HTTPS dalla route **`negozio`** con terminazione edge.

**Risultato atteso**

- `curl -sk https://<host-route-negozio>/db` risponde **200** con `"db": "raggiungibile"`.
- Cancellando (in un secondo momento, dopo la verifica) l'istanza `exam-cache`, lo StatefulSet sparisce.

```bash
bash $EX288_HOME/13-operator/verifica.sh
```

**Verifica con un Operator diverso.** Lo script legge queste variabili (default fra parentesi):

| Variabile | Significato | Default |
|---|---|---|
| `OPERATOR_KIND` | Kind del CR | `Infinispan` |
| `OPERATOR_RESOURCE` | Nome della risorsa per `oc get` (utile se il kind è ambiguo) | `infinispans.infinispan.org` se il kind è `Infinispan`, altrimenti `$OPERATOR_KIND` |
| `OPERATOR_CR` | Nome dell'istanza | `exam-cache` |
| `OPERATOR_READY_CONDITION` | Tipo di condizione che indica "pronto" | `wellFormed` |
| `OPERATOR_SIZE_PATH` | JSONPath del campo repliche (vuoto = non controllare) | `{.spec.replicas}` |
| `OPERATOR_SIZE` | Repliche attese | `2` |
| `OPERATOR_SERVICE` | Service a cui si collega l'app | `$OPERATOR_CR` |
| `OPERATOR_PORT` | Porta del Service | `11222` |

Esempio: `OPERATOR_KIND=Kafka OPERATOR_CR=ordini OPERATOR_READY_CONDITION=Ready OPERATOR_SIZE_PATH= OPERATOR_SERVICE=ordini-kafka-bootstrap OPERATOR_PORT=9092 bash $EX288_HOME/13-operator/verifica.sh`

---

## 8. Riferimenti ufficiali (OCP 4.22 / Red Hat Data Grid 8.5)

- Operators → *User tasks* → *Creating applications from installed Operators*: https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/operators/user-tasks
- Operators → *Understanding Operators* (OLM, CSV, OperatorGroup, install modes): https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/operators/understanding-operators
- Data Grid Operator Guide → *Installing Data Grid Operator*: https://docs.redhat.com/en/documentation/red_hat_data_grid/8.5/html/data_grid_operator_guide/installation
- Data Grid Operator Guide → *Creating Data Grid clusters* (CR `Infinispan`, `oc wait --for condition=wellFormed`): https://docs.redhat.com/en/documentation/red_hat_data_grid/8.5/html/data_grid_operator_guide/creating-clusters
- Data Grid Operator Guide → *Setting up Data Grid services* (storage effimero, campi del CR): https://docs.redhat.com/en/documentation/red_hat_data_grid/8.5/html/data_grid_operator_guide/creating-services
- Data Grid Operator Guide → *Configuring authentication* (`<cluster>-generated-secret`): https://docs.redhat.com/en/documentation/red_hat_data_grid/8.5/html/data_grid_operator_guide/configuring-authentication
- Data Grid Operator Guide → *Configuring network access* (Service `<cluster>` porta 11222): https://docs.redhat.com/en/documentation/red_hat_data_grid/8.5/html/data_grid_operator_guide/creating-network
- Data Grid Operator Guide → *Data Grid Operator* (riconciliazione delle risorse): https://docs.redhat.com/en/documentation/red_hat_data_grid/8.5/html/data_grid_operator_guide/operator
