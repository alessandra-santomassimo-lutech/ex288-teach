# Modulo 08 — Deployment, health check e troubleshooting

> **Obiettivi EX288 coperti**
> - *Work with Red Hat OpenShift Container Platform* → Use application health monitoring
> - *Work with Red Hat OpenShift Container Platform* → Create and deploy single container and multi-container applications (terza parte: più container nello stesso pod, strategie di deployment)
> - *Troubleshoot application builds and deployment issues* → Diagnose and correct minor issues with application deployment
> - *Work with image streams* → Debug minor issues with application deployment (collegamento: gli errori legati agli image stream sono trattati nel modulo 04)
>
> **Durata stimata:** 5-6 ore · **Prerequisiti:** moduli 01, 02, 04, 07 · **Richiede cluster-admin:** no
>
> **Progetti usati:** `${LAB}-m08`, `${LAB}-m08-exam`

---

## 1. Perché e quando

Un'app "che parte" non basta: deve aggiornarsi senza interruzioni, ricevere traffico solo quando è pronta, essere riavviata quando si blocca e restare nei limiti di risorse del progetto. All'esame molti task iniziano con "il deployment X non funziona: correggilo".

| Situazione | Cosa usi | Perché |
|---|---|---|
| Nuova applicazione | **Deployment** | DeploymentConfig è deprecato dal 4.14 |
| Aggiornare senza downtime, vecchia e nuova versione possono coesistere | Strategia **RollingUpdate** (`maxSurge`/`maxUnavailable`) | I pod vengono sostituiti gradualmente |
| Vecchia e nuova versione **non** possono coesistere (migrazione di schema, volume RWO) | Strategia **Recreate** | Spegne tutto e poi riaccende: downtime accettato |
| Il pod non deve ricevere traffico finché non è pronto (cache, connessioni) | **readiness probe** | Se fallisce il pod esce dagli endpoint del Service, non viene riavviato |
| Il processo può bloccarsi senza terminare | **liveness probe** | Se fallisce il container viene riavviato |
| L'app impiega molto ad avviarsi | **startup probe** | Sospende liveness e readiness finché l'avvio non riesce |
| Lo scheduler deve garantire risorse / il progetto ha una quota | `requests` e `limits` (`oc set resources`) | Requests per lo scheduling, limits come tetto |
| Una funzione accessoria che deve vivere accanto all'app (proxy, log, monitoraggio) | **sidecar** (secondo container nel pod) | Condivide rete (`localhost`) e volumi con l'app |
| Un'attività da completare **prima** dell'avvio (attendere una dipendenza, preparare file) | **init container** | Gira fino al completamento, poi parte l'app |
| Un componente con ciclo di vita e scalabilità propri (database) | **Deployment separato** + Service | Si scala e si aggiorna indipendentemente (moduli 02 e 07) |

---

## 2. Concetti essenziali

### 2.1 Deployment e DeploymentConfig

| | Deployment (`apps/v1`) | DeploymentConfig (`apps.openshift.io/v1`) |
|---|---|---|
| Stato | Raccomandato | *Deprecated* dal 4.14 (ancora presente in 4.22, solo correzioni critiche) |
| Pod gestiti tramite | ReplicaSet | ReplicationController |
| Chi esegue il rollout | Il controller manager | Un *deployer pod* per ogni rollout |
| Priorità di progetto | Disponibilità | Coerenza |
| Solo qui | Rollover, scaling proporzionale, pausa durante un rollout | Lifecycle hook, strategia Custom, rollback automatico, trigger `ImageChange`/`ConfigChange` nativi |
| Aggiornamento su nuova immagine | Annotazione `image.openshift.io/triggers` (modulo 04) | Trigger `ImageChange` |

Se trovi un `dc/` in un'applicazione esistente, i comandi `oc rollout` funzionano anche lì (`oc rollout latest dc/x` è specifico dei DeploymentConfig).

### 2.2 Strategie e rollout

Ogni modifica a `spec.template` crea una nuova **ReplicaSet** (una *revisione*). `oc scale` e le modifiche fuori dal template **non** creano revisioni.

Con 4 repliche (le percentuali si arrotondano: per eccesso `maxSurge`, per difetto `maxUnavailable`):

| `maxSurge` | `maxUnavailable` | Pod max | Pod pronti min | Quando |
|---|---|---|---|---|
| 25% (default) | 25% (default) | 5 | 3 | Caso generale |
| 1 | 0 | 5 | 4 | Capacità piena; se la nuova versione non diventa pronta il rollout si ferma ma il servizio continua |
| 0 | 1 | 4 | 3 | Nessuna risorsa in più (quota stretta), capacità ridotta durante l'update |
| 100% | 0 | 8 | 4 | Tutti i nuovi pod subito: serve il doppio delle risorse |

`maxSurge` e `maxUnavailable` non possono essere entrambi 0. Con `type: Recreate` il blocco `rollingUpdate` non deve esistere.

Se un rollout non avanza entro `progressDeadlineSeconds` (default 600) la condizione `Progressing` diventa `False` con motivo `ProgressDeadlineExceeded`. Il Deployment **non** torna indietro da solo: il rollback è una tua decisione (`oc rollout undo`).

### 2.3 Risorse, quota e LimitRange

```yaml
resources:
  requests: {cpu: 50m, memory: 64Mi}    # garantite: lo scheduler cerca un nodo con questo spazio libero
  limits:   {cpu: 250m, memory: 256Mi}  # tetto: CPU rallentata; memoria superata = OOMKilled (exit 137)
```

- **ResourceQuota** del progetto (`oc describe quota`): limita il totale di CPU, memoria, numero di oggetti. Se la quota riguarda `cpu`/`memory`, ogni pod deve dichiarare requests/limits, altrimenti **il pod non viene nemmeno creato** (evento `FailedCreate` sulla ReplicaSet).
- **LimitRange** (`oc describe limitrange`): valori di default per chi non li dichiara, minimi e massimi per container.
- **QoS** del pod (`oc get pod <p> -o jsonpath='{.status.qosClass}'`): `Guaranteed` (requests = limits), `Burstable`, `BestEffort` (nessuna risorsa: primo a essere sfrattato).

### 2.4 Health probe

| Probe | Domanda | Se fallisce |
|---|---|---|
| `readinessProbe` | Posso ricevere traffico? | Il pod esce dagli endpoint del Service (resta in esecuzione e continua a essere sondato) |
| `livenessProbe` | Sono ancora vivo? | Il container viene ucciso e riavviato (RESTARTS aumenta) |
| `startupProbe` | Ho finito di avviarmi? | Riavvio; finché non ha successo le altre probe sono **disabilitate** |

Tipi: `httpGet` (successo con codice 200-399), `tcpSocket` (la porta accetta connessioni), `exec` (comando con exit 0).

| Campo | Default | Note |
|---|---|---|
| `initialDelaySeconds` | 0 | Attesa prima della prima prova |
| `periodSeconds` | 10 | Intervallo tra le prove |
| `timeoutSeconds` | 1 | Tempo massimo di risposta |
| `successThreshold` | 1 | Deve essere 1 per liveness e startup |
| `failureThreshold` | 3 | Fallimenti consecutivi prima di agire |

Tempo massimo di avvio concesso da una startup probe = `failureThreshold × periodSeconds` (es. 30 × 10 = 5 minuti).

> **Errore classico:** usare per la liveness lo stesso endpoint della readiness. Un'app lenta a diventare "pronta" viene uccisa prima di riuscirci, all'infinito (scenario 3).

### 2.5 Più container nello stesso pod

```yaml
spec:
  initContainers:          # in sequenza, ognuno deve terminare con successo prima del successivo
  - name: wait-db
    image: registry.access.redhat.com/ubi9/ubi-minimal
    command: ["/bin/bash", "-c", "until ...; do sleep 5; done"]
  containers:              # tutti insieme, per tutta la vita del pod
  - name: hello            # l'applicazione
  - name: monitor          # sidecar: stessa rete (localhost) e stessi volumi
```

I container di un pod vengono schedulati insieme, condividono IP e volumi e si scalano **insieme**. Per questo app e database restano in Deployment separati. Con più container, `oc logs`, `oc exec`, `oc rsh`, `oc set probe` e `oc set resources` vanno indirizzati con `-c <container>`.

### 2.6 Metodo di debug sistematico

1. **Stato**: `oc get pods` (STATUS, READY, RESTARTS). Nessun pod? `oc get rs`, `oc describe deployment`, `oc get events`.
2. **Eventi e dettagli**: `oc describe pod <pod>` (Events, State, Last State, Exit Code) · `oc get events --field-selector type=Warning --sort-by=.lastTimestamp`.
3. **Log**: `oc logs <pod> [-c <container>]`, `--previous` per il container precedente al riavvio.
4. **Dentro il container**: `oc rsh` / `oc exec` se gira; `oc debug deployment/<d>` se termina subito.
5. **Risorse collegate**: Service ed EndpointSlice, ConfigMap/Secret (modulo 07), image stream (`oc get istag`, modulo 04), quota.

| Stato del pod | Cosa significa | Dove guardi |
|---|---|---|
| `Pending` | Nessun nodo adatto (requests troppo alte, PVC non disponibile, vincoli di scheduling) | `oc describe pod` → `FailedScheduling` |
| `ContainerCreating` a lungo | Volume non montabile (ConfigMap/Secret/PVC mancante) | `oc describe pod` → `FailedMount` |
| `Init:0/1`, `Init:CrashLoopBackOff` | Init container non ancora completato o in errore | `oc logs <pod> -c <init>` |
| `CreateContainerConfigError` | ConfigMap, Secret o chiave mancante | `oc describe pod` |
| `ErrImagePull` / `ImagePullBackOff` | Nome/tag/registry/credenziali errati; nome breve di image stream senza lookup locale | `oc describe pod`, `oc get istag` (moduli 03-04) |
| `CrashLoopBackOff` | Il processo termina; OpenShift riprova con attese crescenti | `oc logs --previous`, `oc debug` |
| `Running` ma `0/1` | La readiness probe fallisce: niente traffico | `oc describe pod` → `Readiness probe failed` |
| Last State `OOMKilled` (exit 137) | Superato il limite di memoria | `oc describe pod`, `oc set resources` |
| `Completed` | Il processo è terminato con 0: in un Deployment è comunque un errore (deve restare in esecuzione) | `oc logs`, command/args del container |
| Nessun pod, evento `FailedCreate` | Rifiutato all'ammissione: quota, LimitRange, SCC | `oc describe rs`, `oc get events` |

---

## 3. Laboratorio guidato

```bash
source env.sh                 # dalla root del repository ex288-teach
M=$EX288_HOME/08-deployment-health-troubleshooting
```

### 3.1 Progetto e applicazione

```bash
oc new-project ${LAB}-m08 --display-name="EX288 m08 - deployment e health"
oc import-image nodejs:22-ubi9 --from=registry.access.redhat.com/ubi9/nodejs-22 --confirm
oc new-app "nodejs:22-ubi9~$GIT_REPO" --context-dir=hello-node --name=hello
oc logs -f bc/hello                 # la PRIMA build richiede qualche minuto
oc rollout status deployment/hello
oc expose service/hello
URL=http://$(oc get route hello -o jsonpath='{.spec.host}')
oc set image-lookup hello           # i manifest di lab/ e troubleshooting/ usano "image: hello:latest"
curl -s $URL/
```

### 3.2 Scaling, revisioni e rollback

```bash
oc scale deployment/hello --replicas=3
oc get pods -l deployment=hello

oc rollout history deployment/hello            # revisioni attuali
oc set env deployment/hello APP_MESSAGE="Versione 2"
oc annotate deployment/hello kubernetes.io/change-cause="APP_MESSAGE versione 2" --overwrite
oc rollout status deployment/hello
oc set env deployment/hello APP_MESSAGE="Versione 3"
oc annotate deployment/hello kubernetes.io/change-cause="APP_MESSAGE versione 3" --overwrite
oc rollout status deployment/hello

oc rollout history deployment/hello            # la colonna CHANGE-CAUSE mostra le annotazioni
oc rollout history deployment/hello --revision=2   # dettaglio del template di quella revisione
oc get rs -l deployment=hello                  # una ReplicaSet per revisione (le vecchie a 0 pod)

oc rollout undo deployment/hello               # torna alla revisione precedente ("Versione 2")
oc rollout undo deployment/hello --to-revision=1   # torna alla prima (nessun APP_MESSAGE)
oc rollout history deployment/hello            # l'undo crea una NUOVA revisione con il vecchio template
curl -s $URL/ | grep message
```

> **Abitudine da esame:** dopo ogni modifica, `oc rollout status deployment/<nome>`. Se si blocca, il problema è nella nuova versione: indaga sui pod nuovi, non su quelli vecchi.

### 3.3 Più modifiche, un solo rollout: pause e resume

```bash
oc rollout pause deployment/hello
oc set env deployment/hello APP_MESSAGE="Configurazione completa"
oc set resources deployment/hello -c=hello --requests=cpu=50m,memory=64Mi --limits=cpu=250m,memory=256Mi
oc get rs -l deployment=hello           # nessuna nuova ReplicaSet: il Deployment è in pausa
oc rollout resume deployment/hello      # UN solo rollout con entrambe le modifiche
oc rollout status deployment/hello
oc rollout restart deployment/hello     # nuovo rollout senza modifiche (es. dopo aver cambiato una ConfigMap)
```

### 3.4 Strategie: RollingUpdate e Recreate

```bash
# Capacità piena durante l'aggiornamento: mai meno di 3 pod pronti
oc patch deployment/hello --type=merge \
  -p '{"spec":{"strategy":{"type":"RollingUpdate","rollingUpdate":{"maxSurge":1,"maxUnavailable":0}}}}'
oc set env deployment/hello APP_MESSAGE="Rolling"
oc get pods -l deployment=hello -w      # osserva: 1 nuovo pod, poi 1 vecchio in Terminating... (Ctrl+C)

# Recreate: rollingUpdate va azzerato, altrimenti la validazione fallisce
oc patch deployment/hello --type=merge -p '{"spec":{"strategy":{"type":"Recreate","rollingUpdate":null}}}'
oc set env deployment/hello APP_MESSAGE="Recreate"
oc get pods -l deployment=hello -w      # tutti Terminating, POI i nuovi: in mezzo la route risponde 503

# Torna a RollingUpdate per il resto del laboratorio
oc patch deployment/hello --type=merge -p '{"spec":{"strategy":{"type":"RollingUpdate"}}}'
oc scale deployment/hello --replicas=1
```

**Caso tipico di Recreate: un database con volume persistente RWO** (*ReadWriteOnce*: montabile da un solo nodo). Con RollingUpdate il nuovo pod potrebbe non riuscire a montare il volume ancora usato dal vecchio. Il database di `lab/db.yaml` usa già `Recreate`; qui gli aggiungi lo storage persistente promesso nel modulo 02:

```bash
oc apply -f $M/lab/db.yaml
oc set volume deployment/db --add --name=data --type=pvc --claim-name=db-data \
  --claim-size=1Gi --claim-mode=rwo --mount-path=/var/lib/pgsql/data
oc get pvc db-data                      # Bound (se il cluster ha una StorageClass di default)
oc rollout status deployment/db
```

> **Da verificare sul tuo cluster:** la creazione automatica della PVC con `--claim-size` richiede una StorageClass di default (`oc get storageclass`); i flag `--claim-size` e `--claim-mode` sono in `oc set volume --help` ma non negli esempi ufficiali. Se la PVC resta `Pending`, chiedi all'amministratore quale StorageClass usare (`--claim-class`).

### 3.5 Risorse, quota e LimitRange

```bash
oc describe quota                       # quote del progetto (può non essercene nessuna)
oc describe limitrange                  # default/min/max per container (può non esisterne)
oc describe appliedclusterresourcequota # quote multi-progetto assegnate dall'amministratore (se presenti)

oc set resources deployment/hello -c=hello --requests=cpu=50m,memory=64Mi --limits=cpu=250m,memory=256Mi
POD=$(oc get pods -l deployment=hello -o name | head -1)
oc get $POD -o jsonpath='{.spec.containers[0].resources}{"\n"}{.status.qosClass}{"\n"}'   # Burstable
oc adm top pods                         # consumo reale (se il cluster espone le metriche al tuo utente)
```

Se il progetto ha una quota su CPU/memoria, nota come i valori di default del LimitRange vengono applicati ai container che non li dichiarano: `oc get $POD -o yaml | grep -A6 resources`.

### 3.6 Readiness probe

```bash
oc set env deployment/hello READY_DELAY_SECONDS=20     # /ready risponde 503 per 20 s dopo l'avvio
oc set probe deployment/hello -c hello --readiness --get-url=http://:8080/ready --period-seconds=5
oc get pods -l deployment=hello -w      # il nuovo pod resta Running 0/1 per ~20 s, poi 1/1 (Ctrl+C)

# Durante quei 20 secondi il pod non è tra gli endpoint pronti del Service:
oc get endpointslices -l kubernetes.io/service-name=hello \
  -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]}{" ready="}{.conditions.ready}{"\n"}{end}'
oc get endpoints hello                  # equivalente storico: in 4.22 stampa un avviso di deprecazione
oc describe pod -l deployment=hello | grep -i readiness
```

Con RollingUpdate il vecchio pod viene spento solo quando il nuovo è pronto: la readiness probe protegge anche gli aggiornamenti.

### 3.7 Liveness probe

```bash
oc set probe deployment/hello -c hello --liveness --get-url=http://:8080/healthz \
  --initial-delay-seconds=5 --period-seconds=5 --failure-threshold=3
oc rollout status deployment/hello
oc get pods -l deployment=hello                       # RESTARTS 0

curl -s $URL/toggle-health                            # /healthz ora risponde 500 (1 replica: colpisci quel pod)
oc get pods -l deployment=hello -w                    # dopo ~15 s RESTARTS diventa 1 (Ctrl+C)
oc describe pod -l deployment=hello | sed -n '/Events/,$p'
# Warning  Unhealthy  Liveness probe failed: HTTP probe failed with statuscode: 500
# Normal   Killing    Container hello failed liveness probe, will be restarted
curl -s $URL/healthz                                  # {"status":"ok"}: il riavvio ha "guarito" l'app
```

> **Da verificare sul tuo cluster:** gli esempi ufficiali di `oc set probe` mostrano `--readiness`, `--liveness`, `--startup`, `--get-url`, `--open-tcp`, `--initial-delay-seconds` e `--remove`. `--period-seconds`, `--timeout-seconds`, `--failure-threshold`, `--success-threshold` e `-c` esistono ma vanno controllati con `oc set probe --help`. In alternativa usa YAML (passo 3.8).

### 3.8 Startup probe, YAML equivalente e console

```bash
oc set probe deployment/hello -c hello --startup --get-url=http://:8080/healthz \
  --period-seconds=5 --failure-threshold=24           # fino a 2 minuti per avviarsi
oc get deployment hello -o yaml | grep -B1 -A9 -E 'readinessProbe|livenessProbe|startupProbe'

# Lo stesso, tutto in YAML (strategia, risorse, tre probe): leggi i commenti e applicalo
cat $M/lab/hello-completo.yaml
oc apply -f $M/lab/hello-completo.yaml
oc rollout status deployment/hello-yaml
oc explain deployment.spec.template.spec.containers.startupProbe     # documentazione dei campi

oc set probe deployment/hello-yaml --remove --readiness --liveness   # rimozione (lascia la startup)
```

In console: dal Deployment, azione **Edit Health Checks** (o, se è abilitata la prospettiva *Developer*, dalla vista *Topology*) → *Add Readiness probe* / *Add Liveness probe* / *Add Startup probe*. Le stesse sezioni compaiono in *Import from Git* (*Health checks*). Verifica sempre il risultato con `oc get deployment -o yaml`.

### 3.9 Sidecar

```bash
cat $M/lab/patch-sidecar.yaml
oc patch deployment/hello -p "$(cat $M/lab/patch-sidecar.yaml)"
oc rollout status deployment/hello
oc get pods -l deployment=hello                       # READY 2/2
oc logs deployment/hello -c monitor --tail=3          # 10:42:01 healthz=200 ...
oc logs deployment/hello                              # senza -c: oc sceglie un container e lo segnala
curl -s $URL/toggle-health; sleep 12
oc logs deployment/hello -c monitor --tail=2          # healthz=500 (poi la liveness riavvia "hello")
oc get pod -l deployment=hello -o jsonpath='{range .items[0].status.containerStatuses[*]}{.name}{" restarts="}{.restartCount}{"\n"}{end}'
```

Il riavvio per liveness riguarda **solo** il container `hello`: `monitor` continua. I `-c` dei passi 3.5-3.8 servivano proprio a non applicare probe e risorse al sidecar.

> **Nota di versione:** Kubernetes (1.35 in OCP 4.22) supporta anche i *sidecar nativi*: init container con `restartPolicy: Always`, avviati prima dell'app e fermati dopo. Questa forma non è descritta nei documenti OpenShift citati: all'esame usa il sidecar classico (secondo elemento in `containers`).

### 3.10 Init container

```bash
oc delete deployment db --ignore-not-found          # parti senza database (e senza PVC in uso)
oc apply -f $M/lab/web-init.yaml
oc get pods -l app=web                              # Init:0/1
oc logs deployment/web -c wait-db                   # "db:5432 non risponde, riprovo tra 5 secondi"
oc apply -f $M/lab/db.yaml                          # ora crea il database
oc get pods -l app=web -w                           # Init:0/1 -> PodInitializing -> Running (Ctrl+C)
oc logs deployment/web -c wait-db | tail -1         # "db:5432 raggiungibile: avvio l'applicazione"
oc exec deployment/web -c hello -- curl -s localhost:8080/db
```

Un init container è adatto quando l'app **non** gestisce da sola l'attesa di una dipendenza. Se l'app ritenta da sola (il caso migliore), basta la readiness probe.

### 3.11 Strumenti di debug

```bash
oc get events --field-selector type=Warning --sort-by=.lastTimestamp
oc get events --field-selector involvedObject.name=<nome-pod>
oc logs <pod> --previous                    # log del container PRIMA dell'ultimo riavvio
oc debug deployment/hello                   # copia del pod con una shell al posto del comando
#   stessa immagine, variabili e volumi; nessuna probe; stesso UID arbitrario (SCC restricted-v2)
oc debug deployment/hello -c hello -- env | sort    # comando singolo, poi il pod di debug viene eliminato
```

> **Da verificare sul tuo cluster:** `oc debug` rimuove le probe per default; le opzioni per mantenerle (`--keep-liveness`, `--keep-readiness`, `--keep-startup`) sono in `oc debug --help`. Le opzioni `--as-root`/`--as-user` richiedono SCC che un utente normale non ha.

### 3.12 Pulizia

Tieni `${LAB}-m08` per le sezioni 4 e 6; alla fine: `oc delete project ${LAB}-m08`.

---

## 4. Esercizi

### 4.1 Esercizio guidato

Nel progetto `${LAB}-m08` crea il Deployment `catalog` dall'immagine `hello:latest` con 2 repliche, strategia RollingUpdate `maxSurge=0`/`maxUnavailable=1`, `READY_DELAY_SECONDS=10`, readiness su `/ready` ogni 5 secondi e liveness su `/healthz` con `failureThreshold=2`. Poi aggiorna `APP_MESSAGE` con change-cause `catalogo v2` e torna alla revisione 1.

<details><summary>Suggerimenti</summary>

- `oc create deployment ... --image=hello:latest --replicas=2 --port=8080` usa il lookup locale.
- Strategia con `oc patch --type=merge`, probe con `oc set probe`, annotazione con `oc annotate`.
- `oc rollout history` prima di `oc rollout undo --to-revision`.
</details>

<details><summary>Soluzione</summary>

```bash
oc create deployment catalog --image=hello:latest --replicas=2 --port=8080
oc patch deployment/catalog --type=merge \
  -p '{"spec":{"strategy":{"type":"RollingUpdate","rollingUpdate":{"maxSurge":0,"maxUnavailable":1}}}}'
oc rollout pause deployment/catalog
oc set env deployment/catalog READY_DELAY_SECONDS=10
oc set probe deployment/catalog --readiness --get-url=http://:8080/ready --period-seconds=5
oc set probe deployment/catalog --liveness --get-url=http://:8080/healthz --failure-threshold=2
oc rollout resume deployment/catalog && oc rollout status deployment/catalog
oc set env deployment/catalog APP_MESSAGE="catalogo v2"
oc annotate deployment/catalog kubernetes.io/change-cause="catalogo v2" --overwrite
oc rollout status deployment/catalog
oc rollout history deployment/catalog
oc rollout undo deployment/catalog --to-revision=1
```
Nota: `oc create deployment` chiama il container come l'immagine (`hello`); con un solo container `-c` non serve. La revisione 1 è quella **senza** probe (creata prima della pausa): è ciò che hai chiesto, ma all'esame controlla sempre che cosa contiene la revisione a cui torni (`oc rollout history --revision=1`).
</details>

### 4.2 Esercizio semi-guidato

1. Aggiungi a `catalog` un sidecar `logger` (`ubi-minimal`) che ogni 15 secondi scrive nel proprio log il risultato di `/ready`.
2. Fai in modo che i pod di `catalog` abbiano classe QoS `Guaranteed`.
3. Dimostra con `oc logs -c` che il sidecar funziona e con `oc get pod -o jsonpath` la classe QoS.

<details><summary>Suggerimenti</summary>

Parti da `lab/patch-sidecar.yaml`. `Guaranteed` richiede requests = limits per CPU **e** memoria in **tutti** i container. `oc set resources -c`.
</details>

<details><summary>Soluzione (aprila solo dopo aver provato)</summary>

```bash
oc project ${LAB}-m08
oc describe limitrange; oc describe quota      # prima di toccare le risorse: vincoli del progetto (può non esserci nulla)
mkdir -p $EX288_WORK/m08

# 1) Patch del sidecar: è lab/patch-sidecar.yaml con 4 differenze (nome logger, endpoint /ready,
#    prefisso "ready=", attesa di 15 s) e senza "resources", che imposti al punto 2.
#    'EOF' tra apici: la shell non espande $(...) e %{http_code} mentre scrive il file.
cat > $EX288_WORK/m08/patch-logger.yaml <<'EOF'
spec:
  template:
    spec:
      containers:
      - name: logger
        image: registry.access.redhat.com/ubi9/ubi-minimal
        command: ["/bin/bash", "-c"]
        args:
        - |
          trap 'exit 0' TERM
          while true; do
            code=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:8080/ready)
            echo "$(date -u +%H:%M:%S) ready=$code"
            sleep 15 & wait $!
          done
EOF

# Sidecar e risorse in UN solo rollout
oc rollout pause deployment/catalog
oc patch deployment/catalog -p "$(cat $EX288_WORK/m08/patch-logger.yaml)"   # strategic merge: "hello" resta, "logger" si aggiunge

# 2) QoS Guaranteed: requests = limits, per CPU e memoria, in OGNI container.
#    Il container dell'app si chiama "hello" (oc create deployment usa il nome dell'immagine).
oc set resources deployment/catalog -c hello  --requests=cpu=250m,memory=256Mi --limits=cpu=250m,memory=256Mi
oc set resources deployment/catalog -c logger --requests=cpu=50m,memory=64Mi --limits=cpu=50m,memory=64Mi
oc rollout resume deployment/catalog
oc rollout status deployment/catalog            # deployment "catalog" successfully rolled out

# 3) Verifiche (se vedi ancora pod Terminating, ripeti dopo qualche secondo)
oc get pods -l app=catalog                      # 2 pod, READY 2/2
oc logs deployment/catalog -c logger --tail=3   # oc sceglie uno dei pod
# 10:42:01 ready=200
# 10:42:16 ready=200        <- una riga ogni 15 secondi
oc get pods -l app=catalog -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.qosClass}{"\n"}{end}'
# catalog-6c9f...-abcde Guaranteed
# catalog-6c9f...-fghij Guaranteed
POD=$(oc get pods -l app=catalog -o name | head -1)
oc get $POD -o jsonpath='{.status.qosClass}{"\n"}'                                          # Guaranteed
oc get $POD -o jsonpath='{range .spec.containers[*]}{.name}{": "}{.resources}{"\n"}{end}'
# hello: {"limits":{"cpu":"250m","memory":"256Mi"},"requests":{"cpu":"250m","memory":"256Mi"}}
# logger: {"limits":{"cpu":"50m","memory":"64Mi"},"requests":{"cpu":"50m","memory":"64Mi"}}
```

**Perché `localhost`:** i container dello stesso pod condividono la rete (stesso IP), quindi `logger` raggiunge l'app su `localhost:8080` senza passare dal Service. Se nei primi secondi vedi `ready=503`, il Deployment ha ancora `READY_DELAY_SECONDS` (cioè non sei tornato alla revisione 1 nel 4.1): è il comportamento atteso di `/ready`.

**Perché due `oc set resources`:** la classe QoS è del **pod**, non del container: è `Guaranteed` solo se **tutti** i container hanno requests e limits di CPU e memoria con valori uguali. Basta un container senza risorse o con requests < limits (come `monitor` di `lab/patch-sidecar.yaml`: 10m/16Mi contro 50m/64Mi) e il pod diventa `Burstable`. `-c` indirizza ogni comando al container giusto; `pause`/`resume` evitano tre rollout consecutivi.

**LimitRange e quota:** i default di un LimitRange si applicano solo ai valori **non** dichiarati; qui li dichiari tutti, quindi non cambiano la classe. Un LimitRange può però rifiutare il pod (minimi/massimi per container, `maxLimitRequestRatio`), e una quota può non bastare perché con `Guaranteed` le requests salgono fino ai limits. In quei casi il rollout si ferma e la ReplicaSet registra `FailedCreate`: riduci i valori restando con requests = limits.

> **Da verificare sul tuo cluster:** se il rollout non avanza, controlla `oc get events --field-selector reason=FailedCreate` e `oc describe limitrange` (colonne Min/Max/Max Limit/Request Ratio) e adatta i valori di `--requests`/`--limits`.
</details>

### 4.3 Esercizio senza aiuti

Crea un Deployment `slowstart` da `hello:latest` che simuli un'app con avvio di 90 secondi (`READY_DELAY_SECONDS=90`). Configura le probe in modo che il pod non venga mai riavviato durante l'avvio, che riceva traffico solo quando è pronto e che, dopo l'avvio, un blocco di `/healthz` venga rilevato in meno di 30 secondi. Dimostra ogni comportamento.

---

## 5. Verifiche pratiche con `oc`

| Domanda | Comando |
|---|---|
| Il rollout è finito? | `oc rollout status deployment/<d>` · `oc get deploy <d>` (READY, UP-TO-DATE, AVAILABLE) |
| Quali revisioni esistono e perché? | `oc rollout history deployment/<d>` · `--revision=N` |
| Il rollout è bloccato? | `oc describe deploy <d>` (Conditions: `ProgressDeadlineExceeded`) |
| Che strategia usa? | `oc get deploy <d> -o jsonpath='{.spec.strategy}'` |
| Che probe ha il container? | `oc get deploy <d> -o yaml \| grep -A8 Probe` · `oc describe pod <p>` (Liveness/Readiness/Startup) |
| Le probe falliscono? | `oc get events --field-selector reason=Unhealthy` |
| Il pod riceve traffico? | `oc get endpointslices -l kubernetes.io/service-name=<svc>` (condizione `ready`) |
| Perché si è riavviato? | `oc describe pod <p>` (Last State, Reason, Exit Code) · `oc logs <p> --previous` |
| Requests, limits e QoS | `oc get pod <p> -o jsonpath='{.spec.containers[*].resources}'` · `{.status.qosClass}` |
| Quota e limiti del progetto | `oc describe quota` · `oc describe limitrange` |
| Log di un container specifico | `oc logs <p> -c <container>` (anche per gli init container) |

---

## 6. Troubleshooting intenzionale

Prerequisito: passo 3.1 completato (lookup locale su `hello`). Crea uno scenario alla volta, indaga con il metodo della sezione 2.6, poi apri la soluzione.

```bash
oc project ${LAB}-m08
oc apply -f $M/troubleshooting/rotto-1-crash.yaml
oc apply -f $M/troubleshooting/rotto-2-readiness.yaml
oc apply -f $M/troubleshooting/rotto-3-liveness.yaml
oc apply -f $M/troubleshooting/rotto-4-oom.yaml
oc apply -f $M/troubleshooting/rotto-5-pending.yaml
bash $M/troubleshooting/rompi-6-rollout.sh
oc apply -f $M/troubleshooting/rotto-7-init.yaml
```

### Scenario 1 — `t1` non resta mai in esecuzione

**Sintomo:** `CrashLoopBackOff`, RESTARTS in aumento.

<details><summary>Indagine e soluzione</summary>

```bash
oc logs deployment/t1 --previous     # FAIL_ON_START=true: termino con errore (scenario di troubleshooting)
oc describe pod -l app=t1 | grep -A4 'Last State'    # Terminated, Reason: Error, Exit Code: 1
oc set env deployment/t1 --list
```
**Causa:** la variabile `FAIL_ON_START=true` fa terminare l'applicazione all'avvio.
**Fix:** `oc set env deployment/t1 FAIL_ON_START-` (il trattino finale rimuove la variabile).
**Lezione:** `CrashLoopBackOff` è un sintomo, non una causa: la causa è nei log del container **precedente**. Se i log sono vuoti, prova `oc debug deployment/t1` e avvia a mano il comando.
</details>

### Scenario 2 — `t2` Running ma senza traffico

**Sintomo:** il pod è `Running` ma `0/1`; il Service `t2` non ha endpoint pronti.

<details><summary>Indagine e soluzione</summary>

```bash
oc describe pod -l app=t2 | sed -n '/Events/,$p'
# Readiness probe failed: Get "http://10.x.x.x:8081/ready": dial tcp 10.x.x.x:8081: connect: connection refused
oc get endpointslices -l kubernetes.io/service-name=t2 -o jsonpath='{.items[*].endpoints[*].conditions.ready}{"\n"}'   # false
```
**Causa:** la readiness probe interroga la porta 8081; l'app ascolta sulla 8080.
**Fix:** `oc set probe deployment/t2 --readiness --get-url=http://:8080/ready` (sostituisce la probe esistente).
**Lezione:** `connection refused` = porta sbagliata o app non in ascolto; `statuscode: 404` = path sbagliato; `statuscode: 503` = l'app risponde "non pronta". Una readiness sbagliata non riavvia nulla: semplicemente il traffico non arriva (route: 503).
</details>

### Scenario 3 — `t3` riavviato in continuazione

**Sintomo:** RESTARTS cresce ogni pochi secondi, poi `CrashLoopBackOff`; nei log nessun errore.

<details><summary>Indagine e soluzione</summary>

```bash
oc describe pod -l app=t3 | sed -n '/Liveness/p;/Readiness/p;/Events/,$p'
# Liveness: http-get http://:8080/ready delay=0s timeout=1s period=5s #success=1 #failure=2
# Liveness probe failed: HTTP probe failed with statuscode: 503
# Container hello failed liveness probe, will be restarted
oc set env deployment/t3 --list      # READY_DELAY_SECONDS=60
```
**Causa:** la liveness usa `/ready`, che risponde 503 per i primi 60 secondi: dopo 10 secondi il container viene ucciso, riparte da zero e non arriva mai a 60.
**Fix:** liveness sull'endpoint di salute e startup probe per proteggere l'avvio:

```bash
oc rollout pause deployment/t3
oc set probe deployment/t3 --liveness --get-url=http://:8080/healthz --period-seconds=10
oc set probe deployment/t3 --startup --get-url=http://:8080/healthz --period-seconds=5 --failure-threshold=24
oc rollout resume deployment/t3
```
**Lezione:** liveness = "sono bloccato?", readiness = "sono pronto?". Mai usare un controllo di prontezza o di dipendenze esterne come liveness.
</details>

### Scenario 4 — `t4` riparte senza errori nei log

**Sintomo:** RESTARTS in aumento, `CrashLoopBackOff`; `oc logs --previous` non mostra errori dell'app (o è vuoto).

<details><summary>Indagine e soluzione</summary>

```bash
oc describe pod -l app=t4 | grep -A5 'Last State'   # Reason: OOMKilled, Exit Code: 137
oc get pod -l app=t4 -o jsonpath='{.items[0].status.containerStatuses[0].lastState.terminated.reason}{"\n"}'
oc get deploy t4 -o jsonpath='{.spec.template.spec.containers[0].resources}{"\n"}'   # limits.memory 16Mi
```
**Causa:** 16 MiB non bastano nemmeno per avviare Node.js: il kernel uccide il processo.
**Fix:** `oc set resources deployment/t4 -c=hello --requests=memory=64Mi --limits=memory=256Mi`.
**Lezione:** exit code 137 = ucciso con SIGKILL; con `OOMKilled` la causa è il limite di memoria. Se nel progetto c'è un LimitRange con un minimo superiore a 16Mi, il pod non viene nemmeno creato: lo vedi con `oc get events` (`FailedCreate`, `minimum memory usage per Container is ...`).
</details>

### Scenario 5 — Il pod di `t5` non parte

**Sintomo:** il pod resta `Pending` (oppure non esiste proprio).

<details><summary>Indagine e soluzione</summary>

```bash
oc get pods -l app=t5
oc describe pod -l app=t5 | sed -n '/Events/,$p'
# Warning  FailedScheduling  0/N nodes are available: N Insufficient cpu ...
oc get events --field-selector reason=FailedCreate   # se il pod non esiste: quota o LimitRange (exceeded quota / maximum cpu usage)
oc describe quota; oc describe limitrange
```
**Causa:** il pod chiede 100 CPU: nessun nodo ha tanta capacità libera (o la quota/il LimitRange lo vietano).
**Fix:** `oc set resources deployment/t5 -c=hello --requests=cpu=50m,memory=64Mi --limits=cpu=250m,memory=256Mi`.
**Lezione:** `Pending` + `FailedScheduling` = problema di **scheduling** (requests, selettori, PVC); nessun pod + `FailedCreate` = problema di **ammissione** (quota, LimitRange, SCC), visibile sulla ReplicaSet.
</details>

### Scenario 6 — L'aggiornamento di `t6` non finisce mai

**Sintomo:** `oc rollout status deployment/t6` non termina e poi fallisce; un pod nuovo è `0/1`, i due vecchi servono ancora il traffico.

<details><summary>Indagine e soluzione</summary>

```bash
oc rollout status deployment/t6 --timeout=90s   # error: deployment "t6" exceeded its progress deadline
oc describe deploy t6 | sed -n '/Conditions/,/Events/p'   # Progressing False ProgressDeadlineExceeded
oc get rs -l app=t6                             # nuova RS: 1 desiderato, 0 pronti; vecchia: 2 pronti
oc rollout history deployment/t6                # 1 "v1: versione stabile", 2 "v2: nuovo messaggio"
oc set env deployment/t6 --list                 # READY_DELAY_SECONDS=100000
```
**Causa:** la revisione 2 non diventa mai pronta; con `maxUnavailable: 0` il controller non spegne i pod vecchi (il servizio continua) e dopo `progressDeadlineSeconds` (60 s) dichiara il fallimento.
**Fix immediato:** `oc rollout undo deployment/t6` (torna alla revisione 1, il pod rotto viene eliminato). Poi correggi la configurazione e riprova con un nuovo rollout.
**Lezione:** `maxUnavailable: 0` + readiness probe trasformano un rilascio rotto in un rollout bloccato invece che in un disservizio. OpenShift non fa rollback automatici dei Deployment: `ProgressDeadlineExceeded` è il segnale per farlo tu.
</details>

### Scenario 7 — `web7` non si avvia

**Sintomo:** il pod di `web7` resta in `Init:0/1`; `t7-backend` funziona.

<details><summary>Indagine e soluzione</summary>

```bash
oc get pods -l app=web7                         # Init:0/1
oc logs deployment/web7 -c wait-backend         # "backend non pronto, riprovo" all'infinito
oc get deploy web7 -o jsonpath='{.spec.template.spec.initContainers[0].args[0]}'   # http://t7-bakend:8080/ready
oc get svc                                      # il Service si chiama t7-backend
```
**Causa:** errore di battitura nel nome del Service atteso dall'init container (`t7-bakend`).
**Fix:** `oc edit deployment/web7` e correggi in `t7-backend` (oppure `oc patch` con il comando corretto).
**Lezione:** finché un init container non termina, l'app non parte e `oc logs` senza `-c` non mostra nulla di utile: interroga l'init container per nome.
</details>

> **Collegamento con il modulo 04:** un `ImagePullBackOff` su un nome breve come `hello:latest` in un progetto **senza** lookup locale, o su un tag dell'image stream che non esiste, è un errore di image stream: verifica con `oc get istag` e `oc set image-lookup --list`.

Pulizia degli scenari: `oc delete deploy,svc -l 'scenario in (m08-1,m08-2,m08-3,m08-4,m08-5,m08-6,m08-7)'`. A fine modulo: `oc delete project ${LAB}-m08`.

---

## 7. Esercizio finale (stile EX288)

> Lavora come all'esame: niente soluzioni, solo documentazione ufficiale, `oc --help` e `oc explain`. Tempo indicativo: **50 minuti**. La prima build S2I richiede qualche minuto.

**Requisiti**

1. Esiste il progetto `${LAB}-m08-exam`.
2. Esiste la BuildConfig **`api`** con strategia Source (S2I), builder Node.js 22 UBI 9, sorgente `$GIT_REPO` cartella `hello-node`, che ha prodotto l'image stream tag **`api:latest`**. L'image stream `api` ha il **lookup locale** attivo.
3. Il Deployment **`api`** ha 3 repliche pronte e:
   - strategia RollingUpdate con `maxSurge=1` e `maxUnavailable=0`;
   - il container **`api`** ha requests `cpu=100m`, `memory=128Mi` e limits `cpu=500m`, `memory=256Mi`, e la variabile `READY_DELAY_SECONDS=15`;
   - startup probe HTTP GET `/healthz` porta 8080, `periodSeconds=5`, `failureThreshold=24`;
   - readiness probe HTTP GET `/ready` porta 8080, `periodSeconds=5`, `failureThreshold=2`;
   - liveness probe HTTP GET `/healthz` porta 8080, `periodSeconds=10`, `timeoutSeconds=2`, `failureThreshold=3`;
   - un secondo container **`monitor`** dall'immagine `registry.access.redhat.com/ubi9/ubi-minimal` che ogni 10 secondi interroga `http://localhost:8080/healthz` e scrive nel proprio log il codice HTTP ottenuto; `monitor` ha limits `memory=64Mi` e non ha probe.
4. `api` è raggiungibile solo via HTTPS tramite la route **`api`** con terminazione edge.
5. Il team ha consegnato il file `$EX288_HOME/08-deployment-health-troubleshooting/lab/esame-orders.yaml`. Applicalo **senza modificarlo**, poi correggi sul cluster il Deployment **`orders`** (senza eliminarlo e ricrearlo) in modo che:
   - abbia 2 repliche pronte con l'immagine dell'image stream `api`;
   - la readiness probe interroghi `/ready` sulla porta 8080;
   - il container `orders` abbia requests `memory=64Mi` e limits `memory=128Mi`;
   - risponda con il messaggio `Ordini`;
   - la revisione corrente abbia la change-cause `fix orders`.

**Risultato atteso**

- `https://<route api>/` risponde con HTTP 200; `oc logs` del container `monitor` mostra righe con il codice `200`.
- `http://<route orders>/` restituisce `"message": "Ordini"`.
- `oc rollout history deployment/orders` mostra almeno 2 revisioni e la corrente con `fix orders`.

```bash
bash $EX288_HOME/08-deployment-health-troubleshooting/verifica.sh
```

---

## 8. Riferimenti ufficiali (OCP 4.22)

- Building applications → *Deployments* (Deployment vs DeploymentConfig, strategie Rolling e Recreate, `oc rollout`, `oc set resources`, `oc set volume`): https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/building_applications/deployments
- Building applications → *Monitoring application health by using health checks* (readiness, liveness, startup, parametri, `oc set probe`, console): https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/building_applications/application-health
- Building applications → *Quotas* (ResourceQuota, ClusterResourceQuota): https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/building_applications/quotas
- Nodes → *Working with pods* (init container, risorse dei container, `oc debug`): https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/nodes/working-with-pods
- Scalability and performance → *Using quotas and limit ranges*: https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/scalability_and_performance/compute-resource-quotas
- Support → *Troubleshooting* (indagare pod, log, eventi): https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/support/troubleshooting
- Release notes OCP 4.22 (DeploymentConfig *Deprecated*, Kubernetes 1.35): https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/release_notes/ocp-4-22-release-notes
