# Versioni, differenze e incoerenze note

Stato verificato il **13 ottobre 2026** sulle fonti ufficiali Red Hat. Prima di prenotare l'esame ricontrolla la pagina EX288: Red Hat aggiorna periodicamente versione di riferimento e obiettivi.

---

## 1. Esame e corso

| Elemento | Stato attuale | Cosa cambia per te |
|---|---|---|
| Nome dell'esame EX288 | **Red Hat Certified Advanced Developer in Cloud-native Applications exam** (rinominato l'11 maggio 2026; prima "Red Hat Certified Specialist in OpenShift Application Development", ancora prima "Red Hat Certified OpenShift Application Developer") | Solo il nome: Red Hat dichiara invariati contenuti, descrizione e difficoltà |
| Versione di riferimento dell'esame | **OpenShift Container Platform 4.22** | Il corso usa la documentazione 4.22 |
| Più versioni dell'esame in uso | La pagina ufficiale avvisa che sono in uso più versioni e rimanda al PDF *Red Hat Certification Exam Objectives by Version* nel Learning Management System | Controlla nel tuo LMS **quale versione ti è assegnata** e confrontane gli obiettivi con la mappa del README |
| Durata | 4 ore, esame pratico, documentazione del prodotto disponibile | Allenati a cercare nella documentazione (vedi `strategia-esame.md`) |
| Corso DO288 | "Red Hat OpenShift Developer II: Building and Deploying Cloud-native Applications", basato su **OpenShift 4.22** | La pagina pubblica non mostra più l'indice dettagliato; l'ultimo indice pubblico (versione 4.18) comprendeva: funzioni per sviluppatori della console, build e pubblicazione di immagini, gestione dei deployment, applicazioni multi-container (template, Helm, Kustomize), health check, CI/CD con OpenShift Pipelines |
| Percorso consigliato da Red Hat | DO188 → EX188 → DO288 → EX288; EX188 + EX288 danno la certificazione "RHCE – Cloud-native Applications" | Facoltativo per te: questo corso copre i prerequisiti container essenziali |
| Red Hat Learning Community | Chiusa il 31 marzo 2026 | Le discussioni su learn.redhat.com non sono più consultabili |

## 2. OpenShift 4.22 — differenze rispetto a materiale più vecchio

| Argomento | Situazione in 4.22 | Dove nel corso |
|---|---|---|
| **DeploymentConfig** | Deprecato dal 4.14, ancora "Deprecated" (non rimosso) nelle release notes 4.22. Usa `Deployment` | 01, 08 |
| `oc new-app` | Crea `Deployment` (la tabella 3.2 della documentazione elenca ancora `DeploymentConfig`: è un refuso della doc) | 02 |
| **Cluster Samples Operator** | Deprecato 4.20-4.22: image stream e template nel namespace `openshift` possono mancare | Il corso importa sempre il builder nel progetto (`oc import-image`) |
| Prospettiva *Developer* della console | Dal 4.19 le prospettive sono unificate e *Developer* non è abilitata di default; voci di menu "Ecosystem > Installed Operators / Software Catalog / Helm" | 01, 10, 13 |
| Webhook delle build | Dal 4.16 gli utenti non autenticati non hanno più il binding `system:webhook`: serve un RoleBinding nel progetto | 05 |
| Strategia di build Pipeline (Jenkins) | Deprecata: sostituita da OpenShift Pipelines | 05, 12 |
| Builds for OpenShift (Shipwright) | Esiste come libro separato accanto a "Builds using BuildConfig". Gli obiettivi EX288 parlano di build e BuildConfig: il corso si concentra su BuildConfig | 05 |
| API `Endpoints` | Deprecata da Kubernetes 1.33 (OCP 4.22 = Kubernetes 1.35): `oc get endpoints` funziona ma stampa un avviso; alternativa `oc get endpointslices` | 01, 08 |
| OLM v1 | GA in 4.22 (`ClusterExtension`), ma è uno strumento da amministratore; le procedure per sviluppatori ("Creating applications from installed Operators") usano ancora le CSV di OLM Classic | 13 |
| Helm | Nuovo in 4.22: chart OCI, installazione da URL, basic auth per `ProjectHelmChartRepository`. La versione esatta della CLI non è indicata nella doc | 10 |
| Kustomize | Integrato in `oc` (`oc apply -k`, `oc kustomize`). La doc OCP non ha un capitolo dedicato: il formato di `kustomization.yaml` è documentato dal progetto Kubernetes | 11 |

## 3. Red Hat OpenShift Pipelines

| Argomento | Situazione | Dove |
|---|---|---|
| Versioni supportate su OCP 4.22 | 1.22, 1.23, 1.24 (ultima: 1.24.1). La versione usata all'esame non è dichiarata | 12 |
| API | `tekton.dev/v1` per Task, TaskRun, Pipeline, PipelineRun | 12 |
| **ClusterTask** | **Rimosso dalla 1.17**. Le Task fornite (git-clone, buildah, s2i-*, openshift-client, ...) sono nel namespace `openshift-pipelines` e si richiamano con il *cluster resolver* | 12 |
| Parametri delle Task fornite | Tutti in **MAIUSCOLO** (`URL`, `REVISION`, `IMAGE`, `DOCKERFILE`, `CONTEXT`, `SCRIPT`). `PATH_CONTEXT` delle s2i è diventato `CONTEXT` | 12 |
| Service account delle PipelineRun | In v1 si imposta in `spec.taskRunTemplate.serviceAccountName` | 12 |
| Triggers | La doc 1.20-1.24 mostra `triggers.tekton.dev/v1`, ma la `ClusterTriggerBinding` installata è `v1beta1` e nessuna release note annuncia la v1: il corso usa `v1beta1`. Verifica con `oc api-resources --api-group=triggers.tekton.dev` | 12 |
| Task `buildah` | La doc riporta sia `TLS_VERIFY` sia `TLSVERIFY`: leggi il nome reale con `oc get task buildah -n openshift-pipelines -o yaml` | 12 |
| `tkn` | Alcuni comandi (`--last` per i log, alias `pr`/`tr`) non sono nel riferimento ufficiale: controllali con `--help` | 12 |

## 4. Fonti non Red Hat usate (dichiarate)

Il corso usa **solo** fonti ufficiali Red Hat, con due eccezioni inevitabili, sempre segnalate nel testo:

- **Helm CLI** (`helm create`, `upgrade`, `rollback`, `uninstall`, `history`, `template`, `--set`, `-f`): la documentazione OCP mostra solo installazione, `repo add`, `lint` e le operazioni da console. Per il resto si fa riferimento alla documentazione del progetto Helm (helm.sh) e a `helm <comando> --help`.
- **Formato di `kustomization.yaml`**: documentato dal progetto Kubernetes (kubernetes.io / kubectl.docs.kubernetes.io).

Nessun exam dump, nessuna domanda trapelata, nessun materiale non ufficiale.

## 5. Come aggiornare il corso quando cambia la versione

1. Rileggi la pagina EX288 e confronta l'elenco degli obiettivi con la mappa del README.
2. Leggi le release notes della nuova versione OCP (sezione *Deprecated and removed features*) e del nuovo OpenShift Pipelines.
3. Riesegui i `verifica.sh` dei moduli su un cluster della nuova versione: i controlli falliti indicano cosa è cambiato.
4. Cerca nel corso i box **"Da verificare sul tuo cluster"**: sono i punti più esposti ai cambiamenti.

## Fonti

- Esame EX288: https://www.redhat.com/en/services/training/ex288-red-hat-certified-openshift-application-developer-exam
- Corso DO288: https://www.redhat.com/en/services/training/red-hat-openshift-developer-ii-building-and-deploying-cloud-native-applications
- Annuncio dei nuovi nomi delle certificazioni (11 maggio 2026): https://www.redhat.com/en/blog/validate-targeted-expertise-major-updates-red-hat-certification
- Release notes OCP 4.22: https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/release_notes/ocp-4-22-release-notes
- Release notes OpenShift Pipelines 1.24: https://docs.redhat.com/en/documentation/red_hat_openshift_pipelines/1.24/html/release_notes/op-release-notes-1-24
- Migrazione da ClusterTask: https://docs.redhat.com/en/documentation/red_hat_openshift_pipelines/1.24/html/creating_cicd_pipelines/migrate-from-clustertask-to-cluster-resolver
- Red Hat Certification Program Guide: https://docs.redhat.com/en/documentation/red_hat_learning_subscription/1-latest/html/red_hat_certification_program_guide/index
