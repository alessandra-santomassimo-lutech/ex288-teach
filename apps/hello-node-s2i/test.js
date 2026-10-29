// Test minimale usato dalla build hook (postCommit) nel modulo 05.
// Avvia il server su una porta locale, interroga / e /healthz e termina
// con exit code 0 (successo) o 1 (fallimento).
// Imposta FAIL_TESTS=true per simulare un test fallito.

'use strict';

const http = require('http');
const { createServer } = require('./server');

const PORT = 18080;

function get(path) {
  return new Promise((resolve, reject) => {
    http.get({ host: '127.0.0.1', port: PORT, path }, (res) => {
      let body = '';
      res.on('data', (c) => { body += c; });
      res.on('end', () => resolve({ status: res.statusCode, body }));
    }).on('error', reject);
  });
}

async function main() {
  if (process.env.FAIL_TESTS === 'true') {
    throw new Error('FAIL_TESTS=true: fallimento simulato');
  }
  const server = createServer().listen(PORT);
  try {
    const root = await get('/');
    if (root.status !== 200) throw new Error(`GET / ha risposto ${root.status}`);
    const health = await get('/healthz');
    if (health.status !== 200) throw new Error(`GET /healthz ha risposto ${health.status}`);
    console.log('TEST OK: / e /healthz rispondono 200');
  } finally {
    server.close();
  }
}

main().then(
  () => process.exit(0),
  (err) => { console.error(`TEST FALLITO: ${err.message}`); process.exit(1); },
);
