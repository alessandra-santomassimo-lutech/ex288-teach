// hello-node — applicazione didattica per il percorso EX288.
// Zero dipendenze esterne: `npm install` non scarica nulla, quindi le build S2I
// funzionano anche su cluster aziendali senza accesso al registry npm.
//
// Endpoint:
//   GET /               info applicazione (versione, messaggio, hostname del pod)
//   GET /healthz        liveness  (200 finché non chiami /toggle-health)
//   GET /ready          readiness (503 per READY_DELAY_SECONDS dopo l'avvio)
//   GET /config         contenuto del file CONFIG_FILE (default /etc/app/app.properties)
//   GET /env            variabili APP_* e presenza (mascherata) di API_KEY / DB_PASSWORD
//   GET /db             verifica TCP verso DB_HOST:DB_PORT
//   GET /toggle-health  inverte lo stato di /healthz (per i lab sulle liveness probe)
//   GET /build-info     contenuto di build-info.txt (scritto dagli script S2I personalizzati)

'use strict';

const http = require('http');
const fs = require('fs');
const os = require('os');
const net = require('net');
const path = require('path');

const pkg = require('./package.json');

const PORT = parseInt(process.env.PORT || '8080', 10);
const VERSION = process.env.APP_VERSION || pkg.version;
const MESSAGE = process.env.APP_MESSAGE || 'Ciao da OpenShift!';
const CONFIG_FILE = process.env.CONFIG_FILE || '/etc/app/app.properties';
const READY_DELAY = parseInt(process.env.READY_DELAY_SECONDS || '0', 10);
const startedAt = Date.now();
let healthy = true;

// --- Controlli all'avvio (usati negli scenari di troubleshooting) ----------

if (process.env.FAIL_ON_START === 'true') {
  console.error('FAIL_ON_START=true: termino con errore (scenario di troubleshooting)');
  process.exit(1);
}

if (process.env.REQUIRED_ENV) {
  for (const name of process.env.REQUIRED_ENV.split(',').map((s) => s.trim()).filter(Boolean)) {
    if (!process.env[name]) {
      console.error(`ERRORE: variabile obbligatoria mancante: ${name}`);
      process.exit(1);
    }
  }
}

if (process.env.DATA_DIR) {
  // Scrive un file nella directory dati: fallisce se l'immagine non rispetta
  // le linee guida OpenShift sugli UID arbitrari (gruppo 0 con permessi g=u).
  const probe = path.join(process.env.DATA_DIR, `.write-test-${process.pid}`);
  try {
    fs.writeFileSync(probe, 'ok');
    fs.unlinkSync(probe);
    console.log(`DATA_DIR ${process.env.DATA_DIR} scrivibile dall'utente ${process.getuid()}`);
  } catch (err) {
    console.error(`ERRORE: impossibile scrivere in DATA_DIR=${process.env.DATA_DIR} come uid=${process.getuid()} gid=${process.getgid()}: ${err.code}`);
    process.exit(1);
  }
}

// --- Funzioni di supporto ---------------------------------------------------

function sendJson(res, code, body) {
  res.writeHead(code, { 'Content-Type': 'application/json; charset=utf-8' });
  res.end(JSON.stringify(body, null, 2) + '\n');
}

function sendText(res, code, body) {
  res.writeHead(code, { 'Content-Type': 'text/plain; charset=utf-8' });
  res.end(body.endsWith('\n') ? body : body + '\n');
}

function uptimeSeconds() {
  return Math.floor((Date.now() - startedAt) / 1000);
}

function checkTcp(host, port, timeoutMs = 2000) {
  return new Promise((resolve) => {
    const socket = net.createConnection({ host, port });
    const done = (ok) => { socket.destroy(); resolve(ok); };
    socket.setTimeout(timeoutMs, () => done(false));
    socket.once('connect', () => done(true));
    socket.once('error', () => done(false));
  });
}

function mask(value) {
  return value ? `impostata (${value.length} caratteri)` : 'NON impostata';
}

// --- Router -----------------------------------------------------------------

async function handle(req, res) {
  const url = new URL(req.url, 'http://localhost');

  switch (url.pathname) {
    case '/':
      return sendJson(res, 200, {
        app: pkg.name,
        version: VERSION,
        message: MESSAGE,
        hostname: os.hostname(),
        uptimeSeconds: uptimeSeconds(),
      });

    case '/healthz':
      return healthy
        ? sendJson(res, 200, { status: 'ok' })
        : sendJson(res, 500, { status: 'unhealthy' });

    case '/ready':
      return uptimeSeconds() >= READY_DELAY
        ? sendJson(res, 200, { ready: true })
        : sendJson(res, 503, { ready: false, secondsLeft: READY_DELAY - uptimeSeconds() });

    case '/config':
      try {
        return sendText(res, 200, fs.readFileSync(CONFIG_FILE, 'utf8'));
      } catch (err) {
        return sendJson(res, 404, { error: `file di configurazione non trovato: ${CONFIG_FILE}` });
      }

    case '/env': {
      const appVars = Object.fromEntries(
        Object.entries(process.env).filter(([k]) => k.startsWith('APP_')).sort(),
      );
      return sendJson(res, 200, {
        ...appVars,
        API_KEY: mask(process.env.API_KEY),
        DB_PASSWORD: mask(process.env.DB_PASSWORD),
      });
    }

    case '/db': {
      const host = process.env.DB_HOST;
      const port = parseInt(process.env.DB_PORT || '5432', 10);
      if (!host) return sendJson(res, 503, { db: 'non configurato (DB_HOST mancante)' });
      const ok = await checkTcp(host, port);
      return sendJson(res, ok ? 200 : 503, {
        db: ok ? 'raggiungibile' : 'NON raggiungibile',
        host,
        port,
        name: process.env.DB_NAME || null,
        user: process.env.DB_USER || null,
      });
    }

    case '/toggle-health':
      healthy = !healthy;
      return sendJson(res, 200, { healthy });

    case '/build-info':
      try {
        return sendText(res, 200, fs.readFileSync(path.join(__dirname, 'build-info.txt'), 'utf8'));
      } catch (err) {
        return sendJson(res, 404, { error: 'build-info.txt non presente (nessuno script S2I personalizzato)' });
      }

    default:
      return sendJson(res, 404, { error: 'not found', path: url.pathname });
  }
}

function createServer() {
  return http.createServer((req, res) => {
    const t0 = Date.now();
    res.on('finish', () => {
      console.log(`${new Date().toISOString()} ${req.method} ${req.url} ${res.statusCode} ${Date.now() - t0}ms`);
    });
    handle(req, res).catch((err) => {
      console.error(err);
      sendJson(res, 500, { error: 'internal error' });
    });
  });
}

module.exports = { createServer };

if (require.main === module) {
  const server = createServer();
  server.listen(PORT, () => {
    console.log(`${pkg.name} v${VERSION} in ascolto sulla porta ${PORT} (uid=${process.getuid()}, gid=${process.getgid()})`);
  });
  // Arresto pulito: OpenShift invia SIGTERM prima di terminare il pod.
  process.on('SIGTERM', () => {
    console.log('SIGTERM ricevuto: chiudo il server');
    server.close(() => process.exit(0));
  });
}
