# Modulo 11 — Kustomize: personalizzare i deployment per più ambienti

> **Obiettivi EX288 coperti**
> - *Deploy multi-container applications* → Customizing deployments with Kustomize
>
> **Durata stimata:** 4 ore · **Prerequisiti:** moduli 01-10 (in particolare 04 image stream e 07 ConfigMap/Secret) · **Richiede cluster-admin:** no
>
> **Progetti usati:** `${LAB}-m11-dev`, `${LAB}-m11-prod`, `${LAB}-m11-exam`

---

## 1. Perché e quando

**Kustomize** personalizza manifest Kubernetes **senza template**: parti da una **base** di YAML normali e, per ogni ambiente, scrivi un **overlay** che dichiara solo le differenze (namespace, prefissi, label, repliche, immagini, patch, configurazione generata). Il risultato è sempre YAML puro, leggibile e applicabile. È integrato in `oc`: `oc kustomize <dir>` mostra il risultato, `oc apply -k <dir>` lo applica.

**Template, Helm o Kustomize?** (stessa tabella dei moduli 09 e 10)

| Criterio | Template OpenShift (modulo 09) | Helm (modulo 10) | Kustomize (modulo 11) |
|---|---|---|---|
| Dove funziona | Solo OpenShift | Qualsiasi Kubernetes; può includere oggetti OpenShift | Qualsiasi Kubernetes; integrato in `oc` |
| Come personalizzi | Parametri `${X}` | Valori + template Go | Overlay e patch su YAML puro, nessuna variabile |
| Logica condizionale | No | Sì | No (overlay/componenti diversi) |
| Valori generati | Sì, `generate: expression` | Sì (funzioni) | No (Secret da file o letterali) |
| Ciclo di vita | Nessuno | Release con revisioni, rollback | Nessuno: `oc apply -k` / `oc delete -k` (la storia la tiene Git) |
| Distribuzione | Oggetto Template | Repository di chart | Directory in Git (anche base remote) |
| Scegli quando... | Form di parametri per un'app OpenShift | Pacchetto versionato con upgrade/rollback | Stessa app in più ambienti con piccole differenze, GitOps |

**Usa Kustomize quando:** hai già manifest funzionanti e vuoi varianti per dev/test/prod senza duplicarli; vuoi che chi legge veda YAML vero e non template; lavori in GitOps (Argo CD/OpenShift GitOps usano Kustomize nativamente); vuoi che una modifica di configurazione provochi un rollout automatico (generatori con hash).
**Evitalo quando:** servono condizioni complesse o un pacchetto da distribuire a terzi con valori documentati (Helm), oppure un form self-service nel catalogo (Template).

> **Fonti:** la documentazione OpenShift 4.22 non ha un capitolo su Kustomize: riporta solo i comandi `oc apply -k`, `oc get -k`, `oc kustomize <dir>` (anche con URL Git). Il formato di `kustomization.yaml` (resources, namespace, namePrefix, labels, images, replicas, patches, generatori, componenti) è documentato dal **progetto Kubernetes upstream**: https://kubectl.docs.kubernetes.io/references/kustomize/ e https://kubernetes.io/docs/tasks/manage-kubernetes-objects/kustomization/. In questo modulo i campi upstream sono segnalati con *(upstream)*.

---

## 2. Concetti essenziali

### 2.1 Base, overlay, componenti

```
lab/
├── base/                       # manifest comuni + kustomization.yaml (nessun namespace)
│   ├── kustomization.yaml
│   ├── app-deployment.yaml  app-service.yaml  app-route.yaml
│   ├── db-deployment.yaml   db-service.yaml
│   └── app.properties          # sorgente della ConfigMap generata
└── overlays/
    ├── dev/kustomization.yaml  # resources: [../../base] + differenze per dev
    └── prod/kustomization.yaml + app.properties + patch-risorse.yaml
```

- **Base:** una kustomization riutilizzabile. Non sa in che ambiente finirà.
- **Overlay:** una kustomization che include la base in `resources` e aggiunge trasformazioni.
- **Componente** *(upstream)*: `kind: Component`, un pezzo opzionale (es. "persistenza") che più overlay includono con `components:`.

### 2.2 Il file `kustomization.yaml` *(upstream)*

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:              # file YAML o directory con un kustomization.yaml (anche URL Git)
- ../../base
namespace: mio-progetto # imposta metadata.namespace su tutte le risorse
namePrefix: dev-        # dev-<nome> (nameSuffix: -<suffisso>)
labels:                 # label su tutte le risorse
- pairs:
    env: dev
  includeSelectors: false   # true = anche selector e template dei pod (immutabili!)
replicas:               # repliche per nome di Deployment
- name: hello-node
  count: 3
images:                 # cambia nome/tag delle immagini per nome
- name: hello-node
  newName: image-registry.openshift-image-registry.svc:5000/progetto/hello-node   # opzionale
  newTag: "1.0"
configMapGenerator:     # genera ConfigMap con suffisso hash (files, literals, envs)
- name: app-config
  files: [app.properties]
secretGenerator:        # idem per i Secret
- name: db-credentials
  literals: [database-password=s3greta]
generatorOptions:
  disableNameSuffixHash: true   # niente hash (sconsigliato: perdi il rollout automatico)
patches:                # strategic merge (file con apiVersion/kind/name) o JSON 6902 (con target)
- path: patch-risorse.yaml
- target: {kind: Route, name: hello-node}
  patch: |-
    - op: replace
      path: /spec/to/name
      value: dev-hello-node
```

> **Nota di versione:** `commonLabels`, `patchesStrategicMerge` e `patchesJson6902` sono **deprecati** in Kustomize v5 a favore di `labels` e `patches`. Funzionano ancora (con un avviso), ma `commonLabels` modifica sempre anche i selector. `oc` 4.22 include Kustomize v5. **Da verificare sul tuo cluster:** `oc kustomize --help`; se hai `kubectl`, `kubectl version --client` mostra la versione di Kustomize.

### 2.3 Generatori e hash: perché sono importanti

`configMapGenerator` crea `app-config-<hash>`, dove l'hash dipende dal **contenuto**. Kustomize riscrive i riferimenti (`volumes[].configMap.name`, `envFrom`, `secretKeyRef`...) nelle risorse **della stessa build**. Quindi cambiare `app.properties` cambia il nome della ConfigMap, cambia il pod template e il Deployment fa **rollout automatico**: niente `oc rollout restart` dimenticati.

### 2.4 Cosa Kustomize NON riscrive

Kustomize aggiorna i riferimenti per nome solo nei campi che conosce (tipi Kubernetes standard). Con `namePrefix`/`nameSuffix`:

| Riferimento | Aggiornato? |
|---|---|
| ConfigMap/Secret in `volumes`, `envFrom`, `valueFrom` | Sì |
| `spec.to.name` di una **Route** (risorsa OpenShift) | **No**: serve una patch |
| Valori di variabili d'ambiente (es. `DB_HOST=postgresql`) | **No**: sono stringhe |
| Selector e label | Non sono nomi: non cambiano con il prefisso |

---

## 3. Laboratorio guidato

```bash
source env.sh                 # dalla root del repository ex288-teach
```

### 3.1 Progetti, immagine e copia di lavoro

```bash
# Progetto dev: costruiamo l'immagine qui
oc new-project ${LAB}-m11-dev --display-name="EX288 m11 - dev"
oc import-image nodejs:22-ubi9 --from=registry.access.redhat.com/ubi9/nodejs-22 --confirm
oc new-build "nodejs:22-ubi9~$GIT_REPO" --context-dir=hello-node --name=hello-node
oc logs -f bc/hello-node
oc set image-lookup hello-node          # "hello-node:latest" nei Deployment = questo image stream (modulo 04)

# Progetto prod: promuoviamo la STESSA immagine con il tag 1.0 (niente nuova build)
oc new-project ${LAB}-m11-prod --display-name="EX288 m11 - prod"
oc policy add-role-to-group system:image-puller system:serviceaccounts:${LAB}-m11-prod -n ${LAB}-m11-dev
oc tag ${LAB}-m11-dev/hello-node:latest ${LAB}-m11-prod/hello-node:1.0
oc set image-lookup hello-node -n ${LAB}-m11-prod

# Copia di lavoro e nome dei tuoi progetti negli overlay (Kustomize non legge variabili d'ambiente)
mkdir -p $EX288_WORK/m11 && cp -r $EX288_HOME/11-kustomize/lab/* $EX288_WORK/m11/
cd $EX288_WORK/m11
sed -i.bak "s/CAMBIAMI/${LAB}/" overlays/dev/kustomization.yaml overlays/prod/kustomization.yaml
rm -f overlays/*/kustomization.yaml.bak               # sed -i.bak funziona sia su Linux sia su macOS
grep -n '^namespace' overlays/*/kustomization.yaml
```

### 3.2 La base

```bash
oc kustomize base | less
oc kustomize base | grep -E '^kind|^  name:'
# kind: ConfigMap  name: app-config-<hash>    <- generate, con suffisso hash
# kind: ConfigMap  name: app-env-<hash>
# kind: Secret     name: db-credentials-<hash>
# kind: Service / Deployment / Route ...
oc kustomize base | grep -B2 -A2 'part-of'     # label in metadata, selector e template dei pod
```

La base si potrebbe applicare così com'è (`oc apply -k base -n <progetto>`), ma non contiene ambienti: è il punto di partenza degli overlay.

### 3.3 Overlay dev: namespace, prefisso, merge dei generatori, patch con target

```bash
oc kustomize overlays/dev | grep -E '^kind|^  name:|^  namespace:'
# tutti i nomi iniziano con dev-, namespace ${LAB}-m11-dev

# La Route: senza la patch punterebbe a "hello-node" (Service che non esiste più)
oc kustomize overlays/dev | grep -A20 'kind: Route' | grep -A2 '  to:'
# Prova: commenta il blocco "patches" in overlays/dev/kustomization.yaml, ripeti il comando, poi ripristinalo

# DB_HOST arriva dalla ConfigMap app-env (merge sul generatore della base)
oc kustomize overlays/dev | grep -B6 -A1 'name: dev-app-env-'    # nel risultato "data" precede "metadata"

oc apply -k overlays/dev                      # crea tutto nel namespace indicato nell'overlay
oc get deploy,svc,route,cm,secret -n ${LAB}-m11-dev -l app.kubernetes.io/part-of=hello-kustomize
oc rollout status deployment/dev-hello-node -n ${LAB}-m11-dev

H=$(oc get route dev-hello-node -n ${LAB}-m11-dev -o jsonpath='{.spec.host}')
curl -s https://$H/ ; echo        # "Ciao da DEV (Kustomize)"
curl -s https://$H/db             # "raggiungibile", host dev-postgresql
```

### 3.4 Overlay prod: repliche, immagine, generatori, patch strategic merge

```bash
# Le differenze tra ambienti, in un colpo d'occhio
diff <(oc kustomize overlays/dev) <(oc kustomize overlays/prod) | less

oc kustomize overlays/prod | grep -E 'replicas:|image:|memory:|cpu:'
# replicas: 3, image: hello-node:1.0, limiti dalla patch

oc apply -k overlays/prod
oc get deploy -n ${LAB}-m11-prod                   # hello-node 3/3, postgresql 1/1 (nessun prefisso)
H=$(oc get route hello-node -n ${LAB}-m11-prod -o jsonpath='{.spec.host}')
curl -s https://$H/ ; echo                          # "Ciao da PROD (Kustomize)"
curl -s https://$H/config                           # ambiente=produzione ... livello.log=warn
oc extract secret/$(oc get secret -n ${LAB}-m11-prod -o name | grep db-credentials | cut -d/ -f2) \
  -n ${LAB}-m11-prod --keys=database-password --to=-   # prod-S3greta-2026
```

### 3.5 Cambiare la configurazione: hash nuovo, rollout automatico

```bash
echo "manutenzione=false" >> overlays/prod/app.properties

oc diff -k overlays/prod          # mostra: nuova ConfigMap app-config-<nuovo hash> e il Deployment che la referenzia
oc apply -k overlays/prod
oc rollout status deployment/hello-node -n ${LAB}-m11-prod      # nuovi pod: rollout partito da solo
curl -s https://$H/config                                        # c'è manutenzione=false

oc get cm -n ${LAB}-m11-prod | grep app-config                   # la vecchia ConfigMap è ancora lì
```

> `oc apply -k` non elimina gli oggetti che non sono più nell'output (le ConfigMap con il vecchio hash restano). Puliscile a mano quando non servono più (`oc delete cm <vecchio-nome>`); utile per tornare indietro rapidamente nel frattempo.

### 3.6 `disableNameSuffixHash`: cosa perdi

```bash
cat >> overlays/dev/kustomization.yaml <<'EOF'
generatorOptions:
  disableNameSuffixHash: true
EOF
oc kustomize overlays/dev | grep -E '^  name: dev-(app|db)'     # dev-app-config, dev-app-env... senza hash
oc apply -k overlays/dev
# Ora cambia un valore di app-env e riapplica: la ConfigMap cambia, ma il Deployment NO
# (il pod template è identico): serve oc rollout restart. Per questo l'hash è il default.
sed -i.bak '/^generatorOptions:/,$d' overlays/dev/kustomization.yaml && rm -f overlays/dev/kustomization.yaml.bak
```

### 3.7 Componenti (cenno) *(upstream)*

Un componente è un "pezzo" opzionale riutilizzabile da più overlay:

```yaml
# components/debug/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1alpha1
kind: Component
patches:
- target: {kind: Deployment, name: hello-node}
  patch: |-
    - op: add
      path: /spec/template/spec/containers/0/env/-
      value: {name: APP_DEBUG, value: "true"}
```

```yaml
# in overlays/dev/kustomization.yaml
components:
- ../../components/debug
```

Usali quando una funzionalità serve ad alcuni ambienti ma non a tutti (in Helm useresti un `if`).

### 3.8 Altri comandi utili

```bash
oc get -k overlays/prod                  # stato degli oggetti descritti dall'overlay
oc kustomize overlays/prod > prod.yaml   # "congela" il risultato (es. per allegarlo a una richiesta di change)
oc delete -k overlays/dev                # elimina gli oggetti descritti (non le vecchie ConfigMap con hash diverso)
```

---

## 4. Esercizi

### 4.1 Esercizio guidato — overlay `test` nel progetto dev

Crea `$EX288_WORK/m11/overlays/test` che, nel progetto `${LAB}-m11-dev` e **accanto** a dev, distribuisce l'app con:

1. suffisso `-test` su tutti i nomi;
2. label `env=test` su tutte le risorse (non sui selector);
3. 2 repliche dell'app e messaggio `Ciao da TEST`;
4. Route e `DB_HOST` funzionanti.

<details><summary>Suggerimenti</summary>

- Parti da una copia di `overlays/dev/kustomization.yaml`: cambia `namePrefix` in `nameSuffix`.
- I nomi diventano `hello-node-test`, `postgresql-test`: aggiorna la patch della Route e `DB_HOST`.
- `replicas` usa il nome della base.
- Controlla sempre con `oc kustomize overlays/test` prima di applicare.
</details>

<details><summary>Soluzione</summary>

```yaml
# $EX288_WORK/m11/overlays/test/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
- ../../base
namespace: <il-tuo-LAB>-m11-dev
nameSuffix: -test
labels:
- pairs:
    env: test
  includeSelectors: false
replicas:
- name: hello-node
  count: 2
configMapGenerator:
- name: app-env
  behavior: merge
  literals:
  - APP_MESSAGE=Ciao da TEST
  - DB_HOST=postgresql-test
patches:
- target:
    kind: Route
    name: hello-node
  patch: |-
    - op: replace
      path: /spec/to/name
      value: hello-node-test
```
```bash
oc kustomize overlays/test | grep -E '^  name:|replicas'
oc apply -k overlays/test
curl -s https://$(oc get route hello-node-test -n ${LAB}-m11-dev -o jsonpath='{.spec.host}')/db
```
Perché dev e test convivono nello stesso progetto? Nomi diversi (prefisso/suffisso). Ma attenzione: i **selector** sono uguali (`app: hello-node` + `part-of`), quindi il Service `dev-hello-node` seleziona anche i pod di test! Verifica con `oc get endpointslices -l kubernetes.io/service-name=dev-hello-node -n ${LAB}-m11-dev`; lo stesso vale per `dev-postgresql`, che seleziona anche il database di test (con un'altra password). La soluzione corretta è aggiungere ai **selector** una label diversa per ogni variante (`includeSelectors: true` con `variante: test`) **prima** del primo deploy, oppure usare progetti separati.
</details>

### 4.2 Esercizio semi-guidato — componente "persistenza"

Crea il componente `$EX288_WORK/m11/components/persistenza` che aggiunge una PVC `postgresql-data` (1Gi) e sostituisce l'`emptyDir` del database con quella PVC. Includilo **solo** nell'overlay prod e riapplica.

<details><summary>Suggerimenti</summary>

- `kind: Component` con `apiVersion: kustomize.config.k8s.io/v1alpha1`; può avere `resources` (la PVC) e `patches`.
- Patch JSON 6902 sul Deployment `postgresql`: `op: replace` su `/spec/template/spec/volumes/0` con un volume `persistentVolumeClaim`.
- Il nome della PVC riceve prefisso/namespace dell'overlay; il riferimento `claimName` viene aggiornato da Kustomize.
- Il database perde i dati di prima (erano su `emptyDir`): normale.
</details>

<details><summary>Soluzione (aprila solo dopo aver provato)</summary>

Prima controlla nella base com'è fatto il volume da sostituire: il Deployment si chiama `postgresql` e ha **un solo** volume, `data`, in posizione `0`.

```bash
cd "$EX288_WORK/m11"
grep -n -A3 'volumes:' base/db-deployment.yaml
#   volumes:
#   - name: data
#     emptyDir: {}
oc kustomize overlays/prod | grep -n 'emptyDir'     # oggi prod usa ancora emptyDir
oc get storageclass                                  # serve una StorageClass "(default)" per la PVC senza storageClassName
mkdir -p "$EX288_WORK/m11/components/persistenza"
```

```yaml
# $EX288_WORK/m11/components/persistenza/pvc.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgresql-data          # nome "di base": l'overlay aggiunge namespace (ed eventuale prefisso)
  labels:
    app: postgresql
spec:
  accessModes:
  - ReadWriteOnce                # un solo nodo alla volta: va bene per un database con 1 replica
  resources:
    requests:
      storage: 1Gi
  # nessuna storageClassName: usa la StorageClass di default del cluster
```

```yaml
# $EX288_WORK/m11/components/persistenza/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1alpha1
kind: Component                  # non una Kustomization: si include con "components:", non con "resources:"
resources:
- pvc.yaml                       # la PVC entra nel risultato dell'overlay che usa il componente
patches:
- target:                        # nome della BASE (in prod non c'è prefisso, ma il target usa sempre quello)
    group: apps
    version: v1
    kind: Deployment
    name: postgresql
  patch: |-
    # 1) protezione: se l'indice 0 non è più il volume "data" la build FALLISCE invece di
    #    sostituire in silenzio il volume sbagliato
    - op: test
      path: /spec/template/spec/volumes/0/name
      value: data
    # 2) sostituisce l'intero elemento: niente più emptyDir, solo la PVC
    - op: replace
      path: /spec/template/spec/volumes/0
      value:
        name: data               # stesso nome: il volumeMount su /var/lib/pgsql/data resta valido
        persistentVolumeClaim:
          claimName: postgresql-data
```

In `$EX288_WORK/m11/overlays/prod/kustomization.yaml` aggiungi in fondo (percorso relativo alla directory dell'overlay):

```yaml
components:
- ../../components/persistenza
```

```bash
cd "$EX288_WORK/m11"
# Anteprima: la PVC c'è, con namespace e label env=prod dell'overlay; il volume punta alla PVC
oc kustomize overlays/prod | grep -B3 -A12 'kind: PersistentVolumeClaim'
oc kustomize overlays/prod | grep -B2 -A1 'claimName'
#       - name: data
#         persistentVolumeClaim:
#           claimName: postgresql-data
oc kustomize overlays/prod | grep -c 'emptyDir'     # 0
oc kustomize overlays/dev  | grep -c 'PersistentVolumeClaim'   # 0: dev non include il componente

oc diff -k overlays/prod                             # nuova PVC + volume del Deployment postgresql
oc apply -k overlays/prod
# persistentvolumeclaim/postgresql-data created
# deployment.apps/postgresql configured
oc rollout status deployment/postgresql -n ${LAB}-m11-prod

oc get pvc -n ${LAB}-m11-prod
# NAME              STATUS   VOLUME     CAPACITY   ACCESS MODES   STORAGECLASS   ...
# postgresql-data   Bound    pvc-...    1Gi        RWO            <default>
oc get deploy postgresql -n ${LAB}-m11-prod \
  -o jsonpath='{.spec.template.spec.volumes[?(@.name=="data")]}{"\n"}'
# {"name":"data","persistentVolumeClaim":{"claimName":"postgresql-data"}}
oc exec deploy/postgresql -n ${LAB}-m11-prod -- df -h /var/lib/pgsql/data   # filesystem della PVC, ~1G
curl -s https://$(oc get route hello-node -n ${LAB}-m11-prod -o jsonpath='{.spec.host}')/db   # raggiungibile
```

**Perché funziona:** il componente aggiunge una risorsa (la PVC) e una patch al risultato dell'overlay che lo include; le trasformazioni dell'overlay (namespace, label `env=prod`) valgono anche per la PVC. Il `claimName` è un riferimento che Kustomize conosce: con un `namePrefix` verrebbe riscritto insieme al nome della PVC. Solo prod ha `components:`, quindi dev resta su `emptyDir`.

**Perché `op: test`:** una patch JSON 6902 lavora per **posizione** nella lista. Se un giorno la base aggiungesse un volume prima di `data`, `replace` su `/volumes/0` sostituirebbe il volume sbagliato senza errori; il `test` fa fallire `oc kustomize` e te ne accorgi subito. In alternativa puoi evitare del tutto l'indice con una patch **strategic merge**, che fonde la lista `volumes` per `name` (`emptyDir: null` cancella la sorgente precedente, altrimenti il volume ne avrebbe due e sarebbe invalido). Nel componente sostituirebbe l'intero blocco `patches`:

```yaml
patches:
- patch: |-
    apiVersion: apps/v1
    kind: Deployment
    metadata:
      name: postgresql
    spec:
      template:
        spec:
          volumes:
          - name: data
            emptyDir: null
            persistentVolumeClaim:
              claimName: postgresql-data
```

**Perché il rollout non si blocca:** la PVC è `ReadWriteOnce` e, con la strategia `RollingUpdate`, il nuovo pod potrebbe restare in attesa del volume ancora montato dal vecchio pod su un altro nodo. Il Deployment `postgresql` della base usa già `strategy: Recreate` (il vecchio pod termina prima che parta il nuovo): è la scelta corretta per un database con un volume RWO. Il database riparte vuoto e viene inizializzato con le credenziali del Secret di prod.

> **Da verificare sul tuo cluster:** con una StorageClass in modalità `WaitForFirstConsumer` la PVC resta `Pending` finché il pod non viene schedulato (è normale); se resta `Pending` anche dopo, leggi `oc describe pvc postgresql-data -n ${LAB}-m11-prod`. Se non c'è una StorageClass di default (`oc get storageclass` senza `(default)`), aggiungi `storageClassName: <classe>` in `pvc.yaml`. Il testo esatto dell'errore quando l'`op: test` fallisce dipende dalla versione di Kustomize: provalo cambiando `value: data` in `value: dati` e lanciando `oc kustomize overlays/prod`.
</details>

### 4.3 Esercizio senza aiuti

Nell'overlay dev: genera `app-env` da un file `dev.env` (invece dei letterali) mantenendo il merge con la base, aggiungi a tutte le risorse l'annotazione `owner: <tuo-nome>`, sostituisci l'immagine del database con `registry.redhat.io/rhel9/postgresql-15` usando `images`. Mostra con `oc diff -k` cosa cambierà prima di applicare, applica e verifica che `/db` risponda ancora `raggiungibile`.

---

## 5. Verifiche pratiche con `oc`

| Domanda | Comando |
|---|---|
| Cosa produce questo overlay? | `oc kustomize <dir>` |
| Che differenza c'è tra due ambienti? | `diff <(oc kustomize overlays/dev) <(oc kustomize overlays/prod)` |
| Cosa cambierebbe sul cluster? | `oc diff -k <dir>` |
| Gli oggetti dell'overlay esistono? | `oc get -k <dir>` |
| Quale ConfigMap usa davvero il Deployment? | `oc get deploy <d> -o jsonpath='{.spec.template.spec.volumes[*].configMap.name}'` |
| A chi punta la Route? | `oc get route <r> -o jsonpath='{.spec.to.name}'` |
| Il Service ha endpoint (dopo prefissi/label)? | `oc get endpointslices -l kubernetes.io/service-name=<svc>` |
| Quali ConfigMap generate restano orfane? | `oc get cm --sort-by=.metadata.creationTimestamp` |

---

## 6. Troubleshooting intenzionale

```bash
oc project ${LAB}-m11-dev
TS=$EX288_HOME/11-kustomize/troubleshooting
```

### Scenario 1 — risorsa mancante

**Riproduci:** `oc apply -k $TS/rotto-1-risorsa-mancante`
**Sintomo:** nessun oggetto creato; errore del tipo `accumulating resources: accumulation err='accumulating resources from 'route.yaml': ... no such file or directory'`.

<details><summary>Indagine e soluzione</summary>

```bash
oc kustomize $TS/rotto-1-risorsa-mancante          # stesso errore, senza toccare il cluster
ls $TS/rotto-1-risorsa-mancante                    # il file si chiama routes.yaml
```
**Causa:** `resources` elenca `route.yaml`, che non esiste.
**Fix:** in una tua copia correggi il nome in `routes.yaml`, poi `oc apply -k <copia>`.
**Lezione:** Kustomize valida tutto prima di applicare: o tutto il risultato è costruibile o non applica nulla. `oc kustomize` è il tuo "lint".
</details>

### Scenario 2 — patch che non trovano il bersaglio

**Riproduci:** `oc kustomize $TS/rotto-2-patch`
**Sintomo:** errore `no matches for Id Deployment.v1.apps/k2-web-server.[noNs]; failed to find unique target for patch ...`. Corretto il primo problema, il risultato non contiene la variabile `TEAM`, senza alcun errore.

<details><summary>Indagine e soluzione</summary>

```bash
grep -n 'name:' $TS/rotto-2-patch/*.yaml       # deployment: k2-webserver | patch: k2-web-server | target: k2-websrv
```
**Causa:** la patch strategic merge identifica il bersaglio per nome (`k2-web-server` non esiste: errore esplicito); la patch JSON 6902 ha un `target` (`k2-websrv`) che non seleziona nulla: in quel caso la patch viene semplicemente non applicata.
**Fix:** in una tua copia usa `k2-webserver` in entrambi, poi `oc kustomize <copia> | grep -A2 -E 'replicas|TEAM'` e `oc apply -k <copia>`.
**Lezione:** dopo ogni patch verifica nell'output che il cambiamento ci sia davvero.

> **Da verificare sul tuo cluster:** a seconda della versione di Kustomize, un `target` che non seleziona nulla può essere ignorato in silenzio o segnalato: controlla il comportamento della tua versione con questo stesso scenario.
</details>

### Scenario 3 — "ho solo aggiunto una label"

**Riproduci:** `oc apply -k $TS/rotto-3-selector/v1` (funziona), poi `oc apply -k $TS/rotto-3-selector/v2`
**Sintomo:** `The Deployment "k3-web" is invalid: spec.selector: Invalid value: ...: field is immutable`. In più, `k3-web` (Service) ora non ha endpoint.

<details><summary>Indagine e soluzione</summary>

```bash
oc kustomize $TS/rotto-3-selector/v2 | grep -A3 -E 'selector:|matchLabels:'     # versione: v2 anche nei selector
oc get svc k3-web -o jsonpath='{.spec.selector}{"\n"}'                          # il Service è stato aggiornato!
oc get endpointslices -l kubernetes.io/service-name=k3-web                     # nessun endpoint
```
**Causa:** `includeSelectors: true` aggiunge la label ai selector. Il selector del Deployment è immutabile (errore), quello del Service no: `oc apply` ha aggiornato il Service e fallito sul Deployment, lasciando un'applicazione **a metà**.
**Fix:** se la label serve solo come metadato, `includeSelectors: false` (copia di v2) e riapplica: il Service torna al selector originale. Se il nuovo selector è davvero voluto: `oc delete deploy k3-web` e riapplica (disservizio).
**Lezione:** decidi le label dei selector alla prima versione; le label "informative" (env, versione, owner) vanno solo in metadata. `oc diff -k` prima di applicare l'avrebbe mostrato.
</details>

### Scenario 4 — namespace di un altro team

**Riproduci:** `oc apply -k $TS/rotto-4-namespace`
**Sintomo:** `Error from server (Forbidden): ... cannot ... in the namespace "ex288-produzione-condivisa"` (oppure `NotFound`).

<details><summary>Indagine e soluzione</summary>

```bash
oc kustomize $TS/rotto-4-namespace | grep namespace
oc auth can-i create configmaps -n ex288-produzione-condivisa         # no
```
**Causa:** il campo `namespace` dell'overlay **vince** su `-n` e sul progetto corrente: gli oggetti vanno in un progetto in cui non hai permessi (o che non esiste).
**Fix:** in una tua copia imposta `namespace: ${LAB}-m11-dev` (valore letterale) oppure rimuovi il campo e usa `oc apply -k <copia> -n ${LAB}-m11-dev`.
**Lezione:** controlla sempre `namespace` negli overlay presi da altri; nelle base non metterlo.
</details>

### Scenario 5 — ConfigMap generata, Deployment applicato a parte

**Riproduci:** `oc apply -k $TS/rotto-5-configmap && oc apply -f $TS/rotto-5-configmap/deployment.yaml`
**Sintomo:** il pod di `k5-web` resta in `ContainerCreating`.

<details><summary>Indagine e soluzione</summary>

```bash
oc describe pod -l app=k5-web | grep -A5 Events     # MountVolume.SetUp failed ... configmap "k5-config" not found
oc get cm -l scenario=m11-5                         # k5-config-<hash>
```
**Causa:** il generatore crea `k5-config-<hash>`; Kustomize aggiorna i riferimenti solo nelle risorse **della stessa kustomization**. Il Deployment è stato applicato con `oc apply -f`, quindi punta ancora a `k5-config`.
**Fix (consigliato):** in una tua copia aggiungi `deployment.yaml` a `resources` e applica solo con `oc apply -k`: il riferimento diventa `k5-config-<hash>`. **Fix alternativo:** `generatorOptions: disableNameSuffixHash: true` (ma perdi il rollout automatico).
**Lezione:** tutto ciò che usa una risorsa generata deve passare dalla stessa build Kustomize.
</details>

Pulizia: `oc delete project ${LAB}-m11-dev ${LAB}-m11-prod`

---

## 7. Esercizio finale (stile EX288)

> Lavora come all'esame: niente soluzioni, solo documentazione (docs OpenShift e documentazione Kustomize upstream), `--help` e `oc explain`. Tempo indicativo: **45 minuti**.

**Requisiti**

1. Esiste il progetto `${LAB}-m11-exam`, nel quale l'image stream `hello-node` ha il tag **`1.0`** con l'applicazione `hello-node` costruita dal tuo `$GIT_REPO`.
2. La base fornita `$EX288_HOME/11-kustomize/lab/esame-base` è copiata **senza modifiche** in `$EX288_WORK/m11-exam/base`.
3. Esiste l'overlay `$EX288_WORK/m11-exam/overlays/prod` che usa la base ed è stato applicato al cluster con Kustomize. L'overlay fa sì che:
   - tutte le risorse finiscano nel progetto `${LAB}-m11-exam` e abbiano il prefisso **`prod-`** (`prod-web`, `prod-db`, ...);
   - tutte le risorse **e i pod** abbiano la label **`env=prod`**;
   - il Deployment `prod-web` abbia **3 repliche** ed esegua l'immagine **`hello-node:1.0`** dell'image stream del progetto;
   - il container `web` abbia richieste `cpu: 100m`, `memory: 128Mi` e limite `memory: 512Mi`;
   - la ConfigMap generata dalla base come `web-config` contenga **solo** il file `app.properties` con le righe `ambiente=produzione` e `livello.log=warn`, mantenendo il suffisso hash nel nome;
   - l'applicazione riceva `APP_MESSAGE=Produzione EX288`;
   - il Secret generato `db-credentials` abbia `database-password=Prod-2026-ex288`, con utente e nome del database invariati;
   - la Route `prod-web` (edge) porti al Service `prod-web` e l'applicazione raggiunga il database `prod-db`.

**Risultato atteso**

- `https://<route prod-web>/` restituisce `"message": "Produzione EX288"`; `/config` mostra `ambiente=produzione`; `/db` risponde `raggiungibile` con host `prod-db`.
- `prod-web` ha 3 repliche pronte e `prod-db` 1.

```bash
bash $EX288_HOME/11-kustomize/verifica.sh
# se hai usato un'altra cartella: EXAM_DIR=/percorso bash $EX288_HOME/11-kustomize/verifica.sh
```

---

## 8. Riferimenti ufficiali

- OCP 4.22 CLI tools → *OpenShift CLI developer command reference* (`oc apply -k`, `oc get -k`, `oc kustomize`, `oc diff`): https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/cli_tools/openshift-cli-oc
- OCP 4.22 Images → *Using image streams with Kubernetes resources* (`oc set image-lookup`, usato con `images:` di Kustomize): https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/images/using-imagestreams-with-kube-resources
- OCP 4.22 Building applications → *Deployments*: https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/building_applications/deployments
- Kubernetes (upstream, NON docs OCP) → *Declarative Management of Kubernetes Objects Using Kustomize*: https://kubernetes.io/docs/tasks/manage-kubernetes-objects/kustomization/
- Kustomize (upstream) → riferimento dei campi di `kustomization.yaml` (labels, patches, generators, components): https://kubectl.docs.kubernetes.io/references/kustomize/kustomization/
