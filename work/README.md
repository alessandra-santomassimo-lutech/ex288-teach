# work/ — la tua area di lavoro

Tutto ciò che crei o modifichi durante il corso sta qui. Il resto del repository (moduli, `apps/`, `lib/`) resta intatto: se devi cambiare un file di laboratorio, prima lo copi qui.

La variabile `$EX288_WORK` punta a questa cartella. `source env.sh` (dalla root del repository) la crea insieme alle sottocartelle.

| Percorso | Cosa contiene |
|---|---|
| `ex288-apps/` | Il tuo clone del repository Git delle applicazioni (modulo 00, passo 3). Qui fai commit e push: il cluster costruisce da lì |
| `m00/` … `m14/` | File del modulo corrispondente: YAML generati con `-o yaml`, copie dei lab da modificare, chart Helm, overlay Kustomize |
| `mNN-exam/` | File richiesti dagli esercizi finali (ad esempio `m10-exam/catalog`, `m11-exam/`, `m14-exam/`). Gli script `verifica.sh` li cercano qui |

Il contenuto di questa cartella è ignorato da Git (vedi `.gitignore`). Per ripartire da zero:

```bash
cd <root del repository>
rm -rf work/ex288-apps work/m*          # cancella il tuo lavoro locale (non tocca il cluster)
source env.sh                           # ricrea le cartelle vuote
```

Ricordati che il clone `ex288-apps/` ha un remote: cancellarlo in locale non cancella il repository su GitHub/GitLab.
