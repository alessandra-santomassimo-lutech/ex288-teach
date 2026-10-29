#!/usr/bin/env bash
# Verifica dell'esercizio finale del modulo 13 (sola lettura).
# Parametrica: per usare un Operator diverso da Data Grid imposta le variabili
# OPERATOR_* descritte nel README (sezione 7), ad esempio:
#   OPERATOR_KIND=Kafka OPERATOR_CR=ordini OPERATOR_READY_CONDITION=Ready \
#   OPERATOR_SIZE_PATH= OPERATOR_SERVICE=ordini-kafka-bootstrap OPERATOR_PORT=9092 bash verifica.sh
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../lib/verifica-lib.sh"
richiedi_login

P="${LAB}-m13-exam"
KIND="${OPERATOR_KIND:-Infinispan}"
if [ "$KIND" = "Infinispan" ]; then R_DEF="infinispans.infinispan.org"; else R_DEF="$KIND"; fi
R="${OPERATOR_RESOURCE:-$R_DEF}"
CR="${OPERATOR_CR:-exam-cache}"
READY="${OPERATOR_READY_CONDITION:-wellFormed}"
DEF_SIZE_PATH='{.spec.replicas}'
SIZE_PATH="${OPERATOR_SIZE_PATH-$DEF_SIZE_PATH}"
SIZE="${OPERATOR_SIZE:-2}"
SVC="${OPERATOR_SERVICE:-$CR}"
PORT="${OPERATOR_PORT:-11222}"
APP="negozio"

titolo "Modulo 13 - esercizio finale (progetto $P, istanza $KIND/$CR)"
info "risorsa: $R · condizione di pronto: $READY · Service: $SVC:$PORT"

check "il progetto $P esiste" oc get project "$P"

# --- Istanza ---------------------------------------------------------------------------
titolo "Istanza $KIND/$CR"
if ! oc get "$R" "$CR" -n "$P" >/dev/null 2>&1; then
  ko "l'istanza $KIND/$CR esiste" "oc get $R $CR -n $P fallisce: API non disponibile o istanza mancante (vedi OPERATOR_KIND/OPERATOR_RESOURCE)"
else
  ok "l'istanza $KIND/$CR esiste"
  check_eq "il kind dell'istanza è $KIND" "oc get $R $CR -n $P -o jsonpath='{.kind}'" "$KIND"
  check_eq "label app.kubernetes.io/part-of=negozio" "oc get $R $CR -n $P -o jsonpath='{.metadata.labels.app\.kubernetes\.io/part-of}'" "negozio"
  if [ -n "$SIZE_PATH" ]; then
    check_eq "repliche richieste nel CR = $SIZE ($SIZE_PATH)" "oc get $R $CR -n $P -o jsonpath='$SIZE_PATH'" "$SIZE"
  else
    info "controllo delle repliche disattivato (OPERATOR_SIZE_PATH vuota)"
  fi
  if [ "$KIND" = "Infinispan" ]; then
    check_eq "storage effimero (spec.service.container.ephemeralStorage)" "oc get $R $CR -n $P -o jsonpath='{.spec.service.container.ephemeralStorage}'" "true"
  fi
  check_eq "condizione $READY = True" "oc get $R $CR -n $P -o jsonpath='{.status.conditions[?(@.type==\"$READY\")].status}'" "True"
  # Il nome di un CSV che fornisce il kind (informativo)
  CSVS="$(oc get csv -n "$P" -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.customresourcedefinitions.owned[*].kind}{"\n"}{end}' 2>/dev/null | awk -v k="$KIND" '{for(i=2;i<=NF;i++) if($i==k) print $1}' | head -1)"
  [ -n "$CSVS" ] && info "API fornita dalla CSV $CSVS"
fi

# --- Risorse figlie ----------------------------------------------------------------------
titolo "Risorse create dall'Operator"
OWNED="$(oc get statefulset,deployment -n "$P" \
  -o jsonpath='{range .items[*]}{.kind}/{.metadata.name}{" "}{range .metadata.ownerReferences[*]}{.kind}/{.name}{" "}{end}{"\n"}{end}' 2>/dev/null \
  | awk -v o="$KIND/$CR" '{for(i=2;i<=NF;i++) if($i==o) print $1}')"
if [ -n "$OWNED" ]; then
  ok "StatefulSet/Deployment posseduti da $KIND/$CR: $(printf '%s' "$OWNED" | tr '\n' ' ')"
else
  ko "almeno uno StatefulSet/Deployment ha come owner $KIND/$CR" "controlla ownerReferences con oc get statefulset,deployment -o yaml"
fi
check "il Service $SVC esiste" oc get svc "$SVC" -n "$P"
check_match "il Service $SVC espone la porta $PORT" "oc get svc $SVC -n $P -o jsonpath='{.spec.ports[*].port}'" "(^| )$PORT( |$)"
EXP_EP="1"; [ -n "$SIZE_PATH" ] && EXP_EP="$SIZE"
N_EP="$(oc get endpoints "$SVC" -n "$P" -o jsonpath='{range .subsets[*].addresses[*]}{.ip}{"\n"}{end}' 2>/dev/null | grep -c .)"
if [ -n "$SIZE_PATH" ]; then
  if [ "$N_EP" = "$EXP_EP" ]; then ok "il Service $SVC ha $EXP_EP endpoint pronti"; else ko "il Service $SVC ha $EXP_EP endpoint pronti" "trovati: $N_EP"; fi
else
  if [ "${N_EP:-0}" -ge 1 ]; then ok "il Service $SVC ha almeno 1 endpoint pronto ($N_EP)"; else ko "il Service $SVC ha almeno 1 endpoint pronto" "trovati: ${N_EP:-0}"; fi
fi

# --- Secret e applicazione ---------------------------------------------------------------
titolo "Secret negozio-db e applicazione $APP"
check "il Secret negozio-db esiste" oc get secret negozio-db -n "$P"
check_match "negozio-db contiene una DB_PASSWORD non vuota" "oc get secret negozio-db -n $P -o jsonpath='{.data.DB_PASSWORD}'" '^.+$'
if [ "$KIND" = "Infinispan" ]; then
  GEN="$(oc get secret "$CR-generated-secret" -n "$P" -o jsonpath='{.data.identities\.yaml}' 2>/dev/null | base64 -d 2>/dev/null)"
  MINE="$(oc get secret negozio-db -n "$P" -o jsonpath='{.data.DB_PASSWORD}' 2>/dev/null | base64 -d 2>/dev/null)"
  if [ -n "$GEN" ] && [ -n "$MINE" ] && printf '%s\n' "$GEN" | grep -F -- "$MINE" >/dev/null; then
    ok "DB_PASSWORD coincide con una password generata dall'Operator ($CR-generated-secret)"
  else
    ko "DB_PASSWORD coincide con una password generata dall'Operator ($CR-generated-secret)"
  fi
fi

DJ="oc get deploy $APP -n $P -o jsonpath"
check_eq "il Deployment $APP ha 1 replica pronta" "$DJ='{.status.readyReplicas}'" "1"
check_match "DB_HOST punta al Service $SVC" "$DJ='{.spec.template.spec.containers[0].env[?(@.name==\"DB_HOST\")].value}'" "^$SVC(\\.$P(\\.svc(\\.cluster\\.local)?)?)?\$"
check_eq "DB_PORT = $PORT" "$DJ='{.spec.template.spec.containers[0].env[?(@.name==\"DB_PORT\")].value}'" "$PORT"
if [ "$KIND" = "Infinispan" ]; then
  check_eq "DB_USER = developer" "$DJ='{.spec.template.spec.containers[0].env[?(@.name==\"DB_USER\")].value}'" "developer"
else
  check_match "DB_USER impostata" "$DJ='{.spec.template.spec.containers[0].env[?(@.name==\"DB_USER\")].value}{.spec.template.spec.containers[0].env[?(@.name==\"DB_USER\")].valueFrom}'" '.+'
fi
check_eq "DB_PASSWORD letta dal Secret negozio-db" "$DJ='{.spec.template.spec.containers[0].env[?(@.name==\"DB_PASSWORD\")].valueFrom.secretKeyRef.name}'" "negozio-db"
check_eq "DB_PASSWORD non è scritta in chiaro" "$DJ='{.spec.template.spec.containers[0].env[?(@.name==\"DB_PASSWORD\")].value}'" ""
check_match "$APP è costruita da hello-node" "oc get bc,deploy -n $P -o jsonpath='{range .items[*]}{.spec.source.contextDir} {.spec.template.spec.containers[*].image}{\"\\n\"}{end}'" 'hello-node|/negozio[@:]'

check "la route $APP esiste" oc get route "$APP" -n "$P"
check_eq "la route $APP ha terminazione edge" "oc get route $APP -n $P -o jsonpath='{.spec.tls.termination}'" "edge"
URL="$(route_url "$APP" "$P")"
[ -n "$URL" ] && check_http "$APP raggiunge il servizio dell'Operator (/db)" "$URL/db" '"db": *"raggiungibile"'

riepilogo
