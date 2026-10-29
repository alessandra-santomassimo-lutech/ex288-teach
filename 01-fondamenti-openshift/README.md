# Modulo 01 — Fondamenti di OpenShift: progetti, applicazioni, servizi e route

> **Obiettivi EX288 coperti**
> - *Work with Red Hat OpenShift Container Platform* → Create and work with multiple OpenShift projects
> - *Work with Red Hat OpenShift Container Platform* → Create and deploy single container and multi-container applications (prima parte)
> - *Work with Red Hat OpenShift Container Platform* → Manage applications with the web console
>
> **Durata stimata:** 3-4 ore · **Prerequisiti:** modulo 00 · **Richiede cluster-admin:** no
>
> **Progetti usati:** `${LAB}-m01`, `${LAB}-m01-b`, `${LAB}-m01-exam`

---

## 1. Perché e quando

Conosci già Kubernetes: OpenShift **è** Kubernetes, con in più API e comportamenti pensati per chi sviluppa e per la sicurezza multi-tenant. In questo modulo impari le differenze che userai in ogni altro modulo.

| Ti serve… | In Kubernetes useresti | In OpenShift usi | Perché |
|---|---|---|---|
| Uno spazio isolato per un'app/team | `Namespace` | **`Project`** (`oc new-project`) | Un Project è un Namespace con metadati (display name, descrizione) e RBAC impostato automaticamente: chi lo crea ne diventa `admin` |
| Esporre un'app HTTP all'esterno | `Ingress` | **`Route`** (`oc expose`, `oc create route`) | Il router OpenShift gestisce hostname automatici e terminazione TLS (edge, passthrough, re-encrypt) |
| Eseguire un'immagine già pronta | `kubectl create deployment` | **`oc new-app --image`** (o `oc create deployment`) | `oc new-app` crea in un colpo Deployment, Service e image stream |
| Eseguire un container come root | Spesso consentito | **Vietato di default** | La SCC `restricted-v2` assegna un **UID arbitrario** (vedi modulo 03) |
| Dare accesso a un collega | `RoleBinding` | `oc policy add-role-to-user` | Stesso RBAC di Kubernetes, con comandi più rapidi |

**Regola pratica:** se un comando `kubectl` ti è familiare, funziona anche con `oc` (`oc` include `kubectl`). Usa `oc` perché aggiunge i comandi OpenShift (`new-project`, `new-app`, `expose`, `start-build`, `process`, `policy`…).

---

## 2. Concetti essenziali

### 2.1 Project
- Si crea con `oc new-project <nome> --display-name=... --description=...`.
- Non puoi usare nomi che iniziano con `openshift-` o `kube-`.
- Chi crea il progetto ottiene il ruolo **admin** sul progetto.
- `oc project <nome>` cambia il progetto corrente; quasi tutti i comandi accettano anche `-n <nome>`.

### 2.2 Ruoli predefiniti a livello di progetto

| Ruolo | Cosa può fare | Quando assegnarlo |
|---|---|---|
| `view` | Leggere quasi tutto (non i Secret) | Auditor, colleghi che devono solo guardare |
| `edit` | Creare/modificare risorse applicative | Sviluppatori, pipeline, service account che fanno deploy |
| `admin` | Tutto `edit` + gestire i permessi del progetto | Responsabile del progetto |

### 2.3 Dal Pod alla Route

```
Utente ──HTTP(S)──▶ Route ──▶ Service ──(selector su label)──▶ Pod (gestiti da ReplicaSet ◀── Deployment)
```

- **Deployment**: descrive *quale* immagine eseguire e *quante* repliche; gestisce i rollout.
- **Service**: IP e nome DNS stabili (`<svc>.<progetto>.svc.cluster.local`) che bilanciano verso i pod selezionati tramite **label**.
- **Route**: rende il Service raggiungibile da fuori con un hostname del tipo `<route>-<progetto>.<dominio-apps>`.

> L'errore più frequente all'esame è una catena interrotta: selector del Service che non corrisponde alle label dei pod, Route che punta al Service o alla porta sbagliata. Lo proverai nella sezione 6.

### 2.4 Applicazioni multi-container
"Multi-container" in OpenShift significa due cose diverse, entrambe in esame:
1. **Più componenti** (es. frontend + database), ognuno con il proprio Deployment e Service, che si parlano via DNS del Service. Lo vedi in questo modulo e nei moduli 09-11.
2. **Più container nello stesso pod** (es. app + sidecar), che condividono rete e volumi. Lo vedi nel modulo 08.

---

## 3. Laboratorio guidato

```bash
source env.sh     # dalla root del repository: carica LAB, GIT_REPO, EX288_WORK, ...
```

### 3.1 Creare e usare più progetti

```bash
# Crea il primo progetto: diventa automaticamente il progetto corrente
oc new-project ${LAB}-m01 \
  --display-name="EX288 m01 - fondamenti" \
  --description="Laboratorio guidato modulo 01"

# Crea un secondo progetto (anche questo diventa corrente!)
oc new-project ${LAB}-m01-b --display-name="EX288 m01 - progetto B"

oc project                       # mostra il progetto corrente: ${LAB}-m01-b
oc projects                      # elenca i progetti a cui hai accesso (* = corrente)
oc project ${LAB}-m01            # torna al primo progetto

# Leggere risorse di un progetto diverso dal corrente, senza cambiarlo
oc get pods -n ${LAB}-m01-b
```

> **Abitudine da esame:** prima di creare qualsiasi cosa esegui `oc project` per sapere dove sei. Una risorsa creata nel progetto sbagliato vale zero punti.

### 3.2 Deploy di un'immagine esistente con `oc new-app`

```bash
# Crea un'app a partire da un'immagine pubblica Red Hat (Apache httpd, porta 8080)
oc new-app --image=registry.access.redhat.com/ubi9/httpd-24 --name=web

# Cosa ha creato? new-app etichetta tutto con app=<nome>
oc get all -l app=web
#  - imagestream.image.openshift.io/web   (riferimento all'immagine, vedi modulo 04)
#  - deployment.apps/web, replicaset, pod
#  - service/web                          (porte esposte dall'immagine: 8080 e 8443)

oc status                        # vista d'insieme del progetto
oc rollout status deployment/web # attende che il rollout sia completo
```

> `oc get all` **non** mostra tutto: include le risorse della categoria "all" (pod, service, deployment, replicaset e, in OpenShift, anche build, buildconfig, imagestream e route), ma esclude ad esempio ConfigMap, Secret, PVC, ServiceAccount e RoleBinding. Quando cerchi qualcosa elenca i tipi esplicitamente: `oc get deploy,svc,route,cm,secret,pvc`.

### 3.3 Esporre l'applicazione

```bash
# Route HTTP semplice: hostname generato automaticamente.
# Il Service espone due porte (8080-tcp e 8443-tcp): indichiamo quella HTTP.
oc expose service/web --port=8080-tcp
oc get route web                                    # colonna HOST/PORT
curl -s -o /dev/null -w '%{http_code}\n' http://$(oc get route web -o jsonpath='{.spec.host}')
# 403 o 200: risponde Apache (senza index.html mostra la pagina di test con 403).
# 503 con "Application is not available" invece è il ROUTER: non trova pod pronti.

# Route HTTPS con terminazione edge (TLS terminato dal router con il suo certificato)
oc create route edge web-tls --service=web --port=8080-tcp
curl -sk -o /dev/null -w '%{http_code}\n' https://$(oc get route web-tls -o jsonpath='{.spec.host}')
```

**Quando usare quale route:**

| Tipo | TLS terminato da | Usala quando |
|---|---|---|
| (nessuno) `oc expose` | — (HTTP in chiaro) | Test, app interne |
| `edge` | Router | Caso più comune: HTTPS verso l'utente, HTTP nel cluster |
| `passthrough` | Pod | L'app gestisce da sé il certificato (es. mTLS) |
| `reencrypt` | Router **e** pod | HTTPS anche dentro il cluster |

### 3.4 Ispezionare e fare debug

```bash
oc describe deployment web           # strategia, immagine, condizioni, eventi
POD=$(oc get pods -l deployment=web -o name | head -1)
oc logs $POD                         # log del container (stdout/stderr)
oc logs deployment/web               # scorciatoia: log di un pod del deployment
oc rsh $POD                          # shell interattiva nel container (exit per uscire)
oc exec $POD -- id                   # nota l'UID arbitrario (es. 1000680000) e il gruppo 0
oc get events --sort-by=.lastTimestamp   # eventi del progetto in ordine cronologico
oc explain deployment.spec.strategy  # documentazione dei campi, utilissima all'esame
```

### 3.5 Scalare e osservare il bilanciamento

```bash
oc scale deployment/web --replicas=3
oc get pods -l deployment=web -o wide
oc get endpoints web                 # 3 IP:porta = 3 pod pronti dietro il Service

# Forma moderna (stessa informazione, nessun warning):
oc get endpointslices -l kubernetes.io/service-name=web
```

> **Nota di versione:** OCP 4.22 è basato su Kubernetes 1.35. Dalla 1.33 l'API `Endpoints` v1 è deprecata a favore di `EndpointSlice`: `oc get endpoints` funziona ancora ma stampa un avviso di deprecazione. Nel corso trovi entrambe le forme; il significato è lo stesso (nessun indirizzo = nessun pod pronto dietro il Service).

### 3.6 Da imperativo a dichiarativo

All'esame puoi creare le risorse con comandi imperativi, ma per risorse complesse è più sicuro generare lo YAML, modificarlo e applicarlo.

```bash
# Genera lo YAML senza creare nulla (--dry-run=client) e salvalo
oc create deployment hello --image=registry.access.redhat.com/ubi9/httpd-24 \
  --replicas=2 --port=8080 --dry-run=client -o yaml > hello-deploy.yaml

# Aggiungi una label al template dei pod, poi applica
vi hello-deploy.yaml                 # es. spec.template.metadata.labels.tier: frontend
oc apply -f hello-deploy.yaml

# Crea il Service per il deployment (il selector viene copiato dal deployment)
oc expose deployment/hello --port=8080
oc get svc hello -o yaml | grep -A3 selector
```

### 3.7 Comunicazione tra componenti e tra progetti

```bash
# Nel progetto B esegui un secondo componente
oc new-app --image=registry.access.redhat.com/ubi9/httpd-24 --name=backend -n ${LAB}-m01-b

# Da un pod temporaneo nel progetto corrente chiama:
#  - un Service dello stesso progetto con il nome breve
#  - un Service di un altro progetto con <svc>.<progetto>.svc
oc run tester --image=registry.access.redhat.com/ubi9/ubi-minimal --rm -it --restart=Never -- \
  sh -c "curl -s -o /dev/null -w 'web: %{http_code}\n' http://web:8080; \
         curl -s -o /dev/null -w 'backend: %{http_code}\n' http://backend.${LAB}-m01-b.svc:8080"
```

> Se il secondo `curl` restituisce `000` (timeout), sul cluster ci sono **NetworkPolicy** che isolano i progetti: è una configurazione dell'amministratore, non un tuo errore.

### 3.8 Permessi sul progetto

```bash
# Un service account che può solo leggere
oc create serviceaccount auditor
oc policy add-role-to-user view -z auditor          # -z = service account del progetto corrente

# Verifica impersonando il service account
oc auth can-i get pods    --as=system:serviceaccount:${LAB}-m01:auditor   # yes
oc auth can-i delete pods --as=system:serviceaccount:${LAB}-m01:auditor   # no
oc get rolebindings -o wide

# Per un collega reale:
# oc policy add-role-to-user edit <username> -n ${LAB}-m01
```

### 3.9 Gestire l'applicazione dalla web console

Apri l'URL restituito da `oc whoami --show-console` e seleziona il progetto `${LAB}-m01`.

> **Nota di versione (4.19+):** le prospettive della console sono unificate e la prospettiva *Developer* non è più abilitata di default. Le funzioni sotto si trovano comunque nel menu (Workloads, Networking, Builds…). Se l'amministratore ha abilitato *Developer*, hai anche le viste **Topology** e **+Add**.

Esegui dalla console, poi verifica con `oc`:

| Azione in console | Verifica con `oc` |
|---|---|
| Workloads → Deployments → `web` → scala a 2 repliche | `oc get deploy web` |
| Deployment `web` → tab *Environment* → aggiungi `WELCOME=console` | `oc set env deployment/web --list` |
| Pod di `web` → tab *Logs* e *Terminal* | `oc logs` / `oc rsh` |
| Networking → Routes → `web-tls` → apri l'URL | `oc get route web-tls` |
| Pulsante **+** (Import YAML) → incolla un ConfigMap | `oc get cm` |

### 3.10 Pulizia

```bash
oc delete project ${LAB}-m01-b
# Tieni ${LAB}-m01 per la sezione 6 (troubleshooting), poi eliminalo.
```

---

## 4. Esercizi

### 4.1 Esercizio guidato
Nel progetto `${LAB}-m01`:
1. crea un deployment `docs` dall'immagine `registry.access.redhat.com/ubi9/httpd-24` con 2 repliche;
2. aggiungi al deployment la label `tier=frontend` (sui metadati del deployment **e** dei pod);
3. esponilo con una route **edge** chiamata `docs`.

<details><summary>Suggerimenti</summary>

- `oc create deployment ... --replicas` oppure `oc new-app` + `oc scale`.
- Per le label sui pod devi modificare `spec.template.metadata.labels` (`oc edit` o `oc patch`); `oc label deployment` agisce solo sul deployment.
- Una route edge richiede un Service: `oc expose deployment/docs --port=8080`, poi `oc create route edge`.
</details>

<details><summary>Soluzione</summary>

```bash
oc create deployment docs --image=registry.access.redhat.com/ubi9/httpd-24 --replicas=2 --port=8080
oc label deployment docs tier=frontend
oc patch deployment docs --type=merge -p '{"spec":{"template":{"metadata":{"labels":{"tier":"frontend"}}}}}'
oc expose deployment docs --port=8080
oc create route edge docs --service=docs
oc get pods -l tier=frontend
```
</details>

### 4.2 Esercizio semi-guidato
1. Crea il progetto `${LAB}-m01-team` con display name `Team`.
2. Dai a un service account `deployer` (nello stesso progetto) il ruolo che gli permetta di creare deployment ma **non** di modificare i permessi del progetto.
3. Dimostra con `oc auth can-i` che può creare deployment ma non rolebinding.

<details><summary>Suggerimento</summary>Ripassa la tabella dei ruoli nella sezione 2.2.</details>

<details><summary>Soluzione (aprila solo dopo aver provato)</summary>

```bash
oc new-project ${LAB}-m01-team --display-name="Team"    # diventa anche il progetto corrente

oc create serviceaccount deployer
# "edit": crea e modifica risorse applicative, ma NON gestisce ruoli e rolebinding.
# "admin" sarebbe troppo (può cambiare i permessi), "view" troppo poco (solo lettura).
oc policy add-role-to-user edit -z deployer             # -z = service account del progetto corrente

SA=system:serviceaccount:${LAB}-m01-team:deployer
oc auth can-i create deployments  --as=$SA              # yes
oc auth can-i create rolebindings --as=$SA              # no
oc get rolebindings -o wide | grep deployer             # ClusterRole/edit -> deployer
```

**Perché funziona:** il ruolo `edit` è il minimo che permette di creare deployment; non include le risorse RBAC, quindi `deployer` non può darsi (o dare ad altri) permessi aggiuntivi.
</details>

### 4.3 Esercizio senza aiuti
Nel progetto `${LAB}-m01-team` esegui due componenti da `registry.access.redhat.com/ubi9/httpd-24`: `frontend` (esposto all'esterno via HTTPS) e `catalog` (raggiungibile solo dall'interno del cluster). Dimostra che `frontend` riesce a raggiungere `catalog` tramite DNS del Service. Poi elimina il progetto.

---

## 5. Verifiche pratiche con `oc`

| Domanda | Comando |
|---|---|
| In che progetto sono? | `oc project` |
| Il deployment ha tutte le repliche pronte? | `oc get deploy <nome>` (colonna READY), `oc rollout status deploy/<nome>` |
| Il Service seleziona dei pod? | `oc get endpoints <svc>` (deve contenere IP) · `oc describe svc <svc>` |
| La route punta al Service giusto? | `oc describe route <route>` (Service, porta, endpoints) |
| L'app risponde dall'esterno? | `curl -sk https://$(oc get route <r> -o jsonpath='{.spec.host}')` |
| Chi ha accesso al progetto? | `oc get rolebindings` · `oc auth can-i --list --as=<utente>` |
| Perché un pod non parte? | `oc describe pod <pod>` (sezione *Events*) · `oc get events --sort-by=.lastTimestamp` |

---

## 6. Troubleshooting intenzionale

Ogni scenario crea volutamente una risorsa rotta. **Prima** indaga con gli strumenti della sezione 5, **poi** apri la soluzione.

```bash
oc project ${LAB}-m01
oc apply -f $EX288_HOME/01-fondamenti-openshift/troubleshooting/rotto-1-immagine.yaml
oc apply -f $EX288_HOME/01-fondamenti-openshift/troubleshooting/rotto-2-selector.yaml
oc apply -f $EX288_HOME/01-fondamenti-openshift/troubleshooting/rotto-3-route.yaml
```

### Scenario 1 — `shop` non parte
**Sintomo:** `oc get pods -l app=shop` mostra `ErrImagePull` / `ImagePullBackOff`.

<details><summary>Indagine e soluzione</summary>

```bash
oc describe pod -l app=shop | sed -n '/Events/,$p'
# Failed to pull image "registry.access.redhat.com/ubi9/httpd-42": ... not found / manifest unknown
```
**Causa:** nome dell'immagine errato (`httpd-42` invece di `httpd-24`).
**Fix:** `oc set image deployment/shop httpd=registry.access.redhat.com/ubi9/httpd-24`
**Lezione:** `ErrImagePull` = problema di *nome*, *tag*, *registry* o *credenziali* (pull secret, modulo 03). Gli eventi del pod dicono quale.
</details>

### Scenario 2 — `cart` gira ma la route dà 503
**Sintomo:** i pod sono `Running`, ma `curl` sulla route restituisce *Application is not available*.

<details><summary>Indagine e soluzione</summary>

```bash
oc get endpoints cart            # ENDPOINTS: <none>
oc describe svc cart | grep -i selector     # app=carts
oc get pods --show-labels -l app=cart       # i pod hanno app=cart
```
**Causa:** il selector del Service (`app=carts`) non corrisponde alle label dei pod (`app=cart`).
**Fix:** `oc patch svc cart --type=merge -p '{"spec":{"selector":{"app":"cart"}}}'`
**Lezione:** Service senza endpoint ⇒ 503 del router. Controlla **sempre** `oc get endpoints`.
</details>

### Scenario 3 — `pay` ha endpoint ma la route non risponde
**Sintomo:** `oc get endpoints pay` mostra IP, ma la route restituisce 503.

<details><summary>Indagine e soluzione</summary>

```bash
oc describe route pay        # Service: pay-svc  (non esiste!) / oppure porta errata
oc get svc
```
**Causa:** la route punta a un Service inesistente (`pay-svc`) e a una porta che il Service non espone.
**Fix:** `oc delete route pay && oc expose svc/pay` (oppure `oc patch route pay ...` correggendo `spec.to.name` e `spec.port.targetPort`).
**Lezione:** la route punta a un *Service* (per nome) e a una *porta del Service* (per nome o numero).
</details>

Pulizia: `oc delete project ${LAB}-m01`

---

## 7. Esercizio finale (stile EX288)

> Lavora come all'esame: niente soluzioni, solo documentazione ufficiale, `oc --help` e `oc explain`. Tempo indicativo: **30 minuti**.

**Requisiti**

1. Esiste il progetto `${LAB}-m01-exam` con display name `Negozio online`.
2. Nel progetto gira un'applicazione **`storefront`**:
   - immagine `registry.access.redhat.com/ubi9/httpd-24`;
   - 3 repliche pronte;
   - il Deployment e i suoi pod hanno la label `tier=frontend`.
3. `storefront` è raggiungibile dall'esterno **solo via HTTPS** tramite una route chiamata `storefront` con terminazione TLS sul router.
4. Nello stesso progetto gira un secondo componente **`inventory`** (stessa immagine, 1 replica; il Deployment **e i suoi pod** hanno la label `tier=backend`) raggiungibile **solo dall'interno del cluster** sulla porta 8080 tramite un Service `inventory`. Non deve esistere alcuna route per `inventory`.
5. Esiste un service account `auditor` che può leggere le risorse del progetto ma non modificarle.

**Risultato atteso**

- `https://<host-route-storefront>` risponde (codice 200 o 403 dalla pagina di test Apache, **non** 503).
- Il Service `inventory` ha 1 endpoint; il Service `storefront` ne ha 3.
- `auditor` può eseguire `get pods` ma non `delete pods`.

```bash
bash $EX288_HOME/01-fondamenti-openshift/verifica.sh
```

---

## 8. Riferimenti ufficiali (OCP 4.22)

- Building applications → *Projects*: https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/building_applications/projects
- Building applications → *Creating applications* (`oc new-app`): https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/building_applications/creating-applications
- CLI tools → *OpenShift CLI developer command reference*: https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/cli_tools/openshift-cli-oc
- Ingress and load balancing → *Routes* (tipi di route e TLS): https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/ingress_and_load_balancing
- Web console → *Web console overview* (prospettive unificate dal 4.19): https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/web_console/web-console-overview
