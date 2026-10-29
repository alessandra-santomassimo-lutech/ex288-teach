# Variabili comuni a tutti i laboratori.
# 1) Copia questo file:      cp env.example.sh env.sh
# 2) Modifica i valori sotto
# 3) In ogni nuovo terminale, dalla root del repository: source env.sh
#
# env.sh è personale: non committarlo nel repository delle app.

# Prefisso per i nomi dei progetti. Su un cluster condiviso i nomi dei progetti
# sono UNICI in tutto il cluster: usa le tue iniziali o il tuo username.
# Esempio: LAB=asanto  ->  progetti asanto-m01, asanto-m02, ...
export LAB="cambiami"

# Repository Git (raggiungibile DAL CLUSTER) che contiene il contenuto della
# cartella apps/ di questo corso. Vedi 00-setup, passo 3.
export GIT_REPO="https://github.com/<tuo-utente>/ex288-apps.git"
export GIT_BRANCH="main"

# Immagine builder Node.js usata per S2I. Il modulo 00 verifica se esiste
# l'image stream nel namespace "openshift"; se manca la importa nel tuo progetto.
export NODE_BUILDER_IMAGE="registry.access.redhat.com/ubi9/nodejs-22"
export NODE_RUNTIME_IMAGE="registry.access.redhat.com/ubi9/nodejs-22-minimal"

# Database usato nelle app multi-container (moduli 07-11 e esame simulato).
# Le immagini registry.redhat.io vengono scaricate grazie al pull secret
# globale del cluster OpenShift.
export POSTGRES_IMAGE="registry.redhat.io/rhel9/postgresql-16"

# Directory radice del corso (non modificare)
export EX288_HOME="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# Directory di lavoro: TUTTI i file che crei o modifichi durante i lab
# (clone del repository delle app, chart Helm, overlay Kustomize, YAML generati,
# file degli esercizi finali) stanno qui dentro, mai nella tua home o in /tmp.
# Contenuto ignorato da Git: puoi cancellarla in qualsiasi momento per ripartire.
export EX288_WORK="$EX288_HOME/work"
for _d in ex288-apps m00 m01 m02 m03 m04 m05 m06 m07 m08 m09 m10 m11 m12 m13 m14; do
  mkdir -p "$EX288_WORK/$_d"
done
unset _d
