# Percorso pratico EX288 — da zero a livello d'esame

Corso hands-on per preparare l'esame **Red Hat EX288 — Red Hat Certified Advanced Developer in Cloud-native Applications**, basato su **OpenShift Container Platform 4.22**. È pensato per chi conosce le basi di Kubernetes e Docker e parte quasi da zero con OpenShift: 14 moduli progressivi più un esame simulato di 4 ore, tutti eseguibili su un cluster OpenShift reale con un utente normale (non `cluster-admin`).

Fonti: solo fonti ufficiali Red Hat (pagina dell'esame EX288, pagina del corso DO288, documentazione OCP 4.22 e Red Hat OpenShift Pipelines 1.24, developers.redhat.com). Le due eccezioni inevitabili (comandi Helm upstream e formato di `kustomization.yaml`) sono dichiarate nel testo. Differenze tra versioni e incoerenze della documentazione sono raccolte in [`docs/versioni-e-differenze.md`](docs/versioni-e-differenze.md).

---

## Guida rapida

```bash
git clone <url-di-questo-repository> ex288-teach    # oppure scompatta l'archivio
cd ex288-teach                                      # la ROOT: parti sempre da qui
cp env.example.sh env.sh && vi env.sh               # imposta LAB e GIT_REPO
source env.sh                                       # variabili + cartella work/
oc login ...                                        # cluster reale o OpenShift Local (vedi sotto)
bash 00-setup/controlla-ambiente.sh                 # cosa offre il cluster
```

Poi apri [`00-setup/README.md`](00-setup/README.md) e prosegui modulo per modulo.

---

## Come funziona il repository: tutto dentro la root

Il corso non scrive **nulla** fuori dalla cartella del repository: niente file nella home, niente `/tmp`. Le variabili di `env.sh` puntano sempre a percorsi interni:

| Variabile | Valore | Uso |
|---|---|---|
| `$EX288_HOME` | la root del repository | Materiale del corso: moduli, `apps/`, `lib/`. **Non si modifica** |
| `$EX288_WORK` | `$EX288_HOME/work` | **La tua area di lavoro**: tutto ciò che crei o modifichi |
| `$LAB` | es. `mrossi` | Prefisso dei progetti OpenShift (`mrossi-m01`, `mrossi-m02`, …) |
| `$GIT_REPO` | URL del tuo repository delle app | Il cluster costruisce le immagini da lì |

```
ex288-teach/                      <- $EX288_HOME (root: apri qui il terminale)
├── README.md                     # questo file
├── env.example.sh                # modello di env.sh
├── env.sh                        # TUO, creato da env.example.sh (ignorato da Git)
├── lib/verifica-lib.sh           # funzioni comuni degli script di verifica
├── apps/                         # sorgenti ORIGINALI delle app (copiati in work/ex288-apps)
├── docs/                         # versioni e differenze, strategia d'esame
├── 00-setup/ … 14-esame-simulato/
│   ├── README.md                 # il modulo
│   ├── lab/                      # file del laboratorio guidato (originali)
│   ├── troubleshooting/          # scenari volutamente rotti
│   └── verifica.sh               # verifica dell'esercizio finale (sola lettura)
└── work/                         <- $EX288_WORK (ignorata da Git, tranne il suo README)
    ├── ex288-apps/               # TUO clone del repository delle app: qui commit e push
    ├── m00/ … m14/               # file creati o modificati nei moduli
    └── mNN-exam/                 # file richiesti dagli esercizi finali (chart, overlay, ...)
```

Regole pratiche:

- **Apri ogni terminale nella root** ed esegui `source env.sh`: definisce le variabili e crea `work/` con le sottocartelle.
- Se un lab ti chiede di modificare un file del corso, prima lo **copi** in `$EX288_WORK/mNN/` (i comandi del modulo lo fanno già).
- Per ripartire da zero: cancella il contenuto di `work/` e rilancia `source env.sh` (vedi [`work/README.md`](work/README.md)).
- Metti il repository in un percorso **senza spazi**: i comandi usano le variabili senza virgolette.
- Prima di passare il repository a qualcun altro, togli `env.sh` e il contenuto di `work/`: sono personali.

---

## Scegli dove fare i laboratori

| | Cluster reale (aziendale o cloud) | OpenShift Local (sul tuo PC) |
|---|---|---|
| Somiglianza con l'esame | Alta: cluster multi-nodo, utente senza privilegi | Buona: stesso OpenShift 4.22, ma un solo nodo |
| Chi installa Pipelines e gli Operator | L'amministratore | Tu, come `kubeadmin` |
| Registry esposto all'esterno | Solo se l'amministratore lo abilita | Sì, con lo script di preparazione |
| Webhook da GitHub (moduli 05 e 12) | Funzionano se il cluster è raggiungibile da Internet | No: il cluster è privato sul tuo PC. I moduli usano comunque `curl` per simulare il webhook |
| Requisiti | Un account sul cluster | PC con almeno 4 core fisici, 10,5 GB di RAM libera (consigliati 16 GB), 35 GB di disco (consigliati 60) |

### Opzione A — Cluster OpenShift reale

1. **Chiedi all'amministratore** quanto elencato nella sezione 4 di [`00-setup/README.md`](00-setup/README.md). Le parti principali sono: permesso di creare progetti, quota sufficiente, OpenShift Pipelines, una StorageClass di default e, per il modulo 13, un Operator installato in modalità *All namespaces*.
2. L'amministratore può configurare quasi tutto in un colpo, con un utente cluster-admin:

   ```bash
   bash 00-setup/prepara-cluster-admin.sh --all     # Pipelines, route del registry, Data Grid, prospettiva Developer
   ```

3. Tu esegui il login con il **tuo** utente. Il comando si copia dalla web console: menu utente → *Copy login command*.

   ```bash
   oc login --token=<token> --server=https://api.<cluster>:6443
   ```

4. In `env.sh` usa un `LAB` univoco sul cluster (le tue iniziali): su un cluster condiviso i nomi dei progetti sono globali.
5. `bash 00-setup/controlla-ambiente.sh` e via con il modulo 00.

### Opzione B — Red Hat OpenShift Local (ex CodeReady Containers)

Al momento della stesura (ottobre 2026) OpenShift Local 2.64 include OpenShift 4.22, la stessa versione dell'esame. Le istruzioni ufficiali sono su crc.dev; il download e il *pull secret* (gratuito, con un account Red Hat) sono su https://console.redhat.com/openshift/create/local.

**1. Installa e dimensiona.** Pipelines, build e Data Grid insieme richiedono più delle risorse minime:

```bash
crc config set cpus 6
crc config set memory 16384        # MiB; il minimo è 10752 ma con Pipelines e Data Grid è stretto
crc config set disk-size 60        # GiB
crc setup                          # una volta sola: prepara il sistema
crc start                          # chiede il pull secret al primo avvio (alcuni minuti)
```

**2. Collega `oc` e leggi le credenziali.**

```bash
eval $(crc oc-env)                 # mette nel PATH l'oc di OpenShift Local
crc console --credentials          # comandi di login per "developer" e "kubeadmin"
```

**3. Prepara il cluster come amministratore**, una volta sola:

```bash
oc login -u kubeadmin https://api.crc.testing:6443       # password da "crc console --credentials"
bash 00-setup/prepara-cluster-admin.sh --all             # senza Data Grid: --pipelines --registry --developer-console
```

**4. Lavora sempre come `developer`**, come all'esame, dove non sei amministratore:

```bash
oc login -u developer https://api.crc.testing:6443
oc whoami                                                # developer
```

**5. Configura `env.sh`** con `LAB` a piacere (ad esempio `dev`) e un `GIT_REPO` su GitHub o GitLab: la VM di OpenShift Local esce su Internet attraverso il tuo PC.

**6. Avvia il modulo 00:** `bash 00-setup/controlla-ambiente.sh`.

Differenze da conoscere su OpenShift Local:

- **Domini locali.** Route e registry hanno nomi in `*.apps-crc.testing` (il registry è `default-route-openshift-image-registry.apps-crc.testing`), risolvibili solo dal tuo PC. I `curl` dei lab funzionano; i webhook da GitHub no.
- **Certificati autofirmati.** Con Podman usa `--tls-verify=false`. Con Docker aggiungi il registry agli `insecure-registries` (modulo 03, passo 3.7).
- **Architettura.** Su un Mac con chip Apple, OpenShift Local gira su **arm64**. Le immagini UBI del corso sono multi-architettura e funzionano. Se costruisci immagini in locale con Docker o Podman, **non** forzare `--platform linux/amd64`: quell'indicazione vale per i cluster con nodi amd64.
- **Monitoraggio disattivato di default.** `oc adm top` non funziona e alcuni comandi di discovery segnalano un gruppo API non disponibile (`metrics.k8s.io`). Gli script del corso ne tengono conto.
- **Un solo nodo.** Le repliche finiscono tutte sullo stesso nodo. Lo scenario "un nuovo pod su un altro nodo" del modulo 03 non si può riprodurre.
- **Ferma il cluster quando hai finito** (`crc stop`) per liberare memoria; `crc delete` lo azzera completamente.

### Alternativa: Developer Sandbox

La [Developer Sandbox](https://developers.redhat.com/developer-sandbox) è gratuita e ha OpenShift Pipelines preinstallato, ma ti dà un solo progetto e nessun permesso di amministratore. Puoi usarla per ripassare i moduli 01-02 e 07-12 (adattando i nomi dei progetti), non per i moduli che richiedono più progetti (03, 04, 14) o l'installazione di Operator (13).

---

## Problemi frequenti (già incontrati durante l'uso del corso)

| Sintomo | Causa | Dove è spiegato |
|---|---|---|
| Uno script dice che OpenShift Pipelines non è installato, ma lo è | Discovery delle API con un gruppo aggregato non raggiungibile (risolto negli script) | Modulo 00, sezione 6 |
| `ServiceUnavailable` su image stream, build o route | L'OpenShift API server non risponde: problema del cluster, non tuo | Modulo 00, sezione 6 |
| Il Deployment non usa l'immagine appena costruita | Manca il trigger dell'image stream, oppure il nodo riusa la copia in cache (`imagePullPolicy`) | Moduli 03 e 04 |
| `ImagePullBackOff` con un'immagine di un altro progetto | Manca `system:image-puller` per il service account del progetto che esegue i pod | Modulo 03, sezioni 3.8 e 7 |
| `docker push` verso il registry: errore 500 | Docker chiede il manifest prima del push e l'image stream non esiste ancora: crealo prima | Modulo 03, passo 3.7 |
| `oc new-app ... --strategy=source`: "none of the arguments ... classified as a source code location" | Variabile vuota o URL non riconosciuto: usa `--code=` | Modulo 02, esercizio 4.2 |
| Task Tekton rifiutata: "non-existent variable" | Un `$(...)` non dichiarato nello script, anche in un commento | Modulo 12, passo 3.3 |

> **Aree da curare con più tempo.** All'esame gli argomenti su cui è più facile inciampare sono **Helm** (modulo 10), **Operator** (modulo 13), **Pipelines** (modulo 12) e i **permessi di pull tra progetti** (modulo 03). Rifai i loro esercizi finali più di una volta, senza guardare le soluzioni.

---

## Come è fatto ogni modulo

| Sezione | Cosa trovi | Come usarla |
|---|---|---|
| 1. Perché e quando | Tabella decisionale: quale risorsa usare e perché | Leggila prima di toccare il terminale |
| 2. Concetti essenziali | Teoria minima con YAML annotati | Ripassala prima dell'esame |
| 3. Laboratorio guidato | Passi con comandi commentati e output atteso | Eseguilo per intero, non copiare e basta: leggi i commenti |
| 4. Esercizi | 4.1 guidato (suggerimenti e soluzione) → 4.2 semi-guidato (suggerimenti e soluzione nascosta) → 4.3 senza aiuti | Apri le soluzioni solo dopo aver provato |
| 5. Verifiche con `oc` | Domanda → comando | Diventa il tuo metodo di controllo all'esame |
| 6. Troubleshooting intenzionale | Scenari rotti da diagnosticare (file in `troubleshooting/`) | Indaga prima di aprire la soluzione |
| 7. Esercizio finale stile EX288 | Solo requisiti e risultato atteso, nessun comando | Lavora a tempo, poi lancia `verifica.sh` |
| 8. Riferimenti ufficiali | Capitoli della documentazione 4.22 | Sono le pagine che avrai all'esame |

Ogni modulo ha uno script `verifica.sh` che **legge soltanto** lo stato del cluster e indica quali requisiti dell'esercizio finale sono soddisfatti.

---

## I moduli

| # | Modulo | Argomenti principali | Durata |
|---|---|---|---|
| 00 | [Setup](00-setup/README.md) | Strumenti, login, repository Git delle app, controllo del cluster | 1 h |
| 01 | [Fondamenti di OpenShift](01-fondamenti-openshift/README.md) | Progetti, RBAC, `oc new-app` da immagine, Service, Route, web console | 3-4 h |
| 02 | [Git e applicazioni da sorgente](02-git-e-app-da-sorgente/README.md) | Git per l'esame, `oc new-app` da Git, S2I vs Docker, branch e context-dir, source secret | 4 h |
| 03 | [Immagini e registry](03-immagini-e-registry/README.md) | Dockerfile per OpenShift, UID arbitrari, build binarie, registry interno, pull tra progetti | 4 h |
| 04 | [Image stream](04-image-stream/README.md) | Import, tag, trigger su Deployment, promozione dev→prod, rollback | 3-4 h |
| 05 | [Build e trigger](05-build-e-trigger/README.md) | BuildConfig in dettaglio, webhook, ImageChange, build hook, troubleshooting delle build | 5 h |
| 06 | [S2I personalizzato](06-s2i-personalizzato/README.md) | Script S2I, `.s2i/`, scripts URL, builder personalizzato | 4 h |
| 07 | [ConfigMap e Secret](07-configmap-secret/README.md) | Creazione, iniezione come env e volumi, aggiornamenti, app + database | 4 h |
| 08 | [Deployment, health check, troubleshooting](08-deployment-health-troubleshooting/README.md) | Strategie, rollout, probe, risorse, sidecar, metodo di debug | 5 h |
| 09 | [Template](09-template/README.md) | Template JSON/YAML, parametri, multi-container | 3-4 h |
| 10 | [Helm](10-helm/README.md) | Chart, values, install/upgrade/rollback, Helm in OpenShift | 4 h |
| 11 | [Kustomize](11-kustomize/README.md) | Base, overlay, patch, generatori | 3 h |
| 12 | [OpenShift Pipelines](12-openshift-pipelines/README.md) | Task, Pipeline, workspace, cluster resolver, `tkn`, Triggers | 6 h |
| 13 | [Operator](13-operator/README.md) | Creare applicazioni da Operator installati | 3 h |
| 14 | [Esame simulato](14-esame-simulato/README.md) | 12 task in 4 ore su tutti gli obiettivi | 4 h + ripasso |

Documenti di supporto: [`docs/versioni-e-differenze.md`](docs/versioni-e-differenze.md) · [`docs/strategia-esame.md`](docs/strategia-esame.md)

---

## Piano di studio consigliato (8 settimane, circa 8-10 ore a settimana)

| Settimana | Moduli | Obiettivo della settimana |
|---|---|---|
| 1 | 00, 01 | Ambiente pronto; muoverti tra progetti, deployment, service e route senza guardare gli appunti |
| 2 | 02, 03 | Costruire ed eseguire app da Git e da Dockerfile; capire UID arbitrari e registry |
| 3 | 04, 05 | Image stream e BuildConfig: trigger, webhook, hook |
| 4 | 06, 07 | S2I personalizzato; configurazione e credenziali |
| 5 | 08 | Deployment robusti e debug sistematico (rifai gli scenari di troubleshooting finché sono automatici) |
| 6 | 09, 10, 11 | Template, Helm, Kustomize: saper scegliere e usare ciascuno |
| 7 | 12, 13 | Pipeline e Operator |
| 8 | 14 + ripasso | Esame simulato a tempo; ripasso mirato dei KO; ripetizione dell'esame simulato |

Prima di prenotare: completa l'esame simulato in **meno di 3 ore** con almeno l'**80%** dei controlli superati, e ripeti senza aiuti gli esercizi finali dei moduli in cui hai avuto KO.

---

## Mappa obiettivi ufficiali EX288 → moduli

Obiettivi riportati come pubblicati da Red Hat (pagina EX288, ottobre 2026).

| Area ufficiale | Obiettivo | Moduli |
|---|---|---|
| Work with Red Hat OpenShift Container Platform | Create and work with multiple OpenShift projects | 01, 03, 04 |
| | Create and deploy single container and multi-container applications | 01, 02, 07, 08 |
| | Use application health monitoring | 08 |
| | Understand basic Git usage and work with Git in the context of deploying applications in OpenShift | 02, 05, 06 |
| | Configure the OpenShift internal registry to meet specific requirements | 03 |
| | Manage applications with the web console | 01 (+ box console nei moduli 02, 08, 10, 13) |
| Deploy multi-container applications | Create and use Helm charts | 10 |
| | Customizing deployments with Kustomize | 11 |
| Work with container images in OpenShift Container Platform | Understand how to create container images based on pre-built images | 03, 06 |
| | Understand and work with image builds and image build configurations | 05 |
| | Work with custom builder workflows to create images to use with OpenShift Container Platform | 06 |
| | Publish container images to a the OpenShift image registry *(refuso presente nel testo ufficiale)* | 03, 04 |
| Troubleshoot application builds and deployment issues | Diagnose and correct minor issues with application deployment | 08 (+ sezione 6 di ogni modulo) |
| | Diagnose and correct minor issues with build process | 05, 06 |
| Work with image streams | Create custom image streams to deploy applications | 04 |
| | Pull applications from existing Git repositories | 02 |
| | Trigger updates on image stream changes | 04, 05 |
| | Debug minor issues with application deployment | 04, 08 |
| Work with configuration maps and secrets | Create configuration maps | 07 |
| | Create secret resources | 07 |
| | Use configuration maps to inject data into applications | 07 |
| Work with the source-to-image (S2I) framework | Build and deploy applications using S2I framework | 02, 06 |
| | Customize existing S2I builder images | 06 |
| Work with build hooks and build triggers | Create a build hook that runs a provided script | 05 |
| | Test and confirm proper operation of the hook | 05 |
| | Manage and trigger application builds | 05 |
| Work with templates | Create an OpenShift template | 09 |
| | Use pre-existing templates written in either JSON or YAML format | 09 |
| | Work with multi-container templates | 09 |
| | Add custom parameters to a template | 09 |
| Work with OpenShift Pipelines | Understanding CI/CD process inside of OpenShift | 12 |
| | Understand and work with standard Tekton custom resource definitions (CRDs) for defining CI/CD pipelines | 12 |
| | Design and define, and troubleshoot CI/CD workflows for applications | 12 |
| | Configure and trigger Pipeline workflows for applications | 12 |
| Work with Operators accessible for users to run in their applications | Creating applications from installed Operators | 13 |

> **Attenzione:** la pagina ufficiale avvisa che sono in uso **più versioni dell'esame**. Nel Learning Management System di Red Hat trovi gli obiettivi della versione che ti è assegnata: confrontali con questa tabella prima di prenotare.

---

## Avvertenze

- Il materiale è stato validato sintatticamente (script, YAML, JSON) e in parte provato su un cluster reale, ma ogni cluster è diverso: i punti più sensibili a versione e configurazione sono segnalati con il box **"Da verificare sul tuo cluster"**.
- Alcuni lab dipendono da ciò che è installato sul cluster (OpenShift Pipelines, una StorageClass di default, un Operator per il modulo 13): `00-setup/controlla-ambiente.sh` te lo dice prima di iniziare.
- Su un cluster condiviso elimina i progetti a fine modulo: ogni modulo indica i comandi di pulizia.

## Risorse ufficiali gratuite complementari

- Pagina esame EX288: https://www.redhat.com/en/services/training/ex288-red-hat-certified-openshift-application-developer-exam
- Corso DO288: https://www.redhat.com/en/services/training/red-hat-openshift-developer-ii-building-and-deploying-cloud-native-applications
- Documentazione OCP 4.22: https://docs.redhat.com/en/documentation/openshift_container_platform/4.22
- Documentazione Red Hat OpenShift Pipelines 1.24: https://docs.redhat.com/en/documentation/red_hat_openshift_pipelines/1.24
- Learning path gratuiti Red Hat Developer: [Foundations of OpenShift](https://developers.redhat.com/learn/openshift/foundations-openshift), [Using OpenShift Pipelines](https://developers.redhat.com/learn/openshift/using-openshift-pipelines), [Deploy to OpenShift using Helm charts](https://developers.redhat.com/learn/openshift/deploy-red-hat-openshift-using-helm-charts)
- Ambienti di pratica alternativi: [Developer Sandbox](https://developers.redhat.com/developer-sandbox) (gratuito, 30 giorni, senza permessi di amministratore) e [OpenShift Local](https://console.redhat.com/openshift/create/local) (cluster 4.22 sul tuo PC, almeno 4 core e circa 11 GB di RAM liberi)
