# Modulo 10 — Helm: usare e creare chart per applicazioni multi-container

> **Obiettivi EX288 coperti**
> - *Deploy multi-container applications* → Create and use Helm charts
>
> **Durata stimata:** 5 ore · **Prerequisiti:** moduli 01-09 (in particolare 07 ConfigMap/Secret, 09 template) · **Richiede cluster-admin:** no (solo le voci indicate)
>
> **Progetti usati:** `${LAB}-m10`, `${LAB}-m10-exam`

---

## 1. Perché e quando

**Helm** è il gestore di pacchetti di Kubernetes. Un **chart** è una cartella con template di manifest (linguaggio di template Go) e un file di **valori** di default; installandolo in un namespace crei una **release**, che Helm traccia come un'unità con una **storia di revisioni**: puoi aggiornarla (`upgrade`), tornare indietro (`rollback`) e rimuoverla (`uninstall`) in blocco.

**Template, Helm o Kustomize?** (stessa tabella del modulo 09)

| Criterio | Template OpenShift (modulo 09) | Helm (modulo 10) | Kustomize (modulo 11) |
|---|---|---|---|
| Dove funziona | Solo OpenShift (API `template.openshift.io`) | Qualsiasi Kubernetes; può includere oggetti OpenShift | Qualsiasi Kubernetes; integrato in `oc` (`oc apply -k`) |
| Come personalizzi | Parametri `${X}`: sostituzione di stringhe | Valori + linguaggio di template Go (`if`, `range`, funzioni) | Overlay e patch su YAML puro, nessuna variabile |
| Logica condizionale | No | Sì | No (overlay/componenti diversi) |
| Valori generati | Sì, `generate: expression` | Sì (funzioni), ma rigenerati a ogni upgrade se non gestiti | No |
| Ciclo di vita | Nessuno | **Release** con revisioni: upgrade, rollback, uninstall | Nessuno: `oc apply -k` / `oc delete -k` |
| Distribuzione | Oggetto Template nel progetto/`openshift` | Repository di chart (HTTP/OCI), catalogo della console | Directory in Git |
| Scegli quando... | Modulo da compilare per un'app OpenShift | Pacchetto versionato con upgrade/rollback, anche fuori da OpenShift | Stessa app in più ambienti con piccole differenze |

**Usa Helm quando:** distribuisci la stessa applicazione a più team/cluster come "prodotto" versionato; ti servono opzioni condizionali (route sì/no, persistenza sì/no); vuoi un rollback dell'intero insieme di oggetti in un comando; un fornitore distribuisce la sua app come chart (catalogo OpenShift).
**Evitalo quando:** hai poche differenze tra ambienti e preferisci YAML leggibile senza template (Kustomize), o ti basta un form di parametri per un'app solo OpenShift (Template).

> **Fonti:** la documentazione OpenShift 4.22 (*Building applications → Working with Helm charts*) copre installazione della CLI, `helm repo add`, `helm install`, `helm lint`, `helm list`, i repository via CR e le operazioni dalla console (upgrade, rollback, delete). I comandi `helm create`, `template`, `upgrade`, `rollback`, `uninstall`, `history`, `get`, `--set`, `-f` e la sintassi dei template sono documentati dal **progetto Helm upstream** (https://helm.sh/docs/), non dai docs OCP: in questo modulo sono segnalati con *(upstream)*.

---

## 2. Concetti essenziali

### 2.1 Vocabolario

| Termine | Significato |
|---|---|
| **Chart** | Cartella (o archivio `.tgz`, o artefatto OCI) con `Chart.yaml`, `values.yaml`, `templates/` |
| **Values** | Valori che i template leggono come `.Values.x.y`; default in `values.yaml`, sovrascritti con `-f file.yaml` e `--set` |
| **Release** | Un'installazione di un chart in un namespace, con un nome (`helm install <release> <chart>`) |
| **Revision** | Numero progressivo della release: 1 all'install, +1 a ogni upgrade **e a ogni rollback** |
| **Repository** | Indice HTTP (`index.yaml`) di chart, aggiunto con `helm repo add`; oppure registry OCI |

### 2.2 Struttura di un chart (`lab/hello-chart`)

```
hello-chart/
├── Chart.yaml            # apiVersion: v2 (Helm 3+), name, version (del chart), appVersion (dell'app)
├── values.yaml           # valori di default
├── values.schema.json    # (opzionale) schema JSON: Helm valida i valori a lint/install/upgrade/template
├── .helmignore           # file esclusi da helm package
└── templates/
    ├── _helpers.tpl      # "named template" riutilizzabili (define/include): nomi e label
    ├── NOTES.txt         # testo stampato dopo install/upgrade
    ├── app-deployment.yaml, app-service.yaml, route.yaml, configmap.yaml
    └── secret.yaml, db-deployment.yaml, db-service.yaml, db-pvc.yaml
```

### 2.3 Il linguaggio dei template in 10 righe *(upstream)*

```yaml
name: {{ include "hello-chart.fullname" . }}-app      # richiama un named template definito in _helpers.tpl
replicas: {{ .Values.app.replicas }}                   # legge un valore
value: {{ .Values.app.message | quote }}               # pipeline: mette le virgolette (sempre per stringhe in env)
labels:
  {{- include "hello-chart.labels" . | nindent 4 }}    # {{- toglie gli spazi a sinistra; nindent 4 = a capo + 4 spazi
{{- if .Values.route.enabled }} ... {{- end }}         # condizione: l'oggetto esiste solo se il valore è true
{{- with .Values.app.resources }}                      # "with": entra nel valore (il punto diventa quel valore) se non vuoto
resources:
  {{- toYaml . | nindent 2 }}                          # converte una mappa di valori in YAML
{{- end }}
image: {{ .Values.app.image.repository | default (printf "...%s/hello-node" .Release.Namespace) }}   # default calcolato
password: {{ required "db.password è obbligatorio" .Values.db.password }}                          # errore esplicito se manca
```

Oggetti predefiniti utili: `.Release.Name`, `.Release.Namespace`, `.Release.Revision`, `.Chart.Name`, `.Chart.Version`, `.Chart.AppVersion`, `.Template.BasePath`.

### 2.4 Precedenza dei valori *(upstream)*

`values.yaml` del chart → file `-f a.yaml -f b.yaml` (l'ultimo vince) → `--set` (vince su tutto). In un `helm upgrade` **senza** `--reuse-values`, i valori passati alle revisioni precedenti con `--set` **non** vengono riportati se passi nuovi valori: riparti dai default del chart più ciò che specifichi ora.

### 2.5 Helm in OpenShift (dai docs OCP 4.22)

- CLI: dalla console (icona **?** → *Command Line Tools*) o da `https://mirror.openshift.com/pub/openshift-v4/clients/helm/latest/`.
- Repository Red Hat/partner certificati: `https://charts.openshift.io/` (già configurato nel catalogo della console).
- Repository aggiuntivi: `HelmChartRepository` (cluster, solo admin) e **`ProjectHelmChartRepository`** (nel tuo progetto, per chi ha i permessi sul progetto).
- Console 4.22: *Ecosystem > Helm* (release, repository, creazione da catalogo o **da URL del chart**), supporto ai chart **OCI**; dalla release: *Upgrade*, *Rollback*, *Delete Helm Release*, tab *Revision history*.

> **Nota di versione:** i docs OCP non indicano la versione esatta della CLI Helm distribuita con 4.22. Controlla con `helm version`. I comandi di questo modulo sono validi sia in Helm 3 sia in Helm 4; alcuni flag avanzati sono cambiati in Helm 4 (es. `--atomic`): se ti servono, verifica con `helm upgrade --help`.

---

## 3. Laboratorio guidato

```bash
source env.sh                 # dalla root del repository ex288-teach
helm version                                  # Helm 3.x o 4.x
mkdir -p $EX288_WORK/m10 && cp -r $EX288_HOME/10-helm/lab/* $EX288_WORK/m10/   # lavora su una COPIA del chart
cd $EX288_WORK/m10 && ls                                # hello-chart/  values-prod.yaml
```

### 3.1 Progetto e immagine dell'applicazione

Il chart che scriveremo deploya un'immagine **già esistente** (Helm installa manifest, non costruisce immagini a meno che il chart contenga una BuildConfig). La costruiamo nel registry interno:

```bash
oc new-project ${LAB}-m10 --display-name="EX288 m10 - Helm"
oc import-image nodejs:22-ubi9 --from=registry.access.redhat.com/ubi9/nodejs-22 --confirm
oc new-build "nodejs:22-ubi9~$GIT_REPO" --context-dir=hello-node --name=hello-node
oc logs -f bc/hello-node                      # attendi "Push successful"
oc get istag hello-node:latest
```

Il chart, se `app.image.repository` è vuoto, usa `image-registry.openshift-image-registry.svc:5000/<namespace della release>/hello-node`: funziona in qualunque progetto in cui hai costruito `hello-node`.

### 3.2 Installare un chart esistente da un repository

```bash
# Repository dei chart certificati per OpenShift (esempio della documentazione)
helm repo add openshift-helm-charts https://charts.openshift.io/
helm repo update
helm search repo openshift-helm-charts/redhat-nodejs     # chart Node.js di Red Hat (quello del catalogo della console)

# Prima di installare un chart sconosciuto: metadati e valori disponibili
helm show chart openshift-helm-charts/redhat-nodejs
helm show values openshift-helm-charts/redhat-nodejs > $EX288_WORK/m10/nodejs-values.yaml
grep -n -A3 '^build:' $EX288_WORK/m10/nodejs-values.yaml
```

Il chart `redhat-nodejs` crea ImageStream, BuildConfig S2I, Deployment, Service e Route. Gli diciamo di costruire **la nostra** `hello-node` con il builder importato nel progetto:

```bash
helm install node-demo openshift-helm-charts/redhat-nodejs \
  --set build.uri=$GIT_REPO \
  --set build.ref=$GIT_BRANCH \
  --set build.contextDir=hello-node \
  --set build.source.namespace=${LAB}-m10 \
  --set build.source.name=nodejs:22-ubi9
# NAME: node-demo  STATUS: deployed  REVISION: 1  + NOTES del chart

oc get bc,is,deploy,svc,route            # oggetti creati dal chart (i nomi dipendono dal chart)
oc logs -f bc/<nome-della-bc>            # segui la build S2I; poi il Deployment si aggiorna
```

> **Da verificare sul tuo cluster:** i nomi dei valori (`build.uri`, `build.ref`, `build.contextDir`, `build.source.namespace`, `build.source.name`) sono quelli del chart Node.js di Red Hat descritto su developers.redhat.com, ma possono cambiare tra versioni del chart: confrontali con `helm show values`. Se la tua postazione non raggiunge `charts.openshift.io`, installa lo stesso chart dalla console (*Ecosystem > Helm* → *Create* → *Helm Release*, oppure Developer Catalog → *Helm Charts* → *Node.js*). L'esempio dei docs `openshift-helm-charts/hashicorp-vault` richiede di norma permessi cluster (oggetti RBAC/webhook a livello cluster) e non è adatto a un utente normale.

### 3.3 Ispezionare una release

```bash
helm list                                   # release del namespace corrente: NAME, REVISION, STATUS, CHART, APP VERSION
helm list -A                                # (upstream) tutti i namespace che puoi leggere
helm status node-demo                       # stato + NOTES
helm get values node-demo                   # (upstream) SOLO i valori che hai passato tu
helm get values node-demo --all             # (upstream) valori calcolati completi (default + tuoi)
helm get manifest node-demo | grep '^kind'  # (upstream) i manifest effettivamente applicati
helm history node-demo                      # (upstream) revisioni: per ora solo la 1
helm uninstall node-demo                    # (upstream) rimuove tutti gli oggetti della release
```

### 3.4 Helm nella console e repository di progetto

1. Console → *Ecosystem > Helm* (con la prospettiva Developer: *Helm* nel menu laterale): elenco delle release del progetto, tab *Repositories*.
2. *Create > Helm Release*: catalogo dei chart (form o YAML dei valori). *Create > Helm chart URL* (4.22): installa da un URL `.tgz` o OCI.
3. Aggiungi un repository **solo per il tuo progetto** (il repository di esempio Red Hat citato dai docs):

```bash
oc auth can-i create projecthelmchartrepositories     # serve "yes" (altrimenti chiedi all'amministratore)
oc apply -f - <<'EOF'
apiVersion: helm.openshift.io/v1beta1
kind: ProjectHelmChartRepository
metadata:
  name: redhat-esempi
spec:
  name: Esempi Red Hat
  connectionConfig:
    url: https://redhat-developer.github.io/redhat-helm-charts
EOF
oc get projecthelmchartrepositories
```

Dopo qualche secondo i chart del repository compaiono nel catalogo del progetto. Lo stesso CR esiste a livello cluster (`HelmChartRepository`), ma richiede cluster-admin.

### 3.5 Il nostro chart: `hello-chart`

Apri i file in `$EX288_WORK/m10/hello-chart` e individua:

- in `_helpers.tpl`: `hello-chart.fullname` (nome della release), `hello-chart.selectorLabels` (le label **immutabili** dei selector), `hello-chart.labels` (label standard `helm.sh/chart`, `app.kubernetes.io/*`), `hello-chart.appImage` (immagine con default calcolato);
- in `app-deployment.yaml`: l'annotazione `checksum/config` (hash della ConfigMap: se la configurazione cambia, cambia il pod template e parte un rollout);
- in `route.yaml` e `db-pvc.yaml`: oggetti creati solo con `route.enabled` / `db.persistence.enabled`;
- in `values.schema.json`: tipi e chiavi ammesse sotto `app`.

> **`helm create`** *(upstream)* genera uno scheletro completo (`helm create mio-chart`), ma usa un'immagine di esempio pensata per Kubernetes generico (spesso non compatibile con la SCC `restricted-v2`) e un Ingress: all'esame è spesso più rapido partire da un chart minimo come questo e aggiungere ciò che serve.

### 3.6 Validare e vedere l'anteprima

```bash
helm lint ./hello-chart                                    # errori di struttura, rendering e schema
helm template hello ./hello-chart | less                   # (upstream) render locale: nessun oggetto creato
helm template hello ./hello-chart --set route.enabled=false | grep '^kind'   # niente Route
helm template hello ./hello-chart -f values-prod.yaml | grep -A3 'kind: PersistentVolumeClaim'
helm template hello ./hello-chart --set app.replica=3       # errore dello schema: chiave sconosciuta
```

> **Abitudine da esame:** `helm lint` e `helm template` prima di ogni `install`/`upgrade`. Un errore di indentazione visto in `helm template` costa 10 secondi; visto in un upgrade fallito costa 10 minuti.

### 3.7 Installare il chart con `--set`

```bash
helm install hello ./hello-chart --set app.message="Ciao dalla revisione 1"
helm list                                                  # hello  REVISION 1  deployed  hello-chart-0.1.0
oc get deploy,svc,route,cm,secret -l app.kubernetes.io/instance=hello
oc rollout status deployment/hello-app

H=$(oc get route hello-app -o jsonpath='{.spec.host}')
curl -s https://$H/ ; echo          # "message": "Ciao dalla revisione 1"
curl -s https://$H/config           # ambiente=sviluppo ... release=hello  revisione.helm=1
curl -s https://$H/db               # "db": "raggiungibile"
```

> `--set` interpreta i tipi: interi (`--set app.image.tag=2`), `true`/`false` e `null` diventano numero, booleano e nullo; lo schema rifiuta quindi il tag `2` (`expected string`). Per forzare una stringa usa `--set-string app.image.tag=2` *(upstream)*. Nei file `-f`, invece, è YAML a decidere il tipo: `tag: 1.0` è un numero decimale, `tag: "1.0"` una stringa.

### 3.8 Upgrade: file di valori, `--reuse-values`, `--install`

```bash
# Revisione 2: valori di produzione da file (2 repliche, PVC per il DB, nuova configurazione)
helm upgrade hello ./hello-chart -f values-prod.yaml
helm history hello                       # 1 superseded, 2 deployed
oc get pvc,deploy -l app.kubernetes.io/instance=hello
curl -s https://$H/ ; echo               # "Ciao da PRODUZIONE (Helm)"

# Revisione 3: cambio SOLO le repliche... senza --reuse-values
helm upgrade hello ./hello-chart --set app.replicas=3
helm get values hello                    # solo app.replicas: 3 -> i valori di values-prod.yaml sono persi!
curl -s https://$H/ ; echo               # di nuovo "Ciao da Helm!" e il DB è tornato su emptyDir

# Revisioni 4 e 5: ripristino prod, poi la stessa modifica mantenendo i valori della revisione precedente
helm upgrade hello ./hello-chart -f values-prod.yaml           # ripristina prod
helm upgrade hello ./hello-chart --reuse-values --set app.replicas=3
helm get values hello                    # valori di prod + app.replicas: 3

# Revisione 6 - upgrade --install: installa se la release non esiste, altrimenti aggiorna (utile negli script)
helm upgrade --install hello ./hello-chart --reuse-values
```

> **Attenzione:** passando da `values-prod.yaml` (PVC) a `--set app.replicas=3` senza file, `db.persistence.enabled` torna `false` e Helm **elimina la PVC** creata dal chart: i dati del database sono persi. Per proteggere una risorsa dall'eliminazione Helm offre l'annotazione `helm.sh/resource-policy: keep` *(upstream)*.

### 3.9 Rollback

```bash
helm history hello                       # scegli la revisione a cui tornare, es. 2
helm rollback hello 2                    # (upstream) crea la revisione 7 con il contenuto della 2
helm history hello                       # ultima riga: DESCRIPTION "Rollback to 2"
helm get values hello                    # valori della revisione 2
curl -s https://$H/config                # revisione.helm=2: vedi la nota sotto
```

Il rollback non "cancella" la storia: la revisione 2 viene **ricopiata** come revisione N+1. Helm riapplica il manifest **già renderizzato** e salvato per la revisione 2, senza rielaborare i template: per questo `revisione.helm` (che viene da `{{ .Release.Revision }}`) mostra ancora `2`, mentre `helm history` e la label `version` del Secret della release indicano il nuovo numero. *(Comportamento upstream di Helm 3.)*

> **Da verificare sul tuo cluster:** il file montato dalla ConfigMap si aggiorna dopo qualche decina di secondi (sincronizzazione del kubelet); se `/config` mostra ancora il valore precedente, attendi e ripeti il `curl`. In console: release → *Actions* → *Rollback* → scegli la revisione.

### 3.10 Dove Helm salva lo stato

```bash
oc get secrets -l owner=helm --show-labels
# sh.helm.release.v1.hello.v1 ... name=hello,owner=helm,status=superseded,version=1
# sh.helm.release.v1.hello.v7 ... name=hello,owner=helm,status=deployed,version=7
oc get secret sh.helm.release.v1.hello.v1 -o jsonpath='{.type}{"\n"}'     # helm.sh/release.v1
```

Ogni revisione è un Secret nel namespace della release (manifest renderizzati + valori, compressi). Conseguenze: chi può leggere i Secret del progetto può leggere i valori (anche le password); cancellare il progetto cancella anche la storia; Helm **non** ha un server nel cluster.

### 3.11 Disinstallare

```bash
helm uninstall hello                     # elimina gli oggetti della release e la sua storia
oc get all,cm,secret,pvc -l app.kubernetes.io/instance=hello      # nulla
```

---

## 4. Esercizi

### 4.1 Esercizio guidato — nuovi valori nel chart

Nel tuo `$EX288_WORK/m10/hello-chart`:

1. aggiungi il valore `app.extraEnv` (lista di coppie `name`/`value`, default vuota) e fai in modo che ogni elemento diventi una variabile d'ambiente del container `hello-node`;
2. aggiorna `values.schema.json` perché accetti `extraEnv` (array);
3. porta il chart alla versione `0.2.0`;
4. installa la release `extra` con `APP_COLORE=verde` in `extraEnv` (da un file `$EX288_WORK/m10/values-extra.yaml`) e verifica con `/env`.

<details><summary>Suggerimenti</summary>

- Nel Deployment, dentro `env:`, usa `{{- with .Values.app.extraEnv }}` e `toYaml . | nindent 8`.
- Lo schema ha `additionalProperties: false` sotto `app`: senza modificarlo `helm lint` fallisce.
- `/env` mostra solo le variabili che iniziano con `APP_`.
</details>

<details><summary>Soluzione</summary>

```yaml
# values.yaml, sotto app:
  extraEnv: []
# values.schema.json, in app.properties:
#   "extraEnv": { "type": "array" },
# templates/app-deployment.yaml, dopo l'ultima variabile DB_PASSWORD:
        {{- with .Values.app.extraEnv }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
# Chart.yaml:
version: 0.2.0
# $EX288_WORK/m10/values-extra.yaml
app:
  extraEnv:
  - name: APP_COLORE
    value: verde
```
```bash
helm lint ./hello-chart -f values-extra.yaml
helm template extra ./hello-chart -f values-extra.yaml | grep -B1 -A1 APP_COLORE
helm install extra ./hello-chart -f values-extra.yaml
curl -s https://$(oc get route extra-app -o jsonpath='{.spec.host}')/env      # "APP_COLORE": "verde"
helm uninstall extra
```
</details>

### 4.2 Esercizio semi-guidato — pacchetto e ciclo di vita

1. Crea il pacchetto del chart (`helm package`) e installa la release `pkg` **dal file `.tgz`** con route disabilitata.
2. Abilita la route con un upgrade che conservi gli altri valori.
3. Fai un upgrade che rompe l'app (immagine inesistente) e riporta la release all'ultima revisione funzionante.
4. Mostra con `oc` (senza `helm`) quante revisioni ha la release e qual è quella attiva.

<details><summary>Suggerimenti</summary>

- `helm package ./hello-chart` produce `hello-chart-<version>.tgz` nella cartella corrente.
- `--reuse-values`; per l'immagine `--set-string app.image.tag=...`.
- Label dei Secret di Helm: `owner`, `name`, `status`, `version`.
</details>

<details><summary>Soluzione (aprila solo dopo aver provato)</summary>

```bash
oc project ${LAB}-m10
cd $EX288_WORK/m10

# 1) Pacchetto (upstream) e installazione DAL FILE .tgz con route disabilitata
helm lint ./hello-chart
helm package ./hello-chart
# Successfully packaged chart and saved it to: /Users/<te>/m10/hello-chart-0.2.0.tgz
#   la versione viene da Chart.yaml: 0.2.0 se hai svolto il 4.1, altrimenti 0.1.0
TGZ=$(ls -t hello-chart-*.tgz | head -1)        # il pacchetto più recente
tar -tzf $TGZ | head                            # hello-chart/Chart.yaml, hello-chart/values.yaml, hello-chart/templates/...
helm install pkg $TGZ --set route.enabled=false
# NAME: pkg ... STATUS: deployed  REVISION: 1
# Route disabilitata (route.enabled=false): l'app è raggiungibile solo dal cluster sul Service pkg-app:8080.
oc get route -l app.kubernetes.io/instance=pkg  # No resources found
oc rollout status deployment/pkg-app

# 2) Route abilitata conservando i valori delle revisioni precedenti (upstream: --reuse-values)
helm upgrade pkg $TGZ --reuse-values --set route.enabled=true
helm get values pkg
# USER-SUPPLIED VALUES:
# route:
#   enabled: true
H=$(oc get route pkg-app -o jsonpath='{.spec.host}')
curl -s https://$H/ ; echo                      # "message": "Ciao da Helm!"

# 3) Upgrade che rompe l'app: tag inesistente (--set-string: lo schema vuole una stringa)
#    --wait fa attendere a Helm che i pod siano pronti: senza, l'upgrade risulterebbe "deployed"
helm upgrade pkg $TGZ --reuse-values --set-string app.image.tag=non-esiste --wait --timeout 90s
# Error: UPGRADE FAILED: ... context deadline exceeded
oc get pods -l app.kubernetes.io/instance=pkg,app.kubernetes.io/component=app
# pkg-app-<nuovo>     0/1   ImagePullBackOff    <- la nuova versione non parte
# pkg-app-<vecchio>   1/1   Running             <- il vecchio pod serve ancora il traffico
helm history pkg                                # (colonne abbreviate)
# REVISION  STATUS      CHART              DESCRIPTION
# 1         superseded  hello-chart-0.2.0  Install complete
# 2         deployed    hello-chart-0.2.0  Upgrade complete
# 3         failed      hello-chart-0.2.0  Upgrade "pkg" failed: context deadline exceeded
helm rollback pkg 2                             # (upstream) 2 = ultima revisione funzionante
# Rollback was a success! Happy Helming!
helm history pkg
# ...
# 3         failed      hello-chart-0.2.0  Upgrade "pkg" failed: context deadline exceeded
# 4         deployed    hello-chart-0.2.0  Rollback to 2
oc rollout status deployment/pkg-app
oc get deploy pkg-app -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'   # .../hello-node:latest
helm get values pkg                             # route.enabled: true (i valori della revisione 2)
curl -s https://$H/config | grep revisione      # revisione.helm=2: il manifest è quello salvato per la 2

# 4) Solo oc: ogni revisione è un Secret con le label owner/name/status/version
oc get secret -l owner=helm,name=pkg -L version,status
# NAME                        TYPE                 DATA   AGE   VERSION   STATUS
# sh.helm.release.v1.pkg.v1   helm.sh/release.v1   1      12m   1         superseded
# sh.helm.release.v1.pkg.v2   helm.sh/release.v1   1      10m   2         superseded
# sh.helm.release.v1.pkg.v3   helm.sh/release.v1   1      6m    3         failed
# sh.helm.release.v1.pkg.v4   helm.sh/release.v1   1      2m    4         deployed
oc get secret -l owner=helm,name=pkg -o name | wc -l               # 4 revisioni
oc get secret -l owner=helm,name=pkg,status=deployed -L version    # quella attiva: VERSION 4
```

**Perché il `.tgz`:** `helm package` (upstream) crea un archivio versionato (nome e versione da `Chart.yaml`, file esclusi secondo `.helmignore`) che si installa come una cartella o un chart di repository. È il formato che pubblicheresti in un repository o installeresti dalla console con *Helm chart URL*.

**Perché `--reuse-values`:** senza, `helm upgrade` riparte dai default del chart più i valori della riga di comando (sezione 2.4). Qui il solo valore precedente è `route.enabled=false`, ma con più valori impostati all'install perderli sarebbe un errore silenzioso. `--set-string` forza il tipo stringa: con un tag numerico (`--set app.image.tag=2`) lo schema rifiuterebbe il valore.

**Perché il rollback crea la revisione 4:** Helm non cancella la storia; ricopia il manifest e i valori della revisione 2 in una **nuova** revisione (`Rollback to 2`) e la applica. Per questo `revisione.helm` nella ConfigMap resta `2` (il manifest non viene renderizzato di nuovo) mentre `helm history` e la label `version` del Secret dicono 4. La revisione `failed` resta visibile come traccia.

> **Da verificare sul tuo cluster:** lo stato della revisione 2 dopo l'upgrade fallito (`deployed` in Helm 3; poi `superseded` dopo il rollback), i testi di errore e il comportamento di `--wait` dipendono dalla versione della CLI (`helm version`; in Helm 4 controlla `helm upgrade --help`). Senza `--wait` la revisione 3 risulta `deployed` anche se il pod è in `ImagePullBackOff`: la revisione buona a cui tornare è comunque la 2. Controlla sempre con `helm history pkg` e `oc get secret -l owner=helm,name=pkg -L version,status`.
</details>

### 4.3 Esercizio senza aiuti

Aggiungi al chart un valore `db.enabled` (default `true`): con `false` il chart non deve creare né il database né il suo Secret/Service/PVC, e l'app deve ricevere `DB_HOST` da un valore `db.externalHost`. Dimostra entrambi i casi con `helm template` e installa una release `nodb` con `db.enabled=false` verificando che `/db` risponda `NON raggiungibile` senza errori di rendering.

---

## 5. Verifiche pratiche con `oc` (e `helm`)

| Domanda | Comando |
|---|---|
| Quali release ci sono nel progetto? | `helm list` · senza helm: `oc get secrets -l owner=helm,status=deployed` |
| Quale revisione è attiva? Cosa è cambiato? | `helm history <rel>` |
| Con quali valori è stata installata? | `helm get values <rel>` (`--all` per quelli calcolati, `--revision N` per una revisione) |
| Cosa ha creato la release? | `helm get manifest <rel>` · `oc get all,cm,secret,route -l app.kubernetes.io/instance=<rel>` |
| A quale release appartiene un oggetto? | `oc get <obj> -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-name}'` |
| Il chart è valido? Cosa produrrebbe? | `helm lint <chart>` · `helm template <rel> <chart> -f ... --set ...` |
| Quali chart offre un repository? | `helm search repo <repo>/` · `helm show values <repo>/<chart>` |
| Repository di progetto configurati? | `oc get projecthelmchartrepositories` |

---

## 6. Troubleshooting intenzionale

```bash
oc project ${LAB}-m10
TS=$EX288_HOME/10-helm/troubleshooting
cd $EX288_WORK/m10
```

### Scenario 1 — il chart non si renderizza

**Riproduci:** `cp -r $TS/rotto-1-render $EX288_WORK/m10/ && helm install render ./rotto-1-render`
**Sintomo:** `Error: INSTALLATION FAILED: template: render-rotto/templates/deployment.yaml:...: nil pointer evaluating interface {}.limits`. Dopo averlo sistemato, compare un secondo errore: `YAML parse error on render-rotto/templates/deployment.yaml: error converting YAML to JSON: ...`.

<details><summary>Indagine e soluzione</summary>

```bash
helm template render ./rotto-1-render                 # stesso errore, senza toccare il cluster
grep -n -A3 '^app:' ./rotto-1-render/values.yaml      # app.resources non esiste
helm template render ./rotto-1-render --debug         # mostra il YAML generato anche se non valido
```
**Causa 1:** `.Values.app.resources.limits.memory` attraversa una chiave che non esiste (`resources` è nil).
**Fix 1:** aggiungi `resources: {limits: {memory: 256Mi}}` sotto `app` in `values.yaml`, oppure proteggi il blocco con `{{- with .Values.app.resources }}...{{- end }}`.
**Causa 2:** `{{ toYaml .Values.labels | indent 4 }}` su una riga già indentata: la prima label finisce a 6 spazi, le altre a 4.
**Fix 2:** `{{- toYaml .Values.labels | nindent 4 }}` (il trattino elimina l'indentazione della riga, `nindent` va a capo e indenta tutte le righe).
**Lezione:** `helm template --debug` e lettura del numero di riga; `nindent` con `{{-` è lo schema giusto per inserire blocchi YAML.
</details>

### Scenario 2 — valori con errori di battitura

**Riproduci:** `helm install valori ./hello-chart -f $TS/rotto-2-valori.yaml`
**Sintomo:** `Error: INSTALLATION FAILED: values don't meet the specifications of the schema(s)...` con due righe d'errore.

<details><summary>Indagine e soluzione</summary>

```bash
helm lint ./hello-chart -f $TS/rotto-2-valori.yaml
# app: Additional property replica is not allowed
# route.enabled: Invalid type. Expected: boolean, given: string
```
**Causa:** `app.replica` invece di `app.replicas`; `route.enabled: "no"` è una stringa. **Senza schema** il primo errore passerebbe in silenzio (repliche al default) e il secondo creerebbe comunque la Route, perché in un `if` di Go ogni stringa non vuota è "vera".
**Fix:** in una tua copia del file: `replicas: 3` e `enabled: false` (senza virgolette), poi reinstalla.
**Lezione:** un `values.schema.json` trasforma errori silenziosi in errori espliciti. Controlla sempre con `helm get values` cosa è arrivato davvero.
</details>

### Scenario 3 — nome di release già in uso

**Riproduci:** `helm install doppia ./hello-chart && helm install doppia ./hello-chart --set app.replicas=2`
**Sintomo:** `Error: INSTALLATION FAILED: cannot re-use a name that is still in use`.

<details><summary>Indagine e soluzione</summary>

```bash
helm list -a              # -a include anche release fallite o in corso
```
**Causa:** una release con lo stesso nome esiste già nel namespace.
**Fix:** per modificarla `helm upgrade doppia ./hello-chart --set app.replicas=2` (o `helm upgrade --install` negli script); per una seconda istanza scegli un altro nome.
**Lezione:** `install` crea, `upgrade` modifica: il nome della release identifica l'istanza nel namespace. Pulizia: `helm uninstall doppia`.
</details>

### Scenario 4 — upgrade bloccato da un campo immutabile

**Riproduci:** `helm install sel ./hello-chart && helm upgrade sel $TS/rotto-4-chart-rinominato`
**Sintomo:** `Error: UPGRADE FAILED: ... Deployment.apps "sel-app" is invalid: spec.selector: Invalid value: ...: field is immutable`; `helm history sel` mostra la revisione 2 `failed`.

<details><summary>Indagine e soluzione</summary>

```bash
diff <(helm template sel ./hello-chart | grep -A4 matchLabels) \
     <(helm template sel $TS/rotto-4-chart-rinominato | grep -A4 matchLabels)
# app.kubernetes.io/name: hello-chart  ->  hello-app
```
**Causa:** il nuovo chart si chiama `hello-app`; il selector usa `.Chart.Name`, quindi cambia, ma `spec.selector` di un Deployment non si può modificare.
**Fix:** se il cambio è voluto, ricrea gli oggetti: `helm uninstall sel && helm install sel $TS/rotto-4-chart-rinominato` (accettando il disservizio), oppure elimina solo i Deployment (`oc delete deploy sel-app sel-db`) e ripeti l'upgrade. Se non è voluto, `helm rollback sel 1` e non rinominare il chart (o rendi fisse le label di selezione).
**Lezione:** le label dei selector vanno decise alla prima versione e non toccate più; non metterci versione, chart o valori che cambiano.
</details>

### Scenario 5 — risorsa creata a mano in conflitto

**Riproduci:** `oc apply -f $TS/rotto-5-configmap-manuale.yaml && helm install conflitto ./hello-chart`
**Sintomo:** `Error: INSTALLATION FAILED: Unable to continue with install: ConfigMap "conflitto-config" in namespace "..." exists and cannot be imported into the current release: invalid ownership metadata; label validation error: missing key "app.kubernetes.io/managed-by": must be set to "Helm"; annotation validation error: missing key "meta.helm.sh/release-name"...`

<details><summary>Indagine e soluzione</summary>

```bash
oc get cm conflitto-config --show-labels                          # creata-da=mano, nessuna label Helm
oc get cm conflitto-config -o jsonpath='{.metadata.annotations}'  # nessuna meta.helm.sh/*
```
**Causa:** Helm si rifiuta di "rubare" un oggetto esistente che non appartiene alla release.
**Fix A (eliminarla):** `oc delete cm conflitto-config && helm install conflitto ./hello-chart`.
**Fix B (adottarla):** `oc label cm conflitto-config app.kubernetes.io/managed-by=Helm` e `oc annotate cm conflitto-config meta.helm.sh/release-name=conflitto meta.helm.sh/release-namespace=${LAB}-m10`, poi `helm install`: la ConfigMap viene presa in carico e sovrascritta.
**Lezione:** non mescolare oggetti creati a mano e oggetti di una release con lo stesso nome.

> **Da verificare sul tuo cluster:** il testo esatto dell'errore cambia tra Helm 3 e Helm 4 (che applica i manifest in modo diverso); la causa e le due soluzioni restano le stesse.
</details>

### Scenario 6 — release in stato `failed` (e `pending-upgrade`)

**Riproduci:** con la release `hello` installata (se l'hai rimossa al passo 3.11: `helm install hello ./hello-chart`): `helm upgrade hello ./hello-chart --reuse-values --set-string app.image.tag=non-esiste --wait --timeout 90s`
**Sintomo:** dopo 90 secondi `Error: UPGRADE FAILED: ... context deadline exceeded`; `helm list` mostra `STATUS failed`; il nuovo pod è in `ImagePullBackOff` mentre i vecchi pod continuano a servire.

<details><summary>Indagine e soluzione</summary>

```bash
helm history hello                          # ultima revisione: failed
oc get pods -l app.kubernetes.io/component=app
oc describe pod -l app.kubernetes.io/component=app | grep -A3 Events
```
**Causa:** `--wait` aspetta che gli oggetti siano pronti; l'immagine non esiste, il timeout scade e Helm marca la revisione come `failed` (gli oggetti restano come applicati).
**Fix:** `helm rollback hello <ultima revisione deployed>` oppure un nuovo `helm upgrade` con valori corretti (da una revisione `failed` si può fare upgrade).
**Variante `pending-upgrade`:** se interrompi `helm upgrade --wait` con Ctrl+C, la release può restare `pending-upgrade` e ogni nuovo comando risponde `another operation (install/upgrade/rollback) is in progress`. Soluzione: `helm rollback hello <revisione buona>`; come ultima risorsa elimina il Secret della revisione bloccata (`oc delete secret sh.helm.release.v1.hello.v<N>`).
**Lezione:** usa `--wait` per sapere se l'upgrade ha davvero funzionato e tieni sempre a portata di mano `helm history`.
</details>

Pulizia: `helm uninstall render valori sel conflitto hello 2>/dev/null; oc delete project ${LAB}-m10`

---

## 7. Esercizio finale (stile EX288)

> Lavora come all'esame: niente soluzioni, solo documentazione (docs OpenShift e https://helm.sh/docs/), `--help` e `oc explain`. Tempo indicativo: **60 minuti**.

**Requisiti**

1. Esiste il progetto `${LAB}-m10-exam`, nel quale l'image stream tag `hello-node:latest` contiene l'applicazione `hello-node` costruita dal tuo `$GIT_REPO`.
2. Nella cartella `$EX288_WORK/m10-exam/catalog` esiste un chart Helm con `apiVersion: v2`, nome **`catalog`**, versione **`1.2.0`** e appVersion **`2.0.0`**; `helm lint` non riporta errori.
3. Il chart espone almeno questi valori, con questi default:

   | Valore | Default |
   |---|---|
   | `web.replicas` | `1` |
   | `web.message` | `Catalogo` |
   | `route.enabled` | `true` |
   | `config.mode` | `standard` |
   | `db.user` | `catalog` |
   | `db.database` | `catalogdb` |
   | `db.password` | un valore a tua scelta |

4. Per una release `<R>` il chart crea:
   - Deployment `<R>-web`: container `web` con l'immagine `hello-node` del registry interno del progetto, repliche da `web.replicas`, `APP_MESSAGE` da `web.message`, readiness su `/ready`, liveness su `/healthz`, variabili `DB_HOST`/`DB_PORT`/`DB_NAME`/`DB_USER`/`DB_PASSWORD` per il database;
   - Service `<R>-web` (porta 8080) e, **solo se `route.enabled` è true**, Route `<R>-web` con terminazione edge;
   - Secret `<R>-db` con chiavi `database-user`, `database-password`, `database-name`;
   - ConfigMap `<R>-config` con chiave `app.properties` contenente `catalog.mode=<config.mode>`, montata in `/etc/app`;
   - Deployment `<R>-db` (`registry.redhat.io/rhel9/postgresql-16`, dati su `emptyDir` in `/var/lib/pgsql/data`) e Service `<R>-db` (porta 5432);
   - su tutti gli oggetti le label `helm.sh/chart`, `app.kubernetes.io/instance`, `app.kubernetes.io/version`, `app.kubernetes.io/managed-by`.
5. Nel progetto `${LAB}-m10-exam` la release **`shop`** ha esattamente questa storia:
   - revisione 1: installazione con `web.message=Benvenuti` e `web.replicas=2`;
   - revisione 2: upgrade con un file `$EX288_WORK/m10-exam/values-saldi.yaml` che imposta `web.message=Saldi di fine stagione`, `web.replicas=3`, `config.mode=saldi`;
   - revisione 3: upgrade che, mantenendo i valori della revisione 2, disabilita la route;
   - revisione 4: la release torna allo stato della revisione 2.

**Risultato atteso**

- `helm history shop` mostra 4 revisioni; la 4 è `deployed` con descrizione `Rollback to 2`.
- `https://<route shop-web>/` restituisce `"message": "Saldi di fine stagione"`; `/config` contiene `catalog.mode=saldi`; `/db` risponde `raggiungibile`.
- Il Deployment `shop-web` ha 3 repliche pronte.

```bash
bash $EX288_HOME/10-helm/verifica.sh
# se il chart è in un'altra cartella: CHART_DIR=/percorso/catalog bash $EX288_HOME/10-helm/verifica.sh
```

---

## 8. Riferimenti ufficiali

- OCP 4.22 Building applications → *Working with Helm charts* (CLI, `helm repo add`, `helm install`, `helm lint`, ProjectHelmChartRepository, console: upgrade/rollback/delete, chart OCI e installazione da URL): https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/building_applications/working-with-helm-charts
- OCP 4.22 CLI tools → *Helm CLI* (download dal mirror): https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/cli_tools
- Red Hat Developer → *Deploy Node.js applications to Red Hat OpenShift with Helm* (chart Node.js del catalogo, valori `build.*`): https://developers.redhat.com/articles/2021/07/20/deploy-nodejs-applications-red-hat-openshift-helm
- Repository di esempio Red Hat citato dai docs: https://github.com/redhat-developer/redhat-helm-charts
- Progetto Helm (upstream, NON docs OCP): comandi https://helm.sh/docs/helm/ · guida ai template https://helm.sh/docs/chart_template_guide/ · schema dei valori https://helm.sh/docs/topics/charts/#schema-files
