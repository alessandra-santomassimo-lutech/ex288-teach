# Strategia per il giorno dell'esame

L'EX288 non premia chi ricorda più comandi, ma chi arriva a uno **stato finale corretto e persistente** in 4 ore, usando la documentazione quando serve. Queste abitudini sono state allenate in tutti i moduli.

## Prima di iniziare

- Leggi **tutti** i task. Segna le dipendenze (un'immagine da costruire prima di un deployment, un secret prima di un template) e i nomi esatti richiesti.
- Copia in un file di appunti i nomi di progetti, risorse, label, porte e valori: un nome scritto male vale come un task non fatto.

## Durante

- **Sempre `oc project` prima di creare qualcosa**, oppure usa `-n` in ogni comando.
- Genera YAML invece di scriverlo da zero:
  - `oc create deployment|service|route|configmap|secret ... --dry-run=client -o yaml`
  - `oc new-app ... -o yaml`
  - `oc get <risorsa> -o yaml` di una risorsa simile, poi pulisci `status`, `uid`, `resourceVersion`, `creationTimestamp`
- Quando non ricordi un campo: `oc explain <tipo>.spec.<campo>` (ad esempio `oc explain bc.spec.postCommit`, `oc explain deployment.spec.template.spec.containers.readinessProbe`).
- Quando non ricordi un flag: `oc <comando> --help` mostra **esempi**, spesso più rapidi della documentazione.
- Dopo ogni task **verifica** come nella sezione 5 dei moduli: `oc get`, `oc describe`, `oc logs`, `curl` sulla route.
- Le build richiedono minuti: avviale presto e lavora su altro mentre girano (`oc logs -f bc/<nome>` in un secondo terminale).
- Se un task è bloccato da più di 20 minuti, passa al successivo.

## Dove cercare nella documentazione (OCP 4.22)

| Ti serve | Libro / capitolo |
|---|---|
| `oc new-app`, template, Helm, Deployment, health check, ConfigMap | *Building applications* |
| BuildConfig, strategie, trigger, webhook, hook, S2I | *Builds using BuildConfig* |
| Image stream, `oc tag`, `oc import-image`, trigger su Deployment, linee guida per le immagini | *Images* |
| Registry interno, ruoli, esposizione | *Registry* |
| Esempi di ogni comando `oc` | *CLI tools* → *OpenShift CLI developer command reference* |
| Route e TLS | *Ingress and load balancing* |
| Operator per sviluppatori | *Operators* → *User tasks* |
| Pipeline, Task, Triggers, parametri delle Task fornite | Documentazione *Red Hat OpenShift Pipelines* → *Creating CI/CD pipelines* |

Allenati a raggiungere queste pagine in meno di un minuto: durante l'esame cercare a caso costa tempo.

## Errori che costano più punti

1. Risorsa nel progetto sbagliato.
2. Nome o label diversi da quelli richiesti.
3. Modifiche fatte a mano dentro un pod (`oc rsh`) invece che nelle risorse: al riavvio spariscono e il task risulta non svolto.
4. Push su Git dimenticato prima di avviare la build.
5. Route che punta al Service o alla porta sbagliati (503).
6. PipelineRun avviata con parametri in minuscolo o senza workspace.
7. Secret creato con valori codificati due volte in base64.

## Alla fine

Riserva gli ultimi 20 minuti per ripassare ogni task con `oc get` e `curl`. Controlla che tutti i pod siano `Running` e `Ready`, che le build richieste siano `Complete`, che le PipelineRun siano `Succeeded`.
