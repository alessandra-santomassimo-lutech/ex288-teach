# Modulo 06 — S2I personalizzato: script, variabili e builder image

> **Obiettivi EX288 coperti**
> - *Work with the source-to-image (S2I) framework* → Build and deploy applications using S2I framework
> - *Work with the source-to-image (S2I) framework* → Customize existing S2I builder images
> - *Work with container images in OpenShift Container Platform* → Work with custom builder workflows to create images to use with OpenShift Container Platform
>
> **Durata stimata:** 4-5 ore · **Prerequisiti:** moduli 02-05, clone `$EX288_WORK/ex288-apps` aggiornato · **Richiede cluster-admin:** no
>
> **Progetti usati:** `${LAB}-m06`, `${LAB}-m06-exam`

---

## 1. Perché e quando

Nel modulo 02 hai usato S2I "così com'è": il builder Node.js sa installare le dipendenze e avviare l'app. Spesso però serve **un passo in più** (scrivere un file di versione, eseguire un controllo, cambiare il comando di avvio) oppure **lo stesso passo in più per tutte le app** dell'azienda. S2I offre quattro livelli di personalizzazione:

| Approccio | Cosa cambi | Chi ne beneficia | Usalo quando | Evitalo quando |
|---|---|---|---|---|
| `.s2i/bin/` nel repository | `assemble`, `run`, `save-artifacts` di **una** app | Solo quel repository | Un'app ha bisogno di un passo particolare | Lo stesso script va copiato in 20 repository |
| `.s2i/environment` nel repository | Variabili di build e runtime di **una** app | Solo quel repository | Configurazione legata al codice, versionata con esso | Valori diversi per ambiente (usa il Deployment) o segreti |
| `scripts` nella BuildConfig (URL) | Script presi da un URL o da un'altra posizione dell'immagine | Le BuildConfig che lo impostano | Non puoi toccare il repo o il builder; vuoi forzare/ripristinare gli script | Lo vuoi come standard per tutti: è un'impostazione per singola build |
| **Builder image personalizzata** | Script (label `io.openshift.s2i.scripts-url`), pacchetti, utenti, label | Tutte le app costruite con quel builder | Standard aziendale: controlli, metadati, tool comuni | Una sola app: troppo costoso da mantenere |
| Dockerfile (strategia Docker, modulo 03) | Tutto | Una app | Serve un'immagine molto diversa (multi-stage, runtime minimo) | Vuoi che il team di sviluppo scriva solo codice |

---

## 2. Concetti essenziali

### 2.1 Come funziona una build S2I

```
 builder (es. nodejs:22-ubi9)                sorgenti (Git o binary, solo contextDir)
          │                                                │
          └────────── S2I genera un Dockerfile ────────────┘
                      FROM <builder>
                      sorgenti        ──▶ /tmp/src
                      script scelti   ──▶ (assemble, run, ...)
                      RUN assemble        installa dipendenze, copia l'app in /opt/app-root/src
                      CMD run             comando di avvio dell'immagine
                                   │ Buildah
                                   ▼
          immagine finale = builder + sorgenti + artefatti ──push──▶ ImageStreamTag
```

| Script | Obbligatorio | Ruolo |
|---|---|---|
| `assemble` | sì | Compila/installa: dai sorgenti in `/tmp/src` agli artefatti nell'immagine |
| `run` | sì | Avvia l'applicazione (diventa il comando dell'immagine) |
| `save-artifacts` | no | Emette (tar su stdout) gli artefatti da riusare nella build successiva: abilita le build **incrementali** |
| `usage` | no | Istruzioni d'uso del builder (è il comando di default dei builder UBI) |
| `test/run` | no | Verifica che l'immagine funzioni |

Nelle immagini UBI di Red Hat gli script originali stanno in **`/usr/libexec/s2i`**, indicata dalla variabile **`STI_SCRIPTS_PATH`** e dalla label **`io.openshift.s2i.scripts-url=image:///usr/libexec/s2i`**.

### 2.2 Da dove vengono gli script: ordine di precedenza

Testo ufficiale (Builds using BuildConfig, S2I): *"All of these locations are checked on each build in the following order: A script specified in the build configuration. A script found in the application source .s2i/bin directory. A script found at the default image URL with the io.openshift.s2i.scripts-url label."* E ancora: *"Files located at the scripts URL take precedence over files located in .s2i/bin of the source repository."*

```
1. spec.strategy.sourceStrategy.scripts (BuildConfig)    vince su tutto
2. .s2i/bin/ nel repository (dentro contextDir)
3. label io.openshift.s2i.scripts-url del builder         default
```

- La scelta avviene **script per script**: se `.s2i/bin` contiene solo `assemble`, `run` arriva dal livello successivo.
- Forme valide per l'URL (sia nella BuildConfig sia nella label): `image:///percorso` (dentro il builder), `file:///percorso`, `http(s)://host/percorso`. La build aggiunge `/assemble`, `/run`, `/save-artifacts` al percorso.

### 2.3 Variabili d'ambiente S2I

| Dove | Quando è disponibile | Note |
|---|---|---|
| `.s2i/environment` (una riga `NOME=valore`) | Build **e** immagine finale | Versionata con il codice; solo strategia Source |
| `sourceStrategy.env` (`oc set env bc/x`, `--build-env`) | Build **e** immagine finale | Configurazione della build, fuori dal codice |
| `oc start-build -e` | Solo quella build | Prove una tantum |
| Deployment (`oc set env deployment/x`) | Solo runtime | **Sovrascrive** il valore presente nell'immagine |

`.s2iignore` (nella radice dei sorgenti) esclude file dalla copia in `/tmp/src`.

### 2.4 Build incrementali

```yaml
strategy:
  sourceStrategy:
    from: {kind: ImageStreamTag, name: nodejs:22-ubi9}
    incremental: true          # riusa artefatti dell'immagine precedente tramite save-artifacts
```

Convengono quando l'installazione delle dipendenze è lenta (molti pacchetti npm, repository Maven `.m2`): `save-artifacts` estrae `node_modules` (o simili) dall'immagine precedente e `assemble` li ripristina. La prima build non è mai incrementale. Se il builder non ha `save-artifacts`, la build riesce comunque e il log segnala che la build incrementale non è stata possibile. Per `hello-node`, che ha zero dipendenze, il guadagno è nullo: lo usiamo solo per osservare il meccanismo.

### 2.5 Builder image personalizzata: anatomia

`apps/builder-nodejs-ex288/Dockerfile`:

```dockerfile
FROM registry.access.redhat.com/ubi9/nodejs-22          # parte dal builder ufficiale: eredita Node.js, npm, script originali
LABEL io.k8s.description="..." \
      io.k8s.display-name="Node.js 22 (ex288)" \
      io.openshift.tags="builder,nodejs,ex288" \
      io.openshift.s2i.scripts-url="image:///usr/libexec/s2i-ex288"   # dove S2I cerca gli script di DEFAULT
USER 0                                                  # root solo per copiare in /usr/libexec
COPY s2i/bin/ /usr/libexec/s2i-ex288/
RUN chmod 0755 /usr/libexec/s2i-ex288/*                 # gli script DEVONO essere eseguibili
USER 1001                                               # utente numerico non root: obbligatorio per S2I
```

I nuovi script **avvolgono** quelli originali (che restano in `/usr/libexec/s2i`): aggiungono un controllo e un file `build-info.txt`, poi delegano. Così beneficiano degli aggiornamenti Red Hat del builder senza riscriverne la logica.

> Puoi aggiungere label all'immagine prodotta anche senza toccare il Dockerfile, con `spec.output.imageLabels` della BuildConfig (Builds using BuildConfig → *Managing build output*).

---

## 3. Laboratorio guidato

```bash
source env.sh                 # dalla root del repository ex288-teach
cd $EX288_WORK/ex288-apps && git switch main && git pull     # parti da main aggiornato
```

### 3.1 Progetto e builder

```bash
oc new-project ${LAB}-m06 --display-name="EX288 m06 - S2I personalizzato"
oc import-image nodejs:22-ubi9 --from=registry.access.redhat.com/ubi9/nodejs-22 --confirm
```

### 3.2 Ispezionare un builder

```bash
# Metadati senza scaricare l'immagine
oc image info registry.access.redhat.com/ubi9/nodejs-22 --filter-by-os=linux/amd64 | grep -iE 'user|workdir|command|scripts-url|STI_SCRIPTS'

# Gli stessi dati dall'image stream tag
oc get istag nodejs:22-ubi9 -o jsonpath='{.image.dockerImageMetadata.Config.Labels.io\.openshift\.s2i\.scripts-url}{"\n"}'
# image:///usr/libexec/s2i
oc get istag nodejs:22-ubi9 -o jsonpath='{.image.dockerImageMetadata.Config.Env}{"\n"}' | tr ',' '\n' | grep -E 'STI_SCRIPTS_PATH|APP_ROOT'
oc get istag nodejs:22-ubi9 -o jsonpath='{.image.dockerImageMetadata.Config.Cmd}{"\n"}'   # di solito lo script usage
```

Leggi gli script con un pod temporaneo:

```bash
oc run s2i-peek --image=registry.access.redhat.com/ubi9/nodejs-22 --restart=Never --command -- sleep 900
oc wait --for=condition=Ready pod/s2i-peek --timeout=180s
oc exec s2i-peek -- ls -l /usr/libexec/s2i          # assemble, run, usage (save-artifacts?)
oc exec s2i-peek -- /usr/libexec/s2i/usage          # istruzioni del builder
oc exec s2i-peek -- cat /usr/libexec/s2i/assemble | less
oc exec s2i-peek -- cat /usr/libexec/s2i/run
oc delete pod s2i-peek
```

Nell'`assemble` di Node.js riconosci: la copia dei sorgenti da `/tmp/src` nella directory corrente (`/opt/app-root/src`), l'installazione delle dipendenze con `npm`, la sistemazione dei permessi per gli UID arbitrari (`fix-permissions`). Nel `run`: l'avvio con `exec` (di solito `npm run`). I dettagli cambiano tra versioni del builder: è proprio per questo che conviene avvolgere lo script originale invece di copiarlo.

> **Abitudine da esame:** prima di personalizzare un builder, guarda `ls /usr/libexec/s2i` e `usage`: in un minuto sai quali script esistono e come si usa.

### 3.3 S2I standard (riferimento)

```bash
oc new-app "nodejs:22-ubi9~$GIT_REPO" --context-dir=hello-node --name=plain
oc logs -f bc/plain
oc expose service/plain
PLAIN=http://$(oc get route plain -o jsonpath='{.spec.host}')
curl -s $PLAIN/build-info          # 404: build-info.txt non presente (nessuno script personalizzato)
oc get istag plain:latest -o jsonpath='{.image.dockerImageMetadata.Config.Cmd}{"\n"}'   # comando = script run
```

`hello-node` contiene un Dockerfile, ma con la sintassi `builder~repo` la strategia è S2I e il Dockerfile viene ignorato.

### 3.4 Personalizzazione 1: `.s2i/bin` nel repository

La cartella `hello-node-s2i` contiene `.s2i/bin/assemble`, `.s2i/bin/run` e `.s2i/environment`.

```bash
oc new-app "nodejs:22-ubi9~$GIT_REPO" --context-dir=hello-node-s2i --name=custom
oc logs -f bc/custom
# ---> [ex288] assemble personalizzato: inizio
# ---> [ex288] sorgenti in /tmp/src:  (elenco file)
# ... output dell'assemble originale (npm) ...
# ---> [ex288] assemble personalizzato: fine
oc expose service/custom
CUSTOM=http://$(oc get route custom -o jsonpath='{.spec.host}')
curl -s $CUSTOM/build-info         # build eseguita da: assemble personalizzato (.s2i/bin) + data, nome build, commit
curl -s $CUSTOM/ | grep message    # "Messaggio definito in .s2i/environment"
oc logs deployment/custom | head -3    # ---> [ex288] run personalizzato: APP_MESSAGE='...'
```

`.s2i/bin/assemble`, riga per riga:

| Riga | Perché |
|---|---|
| `#!/bin/bash` | Interprete esplicito: lo script viene eseguito direttamente |
| `set -euo pipefail` | Qualsiasi errore (anche in una pipe) o variabile non definita interrompe lo script con exit != 0 ⇒ la build fallisce invece di produrre un'immagine a metà |
| `echo "---> [ex288] ..."` | Traccia nel log di build: la convenzione `--->` è quella degli script Red Hat |
| `ls -la /tmp/src` | Mostra cosa S2I ha copiato (solo `contextDir`, esclusi i file di `.s2iignore`) |
| `"${STI_SCRIPTS_PATH:-/usr/libexec/s2i}/assemble"` | **Avvolge** l'assemble originale: copia, `npm install`, permessi. Il default dopo `:-` evita errori se la variabile manca |
| `cat > /opt/app-root/src/build-info.txt <<INFO ...` | Passo aggiuntivo: scrive nell'immagine un file letto dall'endpoint `/build-info`. Usa variabili fornite dalla build (`OPENSHIFT_BUILD_NAME`, `OPENSHIFT_BUILD_COMMIT`) |

`.s2i/bin/run`:

| Riga | Perché |
|---|---|
| `echo "---> [ex288] run personalizzato: APP_MESSAGE=..."` | Banner nei log del pod (runtime, non build) |
| `exec "${STI_SCRIPTS_PATH:-/usr/libexec/s2i}/run"` | `exec` **sostituisce** la shell con lo script originale: il processo dell'app diventa PID 1 e riceve direttamente `SIGTERM` quando OpenShift ferma il pod |

```bash
oc exec deployment/custom -- cat /proc/1/cmdline | tr '\0' ' '; echo   # PID 1 NON è bash: è il processo avviato dal run originale
```

### 3.5 `.s2i/environment`, variabili di build e di runtime

```bash
# Le variabili di .s2i/environment sono nell'immagine
oc get istag custom:latest -o jsonpath='{.image.dockerImageMetadata.Config.Env}{"\n"}' | tr ',' '\n' | grep APP_
# APP_MESSAGE=Messaggio definito in .s2i/environment
# APP_BUILT_WITH=s2i-custom-scripts

# Variabile di build (BuildConfig): anch'essa finisce nell'immagine
oc set env bc/custom APP_BUILD_NOTE="impostata nella BuildConfig"
oc start-build custom --follow
curl -s $CUSTOM/env                # APP_BUILD_NOTE, APP_BUILT_WITH, APP_MESSAGE

# Il Deployment vince sull'immagine (solo a runtime)
oc set env deployment/custom APP_MESSAGE="Impostato nel Deployment"
oc rollout status deployment/custom && curl -s $CUSTOM/ | grep message
oc set env deployment/custom APP_MESSAGE-           # torna il valore dell'immagine
```

### 3.6 Personalizzazione 2: `scripts` nella BuildConfig

Il campo `scripts` vince su `.s2i/bin`: lo usiamo per **tornare agli script originali** del builder senza toccare il repository.

```bash
oc patch bc/custom --type=merge -p '{"spec":{"strategy":{"sourceStrategy":{"scripts":"image:///usr/libexec/s2i"}}}}'
oc start-build custom --follow     # nessuna riga [ex288] nel log
oc rollout status deployment/custom
curl -s $CUSTOM/build-info         # 404: l'assemble personalizzato non è stato usato
curl -s $CUSTOM/ | grep message    # .s2i/environment invece vale ancora: non è uno script

# Rimuovi il campo per tornare a .s2i/bin
oc patch bc/custom --type=json -p '[{"op":"remove","path":"/spec/strategy/sourceStrategy/scripts"}]'
oc start-build custom --follow
```

Facoltativo, se `$GIT_REPO` è un repository **pubblico** su GitHub: gli script possono arrivare via HTTP, per esempio quelli del builder ex288 sul branch `main`:

```bash
# URL "raw" della cartella che contiene assemble e run (la build aggiunge /assemble e /run)
RAW=https://raw.githubusercontent.com/<utente>/ex288-apps/main/builder-nodejs-ex288/s2i/bin
oc patch bc/plain --type=merge -p "{\"spec\":{\"strategy\":{\"sourceStrategy\":{\"scripts\":\"$RAW\"}}}}"
oc start-build plain --follow      # [builder-ex288] verifico che esista package.json
```

> **Da verificare sul tuo cluster:** se un URL `http(s)` non è raggiungibile, S2I prova le posizioni successive (`.s2i/bin`, poi la label) e la build può **riuscire con gli script sbagliati**: controlla sempre il log. Un URL `image://` errato invece fa fallire la build (scenario 4).

### 3.7 Build incrementali

```bash
# Solo se hai eseguito il passo facoltativo con lo URL http: torna agli script di default
oc patch bc/plain --type=json -p '[{"op":"remove","path":"/spec/strategy/sourceStrategy/scripts"}]'

oc patch bc/plain --type=merge -p '{"spec":{"strategy":{"sourceStrategy":{"incremental":true}}}}'
oc start-build plain --follow | grep -iE 'artifact|incremental|save'
```

> **Da verificare sul tuo cluster:** i messaggi esatti dipendono dalla versione del builder. Se nel passo 3.2 non hai trovato `save-artifacts` in `/usr/libexec/s2i`, la build riesce lo stesso e il log dice che la build incrementale non è stata eseguita.

### 3.8 Personalizzazione 3: costruire un builder personalizzato nel cluster

```bash
sed -e "s|__GIT_REPO__|$GIT_REPO|g" -e "s|__GIT_BRANCH__|$GIT_BRANCH|g" \
  $EX288_HOME/06-s2i-personalizzato/lab/builder-ex288.yaml | oc apply -f -
oc logs -f bc/nodejs-ex288          # build Docker: COPY s2i/bin ..., RUN chmod ..., push nodejs-ex288:1.0

# Le label che contano
oc get istag nodejs-ex288:1.0 -o jsonpath='{.image.dockerImageMetadata.Config.Labels}{"\n"}' | tr ',' '\n'
# "io.openshift.s2i.scripts-url":"image:///usr/libexec/s2i-ex288"
# "io.openshift.tags":"builder,nodejs,ex288"  ...

# Lo script usage del nuovo builder
oc run usage-ex288 --restart=Never \
  --image=$(oc get istag nodejs-ex288:1.0 -o jsonpath='{.image.dockerImageReference}') \
  --command -- /usr/libexec/s2i-ex288/usage
sleep 15; oc logs usage-ex288; oc delete pod usage-ex288
```

Usalo come builder per un'app:

```bash
oc new-app "nodejs-ex288:1.0~$GIT_REPO" --context-dir=hello-node --name=hello-ex288
# hello-node contiene un Dockerfile, ma con ~ la strategia è S2I con il builder indicato
oc get bc hello-ex288 -o jsonpath='{.spec.strategy.type} {.spec.strategy.sourceStrategy.from.name}{"\n"}'   # Source nodejs-ex288:1.0
oc logs -f bc/hello-ex288
# ---> [builder-ex288] verifico che esista package.json
# ... assemble originale ...
# ---> [builder-ex288] build-info.txt scritto
oc expose service/hello-ex288
EX=http://$(oc get route hello-ex288 -o jsonpath='{.spec.host}')
curl -s $EX/build-info             # build eseguita dal builder personalizzato ex288 il <data>
oc logs deployment/hello-ex288 | head -2   # ---> [builder-ex288] avvio applicazione
```

### 3.9 Le precedenze, dal vivo

Stesso builder, repository con `.s2i/bin`:

```bash
oc new-app "nodejs-ex288:1.0~$GIT_REPO" --context-dir=hello-node-s2i --name=prec
oc logs -f bc/prec                 # righe [ex288] (repository), NON [builder-ex288]
oc expose service/prec
PREC=http://$(oc get route prec -o jsonpath='{.spec.host}')
curl -s $PREC/build-info           # assemble personalizzato (.s2i/bin): il repository vince sulla label

# Forza gli script del builder dalla BuildConfig
oc patch bc/prec --type=merge -p '{"spec":{"strategy":{"sourceStrategy":{"scripts":"image:///usr/libexec/s2i-ex288"}}}}'
oc start-build prec --follow       # ora [builder-ex288]
oc rollout status deployment/prec
curl -s $PREC/build-info           # builder personalizzato ex288: la BuildConfig vince sul repository
```

| App | Builder | `.s2i/bin` nel repo | `scripts` nella bc | Script usati |
|---|---|---|---|---|
| `plain` | nodejs:22-ubi9 | no | — | originali (label) |
| `custom` | nodejs:22-ubi9 | sì | — | `.s2i/bin` |
| `hello-ex288` | nodejs-ex288:1.0 | no | — | ex288 (label) |
| `prec` (prima) | nodejs-ex288:1.0 | sì | — | `.s2i/bin` |
| `prec` (dopo) | nodejs-ex288:1.0 | sì | `image:///usr/libexec/s2i-ex288` | ex288 (bc) |

### 3.10 Aggiornare il builder ricostruisce le app

`oc new-app` ha creato in `hello-ex288` e `prec` un trigger ImageChange su `nodejs-ex288:1.0`.

```bash
oc set triggers bc/hello-ex288                  # ImageChange  nodejs-ex288:1.0
oc start-build nodejs-ex288 --follow            # nuova immagine (nuovo digest) su nodejs-ex288:1.0
oc get builds -w                                # partono da sole hello-ex288-2 e prec-N (Ctrl+C)
oc describe build hello-ex288-2 | grep -iA2 cause   # Image change
oc rollout history deployment/hello-ex288       # nuova revisione
```

La catena completa è: `nodejs:22-ubi9` → (ImageChange) → `nodejs-ex288:1.0` → (ImageChange) → build delle app → (trigger del Deployment) → rollout. Una patch di sicurezza del builder Red Hat arriva a tutte le app senza intervento manuale.

### 3.11 (Facoltativo) La CLI `s2i`

La CLI `s2i` permette di provare un builder sul PC (richiede Podman/Docker e non serve all'esame):

```bash
s2i create <nome-immagine> <directory>            # scheletro di un nuovo builder (Dockerfile, s2i/bin, test)
s2i build file:///percorso/app <builder> <immagine-output>
podman run <builder>                              # esegue lo script usage
```

### 3.12 Pulizia

Tieni `${LAB}-m06` (serve `nodejs-ex288:1.0` per lo scenario 2). A fine modulo: `oc delete project ${LAB}-m06`.

---

## 4. Esercizi

### 4.1 Esercizio guidato

Nel branch Git `s2i-lab` modifica `hello-node-s2i/.s2i/bin/assemble` in modo che `build-info.txt` contenga anche la riga `versione Node.js: <output di node --version>`. Crea nel progetto `${LAB}-m06` l'app `lab41` da quel branch con il builder `nodejs:22-ubi9` e verifica l'endpoint `/build-info`.

<details><summary>Suggerimenti</summary>

- Aggiungi la riga dentro l'heredoc `INFO`: le sostituzioni `$(...)` funzionano anche lì.
- Ricorda `git push -u origin s2i-lab` e la sintassi `repo#branch`.
</details>

<details><summary>Soluzione</summary>

```bash
cd $EX288_WORK/ex288-apps && git switch -c s2i-lab
# aggiungi dopo la riga "OPENSHIFT_BUILD_COMMIT: ...":
#   versione Node.js: $(node --version)
vi hello-node-s2i/.s2i/bin/assemble
git diff
git commit -am "assemble: versione di Node.js in build-info" && git push -u origin s2i-lab
git switch main
oc project ${LAB}-m06
oc new-app "nodejs:22-ubi9~$GIT_REPO#s2i-lab" --context-dir=hello-node-s2i --name=lab41
oc logs -f bc/lab41
oc expose service/lab41
curl -s http://$(oc get route lab41 -o jsonpath='{.spec.host}')/build-info   # ... versione Node.js: v22.x.y
```
</details>

### 4.2 Esercizio semi-guidato

1. Sulla BuildConfig `custom` imposta la variabile di build `APP_MESSAGE=Dalla BuildConfig`, che è definita **anche** in `.s2i/environment`. Ricostruisci: quale valore finisce nell'immagine? E a runtime?
2. Abilita le build incrementali su `hello-ex288` e spiega, leggendo il log, cosa succede (il builder ex288 non fornisce `save-artifacts` nella sua cartella di script).

<details><summary>Suggerimenti</summary>

- Confronta `oc get istag custom:latest -o jsonpath='{.image.dockerImageMetadata.Config.Env}'` e `curl $CUSTOM/`.
- La documentazione non dichiara quale delle due fonti prevale: è un buon esempio di comportamento da **verificare** invece che ricordare. All'esame evita di definire la stessa variabile in due posti.
- Per `save-artifacts` ripassa l'ordine di precedenza degli script: dove lo cerca S2I?
</details>

<details><summary>Soluzione (aprila solo dopo aver provato)</summary>

```bash
oc project ${LAB}-m06
CUSTOM=http://$(oc get route custom -o jsonpath='{.spec.host}')

# --- Parte 1: APP_MESSAGE definita in due posti ---------------------------------
# Situazione di partenza: il valore arriva solo da .s2i/environment
oc get istag custom:latest -o jsonpath='{.image.dockerImageMetadata.Config.Env}{"\n"}' | tr ',' '\n' | grep APP_MESSAGE
# "APP_MESSAGE=Messaggio definito in .s2i/environment"
oc set env deployment/custom --list | grep APP_MESSAGE    # nessun output: il Deployment non la definisce (rimossa nel 3.5)

oc set env bc/custom APP_MESSAGE="Dalla BuildConfig"
oc set env bc/custom --list                               # APP_BUILD_NOTE (passo 3.5), APP_MESSAGE=Dalla BuildConfig
oc start-build custom --follow
oc rollout status deployment/custom                       # il Deployment segue custom:latest

# a) Valore NELL'IMMAGINE: quante volte compare APP_MESSAGE e con quale valore
oc get istag custom:latest -o jsonpath='{.image.dockerImageMetadata.Config.Env}{"\n"}' | tr ',' '\n' | grep APP_MESSAGE

# b) Valore A RUNTIME, visto dal processo dell'app
curl -s $CUSTOM/ | grep message
oc exec deployment/custom -- printenv APP_MESSAGE
oc logs deployment/custom | grep 'run personalizzato'     # banner del run: APP_MESSAGE='...' all'avvio

# c) Il Deployment sovrascrive l'immagine, solo a runtime
oc set env deployment/custom APP_MESSAGE="Dal Deployment"
oc rollout status deployment/custom
curl -s $CUSTOM/ | grep message                           # "Dal Deployment"
oc get istag custom:latest -o jsonpath='{.image.dockerImageMetadata.Config.Env}{"\n"}' | tr ',' '\n' | grep APP_MESSAGE   # immagine invariata
oc set env deployment/custom APP_MESSAGE-                 # torna il valore dell'immagine

# Pulizia consigliata: la variabile in un solo posto
oc set env bc/custom APP_MESSAGE-
oc start-build custom --follow

# --- Parte 2: build incrementale con il builder ex288 ----------------------------
# Dove cerca gli script S2I per hello-ex288?
oc get bc hello-ex288 -o jsonpath='{.spec.strategy.sourceStrategy.scripts}{"\n"}'   # vuoto: nessun override nella bc
# hello-node non ha .s2i/bin -> resta la label del builder
oc get istag nodejs-ex288:1.0 -o jsonpath='{.image.dockerImageMetadata.Config.Labels.io\.openshift\.s2i\.scripts-url}{"\n"}'
# image:///usr/libexec/s2i-ex288
oc run peek-ex288 --restart=Never \
  --image=$(oc get istag nodejs-ex288:1.0 -o jsonpath='{.image.dockerImageReference}') \
  --command -- ls -l /usr/libexec/s2i-ex288 /usr/libexec/s2i
sleep 15; oc logs peek-ex288; oc delete pod peek-ex288
# /usr/libexec/s2i-ex288: assemble, run, usage  -> nessun save-artifacts

oc patch bc/hello-ex288 --type=merge -p '{"spec":{"strategy":{"sourceStrategy":{"incremental":true}}}}'
oc get bc hello-ex288 -o jsonpath='{.spec.strategy.sourceStrategy.incremental}{"\n"}'   # true
oc start-build hello-ex288 --follow | tee $EX288_WORK/m06/hello-ex288-incr.log
grep -iE 'artifact|incremental|save' $EX288_WORK/m06/hello-ex288-incr.log    # messaggio sul save-artifacts mancante
oc get builds -l buildconfig=hello-ex288 | tail -1                 # Complete
curl -s http://$(oc get route hello-ex288 -o jsonpath='{.spec.host}')/build-info   # build eseguita dal builder personalizzato ex288 ...
```

**Parte 1, immagine:** la documentazione dice solo che le variabili di `.s2i/environment` e quelle della BuildConfig sono presenti durante la build e nell'immagine prodotta, **non** quale prevale se hanno lo stesso nome. La risposta quindi è quella che leggi al punto a): annotala. Se `APP_MESSAGE` compare due volte in `Config.Env`, il valore che conta è quello che il processo vede davvero (punto b).

**Parte 1, runtime:** finché il Deployment non definisce `APP_MESSAGE`, a runtime vale il valore dell'immagine (b coincide con a). Quando il Deployment la definisce, vince il Deployment (punto c), ma l'immagine resta invariata: per questo "valore nell'immagine" e "valore a runtime" sono due domande diverse. All'esame non definire la stessa variabile in due posti.

**Parte 2:** S2I cerca `save-artifacts` con lo stesso ordine degli altri script: `scripts` della BuildConfig (assente), `.s2i/bin` del repository (assente in `hello-node`), URL della label `io.openshift.s2i.scripts-url` del builder, cioè `/usr/libexec/s2i-ex288`, dove ci sono solo `assemble`, `run` e `usage`. Lo script originale in `/usr/libexec/s2i` non viene considerato, anche se esiste: la label ha spostato la posizione di default. Senza `save-artifacts` non si può estrarre nulla dall'immagine precedente. La documentazione conferma che la build riesce comunque e che il log segnala che la build incrementale non è riuscita per la mancanza dello script. Risultato: una build completa normale (per `hello-node`, senza dipendenze, non cambia nulla). Per supportarla, il builder ex288 dovrebbe fornire un proprio `save-artifacts` in `/usr/libexec/s2i-ex288` e un `assemble` che ripristini gli artefatti.

> **Da verificare sul tuo cluster:** (1) quale valore di `APP_MESSAGE` finisce nell'immagine (punto a): non è documentato, conta ciò che vedi; (2) il testo esatto del messaggio sul `save-artifacts` mancante (cercalo con il `grep` sul log; se non compare, ripeti con `oc start-build hello-ex288 --build-loglevel=5 --follow`); (3) se `/usr/libexec/s2i` del builder Node.js contiene `save-artifacts` (dall'output di `ls`): in ogni caso, con la label ex288, S2I non lo usa.
</details>

### 4.3 Esercizio senza aiuti

Nel branch `builder-v11` crea la versione **1.1** del builder ex288: `assemble` scrive in `build-info.txt` anche la versione di Node.js e `usage` cita la versione 1.1. Pubblicala come `nodejs-ex288:1.1` con una **nuova** BuildConfig, poi fai in modo che `hello-ex288` venga ricostruita con 1.1 **senza ricrearla** e che si ricostruisca automaticamente a ogni nuova build di 1.1.

---

## 5. Verifiche pratiche con `oc`

| Domanda | Comando |
|---|---|
| Dove sono gli script di default di un builder? | `oc get istag <is>:<tag> -o jsonpath='{.image.dockerImageMetadata.Config.Labels.io\.openshift\.s2i\.scripts-url}'` |
| Quali script ha davvero il builder? | `oc run ... --command -- ls -l /usr/libexec/s2i` (o il percorso della label) |
| La BuildConfig forza gli script? | `oc get bc <bc> -o jsonpath='{.spec.strategy.sourceStrategy.scripts}'` |
| Quali script sono stati usati? | `oc logs build/<b>` (cerca i messaggi degli script) · comando dell'immagine: `oc get istag <app>:latest -o jsonpath='{.image.dockerImageMetadata.Config.Cmd}'` |
| Che variabili ha l'immagine? | `oc get istag <app>:latest -o jsonpath='{.image.dockerImageMetadata.Config.Env}'` |
| Variabili di build | `oc set env bc/<bc> --list` |
| Build incrementale attiva? | `oc get bc <bc> -o jsonpath='{.spec.strategy.sourceStrategy.incremental}'` |
| Quale builder ha usato una build (digest)? | `oc get build <b> -o jsonpath='{.spec.strategy.sourceStrategy.from.name}'` |
| L'app si ricostruisce se cambia il builder? | `oc set triggers bc/<bc>` (ImageChange) |
| Chi è il PID 1 nel container? | `oc exec deploy/<d> -- cat /proc/1/cmdline \| tr '\0' ' '` |

---

## 6. Troubleshooting intenzionale

```bash
oc project ${LAB}-m06
for s in 1-permessi 2-package 3-run-senza-exec 4-scripts-url 5-environment; do
  bash $EX288_HOME/06-s2i-personalizzato/troubleshooting/rompi-$s.sh
done
```

Gli scenari 1 e 3 creano un piccolo builder (`tN-builder`, Dockerfile inline) e un'app (`tN-app`) che parte da sola quando il builder è pronto. Lo scenario 2 richiede `nodejs-ex288:1.0` (passo 3.8). Lo scenario 5 esegue una build binaria da una copia di `apps/hello-node-s2i`: il tuo repository non viene modificato.

### Scenario 1 — `t1-app`: permission denied

**Sintomo:** `t1-builder-1` è `Complete`, ma `t1-app-1` è `Failed`.

<details><summary>Indagine e soluzione</summary>

```bash
oc logs build/t1-app-1 | tail -5
# /bin/sh: line 1: /usr/libexec/s2i-t1/assemble: Permission denied
oc get istag t1-builder:1 -o jsonpath='{.image.dockerImageMetadata.Config.Labels.io\.openshift\.s2i\.scripts-url}{"\n"}'
oc run t1-peek --restart=Never --image=$(oc get istag t1-builder:1 -o jsonpath='{.image.dockerImageReference}') \
  --command -- ls -l /usr/libexec/s2i-t1
sleep 10; oc logs t1-peek; oc delete pod t1-peek     # -rw-r--r-- : manca il bit x
```
**Causa:** il Dockerfile del builder crea gli script senza renderli eseguibili.
**Fix:** `oc edit bc/t1-builder` e aggiungi `chmod 0755 /usr/libexec/s2i-t1/*` alla `RUN` (dopo il secondo `printf`, con `&& \`), poi `oc start-build t1-builder --follow`. Il trigger ImageChange ricostruisce `t1-app` da solo.
**Lezione:** gli script S2I devono essere eseguibili **nell'immagine**. Se arrivano da Git (il `COPY` di un builder, o script di supporto che il tuo `assemble` invoca dal repository), il bit di esecuzione deve essere registrato **in Git**: da macOS/Windows, dove il filesystem può perderlo, usa
`git update-index --chmod=+x builder-nodejs-ex288/s2i/bin/assemble` (verifica con `git ls-files -s <file>`: modo `100755`), poi commit e push. Il `RUN chmod 0755` nel Dockerfile di `builder-nodejs-ex288` è una seconda protezione.
</details>

> **Da verificare sul tuo cluster:** per gli script standard presi da `.s2i/bin`, S2I può impostare da sé i permessi durante l'installazione; prova a togliere il bit con `git update-index --chmod=-x hello-node-s2i/.s2i/bin/assemble` in un branch di prova e osserva il risultato.

### Scenario 2 — `t2-nopkg`: il builder rifiuta i sorgenti

**Sintomo:** `t2-nopkg-1` è `Failed`.

<details><summary>Indagine e soluzione</summary>

```bash
oc logs build/t2-nopkg-1 | tail -4
# ---> [builder-ex288] verifico che esista package.json
# ERRORE: package.json non trovato nei sorgenti: questo builder supporta solo app Node.js
oc get bc t2-nopkg -o jsonpath='{.spec.source.contextDir}{"\n"}'     # builder-nodejs-ex288
```
**Causa:** il `contextDir` punta alla cartella del builder (Dockerfile e script), non a un'app Node.js: l'`assemble` personalizzato esce con errore.
**Fix:** `oc patch bc/t2-nopkg --type=merge -p '{"spec":{"source":{"contextDir":"hello-node"}}}'` e `oc start-build t2-nopkg --follow`.
**Lezione:** un messaggio di errore chiaro nell'`assemble` (con `exit 1`) è il modo migliore per far fallire presto una build sbagliata. Le prime righe utili del log sono quelle con il prefisso dello script.
</details>

### Scenario 3 — `t3-app`: arresto lento

**Riproduci:** quando `t3-app:latest` esiste, `oc new-app --image-stream=t3-app --name=t3-app -l scenario=m06-3`, poi `time oc delete pod -l deployment=t3-app`.
**Sintomo:** l'app risponde, ma la cancellazione del pod richiede circa 30 secondi; un pod di `custom` (passo 3.4) si ferma in pochi secondi.

<details><summary>Indagine e soluzione</summary>

```bash
POD=$(oc get pod -l deployment=t3-app -o name | head -1)
oc exec $POD -- cat /proc/1/cmdline | tr '\0' ' '; echo     # /bin/bash /usr/libexec/s2i-t3/run
oc logs deployment/t3-app | head -3                          # ---> [t3] avvio applicazione
oc get deploy t3-app -o jsonpath='{.spec.template.spec.terminationGracePeriodSeconds}{"\n"}'   # 30
oc run t3-peek --restart=Never --image=$(oc get istag t3-builder:1 -o jsonpath='{.image.dockerImageReference}') \
  --command -- cat /usr/libexec/s2i-t3/run
sleep 10; oc logs t3-peek; oc delete pod t3-peek            # nessun "exec" prima di /usr/libexec/s2i/run
```
**Causa:** lo script `run` avvia l'applicazione come processo figlio invece che con `exec`. PID 1 resta `bash`, che non inoltra `SIGTERM` all'applicazione: OpenShift attende il *grace period* (30 s) e poi termina tutto con `SIGKILL`. L'app non esegue la chiusura pulita (il messaggio `SIGTERM ricevuto: chiudo il server` non compare) e la riga `applicazione terminata` non viene mai stampata.
**Fix:** `oc edit bc/t3-builder`: nella `printf` del `run` sostituisci `/usr/libexec/s2i/run\necho ...` con `exec /usr/libexec/s2i/run\n`; `oc start-build t3-builder --follow`. Le build di `t3-app` e il rollout seguono da soli.
**Lezione:** ogni script wrapper che avvia il processo principale deve terminare con `exec` (linee guida Red Hat per le immagini). Il sintomo non è un errore ma un arresto lento e connessioni troncate durante i rollout.
</details>

### Scenario 4 — `t4-url`: script non trovati

**Sintomo:** `t4-url-1` è `Failed` subito dopo il clone.

<details><summary>Indagine e soluzione</summary>

```bash
oc logs build/t4-url-1 | tail -5          # /usr/lib/s2i/assemble: No such file or directory
oc get bc t4-url -o jsonpath='{.spec.strategy.sourceStrategy.scripts}{"\n"}'   # image:///usr/lib/s2i
```
**Causa:** il campo `scripts` della BuildConfig punta a un percorso inesistente nel builder (quello giusto è `/usr/libexec/s2i`). Poiché `scripts` ha la precedenza massima, S2I prova a eseguire `assemble` da lì.
**Fix:** se servono gli script di default, rimuovi il campo: `oc patch bc/t4-url --type=json -p '[{"op":"remove","path":"/spec/strategy/sourceStrategy/scripts"}]'`; altrimenti correggi il percorso. Poi `oc start-build t4-url --follow`.
**Lezione:** con `image://` il percorso è **dentro il builder**: verificalo con la label `io.openshift.s2i.scripts-url` o con un `ls` in un pod. Con un URL `http(s)` non raggiungibile il sintomo può essere diverso (vedi la nota del passo 3.6).
</details>

### Scenario 5 — `t5-env`: manca il messaggio

**Sintomo:** la build `t5-env-1` è `Complete`, ma il requisito "l'immagine deve avere `APP_MESSAGE=Messaggio dello scenario 5`" non è soddisfatto.

<details><summary>Indagine e soluzione</summary>

```bash
oc get istag t5-env:latest -o jsonpath='{.image.dockerImageMetadata.Config.Env}{"\n"}' | tr ',' '\n' | grep APP_
# APP_TEAM=ex288          <- c'è
#                         <- APP_MESSAGE manca
oc get bc t5-env -o jsonpath='{.spec.source.type}{"\n"}'          # Binary: il sorgente non è in Git
oc logs build/t5-env-1 | head -20                                 # nessun errore evidente
```
Il file usato (creato dallo script di scenario) era:

```
APP_MESSAGE: Messaggio dello scenario 5
APP_TEAM=ex288
```
**Causa:** `.s2i/environment` accetta solo righe `NOME=valore`. La riga in stile YAML (`NOME: valore`) non viene interpretata come variabile, senza errori.
**Fix:** correggi il file nella sorgente e ricostruisci. Per una build binaria serve ricaricare la cartella:

```bash
mkdir -p $EX288_WORK/m06/t5 && cp -R $EX288_HOME/apps/hello-node-s2i/. $EX288_WORK/m06/t5/
printf 'APP_MESSAGE=Messaggio dello scenario 5\nAPP_TEAM=ex288\n' > $EX288_WORK/m06/t5/.s2i/environment
oc start-build t5-env --from-dir=$EX288_WORK/m06/t5 --follow
oc get istag t5-env:latest -o jsonpath='{.image.dockerImageMetadata.Config.Env}{"\n"}' | tr ',' '\n' | grep APP_
```
**Lezione:** niente `export`, niente `:`, niente spazi attorno a `=`: una variabile per riga. Controlla sempre il risultato nell'immagine (`Config.Env` dell'image stream tag), non solo che la build sia `Complete`.
</details>

> **Da verificare sul tuo cluster:** a seconda della versione di S2I una riga malformata può essere ignorata in silenzio oppure produrre un avviso nel log (alza la verbosità con `oc start-build ... --build-loglevel=5`).

Pulizia: `oc delete project ${LAB}-m06`

---

## 7. Esercizio finale (stile EX288)

> Lavora come all'esame: niente soluzioni, solo documentazione ufficiale, `oc --help` e `oc explain`. Tempo indicativo: **50 minuti**.

**Requisiti**

1. Esiste il progetto `${LAB}-m06-exam`, con l'image stream tag `nodejs:22-ubi9` importato da `registry.access.redhat.com/ubi9/nodejs-22`.
2. La BuildConfig **`nodejs-corp`** costruisce nel cluster un builder S2I personalizzato:
   - strategia **Docker**, sorgente `$GIT_REPO` branch `main`, cartella `builder-nodejs-ex288`;
   - come immagine base usa l'image stream tag `nodejs:22-ubi9` del progetto e si ricostruisce automaticamente quando questo cambia;
   - pubblica l'immagine nel tag **`nodejs-corp:1.0`**.
3. L'immagine `nodejs-corp:1.0` ha le label:
   - `io.k8s.display-name` = `Node.js 22 Corp`;
   - `io.openshift.tags` = `builder,nodejs,corp`;
   - `io.openshift.s2i.scripts-url` = `image:///usr/libexec/s2i-ex288`.
4. Nel repository `$GIT_REPO` esiste, sul remoto, il branch **`exam-s2i`** in cui `hello-node-s2i/.s2i/environment` definisce `APP_MESSAGE=Inventario S2I` (la riga `APP_BUILT_WITH` resta invariata).
5. La BuildConfig **`inventory`**:
   - strategia **Source** con il builder `nodejs-corp:1.0`;
   - sorgente `$GIT_REPO` branch `exam-s2i`, cartella `hello-node-s2i`;
   - variabile di build `APP_TIER=exam`;
   - build incrementali abilitate;
   - deve usare gli script `assemble` e `run` del **builder** `nodejs-corp`, non quelli presenti nel repository;
   - si ricostruisce automaticamente quando cambia `nodejs-corp:1.0`.
6. Il builder `nodejs-corp` è stato ricostruito almeno una volta dopo la prima build, e l'ultima build completata di `inventory` usa l'immagine **attuale** di `nodejs-corp:1.0`.
7. Il Deployment **`inventory`** ha 1 replica pronta, esegue l'immagine attuale di `inventory:latest` e **non** definisce `APP_MESSAGE` né `APP_TIER`. È raggiungibile via HTTP dalla route `inventory`.

**Risultato atteso**

- `http://<route inventory>/` restituisce `"message": "Inventario S2I"`.
- `http://<route inventory>/env` mostra `"APP_TIER": "exam"` e `"APP_BUILT_WITH": "s2i-custom-scripts"`.
- `http://<route inventory>/build-info` contiene `builder personalizzato ex288`.

```bash
bash $EX288_HOME/06-s2i-personalizzato/verifica.sh
```

---

## 8. Riferimenti ufficiali (OCP 4.22)

- Builds using BuildConfig → *Using build strategies* → *Source-to-image build* (build incrementali, override degli script e ordine di precedenza, variabili d'ambiente, `.s2iignore`, creazione di immagini da sorgente con S2I): https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/builds_using_buildconfig/build-strategies
- Builds using BuildConfig → *Managing build output* (`imageLabels`, variabili e label aggiunte all'immagine): https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/builds_using_buildconfig/managing-build-output
- Images → *Creating images* (linee guida: `exec` negli script wrapper, UID arbitrari, utente numerico; S2I: script, `STI_SCRIPTS_PATH`, label, `s2i create`/`s2i build`): https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/images/creating-images
- Builds using BuildConfig → *Triggering and modifying builds* (trigger ImageChange): https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/builds_using_buildconfig/triggering-builds-build-hooks
- Building applications → *Creating applications* (`oc new-app builder~repo`, `--build-env`): https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/building_applications/creating-applications
- CLI tools → *OpenShift CLI developer command reference* (`oc image info`, `oc run`, `oc set env`, `oc set triggers`): https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/cli_tools/openshift-cli-oc
