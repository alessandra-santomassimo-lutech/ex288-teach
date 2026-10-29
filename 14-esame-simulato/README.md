# Modulo 14 — Esame simulato EX288

> **Obiettivi EX288 coperti:** tutti (vedi la tabella in fondo).
>
> **Durata:** 4 ore, come l'esame reale · **Prerequisiti:** moduli 00-13 completati · **Richiede cluster-admin:** no
>
> **Progetti usati:** `${LAB}-ex-build`, `${LAB}-ex-prod`, `${LAB}-ex-helm`, `${LAB}-ex-kust`, `${LAB}-ex-cicd`, `${LAB}-ex-fix`

---

## Regole

Simula le condizioni d'esame il più fedelmente possibile:

1. **Timer di 4 ore**, senza pause lunghe.
2. Puoi consultare **solo** la documentazione ufficiale (docs.redhat.com: OpenShift Container Platform 4.22 e Red Hat OpenShift Pipelines), `oc --help`, `oc explain`, `helm --help`, `tkn --help`. Niente appunti del corso, niente soluzioni dei moduli, niente motori di ricerca.
3. I task sono descritti solo da **requisiti e risultato atteso**: decidi tu come arrivarci.
4. **Regola di persistenza** (dall'esame ufficiale): tutto ciò che configuri deve restare funzionante nel normale ciclo di vita della piattaforma, senza interventi manuali. Modificare un pod a mano o lanciare processi con `oc rsh` non conta: devono essere le risorse (Deployment, BuildConfig, ...) a produrre il risultato.
5. Fai la verifica **solo alla fine** (o quando dichiari concluso un task): all'esame non c'è nessuno script che ti dica se hai fatto bene.

> **Strategia:** leggi tutti i task prima di iniziare. Alcuni dipendono da altri (il 4 dal 3, il 7 dal 5 e dal 6). Se un task si blocca per più di 20 minuti, passa al successivo e torna dopo.

### Preparazione (prima di far partire il timer)

```bash
source env.sh                 # dalla root del repository ex288-teach
bash $EX288_HOME/14-esame-simulato/prepara.sh     # crea il progetto ${LAB}-ex-fix con risorse da correggere (task 11)
mkdir -p $EX288_WORK/m14-exam                              # cartella locale per chart Helm e Kustomize
```

Valori che ti servono durante l'esame (l'equivalente dei dati forniti dall'esaminatore):

| Dato | Valore |
|---|---|
| Repository Git | `$GIT_REPO`, branch `main` |
| Immagine builder Node.js | `registry.access.redhat.com/ubi9/nodejs-22` |
| Immagine database | `$POSTGRES_IMAGE` (variabili `POSTGRESQL_USER`, `POSTGRESQL_PASSWORD`, `POSTGRESQL_DATABASE`, porta 5432) |
| Immagine web generica | `registry.access.redhat.com/ubi9/httpd-24` (porta 8080) |
| Applicazione `hello-node` | porta 8080; variabili `APP_MESSAGE`, `CONFIG_FILE` (default `/etc/app/app.properties`), `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_PASSWORD`; endpoint `/`, `/ready`, `/healthz`, `/config`, `/db`, `/build-info`; `npm test` esegue i test unitari |
| Builder S2I personalizzato | cartella `builder-nodejs-ex288` del repository |

---

## Task 1 — Progetti e accessi (10 minuti)

1. Esistono i progetti `${LAB}-ex-build` (display name `Exam Build`) e `${LAB}-ex-prod` (display name `Exam Prod`).
2. Nel progetto `${LAB}-ex-prod` esiste il service account `deployer`, che può creare e modificare risorse applicative del progetto ma non può gestirne i permessi.
3. Tutti i service account del progetto `${LAB}-ex-prod` possono scaricare le immagini contenute negli image stream di `${LAB}-ex-build`. Nessun permesso più ampio del necessario.

## Task 2 — Image stream del builder (10 minuti)

1. Nel progetto `${LAB}-ex-build` esiste l'image stream `nodejs` con il tag `22` che fa riferimento a `registry.access.redhat.com/ubi9/nodejs-22`.
2. Il tag `nodejs:22` viene reimportato periodicamente in automatico dal registry di origine.

## Task 3 — Builder S2I personalizzato (20 minuti)

1. Nel progetto `${LAB}-ex-build` esiste la BuildConfig `corp-builder` che costruisce, con strategia **Docker**, il contenuto della cartella `builder-nodejs-ex288` del repository Git, branch `main`.
2. L'immagine prodotta viene pubblicata nel tag `corp-builder:1.0` dell'image stream `corp-builder`.
3. Almeno una build di `corp-builder` è stata completata con successo.
4. L'immagine `corp-builder:1.0` dichiara gli script S2I in `/usr/libexec/s2i-ex288` (label standard per l'URL degli script).

## Task 4 — Build applicativa con hook e trigger (35 minuti)

1. Nel progetto `${LAB}-ex-build` esiste la BuildConfig `shop` che costruisce con strategia **Source (S2I)** la cartella `hello-node` del repository (branch `main`) usando come builder `corp-builder:1.0`.
2. L'output è il tag `shop:latest`.
3. Ogni build esegue i test unitari dell'applicazione (`npm test`) **dopo** la creazione dell'immagine e **prima** della pubblicazione: se i test falliscono l'immagine non deve essere pubblicata.
4. Una nuova versione di `corp-builder:1.0` avvia automaticamente una nuova build di `shop`.
5. La BuildConfig può essere avviata da un webhook **generico** protetto dal secret `shop-webhook`, il cui valore è `esame288`.
6. Almeno una build di `shop` è stata completata con successo.

## Task 5 — Promozione in produzione (10 minuti)

1. Nel progetto `${LAB}-ex-prod` esiste l'image stream `shop` con il tag `prod`.
2. `shop:prod` punta alla **stessa immagine** (stesso digest) di `shop:latest` del progetto `${LAB}-ex-build`.

## Task 6 — Configurazione e credenziali (15 minuti)

Nel progetto `${LAB}-ex-prod`:

1. Esiste la ConfigMap `shop-config` con la chiave `app.properties` il cui contenuto è la riga `ambiente=produzione`.
2. Esiste il Secret `shop-db` con le chiavi `user` = `shop`, `password` = `Sh0p-Pass-288`, `database` = `shopdb`.

## Task 7 — Applicazione multi-container da template (45 minuti)

1. Nel progetto `${LAB}-ex-prod` è salvato un template chiamato `shop-stack` con i parametri:
   - `APP_MESSAGE` (obbligatorio, nessun valore di default);
   - `REPLICAS` (default `2`), usato come numero di repliche dell'applicazione.
2. Il template crea:
   - un database: Deployment e Service `shop-db` (porta 5432) con le credenziali lette dal Secret `shop-db`;
   - l'applicazione: Deployment `shop` che usa l'immagine `shop:prod` e **si aggiorna automaticamente** quando `shop:prod` cambia; Service `shop` sulla porta 8080; Route `shop` con terminazione TLS edge.
3. Il template è stato istanziato con `APP_MESSAGE=Benvenuti in produzione` e i valori di default per gli altri parametri.
4. L'applicazione `shop`:
   - ha 2 repliche pronte;
   - riceve `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_PASSWORD` coerenti con il database (nome, utente e password letti dal Secret);
   - legge la configurazione dalla ConfigMap `shop-config` montata in `/etc/app`;
   - ha una readiness probe HTTP su `/ready` e una liveness probe HTTP su `/healthz`, porta 8080;
   - ha un limite di memoria di `256Mi`.

**Risultato atteso:** via route HTTPS, `/` mostra il messaggio `Benvenuti in produzione`, `/db` risponde `raggiungibile`, `/config` mostra `ambiente=produzione`, `/build-info` indica che l'immagine è stata costruita dal builder personalizzato.

## Task 8 — Helm (30 minuti)

1. In `$EX288_WORK/m14-exam/catalog` esiste un chart Helm `catalog` (versione chart `0.1.0`) che crea un Deployment e un Service per l'immagine `registry.access.redhat.com/ubi9/httpd-24`. Il numero di repliche è configurabile con il valore `replicaCount` (default `1`).
2. Nel progetto `${LAB}-ex-helm` è installata la release `catalog` di questo chart.
3. La release ha **almeno 2 revisioni**; la revisione corrente usa `replicaCount=2`.
4. Il Deployment della release ha 2 repliche pronte.

## Task 9 — Kustomize (25 minuti)

1. In `$EX288_WORK/m14-exam/kustomize` esistono una base (`base/`) con un Deployment `inventory` (immagine `registry.access.redhat.com/ubi9/httpd-24`, 1 replica) e un Service `inventory` sulla porta 8080, e un overlay `overlays/prod`.
2. L'overlay `prod`, applicato al progetto `${LAB}-ex-kust`:
   - antepone il prefisso `prod-` al nome di tutte le risorse;
   - imposta 2 repliche;
   - aggiunge la label `env=prod` a tutte le risorse;
   - genera una ConfigMap `inventory-config` (con suffisso hash) contenente `MODE=prod`, le cui chiavi diventano variabili d'ambiente del container.
3. L'overlay è applicato: nel progetto `${LAB}-ex-kust` il Deployment `prod-inventory` ha 2 repliche pronte e i suoi pod hanno la variabile `MODE=prod`.

## Task 10 — OpenShift Pipelines (45 minuti)

Nel progetto `${LAB}-ex-cicd`:

1. Esiste la Task `npm-test` con un workspace `source` che esegue `npm test` nella cartella `hello-node` del workspace.
2. Esiste la Pipeline `shop-ci` con:
   - parametri `GIT_URL`, `GIT_REVISION` (default `main`) e `IMAGE`;
   - workspace `source`;
   - tre task in sequenza: `clone` (Task `git-clone` fornita da OpenShift Pipelines), `test` (Task `npm-test`), `build` (Task `buildah` fornita da OpenShift Pipelines, che costruisce `hello-node/Dockerfile` e pubblica `IMAGE`).
3. Almeno una PipelineRun di `shop-ci` è terminata con successo e ha pubblicato `shop-ci:latest` nel registry interno del progetto.
4. Esiste un EventListener `shop-ci-listener` raggiungibile dall'esterno tramite una route, che avvia `shop-ci` quando riceve una richiesta.

## Task 11 — Troubleshooting (30 minuti)

Il progetto `${LAB}-ex-fix` è stato creato da `prepara.sh` e contiene risorse con errori. **Non eliminare e ricreare il progetto**; correggi le risorse esistenti (puoi ricrearne singole risorse mantenendo nome e scopo).

1. Il Deployment `legacy` ha 1 replica pronta, usa l'immagine `registry.access.redhat.com/ubi9/httpd-24`, mantiene una readiness probe e riceve la variabile `LEGACY_TOKEN` dalla chiave `token` del Secret `legacy-secret`.
2. La route `legacy` risponde (pagina di Apache, non l'errore 503 del router).
3. La BuildConfig `report` completa con successo una build dell'applicazione `hello-node`.

## Task 12 — Operator (facoltativo, 20 minuti)

Esegui questo task solo se sul tuo cluster è disponibile un Operator (vedi modulo 13).

1. Nel progetto `${LAB}-ex-prod` esiste un'istanza chiamata `exam-cache` di una API fornita da un Operator installato, creata a partire dall'esempio fornito dall'Operator.
2. L'istanza riporta uno stato pronto.

Per la verifica imposta le stesse variabili `OPERATOR_*` descritte nel modulo 13 (`OPERATOR_KIND`, `OPERATOR_READY_CONDITION`). Se `OPERATOR_KIND` non è impostata, il task viene saltato.

---

## Verifica finale

Quando il timer scade (o hai finito):

```bash
CHART_DIR=$EX288_WORK/m14-exam/catalog KUST_DIR=$EX288_WORK/m14-exam/kustomize \
  bash $EX288_HOME/14-esame-simulato/verifica.sh
```

Lo script stampa il risultato per task e una percentuale. L'esame reale non pubblica la soglia per singolo task e riporta solo il punteggio totale: usa la percentuale come indicatore, puntando ad **almeno l'80%** prima di prenotare l'esame. Per ogni KO torna al modulo corrispondente:

| Task | Modulo di ripasso | Obiettivi EX288 |
|---|---|---|
| 1 | 01, 03 | Create and work with multiple OpenShift projects; Configure the OpenShift internal registry to meet specific requirements |
| 2 | 04 | Create custom image streams to deploy applications |
| 3 | 03, 06 | Work with custom builder workflows to create images; Customize existing S2I builder images |
| 4 | 05, 06 | Understand and work with image builds and image build configurations; Create a build hook that runs a provided script; Manage and trigger application builds |
| 5 | 04 | Trigger updates on image stream changes; Publish container images to the OpenShift image registry |
| 6 | 07 | Create configuration maps; Create secret resources |
| 7 | 07, 08, 09 | Work with multi-container templates; Add custom parameters to a template; Use configuration maps to inject data into applications; Use application health monitoring |
| 8 | 10 | Create and use Helm charts |
| 9 | 11 | Customizing deployments with Kustomize |
| 10 | 12 | Work with OpenShift Pipelines (tutti gli obiettivi) |
| 11 | 02, 05, 08 | Diagnose and correct minor issues with application deployment / build process |
| 12 | 13 | Creating applications from installed Operators |

### Pulizia

```bash
for p in ex-build ex-prod ex-helm ex-kust ex-cicd ex-fix; do oc delete project ${LAB}-$p --wait=false; done
```

Ripeti l'esame dopo qualche giorno partendo da progetti vuoti: l'obiettivo è completarlo in **meno di 3 ore**, così da avere margine il giorno dell'esame.
