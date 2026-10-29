# Modulo 09 — Template OpenShift: creare, usare e parametrizzare applicazioni multi-container

> **Obiettivi EX288 coperti**
> - *Work with templates* → Create an OpenShift template
> - *Work with templates* → Use pre-existing templates written in either JSON or YAML format
> - *Work with templates* → Work with multi-container templates
> - *Work with templates* → Add custom parameters to a template
>
> **Durata stimata:** 4 ore · **Prerequisiti:** moduli 01-08 (in particolare 04 image stream, 05 build, 07 ConfigMap/Secret) · **Richiede cluster-admin:** no
>
> **Progetti usati:** `${LAB}-m09`, `${LAB}-m09-exam`

---

## 1. Perché e quando

Un **Template** (`template.openshift.io/v1`) è un oggetto OpenShift che contiene un elenco di oggetti (Deployment, Service, Route, Secret, BuildConfig...) con dei **segnaposto** `${PARAMETRO}`. *Processare* il template significa sostituire i parametri e ottenere una lista di oggetti pronti da creare. È il meccanismo più vecchio e più semplice dei tre che vedrai nei moduli 09-11, ed è **solo OpenShift**.

**Template, Helm o Kustomize?** (questa tabella torna nei moduli 10 e 11)

| Criterio | Template OpenShift (modulo 09) | Helm (modulo 10) | Kustomize (modulo 11) |
|---|---|---|---|
| Dove funziona | Solo OpenShift (API `template.openshift.io`) | Qualsiasi Kubernetes; può includere oggetti OpenShift | Qualsiasi Kubernetes; integrato in `oc` (`oc apply -k`) |
| Come personalizzi | Parametri `${X}`: sostituzione di stringhe | Valori + linguaggio di template Go (`if`, `range`, funzioni) | Overlay e patch su YAML puro, nessuna variabile |
| Logica condizionale (es. "route solo se...") | No | Sì | No (si ottiene con overlay/componenti diversi) |
| Valori generati (password casuali) | Sì, `generate: expression` | Sì (funzioni), ma rigenerati a ogni upgrade se non gestiti | No (i Secret si generano da file o letterali) |
| Ciclo di vita | Nessuno: crea gli oggetti e li "dimentica" | **Release** con revisioni: upgrade, rollback, uninstall | Nessuno: `oc apply -k` dichiarativo, `oc delete -k` |
| Distribuzione | Oggetto Template nel progetto o nel namespace `openshift` | Repository di chart (HTTP/OCI), catalogo della console | Directory in Git (base riutilizzabili) |
| Scegli quando... | Vuoi un "modulo da compilare" per un'app OpenShift, con pochi parametri | Vuoi un pacchetto versionato con upgrade/rollback, anche fuori da OpenShift | Hai la stessa app in più ambienti (dev/prod) che differiscono di poco |

**Usa un template quando:** ti serve un catalogo self-service semplice (chi lo usa compila 3-4 parametri, anche dalla console), l'app è solo OpenShift (BuildConfig, ImageStream, Route), vuoi generare password al volo.
**Non usarlo quando:** servono condizioni o cicli (es. "crea la PVC solo in produzione"), devi aggiornare e fare rollback dell'insieme degli oggetti come un'unica unità, o i manifest devono girare anche su Kubernetes non OpenShift.

> **Nota di versione:** i template di esempio nel namespace `openshift` (es. `postgresql-ephemeral`) li fornisce il **Cluster Samples Operator**, deprecato in 4.20-4.22. Sul tuo cluster potrebbero non esserci: per questo il modulo usa template forniti in `lab/`. La funzionalità Template in sé **non** è deprecata.

---

## 2. Concetti essenziali

### 2.1 Anatomia di un template

```yaml
apiVersion: template.openshift.io/v1
kind: Template
metadata:
  name: hello-full                       # nome con cui lo usi: oc process hello-full / oc new-app --template=hello-full
  annotations:
    openshift.io/display-name: "Hello Node + PostgreSQL"   # nome mostrato nel catalogo della console
    description: "..."                    # descrizione nel catalogo
    tags: "nodejs,postgresql"             # parole chiave per la ricerca nel catalogo
    iconClass: icon-nodejs
message: "Creata ${APP_NAME}, password ${DB_PASSWORD}"   # stampato da oc new-app dopo la creazione
labels:                                   # aggiunte a TUTTI gli oggetti generati
  template: hello-full
parameters:
- name: APP_NAME                          # nome usato nei segnaposto ${APP_NAME}
  displayName: Nome applicazione          # etichetta nel form della console
  description: Nome di tutti gli oggetti
  value: hello                            # valore di default (SEMPRE una stringa)
  required: true                          # errore se alla fine resta vuoto
- name: DB_PASSWORD
  generate: expression                    # valore generato se non lo passi...
  from: "[a-zA-Z0-9]{16}"                 # ...secondo questa espressione (16 alfanumerici)
objects:                                  # gli oggetti, con i segnaposto
- apiVersion: v1
  kind: Secret
  metadata:
    name: ${APP_NAME}-db                  # ${X} può stare dentro una stringa più lunga
  stringData:
    database-password: ${DB_PASSWORD}
```

### 2.2 `${PARAM}` e `${{PARAM}}`

| Sintassi | Risultato | Uso tipico |
|---|---|---|
| `${REPLICAS}` | Sempre una **stringa** (anche concatenata: `${APP_NAME}-db`) | Nomi, messaggi, immagini, label |
| `${{REPLICAS}}` | Il valore viene interpretato come JSON: **numero, booleano, oggetto** | `replicas: ${{REPLICAS}}`, `port: ${{PORT}}`, campi booleani |

Regole: `${{X}}` deve essere l'**intero** valore del campo (niente prefissi o suffissi); il `value` di default di un parametro è sempre una stringa (`value: "2"`, non `value: 2`). In JSON scrivi `"replicas": "${{REPLICAS}}"` (le virgolette sono obbligatorie in JSON: la sostituzione rimpiazza tutta la stringa con il numero).

### 2.3 Dove vive un template e chi lo processa

| Modalità | Comando | Note |
|---|---|---|
| File locale, processato dal server | `oc process -f t.yaml -p A=b \| oc create -f -` | Il comando più usato |
| File locale, processato in locale (anteprima) | `oc process -f t.yaml --local -o yaml` | Non contatta l'API: utile per controllare l'output |
| Template salvato nel progetto | `oc create -f t.yaml` poi `oc process hello-full ...` o `oc new-app --template=hello-full -p ...` | Compare anche nel catalogo della console del progetto |
| Template condiviso del cluster | `oc get templates -n openshift`, `oc process --parameters -n openshift <nome>` | Se il Samples Operator è presente |

> **Abitudine da esame:** prima di istanziare un template sconosciuto esegui sempre `oc process --parameters` (quali parametri, quali obbligatori, quali generati) e un'anteprima con `--local -o yaml`.

### 2.4 Cosa NON fa un template

- Nessuna logica (`if`, cicli): ogni oggetto in `objects` viene sempre creato.
- Nessun "aggiornamento": riprocessare con `oc create` fallisce su oggetti esistenti (`AlreadyExists`); con `oc apply` li aggiorna, ma i valori **generati** cambiano a ogni processo.
- Nessuna traccia di "istanza": per ritrovare e cancellare gli oggetti usi le **label** (sezione `labels` o `-l`).
- Un `namespace` **fisso** dentro un oggetto viene rimosso durante l'istanziazione; un namespace **parametrico** (`namespace: ${NS}`) viene invece sostituito e rispettato.

---

## 3. Laboratorio guidato

```bash
source env.sh                 # dalla root del repository ex288-teach
T=$EX288_HOME/09-template/lab          # cartella con i template del modulo
mkdir -p $EX288_WORK/m09                         # cartella di lavoro per le TUE copie modificate
```

### 3.1 Progetto e immagine dell'applicazione

Il template JSON (passo 3.3) esegue un'immagine **già costruita**: la creiamo una volta nel registry interno, così il lab non dipende dalle build. Il template YAML (passo 3.5) invece contiene esso stesso ImageStream e BuildConfig.

```bash
oc new-project ${LAB}-m09 --display-name="EX288 m09 - template"

# Builder S2I locale (il Samples Operator potrebbe non esserci: vedi modulo 00)
oc import-image nodejs:22-ubi9 --from=registry.access.redhat.com/ubi9/nodejs-22 --confirm

# Solo build (nessun Deployment): produce l'image stream hello-node:latest
oc new-build "nodejs:22-ubi9~$GIT_REPO" --context-dir=hello-node --name=hello-node
oc logs -f bc/hello-node                # attendi "Push successful"
oc get istag hello-node:latest

# Riferimento completo all'immagine nel registry interno: lo passeremo come parametro
APP_IMAGE=image-registry.openshift-image-registry.svc:5000/${LAB}-m09/hello-node:latest
```

### 3.2 Template forniti dal cluster (se ci sono)

```bash
oc get templates -n openshift                    # "No resources found" = Samples Operator assente/rimosso
# Se l'elenco non è vuoto, esplora un template come faresti all'esame:
oc describe template postgresql-ephemeral -n openshift | head -40
oc process --parameters -n openshift postgresql-ephemeral
```

Colonne di `oc process --parameters`: `NAME`, `DESCRIPTION`, `GENERATOR` (es. `expression` = valore generato) e `VALUE` (default). I parametri senza valore e senza generatore che sono `required` vanno passati per forza.

### 3.3 Usare un template pre-esistente in JSON (multi-container)

`lab/hello-db-template.json` crea: Secret con password generata, ConfigMap montata in `/etc/app`, Deployment + Service + Route edge per hello-node, Deployment + Service per PostgreSQL. Aprilo e individua `parameters`, `objects`, `labels`, `"replicas": "${{REPLICAS}}"`.

```bash
# 1) Quali parametri accetta?
oc process --parameters -f $T/hello-db-template.json
# NAME           DESCRIPTION                                    GENERATOR    VALUE
# APP_NAME       Nome di tutti gli oggetti; ...                              hello
# APP_IMAGE      Riferimento completo all'immagine, ...
# ...
# DB_PASSWORD    Generata se non specificata                     expression   [a-zA-Z0-9]{16}

# 2) Anteprima in locale: nessun oggetto creato. Controlla nomi, repliche, password generata
oc process -f $T/hello-db-template.json --local -o yaml \
  -p APP_NAME=demo -p APP_IMAGE=$APP_IMAGE | less

# 3) Istanziazione: il server processa il template, oc create crea gli oggetti
oc process -f $T/hello-db-template.json -p APP_NAME=demo -p APP_IMAGE=$APP_IMAGE \
  | oc create -f -
# secret/demo-db created, configmap/demo-config created, deployment.apps/demo-db created, ...

oc get deploy,svc,route,cm,secret -l template=hello-db     # tutti gli oggetti hanno la label del template
oc rollout status deployment/demo-db
oc rollout status deployment/demo

H=$(oc get route demo -o jsonpath='{.spec.host}')
curl -s https://$H/        ; echo   # "message": "Ciao da un template JSON!"
curl -s https://$H/config         # app.name=demo ...
curl -s https://$H/db             # "db": "raggiungibile", "name": "hellodb"
```

> La documentazione usa `oc process ... | oc create -f -`. Con `oc apply -f -` ottieni lo stesso risultato e puoi riapplicare, ma attenzione: ogni nuovo processo **rigenera** `DB_PASSWORD` e aggiornerebbe il Secret.

### 3.4 Parametri da file e label aggiuntive

```bash
cat $T/demo2.env                         # NOME=valore, una riga per parametro

# --param-file per i parametri "fissi", -p per quelli che dipendono dal tuo ambiente,
# -l per aggiungere una label a tutti gli oggetti (oltre a quelle del template)
oc process -f $T/hello-db-template.json --param-file=$T/demo2.env \
  -p APP_IMAGE=$APP_IMAGE -l ambiente=test | oc create -f -

oc get deploy -l ambiente=test           # demo2 e demo2-db
oc get deploy demo2 -o jsonpath='{.spec.replicas}{"\n"}'   # 2 (numero, grazie a ${{REPLICAS}})
```

### 3.5 Template YAML con build incluse, salvato nel progetto

`lab/hello-full-template.yaml` dimostra che un template può contenere **oggetti OpenShift**: ImageStream (con `lookupPolicy.local: true`), BuildConfig S2I con trigger `ConfigChange` (la build parte appena creata) e un Deployment con l'annotazione `image.openshift.io/triggers` (modulo 04) che si aggiorna quando la build pubblica `${APP_NAME}:latest`.

```bash
# Salva il template come oggetto del progetto (non crea ancora nulla dell'app)
oc create -f $T/hello-full-template.yaml
oc get templates                                   # hello-full
oc process --parameters hello-full                 # senza -f: usa il template salvato

# Istanzia con oc new-app: stampa anche il campo "message" del template
oc new-app --template=hello-full -p APP_NAME=shop -p GIT_URI=$GIT_REPO -p REPLICAS=2
#   Applicazione shop creata. La prima build parte subito: oc logs -f bc/shop
#   Database hellodb, utente hello, password generata: Xy7...

oc logs -f bc/shop                 # build S2I
oc get pods -l deployment=shop -w  # prima ErrImagePull (immagine non ancora costruita), poi Running
oc get deploy shop -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
# image-registry.openshift-image-registry.svc:5000/<progetto>/shop@sha256:...  <- scritto dal trigger
curl -s https://$(oc get route shop -o jsonpath='{.spec.host}')/db
```

Dalla console: menu **+** (o *+Add* se hai la prospettiva Developer) → *Developer Catalog* / *Software Catalog* → filtra per tipo *Template* → **Hello Node + PostgreSQL (build da Git)**: compare un form con i `displayName` dei parametri. Compilalo con `APP_NAME=shop2` e confronta il risultato con la CLI.

> **Da verificare sul tuo cluster:** il nome esatto della voce di catalogo cambia con la versione della console (in 4.22 la navigazione usa *Ecosystem > Software Catalog*). I template del progetto compaiono nel catalogo solo se il tipo *Template* è abilitato dall'amministratore.

### 3.6 Creare un template partendo da risorse esistenti

Non esiste più `oc export`: si parte da `oc get -o yaml` e si **ripulisce** l'output.

```bash
# Esporta gli oggetti dell'istanza "demo" (passo 3.3) in un'unica lista
oc get deploy,svc,route,cm,secret -l template=hello-db,app=demo -o yaml > $EX288_WORK/m09/da-risorse.yaml
grep -n '^kind\|^items\|^- apiVersion' $EX288_WORK/m09/da-risorse.yaml | head   # kind: List / items:
```

Trasformalo in template con un editor (`vi $EX288_WORK/m09/da-risorse.yaml`):

| Cosa | Perché |
|---|---|
| `apiVersion: v1` + `kind: List` → `apiVersion: template.openshift.io/v1` + `kind: Template` | È un Template, non una lista |
| `items:` → `objects:` e aggiungi `metadata.name` del template | Struttura del Template |
| Elimina `status`, `metadata.uid`, `resourceVersion`, `creationTimestamp`, `generation`, `managedFields`, `namespace` | Campi gestiti dal cluster: se restano, la creazione fallisce o finisce nel progetto sbagliato |
| Elimina annotazioni come `deployment.kubernetes.io/revision` e `kubectl.kubernetes.io/last-applied-configuration` | Stato di un oggetto specifico |
| Service: elimina `spec.clusterIP`, `spec.clusterIPs` | Sono assegnati dal cluster: riusarli provoca conflitti |
| Route: elimina `spec.host` (e `status.ingress`) | Altrimenti due istanze chiedono lo stesso hostname |
| Secret: sostituisci `data` con `stringData` e un parametro generato | Una password scritta nel template sarebbe uguale per tutti |
| Sostituisci i nomi (`demo`) con `${APP_NAME}` e aggiungi la sezione `parameters` | Rende il template riutilizzabile |

Valida il risultato a ogni modifica:

```bash
oc process -f $EX288_WORK/m09/da-risorse.yaml --local -o yaml -p APP_NAME=prova | head -50
```

> **Alternativa più pulita:** genera gli oggetti con `--dry-run=client -o yaml` (es. `oc create deployment x --image=... --dry-run=client -o yaml`, `oc create secret generic ... --dry-run=client -o yaml`) e incollali sotto `objects:`. Nessun campo di stato da togliere.

### 3.7 Aggiungere parametri custom

Aggiungiamo al template JSON un parametro `MEMORY_LIMIT` e usiamolo nel container dell'app.

```bash
cp $T/hello-db-template.json $EX288_WORK/m09/hello-db-mem.json
vi $EX288_WORK/m09/hello-db-mem.json
```

1. In `parameters` aggiungi `{ "name": "MEMORY_LIMIT", "displayName": "Limite di memoria", "value": "256Mi" }` (attenzione alle virgole JSON).
2. Nel container `hello-node` aggiungi `"resources": { "limits": { "memory": "${MEMORY_LIMIT}" } }`.

```bash
python3 -m json.tool $EX288_WORK/m09/hello-db-mem.json > /dev/null && echo "JSON valido"   # se hai python3; altrimenti usa il passo seguente
oc process -f $EX288_WORK/m09/hello-db-mem.json --local -o yaml -p APP_IMAGE=x -p MEMORY_LIMIT=384Mi | grep -A2 limits
```

### 3.8 Pulizia (selettiva, grazie alle label)

```bash
oc delete deploy,svc,route,cm,secret -l template=hello-db        # istanze demo e demo2
oc delete deploy,svc,route,cm,secret,bc,is -l template=hello-full  # istanza shop (le build seguono la bc)
oc get templates                                                 # il template salvato resta: è un oggetto a sé
```

---

## 4. Esercizi

### 4.1 Esercizio guidato — completare un template con parametri custom

Copia `lab/esercizio-incompleto.yaml` in `$EX288_WORK/m09/hello-custom.yaml` e completalo:

1. dichiara i parametri `APP_MESSAGE` (default `Ciao dal template personalizzato`), `REPLICAS` (default 2), `MEMORY_LIMIT` (default `256Mi`), `DB_VOLUME_CAPACITY` (default `1Gi`, obbligatorio);
2. correggi il campo `replicas` del Deployment dell'app (TODO 5);
3. salva il template nel progetto `${LAB}-m09` e istanzialo con `APP_NAME=custom`, `REPLICAS=3`, il tuo `APP_IMAGE`;
4. verifica che il PVC `custom-db` sia `Bound` e che `/db` risponda `raggiungibile`.

<details><summary>Suggerimenti</summary>

- I parametri si aggiungono come elementi della lista `parameters` (stessi campi degli altri: `name`, `displayName`, `value`, `required`).
- `value` è sempre una stringa: `value: "2"`.
- `replicas` deve ricevere un numero: serve la sintassi a doppia graffa.
- Il PVC richiede una StorageClass di default: `oc get storageclass`.
</details>

<details><summary>Soluzione</summary>

```yaml
# in parameters:
- name: APP_MESSAGE
  displayName: Messaggio
  value: Ciao dal template personalizzato
- name: REPLICAS
  displayName: Repliche
  value: "2"
- name: MEMORY_LIMIT
  displayName: Limite di memoria dell'app
  value: 256Mi
- name: DB_VOLUME_CAPACITY
  displayName: Dimensione del volume del database
  value: 1Gi
  required: true
# nel Deployment dell'app:
    replicas: ${{REPLICAS}}
```

```bash
oc create -f $EX288_WORK/m09/hello-custom.yaml -n ${LAB}-m09
oc new-app --template=hello-custom -p APP_NAME=custom -p REPLICAS=3 -p APP_IMAGE=$APP_IMAGE
oc get pvc custom-db                       # STATUS Bound
oc get deploy custom                       # 3/3
curl -s https://$(oc get route custom -o jsonpath='{.spec.host}')/db
```
Se `oc create` del template fallisce perché esiste già: `oc replace -f $EX288_WORK/m09/hello-custom.yaml` (o `oc delete template hello-custom` e ricrealo).
</details>

### 4.2 Esercizio semi-guidato — template da risorse esistenti

Completa la trasformazione del passo 3.6 in un template `demo-clone` con parametri `APP_NAME` (obbligatorio), `APP_MESSAGE` e `DB_PASSWORD` generata (20 caratteri). Istanzialo con `APP_NAME=clone` nello stesso progetto senza conflitti con `demo`.

<details><summary>Suggerimenti</summary>

- Cerca tutti i punti in cui compare `demo`: nomi, selector, label, riferimenti al Secret e alla ConfigMap, `DB_HOST`, la Route (`spec.to.name`).
- Se `oc create` risponde `AlreadyExists` o `field is immutable`, hai lasciato un nome o un campo di stato.
- `oc process --local -o yaml | grep -n demo` deve restituire zero righe.
</details>

<details><summary>Soluzione (aprila solo dopo aver provato)</summary>

```bash
oc project ${LAB}-m09

# 0) Export dell'istanza demo (passo 3.6) e copia di lavoro
oc get deploy,svc,route,cm,secret -l template=hello-db,app=demo -o yaml > $EX288_WORK/m09/da-risorse.yaml
cp $EX288_WORK/m09/da-risorse.yaml $EX288_WORK/m09/demo-clone.yaml

# 1) Sostituzioni meccaniche (sed di macOS: -i.bak lascia il backup demo-clone.yaml.bak)
#    - ogni "demo" diventa ${APP_NAME}: nomi, label, selector, secretKeyRef, volume ConfigMap,
#      DB_HOST, spec.to.name della Route, app.properties
#    - il messaggio diventa ${APP_MESSAGE}
#    - via le righe di stato a riga singola e la label del template di origine
sed -i.bak \
  -e 's/demo/${APP_NAME}/g' \
  -e 's/Ciao da un template JSON!/${APP_MESSAGE}/' \
  -e '/^ *template: hello-db$/d' \
  -e '/^ *uid:/d' -e '/^ *resourceVersion:/d' -e '/^ *creationTimestamp:/d' \
  -e '/^ *generation:/d' -e '/^ *namespace:/d' \
  -e '/^ *clusterIP:/d' -e '/^ *host:/d' \
  $EX288_WORK/m09/demo-clone.yaml

# 2) A mano (vi $EX288_WORK/m09/demo-clone.yaml), i blocchi su più righe:
#    - in fondo al file elimina "kind: List" e "metadata:"; in cima sostituisci "apiVersion: v1"
#      con intestazione e parametri (vedi il file finale sotto); "items:" diventa "objects:"
#    - elimina ogni blocco "status:" (Deployment, Service, Route con status.ingress)
#    - elimina i blocchi "annotations:" (deployment.kubernetes.io/revision, openshift.io/host.generated)
#      e "managedFields:" se presente
#    - Service: elimina "clusterIPs:" e la riga con l'IP sotto
#    - Secret: sostituisci "data:" (valori base64) con "stringData:" e ${DB_PASSWORD}
grep -nE 'status:|clusterIP|annotations:|managedFields|kind: List|^ *data:' $EX288_WORK/m09/demo-clone.yaml
# deve restare solo il "data:" della ConfigMap

# 3) Validazione locale
oc process --parameters -f $EX288_WORK/m09/demo-clone.yaml
# NAME          DESCRIPTION                       GENERATOR    VALUE
# APP_NAME      Nome di tutti gli oggetti; ...
# APP_MESSAGE                                                  Ciao da un template JSON!
# DB_PASSWORD                                     expression   [a-zA-Z0-9]{20}
oc process --local -f $EX288_WORK/m09/demo-clone.yaml -p APP_NAME=clone -o yaml | grep -n demo     # nessuna riga
oc process --local -f $EX288_WORK/m09/demo-clone.yaml -p APP_NAME=clone -o yaml | grep -n '\${'    # nessun segnaposto rimasto
oc process --local -f $EX288_WORK/m09/demo-clone.yaml -o yaml > /dev/null    # errore: APP_NAME è obbligatorio

# 4) Template salvato nel progetto e istanza "clone"
oc create -f $EX288_WORK/m09/demo-clone.yaml              # template.template.openshift.io/demo-clone created
oc process demo-clone -p APP_NAME=clone | oc create -f -
# deployment.apps/clone created, deployment.apps/clone-db created, service/clone created,
# service/clone-db created, route.route.openshift.io/clone created, configmap/clone-config created,
# secret/clone-db created
#   (equivalente: oc new-app --template=demo-clone -p APP_NAME=clone)

# 5) Verifiche: clone funziona e demo è intatta
oc get deploy,svc,route,cm,secret -l app=clone
oc rollout status deployment/clone-db && oc rollout status deployment/clone
H=$(oc get route clone -o jsonpath='{.spec.host}')
curl -s https://$H/ ; echo                      # "message": "Ciao da un template JSON!"
curl -s https://$H/config                       # app.name=clone, db.host=clone-db
curl -s https://$H/db                           # "db": "raggiungibile", "host": "clone-db"
oc get secret clone-db -o jsonpath='{.data.database-password}' | base64 -d | wc -c   # 20
oc get deploy demo clone                        # entrambi READY 1/1
```

Il template finale (`$EX288_WORK/m09/demo-clone.yaml`). L'ordine delle chiavi non conta: `oc get` le stampa in ordine alfabetico; qui sono riordinate e sono omessi i campi con valore di default che `oc get` aggiunge (`imagePullPolicy`, `terminationMessagePath`, `dnsPolicy`, `restartPolicy`, `protocol`, `sessionAffinity`, `ipFamilies`, `weight`, `wildcardPolicy`...): puoi lasciarli, sono innocui.

```yaml
apiVersion: template.openshift.io/v1
kind: Template
metadata:
  name: demo-clone
  annotations:
    openshift.io/display-name: "Clone di demo (hello-node + PostgreSQL)"
    description: Ricavato dalle risorse dell'istanza demo (modulo 09, passo 3.6)
parameters:
- name: APP_NAME
  displayName: Nome applicazione
  description: Nome di tutti gli oggetti; il database usa il suffisso -db
  required: true
- name: APP_MESSAGE
  displayName: Messaggio dell'applicazione
  value: "Ciao da un template JSON!"
- name: DB_PASSWORD
  displayName: Password del database
  generate: expression
  from: "[a-zA-Z0-9]{20}"
objects:
- apiVersion: apps/v1
  kind: Deployment
  metadata:
    name: ${APP_NAME}
    labels:
      app: ${APP_NAME}
      app.kubernetes.io/component: frontend
  spec:
    replicas: 1
    selector:
      matchLabels:
        deployment: ${APP_NAME}
    template:
      metadata:
        labels:
          app: ${APP_NAME}
          deployment: ${APP_NAME}
      spec:
        containers:
        - name: hello-node
          # immagine già costruita: resta il valore esportato (con il TUO progetto al posto di cambiami-m09)
          image: image-registry.openshift-image-registry.svc:5000/cambiami-m09/hello-node:latest
          ports:
          - name: http
            containerPort: 8080
          env:
          - name: APP_MESSAGE
            value: ${APP_MESSAGE}
          - name: DB_HOST
            value: ${APP_NAME}-db
          - name: DB_PORT
            value: "5432"
          - name: DB_NAME
            valueFrom:
              secretKeyRef:
                name: ${APP_NAME}-db
                key: database-name
          - name: DB_USER
            valueFrom:
              secretKeyRef:
                name: ${APP_NAME}-db
                key: database-user
          - name: DB_PASSWORD
            valueFrom:
              secretKeyRef:
                name: ${APP_NAME}-db
                key: database-password
          readinessProbe:
            httpGet:
              path: /ready
              port: 8080
            periodSeconds: 5
          livenessProbe:
            httpGet:
              path: /healthz
              port: 8080
            initialDelaySeconds: 10
          volumeMounts:
          - name: config
            mountPath: /etc/app
            readOnly: true
        volumes:
        - name: config
          configMap:
            name: ${APP_NAME}-config
- apiVersion: apps/v1
  kind: Deployment
  metadata:
    name: ${APP_NAME}-db
    labels:
      app: ${APP_NAME}
      app.kubernetes.io/component: database
  spec:
    replicas: 1
    strategy:
      type: Recreate
    selector:
      matchLabels:
        deployment: ${APP_NAME}-db
    template:
      metadata:
        labels:
          app: ${APP_NAME}
          deployment: ${APP_NAME}-db
      spec:
        containers:
        - name: postgresql
          image: registry.redhat.io/rhel9/postgresql-16
          ports:
          - name: postgresql
            containerPort: 5432
          env:
          - name: POSTGRESQL_DATABASE
            valueFrom:
              secretKeyRef:
                name: ${APP_NAME}-db
                key: database-name
          - name: POSTGRESQL_USER
            valueFrom:
              secretKeyRef:
                name: ${APP_NAME}-db
                key: database-user
          - name: POSTGRESQL_PASSWORD
            valueFrom:
              secretKeyRef:
                name: ${APP_NAME}-db
                key: database-password
          readinessProbe:
            tcpSocket:
              port: 5432
            initialDelaySeconds: 5
          volumeMounts:
          - name: data
            mountPath: /var/lib/pgsql/data
        volumes:
        - name: data
          emptyDir: {}
- apiVersion: v1
  kind: Service
  metadata:
    name: ${APP_NAME}
    labels:
      app: ${APP_NAME}
  spec:
    type: ClusterIP                 # niente clusterIP/clusterIPs: li assegna il cluster
    selector:
      deployment: ${APP_NAME}
    ports:
    - name: http
      port: 8080
      targetPort: 8080
- apiVersion: v1
  kind: Service
  metadata:
    name: ${APP_NAME}-db
    labels:
      app: ${APP_NAME}
  spec:
    type: ClusterIP
    selector:
      deployment: ${APP_NAME}-db
    ports:
    - name: postgresql
      port: 5432
      targetPort: 5432
- apiVersion: route.openshift.io/v1
  kind: Route
  metadata:
    name: ${APP_NAME}
    labels:
      app: ${APP_NAME}
  spec:                             # niente spec.host: lo genera il router per ogni istanza
    to:
      kind: Service
      name: ${APP_NAME}
    port:
      targetPort: http
    tls:
      termination: edge
      insecureEdgeTerminationPolicy: Redirect
- apiVersion: v1
  kind: ConfigMap
  metadata:
    name: ${APP_NAME}-config
    labels:
      app: ${APP_NAME}
  data:
    app.properties: |
      app.name=${APP_NAME}
      db.host=${APP_NAME}-db
      origine=template hello-db (JSON)
- apiVersion: v1
  kind: Secret
  metadata:
    name: ${APP_NAME}-db
    labels:
      app: ${APP_NAME}
  type: Opaque
  stringData:                       # al posto di data: (base64 della password esportata)
    database-name: hellodb
    database-user: hello
    database-password: ${DB_PASSWORD}
```

**Perché `sed` + editing manuale:** la sostituzione di `demo` è meccanica e va fatta **ovunque** (un solo riferimento dimenticato, ad esempio il `secretKeyRef` o lo `spec.to.name` della Route, collega `clone` agli oggetti di `demo`); va fatta **prima** di scrivere `name: demo-clone` nell'intestazione, altrimenti `sed` trasformerebbe anche quello. I blocchi su più righe (`status`, `annotations`, `clusterIPs`, `data`) invece si tolgono meglio a mano: con `sed` di macOS è facile cancellare troppo.

**Perché togliere quei campi:** `uid`, `resourceVersion`, `creationTimestamp`, `status` e le annotazioni di revisione descrivono l'oggetto **esistente**; `clusterIP`/`clusterIPs` farebbero chiedere a `clone` lo stesso IP di `demo` (errore di IP già allocato); `spec.host` farebbe chiedere alla Route lo stesso hostname (Route non ammessa, `HostAlreadyClaimed`); `namespace` fisso verrebbe comunque ignorato. Il Secret passa a `stringData` con `${DB_PASSWORD}` così ogni istanza ha la sua password (20 caratteri). La label `template: hello-db` viene tolta perché `clone` non è un'istanza di `hello-db`: la ritrovi con `-l app=clone` (e la pulizia del passo 3.8 non la tocca). Il Deployment di `demo` non ha l'annotazione `image.openshift.io/triggers` e usa un riferimento completo all'immagine: si può tenere così; se esportassi un Deployment con trigger, terresti l'annotazione (è configurazione) e sostituiresti l'eventuale `@sha256:...` con il tag.

**Perché il controllo `grep -n demo`:** è la prova che nessun nome di `demo` è rimasto nell'output processato; il secondo `grep` assicura che ogni `${...}` corrisponda a un parametro dichiarato (scenario 5).

> **Da verificare sul tuo cluster:** l'output di `oc get -o yaml` cambia leggermente con la versione di `oc` (le versioni recenti non mostrano `managedFields` senza `--show-managed-fields`; annotazioni e campi di default possono differire). Prima dell'editing controlla cosa c'è davvero con `grep -nE 'annotations:|managedFields|clusterIPs|status:' -A3 $EX288_WORK/m09/demo-clone.yaml`. Se il tuo `LAB` contiene la parola `demo`, la `sed` modifica anche il percorso dell'immagine: ricontrolla la riga `image:`.
</details>

### 4.3 Esercizio senza aiuti

Scrivi da zero (YAML) il template `static-site` con: un Deployment `httpd` (`registry.access.redhat.com/ubi9/httpd-24`) con nome, repliche e limite di memoria parametrici; un Service; una Route edge il cui hostname è un parametro opzionale (vuoto = generato dal cluster). Salvalo nel progetto, istanzialo due volte (`site-a` con 1 replica, `site-b` con 2) e poi convertilo in JSON verificando che `oc process --local` produca lo stesso output.

---

## 5. Verifiche pratiche con `oc`

| Domanda | Comando |
|---|---|
| Quali template ci sono nel progetto / nel cluster? | `oc get templates` · `oc get templates -n openshift` |
| Quali parametri accetta un template? | `oc process --parameters -f <file>` · `oc process --parameters <nome>` |
| Cosa creerebbe, senza creare nulla? | `oc process -f <file> --local -o yaml -p ...` |
| Quali oggetti contiene un template salvato? | `oc get template <nome> -o jsonpath='{range .objects[*]}{.kind}/{.metadata.name}{"\n"}{end}'` |
| Default e generatori dei parametri? | `oc get template <nome> -o jsonpath='{range .parameters[*]}{.name}={.value}{.from}{"\n"}{end}'` |
| Quali oggetti appartengono a un'istanza? | `oc get all,cm,secret,route -l <label-del-template>` |
| Che valore ha ricevuto un parametro generato? | `oc extract secret/<nome> --to=-` |
| Documentazione dei campi? | `oc explain template.parameters` · `oc explain template.objects` |

---

## 6. Troubleshooting intenzionale

```bash
oc project ${LAB}-m09
TS=$EX288_HOME/09-template/troubleshooting
```

### Scenario 1 — parametro obbligatorio mancante

**Riproduci:** `oc process -f $TS/rotto-1-required.yaml | oc create -f -`
**Sintomo:** nessun oggetto creato; `oc` stampa un errore sul template.

<details><summary>Indagine e soluzione</summary>

```bash
oc process --parameters -f $TS/rotto-1-required.yaml    # APP_IMAGE: nessun VALUE, nessun GENERATOR
# errore tipico: template.parameters[1]: Required value: template.parameters[1]: parameter APP_IMAGE is required and must be specified
```
**Causa:** `APP_IMAGE` è `required: true` senza default né generatore.
**Fix:** `oc process -f $TS/rotto-1-required.yaml -p APP_IMAGE=$APP_IMAGE | oc create -f -`
**Lezione:** `required` + nessun `value` = parametro da passare sempre. All'esame leggi `oc process --parameters` prima di istanziare.
</details>

### Scenario 2 — `replicas` scritto come stringa

**Riproduci:** `oc process -f $TS/rotto-2-replicas.yaml | oc create -f -`
**Sintomo:** il processo riesce, ma la creazione del Deployment `t2` fallisce.

<details><summary>Indagine e soluzione</summary>

```bash
oc process -f $TS/rotto-2-replicas.yaml --local -o yaml | grep replicas    # replicas: "2"  <- stringa
# errore tipico: Deployment in version "v1" cannot be handled as a Deployment:
#   json: cannot unmarshal string into Go struct field DeploymentSpec.spec.replicas of type int32
```
**Causa:** `"${REPLICAS}"` produce sempre una stringa; `spec.replicas` è un intero.
**Fix:** in una tua copia scrivi `replicas: ${{REPLICAS}}`, poi `oc process -f <copia> | oc create -f -`.
**Lezione:** numeri e booleani richiedono `${{...}}`. Lo stesso vale per `port`, `containerPort`, `initialDelaySeconds` se parametrici.
</details>

### Scenario 3 — namespace nel template

**Riproduci:** `oc process -f $TS/rotto-3-namespace.yaml | oc create -f -`
**Sintomo:** `t3-fisso` viene creata nel tuo progetto, `t3-parametrico` no (errore `Forbidden` o `NotFound`).

<details><summary>Indagine e soluzione</summary>

```bash
oc process -f $TS/rotto-3-namespace.yaml --local -o yaml | grep -n namespace
oc get cm t3-fisso -o jsonpath='{.metadata.namespace}{"\n"}'     # il TUO progetto
```
**Causa:** un `namespace` fisso negli oggetti viene rimosso durante l'istanziazione (l'oggetto finisce nel progetto corrente); un namespace **da parametro** viene sostituito e rispettato: `ex288-produzione-condivisa` non esiste o non hai permessi lì.
**Fix:** `oc process -f $TS/rotto-3-namespace.yaml -p TARGET_NAMESPACE=${LAB}-m09 | oc create -f -` (o togli il campo `namespace` da una tua copia).
**Lezione:** nei template non mettere `namespace`: lascia decidere a chi istanzia (`-n` o progetto corrente).

> **Da verificare sul tuo cluster:** se `--local` mostra ancora `namespace: produzione`, confronta con `oc process -f ... -o yaml` (senza `--local`, processato dal server).
</details>

### Scenario 4 — la seconda istanziazione fallisce

**Riproduci:** esegui **due volte** `oc process -f $T/hello-db-template.json -p APP_NAME=twice -p APP_IMAGE=$APP_IMAGE | oc create -f -`
**Sintomo:** la seconda volta: `Error from server (AlreadyExists): secrets "twice-db" already exists` (e così via per ogni oggetto).

<details><summary>Indagine e soluzione</summary>

```bash
oc get deploy,svc,route,cm,secret -l template=hello-db | grep twice
```
**Causa:** `oc create` non aggiorna oggetti esistenti; i nomi derivano da `APP_NAME`, uguale nelle due esecuzioni.
**Fix:** per un'istanza nuova cambia `APP_NAME`; per ricrearla da zero `oc delete deploy,svc,route,cm,secret -l template=hello-db,app=twice` e riesegui; per aggiornarla usa `| oc apply -f -` sapendo che la password generata cambia (passa `-p DB_PASSWORD=...` per tenerla).
**Lezione:** un template non ha memoria delle istanze: le **label** sono il tuo "handle" per ritrovarle e cancellarle.
</details>

### Scenario 5 — valore letterale `${...}` nell'oggetto

**Riproduci:** `oc process -f $TS/rotto-5-parametro-non-dichiarato.yaml | oc create -f -`
**Sintomo:** nessun errore, ma `oc get cm t5-config -o yaml` mostra `tema.colore=${APP_COLOR}`.

<details><summary>Indagine e soluzione</summary>

```bash
oc process --parameters -f $TS/rotto-5-parametro-non-dichiarato.yaml   # c'è APP_COLOUR, non APP_COLOR
```
**Causa:** l'oggetto usa `${APP_COLOR}`, ma il parametro dichiarato si chiama `APP_COLOUR`. I riferimenti a parametri non dichiarati non vengono sostituiti (e `-p APP_COLOR=...` viene rifiutato perché il parametro non esiste).
**Fix:** in una tua copia allinea i nomi, poi `oc delete cm t5-config` e ricrea.
**Lezione:** controlla sempre l'anteprima con `--local -o yaml | grep '\${'`: non devono restare segnaposto.

> **Da verificare sul tuo cluster:** il comportamento esatto con un `-p` su un parametro non dichiarato (errore o avviso) dipende dalla versione di `oc`.
</details>

### Scenario 6 — template JSON non valido

**Riproduci:** `oc process -f $TS/rotto-6-json-non-valido.json`
**Sintomo:** errore di parsing prima di qualsiasi processo (es. `invalid character ']' looking for beginning of value`).

<details><summary>Indagine e soluzione</summary>

```bash
python3 -m json.tool $TS/rotto-6-json-non-valido.json     # indica riga e colonna (se hai python3)
```
**Causa:** virgola finale dopo l'ultimo elemento di `parameters` (non ammessa in JSON).
**Fix:** rimuovi la virgola in una tua copia e riesegui.
**Lezione:** in JSON niente commenti né virgole finali; preferisci il YAML per i template che scrivi a mano, il JSON per quelli generati da strumenti.
</details>

Pulizia: `oc delete project ${LAB}-m09`

---

## 7. Esercizio finale (stile EX288)

> Lavora come all'esame: niente soluzioni, solo documentazione ufficiale, `oc --help` e `oc explain`. Tempo indicativo: **50 minuti**.

**Requisiti**

1. Esiste il progetto `${LAB}-m09-exam`, nel quale l'image stream tag `nodejs:22-ubi9` punta a `registry.access.redhat.com/ubi9/nodejs-22`.
2. Nel progetto è salvato un template chiamato **`inventory-app`** con:
   - display name `Inventory App`, una descrizione non vuota e il tag `ex288` tra i tag;
   - la label `app.kubernetes.io/part-of=inventory` applicata a tutti gli oggetti che crea.
3. Il template dichiara **esattamente** questi parametri:

   | Parametro | Default | Altro |
   |---|---|---|
   | `APP_NAME` | `inventory` | obbligatorio |
   | `APP_MESSAGE` | `Inventario attivo` | |
   | `REPLICAS` | `2` | usato come numero |
   | `GIT_URI` | nessuno | obbligatorio |
   | `DB_NAME` | `inventorydb` | |
   | `DB_USER` | `inventory` | |
   | `DB_PASSWORD` | nessuno | generato: 12 caratteri alfanumerici, espressione `[a-zA-Z0-9]{12}` |
   | `MEMORY_LIMIT` | `256Mi` | |

4. Il template crea, per un'istanza con nome `<APP_NAME>`:
   - ImageStream e BuildConfig `<APP_NAME>` (strategia Source, builder `nodejs:22-ubi9` del progetto, repository `GIT_URI`, context dir `hello-node`), con la prima build avviata automaticamente;
   - Deployment `<APP_NAME>` (repliche `REPLICAS`, limite di memoria `MEMORY_LIMIT`, `APP_MESSAGE` nella variabile omonima) che si aggiorna automaticamente quando cambia `<APP_NAME>:latest`, con readiness su `/ready` e liveness su `/healthz`;
   - Service `<APP_NAME>` (porta 8080) e Route `<APP_NAME>` con terminazione edge;
   - Secret `<APP_NAME>-db` con le chiavi `database-name`, `database-user`, `database-password`;
   - ConfigMap `<APP_NAME>-config` con la chiave `app.properties` che contiene la riga `inventory.name=<APP_NAME>`, montata in `/etc/app`;
   - Deployment `<APP_NAME>-db` (`registry.redhat.io/rhel9/postgresql-16`, credenziali dal Secret, dati su `emptyDir` in `/var/lib/pgsql/data`) e Service `<APP_NAME>-db` (porta 5432);
   - l'app riceve `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_PASSWORD` coerenti con il database.
5. Il template è stato istanziato nel progetto con `APP_NAME=stock`, `APP_MESSAGE=Magazzino centrale`, `REPLICAS=3`, `GIT_URI=` il tuo `$GIT_REPO`; gli altri parametri restano ai default.

**Risultato atteso**

- `https://<route stock>/` restituisce `"message": "Magazzino centrale"` e il Deployment `stock` ha 3 repliche pronte.
- `https://<route stock>/db` restituisce `"db": "raggiungibile"` con database `inventorydb` e utente `inventory`.
- `https://<route stock>/config` contiene `inventory.name=stock`.
- La password nel Secret `stock-db` è di 12 caratteri alfanumerici.

```bash
bash $EX288_HOME/09-template/verifica.sh
```

---

## 8. Riferimenti ufficiali (OCP 4.22)

- Building applications → *Creating applications* → *Using templates* (struttura, parametri, `${{}}`, `oc process`, `oc new-app --template`, creazione da oggetti esistenti): https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/building_applications/creating-applications
- Building applications → *Deployments* (Deployment vs DeploymentConfig): https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/building_applications/deployments
- Images → *Triggering updates on image stream changes* (annotazione `image.openshift.io/triggers`): https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/images/triggering-updates-on-imagestream-changes
- Images → *Configuring the Cluster Samples Operator* (template del namespace `openshift`, deprecazione): https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/images/configuring-samples-operator
- CLI tools → *OpenShift CLI developer command reference* (`oc process`, `oc new-app`): https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/cli_tools/openshift-cli-oc
