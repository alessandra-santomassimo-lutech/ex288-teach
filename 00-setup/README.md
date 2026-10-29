# Modulo 00 — Preparare l'ambiente di laboratorio

> **Obiettivo:** avere una postazione con `oc`, `helm`, `tkn`, `git` (e opzionalmente `podman`), un accesso funzionante al cluster OpenShift e un repository Git con le app del corso, raggiungibile dal cluster.
>
> **Durata stimata:** 45-60 minuti · **Richiede cluster-admin:** no (ma alcune verifiche dipendono da cosa ha installato l'amministratore)

---

## 1. Perché questo modulo è importante

L'EX288 è un esame **pratico**: lavori su un cluster OpenShift reale con la sola documentazione ufficiale a disposizione. Prima di imparare le risorse OpenShift ti serve un ambiente stabile e ripetibile, altrimenti passerai il tempo a combattere con problemi di rete, di permessi o di versioni invece che a imparare.

Su un **cluster aziendale o cloud condiviso** ci sono tre vincoli da tenere a mente fin da subito:

| Vincolo | Conseguenza nei lab | Come lo gestiamo |
|---|---|---|
| I nomi dei progetti sono unici nell'intero cluster | `oc new-project test` può fallire perché qualcun altro l'ha già usato | Tutti i progetti si chiamano `${LAB}-mNN` (es. `asanto-m05`) |
| Di solito non sei `cluster-admin` | Non puoi installare Operator né esporre il registry interno | Il modulo indica sempre se un passo richiede l'amministratore e offre un'alternativa |
| Il cluster deve raggiungere il tuo Git | Le build S2I/Docker clonano il codice **dal cluster**, non dal tuo PC | Usi un repository pubblico (o privato con source secret, modulo 02) |

---

## 2. Strumenti da installare sulla tua postazione

| Strumento | A cosa serve nel corso | Dove scaricarlo (fonte ufficiale) |
|---|---|---|
| `oc` | CLI di OpenShift (include anche `kubectl` e `oc kustomize`) | Web console → icona **?** → *Command Line Tools*, oppure `https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable-4.22/` |
| `helm` | Moduli 10 e 14 | Web console → *Command Line Tools*, oppure `https://mirror.openshift.com/pub/openshift-v4/clients/helm/latest/` |
| `tkn` | CLI di OpenShift Pipelines (moduli 12 e 14) | Web console → *Command Line Tools* (compare se l'Operator Pipelines è installato) |
| `git` | Moduli 02, 05, 06, 12 | Pacchetto del sistema operativo |
| `podman` (oppure Docker) | Modulo 03 (build locale delle immagini) — **opzionale**. Con Docker alcune opzioni cambiano (ad esempio non esiste `--tls-verify`): il modulo 03 indica gli equivalenti | Pacchetto del sistema operativo / Podman Desktop |
| `curl`, `jq` | Test delle route e lettura di JSON | Pacchetto del sistema operativo |

> **Versioni:** usa un `oc` della stessa versione minore del cluster (o al massimo una di differenza). L'esame EX288 attuale è basato su **OpenShift 4.22**. Controlla la versione del cluster con `oc version` dopo il login.

Verifica rapida:

```bash
oc version --client        # versione della CLI
helm version               # Helm 3.x
tkn version                # client tkn (e, dopo il login, versione di Pipelines)
git --version
podman --version           # opzionale
```

---

## 3. Laboratorio guidato

### Passo 1 — Login al cluster

```bash
# Metodo consigliato: dalla web console, menu utente in alto a destra
# -> "Copy login command" -> "Display Token", poi incolla il comando:
oc login --token=sha256~XXXX --server=https://api.<cluster>.<dominio>:6443

# In alternativa (oc recenti) login via browser:
oc login --web https://api.<cluster>.<dominio>:6443

oc whoami                  # chi sono
oc whoami --show-server    # su quale API server
oc whoami --show-console   # URL della web console
oc version                 # versione client E server (deve mostrare 4.x)
```

### Passo 2 — Ottieni il materiale del corso e crea `env.sh`

Il corso è autosufficiente: **tutto avviene dentro la cartella del repository** (`ex288-teach`). I file che crei o modifichi durante i lab finiscono nella sottocartella `work/`, mai nella tua home o in `/tmp`.

> Metti il repository in un percorso **senza spazi** (es. `~/corsi/ex288-teach`): i comandi del corso usano variabili come `$EX288_WORK` senza virgolette.

```bash
cd <percorso>/ex288-teach     # la root del repository: d'ora in poi parti sempre da qui
cp env.example.sh env.sh
vi env.sh                     # imposta almeno LAB e GIT_REPO
source env.sh                 # carica le variabili e crea work/ con le sottocartelle
echo "$LAB $GIT_REPO"
echo "$EX288_HOME"            # root del repository
echo "$EX288_WORK"            # <root>/work: la tua area di lavoro
ls "$EX288_WORK"              # ex288-apps  m00 m01 ... m14
```

> Ogni volta che apri un nuovo terminale, vai nella root del repository ed esegui `source env.sh`. Tutti i comandi del corso usano `$LAB`, `$GIT_REPO`, `$EX288_HOME` (materiale del corso, da non modificare) ed `$EX288_WORK` (i tuoi file).

| Cartella | Contenuto | La modifichi? |
|---|---|---|
| `$EX288_HOME/NN-*/` | Moduli, file di laboratorio originali, script di verifica | No: copia in `work/` ciò che devi cambiare |
| `$EX288_HOME/apps/` | Sorgenti originali delle applicazioni | No |
| `$EX288_WORK/ex288-apps/` | Il **tuo** clone del repository delle app (passo 3) | Sì: qui fai commit e push |
| `$EX288_WORK/mNN/` | File creati o modificati nel modulo NN (YAML generati, chart, overlay, copie dei lab) | Sì |
| `$EX288_WORK/mNN-exam/` | File richiesti dagli esercizi finali (es. il chart del modulo 10) | Sì |

`work/` è ignorata da Git: per ripartire da zero basta cancellarne il contenuto e rieseguire `source env.sh`.

### Passo 3 — Crea il repository Git delle applicazioni

Le build OpenShift scaricano il codice da Git: crea un repository **vuoto** (es. `ex288-apps`) su GitHub, GitLab o sul Git aziendale, e caricaci il contenuto della cartella `apps/`. Il clone locale vive in `$EX288_WORK/ex288-apps`.

```bash
# Copia le app nella cartella di lavoro (il repo delle app NON è il repo del corso)
cp -R "$EX288_HOME/apps/." "$EX288_WORK/ex288-apps/"
cd "$EX288_WORK/ex288-apps"

git init -b main                       # crea il repo locale con branch "main"
git add .                              # prepara tutti i file per il commit
git commit -m "App iniziali corso EX288"
git remote add origin "$GIT_REPO"      # collega il repo remoto
git push -u origin main                # invia il branch main e lo imposta come upstream

cd "$EX288_HOME"                       # torna alla root del corso
```

Struttura che otterrai (ogni cartella viene usata come `--context-dir`):

```
work/ex288-apps/
├── hello-node/            # app Node.js (S2I oppure Dockerfile)
├── hello-node-s2i/        # stessa app con script S2I personalizzati (.s2i/)
├── builder-nodejs-ex288/  # builder S2I personalizzato (modulo 06)
└── broken-image/          # Dockerfile volutamente errato (modulo 03)
```

> **Repository privato?** Va bene, ma dal modulo 02 in poi dovrai creare un *source secret* per far clonare il codice al cluster. Se vuoi partire semplice, usa un repository pubblico.

### Passo 4 — Controlla cosa offre il cluster

Esegui lo script di controllo. Non modifica nulla: legge soltanto.

```bash
cd "$EX288_HOME"
bash 00-setup/controlla-ambiente.sh
```

Lo script verifica:

1. login e versione del cluster;
2. permesso di creare progetti;
3. raggiungibilità del repository Git;
4. presenza dell'image stream `nodejs` nel namespace `openshift`;
5. presenza di OpenShift Pipelines e delle Task fornite in `openshift-pipelines`;
6. versione dell'API di Tekton Triggers servita dal cluster;
7. eventuali Operator installati utilizzabili nel modulo 13;
8. presenza degli strumenti locali.

### Passo 5 — Primo progetto di prova

```bash
oc new-project ${LAB}-m00 --display-name="EX288 - setup"
oc get project ${LAB}-m00
oc delete project ${LAB}-m00          # lo eliminiamo subito: era solo una prova
```

---

## 4. Cosa chiedere all'amministratore del cluster

Copia questa lista e inviala all'amministratore. Le voci **obbligatorie** servono per la maggior parte del corso, quelle **opzionali** abilitano lab specifici.

| # | Richiesta | Serve per | Priorità |
|---|---|---|---|
| 1 | Permesso di creare progetti (self-provisioner) oppure 6-8 progetti già creati con ruolo `admin` | Tutti i moduli | Obbligatoria |
| 2 | Quota per progetto di almeno 4 vCPU / 8 GiB RAM / 10 GiB storage | Build e app multi-container | Obbligatoria |
| 3 | Operator **Red Hat OpenShift Pipelines** installato (versione supportata su 4.22: 1.22, 1.23 o 1.24) | Moduli 12 e 14 | Obbligatoria |
| 4 | Una StorageClass di default | Workspace delle pipeline, database | Obbligatoria |
| 5 | Almeno un Operator installato in modalità *All namespaces* che fornisca una risorsa applicativa (il modulo 13 usa come esempio **Red Hat Data Grid**, ma la procedura vale per qualunque Operator) | Modulo 13 | Consigliata |
| 6 | Image stream di esempio nel namespace `openshift` (Cluster Samples Operator) | Moduli 02, 05, 06 | Opzionale: in mancanza le importiamo noi |
| 7 | Route di default del registry interno esposta (`defaultRoute: true`) | Modulo 03, parte con `podman push` | Opzionale |
| 8 | Prospettiva *Developer* della web console abilitata | Esercizi sulla console | Opzionale |

**Script per l'amministratore.** Le voci 3, 5 (con Data Grid), 7 e 8 si configurano in un colpo solo con lo script del corso, da eseguire con un utente cluster-admin (su OpenShift Local: `kubeadmin`):

```bash
bash 00-setup/prepara-cluster-admin.sh --all        # oppure solo alcune: --pipelines --registry --datagrid --developer-console
```

Lo script è idempotente e usa il canale di default di ogni Operator presente nel catalogo del cluster. Le voci 1, 2, 4 e 6 dipendono dalla configurazione del cluster e non sono gestite dallo script.

> **Nota di versione:** dal 4.19 la web console ha prospettive unificate e la prospettiva *Developer* non è più abilitata di default; il **Cluster Samples Operator** (che fornisce image stream e template di esempio nel namespace `openshift`) è **deprecato** in 4.20-4.22. Per questo il corso non dà per scontato che esistano. Vedi `docs/versioni-e-differenze.md`.

---

## 5. Verifiche pratiche

```bash
oc whoami                                        # utente corrente
oc auth can-i create projectrequests             # "yes" = puoi creare progetti
oc get is -n openshift nodejs                    # image stream builder Node.js (se esiste)
oc api-resources --api-group=tekton.dev          # CRD Tekton (Pipelines installato?)
oc get tasks -n openshift-pipelines              # Task fornite dall'Operator
git ls-remote "$GIT_REPO"                        # il repo esiste ed è raggiungibile
```

---

## 6. Troubleshooting dell'ambiente

| Sintomo | Causa probabile | Cosa fare |
|---|---|---|
| `error: You must be logged in to the server (Unauthorized)` | Token scaduto | Ripeti `oc login` (i token durano tipicamente 24 ore) |
| `x509: certificate signed by unknown authority` al login | CA del cluster non attendibile sulla tua postazione | Chiedi la CA all'amministratore; solo in laboratorio puoi usare `--insecure-skip-tls-verify=true` |
| `project.project.openshift.io "xyz" already exists` o `forbidden` su `new-project` | Nome già usato da altri / nessun permesso | Usa il prefisso `$LAB`; chiedi il permesso all'amministratore |
| `git ls-remote` funziona dal PC ma le build falliscono su `git clone` | Il cluster non raggiunge il Git (proxy, firewall, repo privato) | Verifica con l'amministratore; per repo privati vedi modulo 02 |
| `tkn: command not found` | CLI non installata | Scaricala da *Command Line Tools* della console |
| `Error from server (ServiceUnavailable): the server is currently unable to handle the request` su image stream, build, route o progetti, mentre `oc get pods` funziona | L'**OpenShift API server** (che serve le API `*.openshift.io`) non è disponibile: aggiornamento del cluster, riavvio dei suoi pod, problema sui nodi master. Non dipende dai tuoi comandi né dai permessi (quelli darebbero `Forbidden`) | Riprova dopo qualche minuto; `bash 00-setup/controlla-ambiente.sh` mostra quali API rispondono. Se persiste, l'amministratore controlla `oc get clusteroperator openshift-apiserver` e i pod nel namespace `openshift-apiserver` |
| Uno script segnala come assente qualcosa che sai essere installato | Permessi del tuo utente diversi da quelli previsti, o risposta del cluster in un formato inatteso | Esegui `bash 00-setup/diagnostica-cluster.sh > diagnostica.txt 2>&1`: raccoglie (in sola lettura, senza token né Secret) l'output grezzo dei comandi usati dagli script, con i loro exit code |

> **Perché gli script non si fidano dell'exit code di `oc api-resources`:** su molti cluster reali basta un gruppo API aggregato temporaneamente non raggiungibile (ad esempio `metrics.k8s.io`) perché `oc api-resources` stampi l'elenco corretto **e** termini con exit code 1. Per questo gli script rilevano le API installate con `oc api-versions` e valutano solo l'output. Ricordalo anche quando scrivi i tuoi script.

---

## 7. Esercizio finale (stile EX288)

**Requisiti**

1. Sei autenticata sul cluster con il tuo utente (non `kubeadmin`).
2. Il file `env.sh` è configurato e caricato: `LAB` non vale `cambiami` e `GIT_REPO` punta al tuo repository.
3. Il repository `GIT_REPO` è raggiungibile e il branch `main` contiene le cartelle `hello-node`, `hello-node-s2i`, `builder-nodejs-ex288`, `broken-image`.
4. Esiste un progetto `${LAB}-m00` con display name `EX288 - setup`.

**Risultato atteso:** lo script di verifica segnala tutti i requisiti come soddisfatti.

```bash
bash 00-setup/verifica.sh
```

Al termine puoi eliminare il progetto `${LAB}-m00`.

---

## 8. Riferimenti ufficiali

- CLI tools, *Getting started with the OpenShift CLI* (OCP 4.22): https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/cli_tools/openshift-cli-oc
- Web console (OCP 4.22): https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/web_console/web-console-overview
- Pagina ufficiale dell'esame EX288: https://www.redhat.com/en/services/training/ex288-red-hat-certified-openshift-application-developer-exam
