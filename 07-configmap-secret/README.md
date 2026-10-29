# Modulo 07 — ConfigMap e Secret: configurazione fuori dall'immagine

> **Obiettivi EX288 coperti**
> - *Work with configuration maps and secrets* → Create configuration maps
> - *Work with configuration maps and secrets* → Create secret resources
> - *Work with configuration maps and secrets* → Use configuration maps to inject data into applications
>
> **Durata stimata:** 4 ore · **Prerequisiti:** moduli 01-02 (05-06 utili per la parte sulle variabili di build) · **Richiede cluster-admin:** no
>
> **Progetti usati:** `${LAB}-m07`, `${LAB}-m07-exam`

---

## 1. Perché e quando

Una buona immagine è **la stessa** in sviluppo, collaudo e produzione: cambia solo la configurazione che le inietti al momento del deploy. OpenShift offre più posti dove mettere un valore; all'esame la scelta sbagliata (ad esempio una password scritta in chiaro nel Deployment) può costare il requisito anche se l'app funziona.

| Il dato è… | Dove lo metti | Perché |
|---|---|---|
| Un parametro non sensibile che cambia per ambiente (messaggio, URL di un servizio, livello di log) | **ConfigMap** → variabili d'ambiente | Una sola immagine per tutti gli ambienti; il valore si cambia senza ricostruire |
| Un file di configurazione intero (`app.properties`, `nginx.conf`) | **ConfigMap** → volume | L'app legge un file; il file montato si aggiorna anche senza riavviare il pod |
| Password, token, chiavi API | **Secret** → env o volume | RBAC separato (il ruolo `view` non legge i Secret), montato su tmpfs, il valore non compare nel Deployment |
| Certificato TLS, chiave SSH, credenziali di un registry | **Secret tipizzato** (`tls`, `ssh-auth`, `dockerconfigjson`, `basic-auth`) | Il tipo impone le chiavi attese ed è ciò che si aspettano build, pull di immagini e route |
| Un valore fisso, non sensibile, che riguarda solo quel Deployment | `env` nel Deployment (`oc set env deployment/x VAR=v`) | Rapido, ma va ripetuto in ogni Deployment ed è visibile a chi legge il Deployment |
| Un valore che deve viaggiare **con il codice** (build S2I e runtime) | `.s2i/environment` nel repository | È versionato con il sorgente; per cambiarlo servono commit, push e nuova build (modulo 06) |
| Un valore che serve **solo durante la build** (`BUILD_LOGLEVEL`, proxy npm) | Env della BuildConfig (`--build-env`, `oc set env bc/x`) | Non riguarda il container in esecuzione; i valori presi da Secret compaiono in chiaro nel log della build (modulo 05) |

**Regola d'oro:** se il valore cambia tra ambienti va in una ConfigMap; se è sensibile va in un Secret; se cambia con il codice va nel repository.

---

## 2. Concetti essenziali

### 2.1 ConfigMap

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-config          # namespace-scoped: deve esistere nel progetto del pod, PRIMA del pod
data:                       # chiave -> stringa (anche multilinea)
  APP_MESSAGE: "Ciao"       # chiave "da variabile"
  app.properties: |         # chiave "da file": il nome della chiave diventa il nome del file
    negozio.nome=Demo
# binaryData:               # contenuti binari in base64 (raro)
# immutable: true           # non modificabile: per cambiarla la cancelli e la ricrei
```

### 2.2 Secret

Stessa struttura di una ConfigMap, con un **tipo** e i valori in `data` codificati in **base64** (oppure in chiaro in `stringData`, che l'API server converte in `data`). Dimensione massima: 1 MB.

| Tipo | Chiavi attese | Come si crea | Uso tipico |
|---|---|---|---|
| `Opaque` (default) | qualsiasi | `oc create secret generic` | Password e token applicativi |
| `kubernetes.io/basic-auth` | `username`, `password` | `oc create secret generic --type=kubernetes.io/basic-auth` | Clone Git nelle build (modulo 02) |
| `kubernetes.io/ssh-auth` | `ssh-privatekey` | `oc create secret generic --type=kubernetes.io/ssh-auth` | Clone Git via SSH |
| `kubernetes.io/tls` | `tls.crt`, `tls.key` | `oc create secret tls` | Certificati per app e route |
| `kubernetes.io/dockerconfigjson` | `.dockerconfigjson` | `oc create secret docker-registry` | Pull secret (modulo 03) |

> **I Secret non sono cifrati, sono solo codificati.** base64 non è crittografia: chiunque possa leggere il Secret ne ricava il valore con `base64 -d`. La protezione sta nell'**RBAC**: il ruolo `view` non può leggere i Secret, `edit` e `admin` sì. Attenzione: chi può creare pod nel progetto può anche montare qualsiasi Secret del progetto e leggerlo. I volumi dei Secret sono su tmpfs (non vengono scritti sul disco del nodo). La cifratura di etcd è una scelta dell'amministratore del cluster (*Enabling etcd encryption*), invisibile per te.

### 2.3 Tre modi di consumare ConfigMap e Secret

```yaml
spec:
  containers:
  - name: hello
    env:
    - name: APP_COLOR                  # (1) UNA chiave -> UNA variabile (con il nome che vuoi)
      valueFrom:
        configMapKeyRef: {name: app-config, key: COLOR, optional: false}
    - name: DB_PASSWORD
      valueFrom:
        secretKeyRef: {name: db-cred, key: PASSWORD}
    envFrom:                           # (2) TUTTE le chiavi -> variabili (eventuale prefisso)
    - configMapRef: {name: app-config}
      prefix: APP_
    - secretRef: {name: api-cred}
    volumeMounts:                      # (3) chiavi -> FILE in una directory
    - {name: config, mountPath: /etc/app}
  volumes:
  - name: config
    configMap: {name: app-config}      # per un Secret: secret: {secretName: ...}
```

| Modo | Comando rapido | Se cambi la ConfigMap/Secret… | Errore se manca la chiave o la risorsa |
|---|---|---|---|
| (1) `env.valueFrom` | `oc set env deployment/x --from=configmap/y` (una voce `valueFrom` per ogni chiave **esistente in quel momento**) | Nessun effetto finché non nasce un **nuovo pod** | `CreateContainerConfigError` (salvo `optional: true`) |
| (2) `envFrom` | YAML (`oc edit`, `oc patch`) | Nessun effetto finché non nasce un nuovo pod (che vede anche le chiavi aggiunte) | `CreateContainerConfigError` se manca la risorsa |
| (3) volume | `oc set volume deployment/x --add --type=configmap ...` | I file vengono aggiornati dal kubelet dopo un ritardo (circa un minuto), **tranne** i mount con `subPath` | Pod bloccato in `ContainerCreating` (evento `FailedMount`) |

Se la stessa variabile arriva sia da `envFrom` sia da `env`, vince `env`.

> **Abitudine da esame:** dopo aver modificato una ConfigMap o un Secret usati come variabili, esegui `oc rollout restart deployment/<nome>`. Nessuno lo fa per te.

---

## 3. Laboratorio guidato

```bash
source env.sh                 # dalla root del repository ex288-teach
M=$EX288_HOME/07-configmap-secret      # scorciatoia per i file del modulo
```

### 3.1 Progetto e applicazione di partenza

```bash
oc new-project ${LAB}-m07 --display-name="EX288 m07 - ConfigMap e Secret"

# Builder S2I locale (sui cluster con Samples Operator esiste anche openshift/nodejs:22-ubi9,
# ma il Samples Operator è deprecato in 4.20-4.22: non darlo per scontato)
oc import-image nodejs:22-ubi9 --from=registry.access.redhat.com/ubi9/nodejs-22 --confirm

# App hello-node costruita con S2I: la PRIMA build richiede qualche minuto
oc new-app "nodejs:22-ubi9~$GIT_REPO" --context-dir=hello-node --name=hello
oc logs -f bc/hello                    # attendi "Push successful"
oc rollout status deployment/hello
oc expose service/hello
URL=http://$(oc get route hello -o jsonpath='{.spec.host}')

# Lookup locale: permette ai manifest della sezione 6 di usare "image: hello:latest"
oc set image-lookup hello

curl -s $URL/config    # 404: "file di configurazione non trovato: /etc/app/app.properties"
curl -s $URL/env       # nessuna APP_*, API_KEY e DB_PASSWORD "NON impostata"
```

### 3.2 Creare ConfigMap: quattro modi

```bash
# 1) Da valori letterali: una chiave per ogni --from-literal
oc create configmap app-env \
  --from-literal=APP_MESSAGE="Ciao dalla ConfigMap" \
  --from-literal=APP_COLOR=verde

# 2) Da file, con chiave personalizzata: chiave "app.properties" = contenuto del file.
#    Senza "chiave=" la chiave è il nome del file; con una directory, una chiave per file.
oc create configmap app-props --from-file=app.properties=$M/lab/app.properties

# 3) Da env file: una chiave per OGNI riga CHIAVE=valore del file
oc create configmap app-envfile --from-env-file=$M/lab/app.env

# 4) Da YAML (dichiarativo)
oc apply -f $M/lab/configmap-features.yaml

oc get configmaps                              # colonna DATA = numero di chiavi
oc describe configmap app-props                # mostra chiavi e contenuto
oc get configmap app-envfile -o jsonpath='{.data}{"\n"}'
# {"APP_ENVIRONMENT":"laboratorio","APP_OWNER":"team-ex288","LOG_LEVEL":"info"}
```

Confronta: `--from-file=$M/lab/app.env` creerebbe **una** chiave `app.env` con tutto il file; `--from-env-file` crea **tre** chiavi. È una delle confusioni più frequenti.

Per generare lo YAML senza creare nulla (e per **aggiornare** una ConfigMap partendo dai file):

```bash
oc create configmap app-props --from-file=app.properties=$M/lab/app.properties \
  --dry-run=client -o yaml                     # stampa lo YAML
# ... | oc apply -f -                          # pattern di aggiornamento (passo 3.7)
```

### 3.3 Creare Secret

```bash
# generic (Opaque) da letterali
oc create secret generic api-cred \
  --from-literal=API_KEY=k-abc-123 \
  --from-literal=DB_PASSWORD=s3greta

# generic da file (chiave personalizzata) e da env file
oc create secret generic app-token --from-file=token=$M/lab/token.txt
oc create secret generic app-envsecret --from-env-file=$M/lab/secret.env

# basic-auth: chiavi obbligatorie username/password
oc create secret generic git-basic --type=kubernetes.io/basic-auth \
  --from-literal=username=sviluppo --from-literal=password=token-finto

# docker-registry: produce un Secret kubernetes.io/dockerconfigjson
oc create secret docker-registry quay-pull --docker-server=quay.io \
  --docker-username=utente --docker-password=token-finto --docker-email=utente@example.com

# tls: serve una coppia certificato/chiave (qui autofirmata, valida 30 giorni)
openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj "/CN=hello.example.com" \
  -keyout $EX288_WORK/m07/tls.key -out $EX288_WORK/m07/tls.crt
oc create secret tls hello-tls --cert=$EX288_WORK/m07/tls.crt --key=$EX288_WORK/m07/tls.key

# da YAML: stringData (in chiaro) e data (base64) producono lo stesso risultato
oc apply -f $M/lab/secret-yaml.yaml

oc get secrets                                 # colonna TYPE
oc describe secret api-cred                    # mostra solo le dimensioni, non i valori
```

**Leggere un Secret** (se il tuo ruolo lo consente):

```bash
oc extract secret/api-cred --to=-                                   # tutte le chiavi, decodificate
oc extract secret/api-cred --keys=API_KEY --to=-                    # una sola chiave
oc get secret api-cred -o jsonpath='{.data.API_KEY}' | base64 -d; echo
oc get secret yaml-stringdata -o jsonpath='{.data.password}' | base64 -d; echo   # Pa55-demo
oc extract configmap/app-props --to=$EX288_WORK/m07 --confirm      # anche per le ConfigMap: crea $EX288_WORK/m07/app.properties
```

> Per codificare a mano un valore usa `printf 'valore' | base64` (oppure `echo -n`): con `echo` semplice codifichi anche il carattere di fine riga e la password diventa sbagliata.

**Chi può leggere i Secret:**

```bash
oc create serviceaccount reader
oc policy add-role-to-user view -z reader
oc auth can-i get configmaps --as=system:serviceaccount:${LAB}-m07:reader   # yes
oc auth can-i get secrets    --as=system:serviceaccount:${LAB}-m07:reader   # no
oc auth can-i get secrets                                                   # yes: sei admin del progetto
```

### 3.4 Iniettare variabili d'ambiente

**Tutte le chiavi, con `oc set env --from`:**

```bash
oc set env deployment/hello --from=configmap/app-env
oc set env deployment/hello --list
# # APP_MESSAGE from configmap app-env, key APP_MESSAGE
# # APP_COLOR from configmap app-env, key APP_COLOR
oc rollout status deployment/hello      # ogni modifica al template = nuovo rollout
curl -s $URL/ | grep message            # "Ciao dalla ConfigMap"

# Con prefisso: le chiavi BETA e THEME diventano APP_BETA e APP_THEME
oc create configmap flags --from-literal=BETA=true --from-literal=THEME=scuro
oc set env deployment/hello --from=configmap/flags --prefix=APP_
curl -s $URL/env                        # APP_BETA, APP_COLOR, APP_MESSAGE, APP_THEME
oc get deployment hello -o yaml | grep -B2 -A4 configMapKeyRef | head -20
```

`oc set env --from` scrive nel Deployment **una voce `env` con `valueFrom` per ogni chiave presente in quel momento**: se domani aggiungi una chiave alla ConfigMap, non arriverà al container.

> **Da verificare sul tuo cluster:** il nome della variabile viene derivato dalla chiave (e normalizzato se la chiave contiene caratteri non validi, ad esempio `.` o `-`). Controlla sempre il risultato con `oc set env deployment/<nome> --list`. Le opzioni disponibili (es. `--keys` per importare solo alcune chiavi) sono elencate in `oc set env --help`.

**Una singola chiave, con un nome a scelta (`valueFrom`) e `optional`:**

```bash
cat $M/lab/patch-env-chiave.yaml                  # leggi i commenti
oc patch deployment/hello -p "$(cat $M/lab/patch-env-chiave.yaml)"
curl -s $URL/env | grep -E 'OWNER|REGION'         # APP_OWNER presente, APP_REGION assente ma il pod è partito
```

**Tutte le chiavi con `envFrom`** (dinamico: al prossimo pod arrivano anche le chiavi nuove):

```bash
oc patch deployment/hello -p "$(cat $M/lab/patch-envfrom.yaml)"
curl -s $URL/env | grep FEATURE                   # APP_FEATURE_CART "on", APP_FEATURE_WISHLIST "off"
```

### 3.5 Montare una ConfigMap come volume

```bash
# Ogni chiave della ConfigMap diventa un file in /etc/app
oc set volume deployment/hello --add --name=app-config \
  --type=configmap --configmap-name=app-props --mount-path=/etc/app
oc rollout status deployment/hello
curl -s $URL/config                       # contenuto di app.properties
oc exec deployment/hello -- ls -la /etc/app
# app.properties -> ..data/app.properties   (link simbolici: è così che il kubelet aggiorna i file)
oc set volume deployment/hello            # elenca i volumi del deployment
```

> **Da verificare sul tuo cluster:** gli esempi ufficiali di `oc set volume` mostrano `--add --mount-path` e i volumi PVC (`-t pvc --claim-name`). Le opzioni `--type=configmap --configmap-name` e `--type=secret --secret-name` (e `--read-only`) sono flag reali di `oc`, ma controllali con `oc set volume --help` prima dell'esame.

YAML equivalente, con `items` (scegli quali chiavi montare e con che nome di file) e `subPath` (monta un solo file senza nascondere il resto della directory):

```bash
cat $M/lab/patch-volume-items.yaml
oc patch deployment/hello -p "$(cat $M/lab/patch-volume-items.yaml)"
oc rollout status deployment/hello
oc exec deployment/hello -- find /etc/items /etc/subpath -name '*.properties'
# /etc/items/ambiente/negozio.properties
# /etc/subpath/negozio.properties
```

| Quando usare | Montaggio |
|---|---|
| L'app legge tutti i file di una directory dedicata | Volume intero su una directory vuota (`/etc/app`) |
| Ti serve un nome di file diverso dalla chiave o solo alcune chiavi | `items: [{key, path}]` |
| Devi mettere **un** file in una directory che contiene già altri file dell'immagine | `subPath` (ma niente aggiornamenti automatici) |

Un volume montato su una directory **nasconde** il contenuto originale di quella directory nell'immagine: non montare mai su `/opt/app-root/src`.

### 3.6 Secret come variabili e come volume

```bash
# Come variabili: API_KEY e DB_PASSWORD
oc set env deployment/hello --from=secret/api-cred
oc rollout status deployment/hello
curl -s $URL/env | grep -E 'API_KEY|DB_PASSWORD'
#  "API_KEY": "impostata (9 caratteri)",  "DB_PASSWORD": "impostata (7 caratteri)"
oc set env deployment/hello --list | grep -i secret      # il Deployment contiene il riferimento, non il valore

# Come volume: ogni chiave (tls.crt, tls.key) diventa un file
oc set volume deployment/hello --add --name=tls --type=secret \
  --secret-name=hello-tls --mount-path=/etc/tls --read-only=true
oc rollout status deployment/hello
oc exec deployment/hello -- ls -l /etc/tls/
oc exec deployment/hello -- grep /etc/tls /proc/mounts   # tipo di filesystem: tmpfs
```

I volumi ConfigMap e Secret sono comunque montati in sola lettura; `readOnly: true` rende esplicita l'intenzione. Per i permessi dei file usa `defaultMode` (es. `0400`) nel volume.

Variabile o file? Le variabili sono comode ma finiscono facilmente nei log o nei dump di processo e non si aggiornano mai; i file si aggiornano e sono preferibili per certificati e chiavi.

### 3.7 Aggiornamenti: cosa cambia e quando

```bash
# 1) Cambia una ConfigMap usata come VARIABILI (pattern create --dry-run | apply)
oc create configmap app-env --from-literal=APP_MESSAGE="Messaggio aggiornato" \
  --from-literal=APP_COLOR=verde --dry-run=client -o yaml | oc apply -f -
# (il warning sull'annotazione last-applied-configuration è innocuo)
curl -s $URL/ | grep message               # ANCORA "Ciao dalla ConfigMap"

# 2) Cambia una ConfigMap usata come VOLUME
oc create configmap app-props --from-file=app.properties=$M/lab/app-v2.properties \
  --dry-run=client -o yaml | oc apply -f -
sleep 90                                   # il kubelet aggiorna i file dopo un ritardo
curl -s $URL/config                        # versione 2, SENZA riavvio del pod
oc exec deployment/hello -- cat /etc/subpath/negozio.properties   # subPath: ancora versione 1

# 3) Applica le modifiche alle variabili: serve un nuovo pod
oc rollout restart deployment/hello
oc rollout status deployment/hello
curl -s $URL/ | grep message               # "Messaggio aggiornato"
```

> **Da verificare sul tuo cluster:** `oc set data configmap/<nome> --from-file=...` (o `--from-literal`) aggiorna direttamente una ConfigMap o un Secret; controlla la sintassi con `oc set data --help`. Il pattern `--dry-run=client -o yaml | oc apply -f -` funziona sempre.

Il fatto che hello-node rilegga il file a ogni richiesta è una scelta dell'app: molte applicazioni leggono la configurazione solo all'avvio, e allora anche per i volumi serve un riavvio.

**ConfigMap immutabili** (`immutable: true`): non si possono modificare, solo cancellare e ricreare. Si usano con nomi versionati (`app-env-v1`, `app-env-v2`): passare alla nuova versione significa cambiare il riferimento nel Deployment, quindi rollout e rollback sono espliciti.

```bash
oc create configmap demo-immutabile --from-literal=APP_MESSAGE=v1
oc patch configmap demo-immutabile --type=merge -p '{"immutable":true}'
oc patch configmap demo-immutabile --type=merge -p '{"data":{"APP_MESSAGE":"v2"}}'   # errore: field is immutable
```

### 3.8 App multi-componente con un Secret condiviso

L'app e il database devono usare **la stessa** password: mettila una sola volta in un Secret e falla consumare a entrambi.

```bash
# Un Secret, tre chiavi neutre
oc create secret generic db-cred \
  --from-literal=USER=appuser --from-literal=PASSWORD=Db-Pass-07 --from-literal=DATABASE=appdb

# Database: le chiavi diventano POSTGRESQL_USER/PASSWORD/DATABASE grazie al prefisso
oc create deployment db --image=$POSTGRES_IMAGE --port=5432
oc set env deployment/db --from=secret/db-cred --prefix=POSTGRESQL_
oc expose deployment/db --port=5432              # Service "db"
oc rollout status deployment/db                  # il primo pod (senza variabili) può fallire: è normale
oc logs deployment/db | tail -2                  # "... ready to accept connections"

# App: DB_HOST/DB_PORT non sono segreti -> ConfigMap; credenziali -> stesso Secret con prefisso DB_
oc create configmap db-conn --from-literal=DB_HOST=db --from-literal=DB_PORT=5432
oc set env deployment/hello --from=configmap/db-conn
oc set env deployment/hello --from=secret/db-cred --prefix=DB_      # DB_USER, DB_PASSWORD (sovrascrive quella del 3.6), DB_DATABASE
oc patch deployment/hello -p "$(cat $M/lab/patch-db-name.yaml)"     # DB_NAME <- chiave DATABASE (nome diverso: valueFrom)
oc rollout status deployment/hello

curl -s $URL/db
# { "db": "raggiungibile", "host": "db", "port": 5432, "name": "appdb", "user": "appuser" }
curl -s $URL/env | grep DB_PASSWORD      # "impostata (10 caratteri)"
```

`/db` verifica solo che la porta risponda. Per provare che la **password** sia corretta, connettiti con un client PostgreSQL usando il valore del Secret:

```bash
PGPW=$(oc get secret db-cred -o jsonpath='{.data.PASSWORD}' | base64 -d)
oc run psql-client --image=$POSTGRES_IMAGE --rm -i --restart=Never --env=PGPASSWORD="$PGPW" -- \
  psql -h db -U appuser -d appdb -c 'select current_user'
#  current_user -> appuser
```

> Con `oc new-app` avresti potuto creare il database in un colpo solo, ma i valori `-e` finiscono in chiaro nel Deployment (modulo 02). Con il Secret condiviso, cambiare la password significa aggiornare **un** oggetto e riavviare **entrambi** i Deployment.

### 3.9 Dalla web console

Nella console (progetto `${LAB}-m07`): *Workloads → ConfigMaps → Create ConfigMap* e *Workloads → Secrets → Create* (Key/value secret, Image pull secret, Source secret…). Dal dettaglio di un Secret, l'azione **Add Secret to workload** lo collega a un Deployment come variabili o come volume. Nel Deployment, la tab *Environment* permette di aggiungere variabili da ConfigMap/Secret. Verifica sempre il risultato con `oc set env deployment/hello --list` e `oc set volume deployment/hello`.

### 3.10 Pulizia

Tieni `${LAB}-m07` per le sezioni 4 e 6; alla fine: `oc delete project ${LAB}-m07`.

---

## 4. Esercizi

### 4.1 Esercizio guidato

Nel progetto `${LAB}-m07`:

1. crea la ConfigMap `ui` con le chiavi `TITLE=Catalogo` e `THEME=chiaro`;
2. rendi disponibili **tutte** le sue chiavi a `hello` come variabili con prefisso `APP_UI_`;
3. monta **solo** la chiave `TITLE` della stessa ConfigMap come file `/etc/ui/titolo.txt`.

<details><summary>Suggerimenti</summary>

- `oc set env --from=configmap/... --prefix=...`.
- Per montare una sola chiave con un nome di file diverso servono `items` (key/path): usa `oc patch` con uno YAML sul modello di `lab/patch-volume-items.yaml`.
- Verifica con `curl $URL/env` e `oc exec deployment/hello -- cat /etc/ui/titolo.txt`.
</details>

<details><summary>Soluzione</summary>

```bash
oc create configmap ui --from-literal=TITLE=Catalogo --from-literal=THEME=chiaro
oc set env deployment/hello --from=configmap/ui --prefix=APP_UI_
oc patch deployment/hello -p '
spec:
  template:
    spec:
      volumes:
      - name: ui
        configMap:
          name: ui
          items:
          - key: TITLE
            path: titolo.txt
      containers:
      - name: hello
        volumeMounts:
        - name: ui
          mountPath: /etc/ui
'
oc rollout status deployment/hello
curl -s $URL/env | grep APP_UI_                       # APP_UI_THEME, APP_UI_TITLE
oc exec deployment/hello -- cat /etc/ui/titolo.txt    # Catalogo
```
</details>

### 4.2 Esercizio semi-guidato

1. Crea il Secret `registry-cred` di tipo `kubernetes.io/basic-auth` con utente `robot` e password `R0bot-pass`.
2. Montalo in `hello` in sola lettura in `/etc/registry`, con permessi `0400` sui file.
3. Dimostra che il service account `reader` (ruolo `view`) non può leggerlo, mentre tu sì; recupera la password decodificata in due modi diversi.

<details><summary>Suggerimenti</summary>

- Il tipo si passa con `--type` a `oc create secret generic`.
- `defaultMode` si imposta nel volume (`oc explain deployment.spec.template.spec.volumes.secret`).
- `oc extract` e `oc get ... -o jsonpath | base64 -d`.
</details>

<details><summary>Soluzione (aprila solo dopo aver provato)</summary>

```bash
oc project ${LAB}-m07

# 1) Secret basic-auth: le chiavi devono chiamarsi username e password
oc create secret generic registry-cred --type=kubernetes.io/basic-auth \
  --from-literal=username=robot --from-literal=password=R0bot-pass
oc get secret registry-cred              # TYPE kubernetes.io/basic-auth, DATA 2

# 2) Volume Secret in sola lettura, file con permessi 0400
oc patch deployment/hello -p '
spec:
  template:
    spec:
      volumes:
      - name: registry
        secret:
          secretName: registry-cred
          defaultMode: 256          # = 0400 ottale (in JSON va il decimale)
      containers:
      - name: hello
        volumeMounts:
        - name: registry
          mountPath: /etc/registry
          readOnly: true
'
oc rollout status deployment/hello
oc get deploy hello -o jsonpath='{.spec.template.spec.volumes[?(@.name=="registry")]}{"\n"}'
# {"name":"registry","secret":{"defaultMode":256,"secretName":"registry-cred"}}
oc get deploy hello -o jsonpath='{.spec.template.spec.containers[0].volumeMounts[?(@.name=="registry")]}{"\n"}'
# {"mountPath":"/etc/registry","name":"registry","readOnly":true}

oc exec deployment/hello -- ls -l /etc/registry        # password -> ..data/password, username -> ..data/username (link simbolici)
oc exec deployment/hello -- ls -lL /etc/registry       # -L segue i link: permessi dei file VERI (vedi il box)
oc exec deployment/hello -- cat /etc/registry/username; echo     # robot
oc exec deployment/hello -- sh -c 'echo x > /etc/registry/prova' # errore: Read-only file system

# 3) RBAC: reader (view) non legge i Secret, tu sì
# (se non hai fatto il passo 3.3: oc create serviceaccount reader && oc policy add-role-to-user view -z reader)
SA=system:serviceaccount:${LAB}-m07:reader
oc auth can-i get secrets --as=$SA                     # no
oc auth can-i get secrets/registry-cred --as=$SA       # no
oc get secret registry-cred --as=$SA                   # Error from server (Forbidden): ... cannot get resource "secrets" ...
oc auth can-i get configmaps --as=$SA                  # yes: view legge il resto del progetto
oc auth can-i get secrets/registry-cred                # yes: sei admin del progetto

# Password decodificata, modo 1: oc extract (decodifica da solo)
oc extract secret/registry-cred --keys=password --to=-                     # R0bot-pass (con l'intestazione "# password")
# Password decodificata, modo 2: jsonpath + base64
oc get secret registry-cred -o jsonpath='{.data.password}' | base64 -d; echo   # R0bot-pass
```

**Perché `--type=kubernetes.io/basic-auth`:** `oc create secret generic` crea per default un `Opaque`; con `--type` imposti il tipo, che si aspetta le chiavi `username` e `password`. Non esiste un `oc create secret basic-auth`.

**Perché `defaultMode` e `readOnly`:** `defaultMode` è un campo del **volume** e si applica a tutti i file creati dalle chiavi (`items[].mode` lo farebbe per una singola chiave). In JSON va scritto in decimale (`0400` ottale = `256`); in un file YAML puoi scrivere `0400`. `readOnly: true` è un campo del **mount** nel container: i volumi Secret sono già in sola lettura, ma così l'intenzione è esplicita e il tentativo di scrittura fallisce.

**Perché reader non può e tu sì:** il ruolo `view` esclude volutamente i Secret; `admin` (il tuo ruolo sul progetto) li include. `oc auth can-i ... --as` simula la richiesta come quel service account senza usarne il token.

> **Da verificare sul tuo cluster:** `ls -l` mostra solo i link simbolici (`lrwxrwxrwx`), per questo serve `ls -lL`. Con l'SCC `restricted-v2` il pod riceve un `fsGroup`: il kubelet assegna i file a quel gruppo e può aggiungere il permesso di lettura per il gruppo, quindi potresti vedere `-r--r-----` (0440) invece di `-r--------` (0400). È anche il motivo per cui l'UID arbitrario del container riesce a leggere un file di proprietà di `root`. Confronta con `oc get pod -l deployment=hello -o jsonpath='{.items[0].spec.securityContext.fsGroup}{"\n"}'` e `oc exec deployment/hello -- id`: il requisito è soddisfatto dal `defaultMode: 256` nel Deployment. Se `oc set volume --help` elenca un'opzione `--default-mode`, puoi creare il volume anche con `oc set volume deployment/hello --add --name=registry --type=secret --secret-name=registry-cred --mount-path=/etc/registry --read-only=true --default-mode=0400`.
</details>

### 4.3 Esercizio senza aiuti

Configura `hello` in modo che `APP_MESSAGE` provenga dalla ConfigMap **immutabile** `msg-v1` (valore `Release 1`). Poi pubblica `Release 2` senza modificare `msg-v1`, con un solo rollout, e dimostra che tornare a `Release 1` richiede solo `oc rollout undo` (modulo 08). Infine dimostra che `msg-v1` non è modificabile.

---

## 5. Verifiche pratiche con `oc`

| Domanda | Comando |
|---|---|
| Quali chiavi ha una ConfigMap/Secret? | `oc describe cm <cm>` · `oc describe secret <s>` (solo dimensioni) |
| Qual è il valore di una chiave di un Secret? | `oc extract secret/<s> --keys=<k> --to=-` · `oc get secret <s> -o jsonpath='{.data.<k>}' \| base64 -d` |
| Da dove arrivano le variabili del Deployment? | `oc set env deployment/<d> --list` |
| Quali variabili vede davvero il container? | `oc exec deployment/<d> -- env \| sort` (o l'endpoint `/env` di hello-node) |
| Quali volumi sono montati e dove? | `oc set volume deployment/<d>` · `oc get deploy <d> -o jsonpath='{.spec.template.spec.containers[0].volumeMounts}'` |
| Che file ci sono nel mount? | `oc exec deployment/<d> -- ls -la <mountPath>` |
| Il pod usa la versione nuova delle variabili? | Confronta l'età del pod (`oc get pods`) con l'ultima modifica; nel dubbio `oc rollout restart` |
| Chi può leggere i Secret? | `oc auth can-i get secrets --as=<utente o system:serviceaccount:ns:sa>` |
| Perché il pod non parte? | `oc describe pod <pod>` (Events) · `oc get events --field-selector type=Warning` |

---

## 6. Troubleshooting intenzionale

Prerequisito: passo 3.1 completato (image stream `hello` con lookup locale). Applica uno scenario alla volta.

```bash
oc project ${LAB}-m07
oc apply -f $M/troubleshooting/rotto-1-chiave.yaml
oc apply -f $M/troubleshooting/rotto-2-configmap-mancante.yaml
oc apply -f $M/troubleshooting/rotto-3-required-env.yaml
oc apply -f $M/troubleshooting/rotto-4-mount-path.yaml
oc apply -f $M/troubleshooting/rotto-5-modifica.yaml
oc apply -f $M/troubleshooting/rotto-6-base64.yaml
```

### Scenario 1 — `t1` non parte

**Sintomo:** `oc get pods -l app=t1` mostra `CreateContainerConfigError`.

<details><summary>Indagine e soluzione</summary>

```bash
oc describe pod -l app=t1 | sed -n '/Events/,$p'
# Error: couldn't find key APP_COLOR in ConfigMap <progetto>/t1-config
oc get cm t1-config -o jsonpath='{.data}{"\n"}'      # {"APP_COLOUR":"rosso"}
```
**Causa:** il Deployment cerca la chiave `APP_COLOR`, ma la ConfigMap ha `APP_COLOUR`.
**Fix:** correggi la chiave nella ConfigMap: `oc create configmap t1-config --from-literal=APP_COLOR=rosso --dry-run=client -o yaml | oc apply -f -` (il kubelet riprova da solo, il pod parte senza intervento). In alternativa correggi `key:` nel Deployment con `oc edit deployment t1`.
**Lezione:** `CreateContainerConfigError` = il container non può essere configurato: ConfigMap/Secret o chiave mancanti nei riferimenti `env`/`envFrom`. Con `optional: true` la variabile viene semplicemente omessa.
</details>

### Scenario 2 — `t2` resta in `ContainerCreating`

**Sintomo:** dopo minuti il pod di `t2` è ancora `ContainerCreating`.

<details><summary>Indagine e soluzione</summary>

```bash
oc describe pod -l app=t2 | sed -n '/Events/,$p'
# Warning  FailedMount  MountVolume.SetUp failed for volume "files" : configmap "t2-files" not found
oc get cm t2-files                                   # NotFound
```
**Causa:** il volume fa riferimento a una ConfigMap che non esiste nel progetto.
**Fix:** `oc create configmap t2-files --from-file=app.properties=$M/lab/app.properties`; il kubelet ritenta il mount e il pod parte (eventualmente `oc delete pod -l app=t2` per accelerare).
**Lezione:** risorsa mancante come **volume** ⇒ `ContainerCreating` + `FailedMount`; come **variabile** ⇒ `CreateContainerConfigError`. ConfigMap e Secret devono esistere nello stesso progetto e prima del pod.
</details>

### Scenario 3 — `t3` in `CrashLoopBackOff`

**Sintomo:** `oc get pods -l app=t3` mostra `CrashLoopBackOff` e RESTARTS che cresce.

<details><summary>Indagine e soluzione</summary>

```bash
oc logs deployment/t3 --previous        # ERRORE: variabile obbligatoria mancante: API_KEY
oc set env deployment/t3 --list         # REQUIRED_ENV=APP_MESSAGE,API_KEY ; envFrom t3-config, t3-secret
oc describe secret t3-secret            # chiave APIKEY (senza underscore)
```
**Causa:** `envFrom` importa le chiavi con il loro nome: il Secret ha `APIKEY`, l'app richiede `API_KEY`.
**Fix:** `oc patch deployment/t3 -p '{"spec":{"template":{"spec":{"containers":[{"name":"hello","env":[{"name":"API_KEY","valueFrom":{"secretKeyRef":{"name":"t3-secret","key":"APIKEY"}}}]}]}}}}'` (mappa la chiave sul nome giusto), oppure ricrea il Secret con la chiave `API_KEY` e fai `oc rollout restart deployment/t3`.
**Lezione:** qui il problema non è di OpenShift (il container è stato configurato) ma dell'app, che termina: la causa è **nei log**. Usa `--previous` se il container è appena ripartito.
</details>

### Scenario 4 — `t4` funziona ma `/config` risponde 404

**Sintomo:** il pod è `Running`, ma `oc exec deployment/t4 -- curl -s localhost:8080/config` restituisce `file di configurazione non trovato: /etc/app/app.properties`.

<details><summary>Indagine e soluzione</summary>

```bash
oc set volume deployment/t4                       # configMap/t4-files as files mounted at /etc/config
oc exec deployment/t4 -- ls /etc/config /etc/app  # il file c'è, ma nella directory sbagliata
```
**Causa:** la ConfigMap è montata in `/etc/config`, l'app legge `/etc/app/app.properties` (valore di default di `CONFIG_FILE`).
**Fix:** `oc set volume deployment/t4 --add --name=files --type=configmap --configmap-name=t4-files --mount-path=/etc/app --overwrite`, oppure lascia il mount e imposta `oc set env deployment/t4 CONFIG_FILE=/etc/config/app.properties`.
**Lezione:** nessun errore in OpenShift: il volume è montato correttamente, solo non dove l'app lo cerca. Confronta sempre il `mountPath` con il percorso che l'app si aspetta.
</details>

### Scenario 5 — "Ho cambiato la ConfigMap ma non cambia niente"

**Riproduci** (dopo che `t5` è Running):

```bash
oc create configmap t5-config --from-literal=APP_MESSAGE="Versione 2" --dry-run=client -o yaml | oc apply -f -
oc exec deployment/t5 -- curl -s localhost:8080/ | grep message
```
**Sintomo:** la ConfigMap contiene `Versione 2`, l'app risponde ancora `Versione 1`, anche dopo diversi minuti.

<details><summary>Indagine e soluzione</summary>

```bash
oc get cm t5-config -o jsonpath='{.data.APP_MESSAGE}{"\n"}'   # Versione 2
oc get pods -l app=t5                                          # AGE: il pod è precedente alla modifica
oc exec deployment/t5 -- printenv APP_MESSAGE                  # Versione 1
```
**Causa:** le variabili d'ambiente vengono lette solo alla creazione del container.
**Fix:** `oc rollout restart deployment/t5`.
**Lezione:** ConfigMap come variabili ⇒ serve un nuovo pod; come volume ⇒ aggiornamento automatico con ritardo (non per `subPath`).
</details>

### Scenario 6 — Il database rifiuta la password

**Riproduci** (dopo che `t6-db` è Running): il team dichiara che la password è `app123`.

```bash
oc run t6-client --image=$POSTGRES_IMAGE --rm -i --restart=Never --env=PGPASSWORD=app123 -- \
  psql -h t6-db -U app -d appdb -c 'select 1'
```
**Sintomo:** `FATAL: password authentication failed for user "app"`.

<details><summary>Indagine e soluzione</summary>

```bash
oc extract secret/t6-db-cred --keys=PASSWORD --to=-     # YXBwMTIz  (non app123!)
oc exec deployment/t6-db -- printenv POSTGRESQL_PASSWORD # YXBwMTIz
printf 'YXBwMTIz' | base64 -d; echo                      # app123
```
**Causa:** nel campo `data` del manifest il valore è stato codificato **due volte** (`base64(base64("app123"))`). Il database è stato inizializzato con la stringa `YXBwMTIz` come password. Lo stesso errore si ottiene mettendo un valore già codificato in `stringData`.
**Fix:**

```bash
oc create secret generic t6-db-cred --from-literal=USER=app --from-literal=PASSWORD=app123 \
  --from-literal=DATABASE=appdb --dry-run=client -o yaml | oc apply -f -
oc rollout restart deployment/t6-db         # nuovo pod: senza volume persistente il database viene reinizializzato con la password giusta
oc rollout status deployment/t6-db          # poi ripeti il comando psql: (1 row)
```
**Lezione:** in `data` va il valore codificato **una** volta, in `stringData` il valore in chiaro. Controlla sempre con `oc extract`. Indizio rapido: `/env` di hello-node mostra la **lunghezza** di `DB_PASSWORD`; 8 caratteri invece di 6 tradiscono la doppia codifica.
</details>

Pulizia degli scenari: `oc delete all,cm,secret -l 'scenario in (m07-1,m07-2,m07-3,m07-4,m07-5,m07-6)'`. A fine modulo: `oc delete project ${LAB}-m07`.

---

## 7. Esercizio finale (stile EX288)

> Lavora come all'esame: niente soluzioni, solo documentazione ufficiale, `oc --help` e `oc explain`. Tempo indicativo: **45 minuti**. La prima build S2I richiede qualche minuto.

**Requisiti**

1. Esiste il progetto `${LAB}-m07-exam`.
2. Nel progetto gira l'applicazione **`shop`** (2 repliche pronte), costruita con strategia **Source (S2I)** con il builder Node.js 22 UBI 9 da `$GIT_REPO`, cartella `hello-node`, ed esposta via HTTP dalla route `shop`.
3. Esiste la ConfigMap **`shop-settings`** con esattamente le chiavi `MESSAGE` = `Negozio configurato` e `COLOR` = `blu`. Tutte le sue chiavi sono disponibili nel container di `shop` come variabili d'ambiente con prefisso **`APP_`**, lette dalla ConfigMap (nessun valore scritto direttamente nel Deployment).
4. Esiste la ConfigMap **`shop-files`** con la chiave `shop.properties`, il cui contenuto è composto dalle due righe `negozio.nome=EX288 Shop` e `negozio.valuta=EUR`. Il contenuto è montato nel container di `shop` nella directory **`/etc/shop`** e l'applicazione lo legge da `/etc/shop/shop.properties` (variabile `CONFIG_FILE`).
5. Esiste il Secret **`shop-api`** di tipo `Opaque` con la chiave `API_KEY` = `k-12345-exam`, disponibile a `shop` come variabile `API_KEY`.
6. Esiste il Secret **`shop-db`** di tipo `Opaque` con le chiavi `USER` = `shop`, `PASSWORD` = `Negozi0-2026`, `DATABASE` = `shopdb`.
7. Nel progetto gira il database **`shop-db`** (Deployment, 1 replica pronta) dall'immagine `$POSTGRES_IMAGE`, raggiungibile tramite il Service `shop-db` sulla porta 5432. Le variabili `POSTGRESQL_USER`, `POSTGRESQL_PASSWORD` e `POSTGRESQL_DATABASE` provengono **tutte** dal Secret `shop-db`.
8. `shop` è collegata al database con `DB_HOST=shop-db`, `DB_PORT=5432` e con `DB_USER`, `DB_PASSWORD`, `DB_NAME` letti dal Secret `shop-db`.
9. Il Deployment `shop` ha la variabile `REQUIRED_ENV=APP_MESSAGE,API_KEY,DB_PASSWORD`.
10. Esiste il service account **`reader`** che può leggere le ConfigMap del progetto ma **non** i Secret.

**Risultato atteso**

- `http://<route shop>/` restituisce `"message": "Negozio configurato"`.
- `http://<route shop>/env` mostra `"APP_COLOR": "blu"`, `API_KEY` e `DB_PASSWORD` `impostata (12 caratteri)`.
- `http://<route shop>/config` mostra `negozio.nome=EX288 Shop`.
- `http://<route shop>/db` restituisce HTTP 200 con `"db": "raggiungibile"`, `"name": "shopdb"`, `"user": "shop"`.

```bash
bash $EX288_HOME/07-configmap-secret/verifica.sh
```

---

## 8. Riferimenti ufficiali (OCP 4.22)

- Building applications → *Using config maps with applications* (creazione, variabili, argomenti, volumi, restrizioni): https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/building_applications/config-maps
- Nodes → *Working with pods* → *Providing sensitive data to pods by using secrets* (tipi, `data`/`stringData`, volumi tmpfs) e *Creating and using config maps*: https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/nodes/working-with-pods
- Building applications → *Deployments* (`oc set env --from`, `--prefix`, `oc set volume`): https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/building_applications/deployments
- CLI tools → *OpenShift CLI developer command reference* (`oc create configmap`, `oc create secret`, `oc extract`, `oc set env`, `oc set volume`, `oc set data`): https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/cli_tools/openshift-cli-oc
- Authentication and authorization → *Using RBAC to define and apply permissions* (ruoli `view`, `edit`, `admin`): https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/authentication_and_authorization/using-rbac
- etcd → *Enabling etcd encryption* (attività dell'amministratore): https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/etcd/enabling-etcd-encryption
- Builds using BuildConfig → *Creating build inputs* (variabili di build, `.s2i/environment`, input secret): https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/builds_using_buildconfig/creating-build-inputs
