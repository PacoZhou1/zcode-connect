// Bounded loopback-only fixture for the real iOS URLSession delegate. No ZCode RPCs.
import assert from 'node:assert/strict';
import { createServer, request } from 'node:https';
import { checkServerIdentity } from 'node:tls';
import { randomBytes, X509Certificate } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync, chmodSync, realpathSync, rmSync } from 'node:fs';
import { dirname, join, resolve, relative } from 'node:path';
import { fileURLToPath } from 'node:url';
import { authorized, hash } from '../src/util.mjs';
import { prepareTLSIdentity, readTLSIdentity } from '../src/secure-gateway.mjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..'), fixtureRoot = join(root, '.runtime/native-tls-fixtures');
const args = process.argv.slice(2), action = args[0] ?? '--serve';
const save = (path, value) => writeFileSync(path, JSON.stringify(value, null, 2) + '\n', { mode: 0o600 });
function checkedDirectory(path) {
  if (!path) throw new Error('Pass the fixture directory printed at startup.');
  const directory = realpathSync(resolve(path)), base = realpathSync(fixtureRoot), rel = relative(base, directory);
  if (!rel.startsWith('fixture-') || rel.includes('/') || rel.includes('\\') || rel === '..') throw new Error('Only this script’s private fixture directories are accepted.');
  const manifest = JSON.parse(readFileSync(join(directory, 'manifest.json')));
  if (manifest.kind !== 'zcode-native-tls-fixture') throw new Error('Unknown fixture identity.');
  return { directory, manifest, config: JSON.parse(readFileSync(join(directory, 'tls-acceptance.json'))) };
}
async function call(config, directory, path, { wrongHostname = false, wrongPin = false, method = 'GET' } = {}) {
  const url = new URL(path, wrongHostname ? config.wrongHostnameBaseURL : config.baseURL);
  const cert = readFileSync(join(directory, wrongHostname ? 'wrong-host-certificate.pem' : 'tls/127.0.0.1/certificate.pem'));
  const pin = wrongPin ? config.wrongPin : wrongHostname ? config.wrongHostnameCertificateSHA256 : config.certificateSHA256;
  return new Promise((resolve, reject) => {
    const req = request(url, { method, ca: cert, agent: false, headers: { Authorization: 'Bearer ' + config.token },
      checkServerIdentity: (host, leaf) => checkServerIdentity(host, leaf) || (hash(leaf.raw) === pin ? undefined : new Error('fixture_pin_mismatch')) }, response => {
      const chunks = []; response.on('data', data => chunks.push(data)); response.on('end', () => resolve({ status: response.statusCode, headers: response.headers, body: Buffer.concat(chunks).toString(), tlsVersion: response.socket?.getProtocol() }));
    });
    req.on('error', reject); req.setTimeout(5000, () => req.destroy(new Error('Fixture request timeout'))); req.end();
  });
}
if (action !== '--serve') {
  if (!['--check', '--stop', '--cleanup'].includes(action) || args.length !== 2) throw new Error('Use --serve, --check <directory>, --stop <directory>, or --cleanup <directory>.');
  const { directory, manifest, config } = checkedDirectory(args[1]);
  if (action === '--check') {
    assert.equal((await call(config, directory, '/health')).body, '{"ok":true}');
    assert.match((await call(config, directory, '/v1/events')).body, /event: ready\ndata:/);
    await assert.rejects(call(config, directory, '/health', { wrongPin: true }), /fixture_pin_mismatch/);
    await assert.rejects(call(config, directory, '/health', { wrongHostname: true }), error => error.code === 'ERR_TLS_CERT_ALTNAME_INVALID');
    const before = JSON.parse((await call(config, directory, '/fixture/counters')).body);
    const redirect = await call(config, directory, '/redirect'); assert.equal(redirect.status, 302);
    const after = JSON.parse((await call(config, directory, '/fixture/counters')).body);
    assert.equal(after.redirectRequests, before.redirectRequests + 1); assert.equal(after.redirectTargetRequests, before.redirectTargetRequests);
    const output = { verifiedAt: new Date().toISOString(), passed: true, nativeIOSVerified: false, source: 'Node fixture self-check only', checks: ['pinned_health', 'sse', 'wrong_pin_rejected', 'correct_pin_wrong_hostname_rejected', 'redirect_target_not_requested'], counters: after };
    save(join(directory, 'self-check.json'), output); console.log(JSON.stringify(output));
  } else if (action === '--stop') {
    if (!manifest.stoppedAt) await call(config, directory, '/fixture/stop', { method: 'POST' });
    console.log(JSON.stringify({ stopped: true, directory }));
  } else {
    if (!manifest.stoppedAt) {
      let alive = true;
      try { process.kill(manifest.pid, 0); } catch (error) { if (error.code === 'ESRCH') alive = false; else throw error; }
      if (alive) throw new Error('Stop the fixture first and preserve its sanitized evidence before cleanup.');
    }
    rmSync(directory, { recursive: true }); console.log(JSON.stringify({ removedPrivateFixture: directory }));
  }
} else {
  if (args.length > 1) throw new Error('This fixture has no host/port override; it only uses ephemeral 127.0.0.1 listeners.');
  mkdirSync(fixtureRoot, { recursive: true, mode: 0o700 });
  const directory = mkdtempSync(join(fixtureRoot, 'fixture-')); chmodSync(directory, 0o700);
  prepareTLSIdentity(directory, '127.0.0.1'); const identity = readTLSIdentity(directory, '127.0.0.1');
  const wrongConfig = join(directory, 'wrong-host-openssl.cnf'), wrongKey = join(directory, 'wrong-host-key.pem'), wrongCert = join(directory, 'wrong-host-certificate.pem');
  writeFileSync(wrongConfig, '[req]\ndistinguished_name=dn\nx509_extensions=extensions\nprompt=no\n[dn]\nCN=wrong-host.invalid\n[extensions]\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:wrong-host.invalid\n', { mode: 0o600 });
  execFileSync('/usr/bin/openssl', ['req', '-x509', '-newkey', 'rsa:3072', '-nodes', '-sha256', '-days', '2', '-keyout', wrongKey, '-out', wrongCert, '-config', wrongConfig], { stdio: 'pipe', timeout: 30000 });
  chmodSync(wrongKey, 0o600); chmodSync(wrongCert, 0o600);
  const token = randomBytes(32).toString('base64url'), counters = { healthRequests: 0, eventRequests: 0, redirectRequests: 0, redirectTargetRequests: 0, wrongHostnameHTTPRequests: 0, unauthorizedRequests: 0, tlsClientErrors: 0 };
  const manifest = { kind: 'zcode-native-tls-fixture', pid: process.pid, startedAt: new Date().toISOString(), expiresAt: new Date(Date.now() + 30 * 60_000).toISOString(), loopbackOnly: true, realZCodeConnected: false };
  let stopping = false, deadline;
  const servers = [];
  const persistCounters = () => save(join(directory, 'counters.json'), counters);
  const stop = async () => {
    if (stopping) return; stopping = true; clearTimeout(deadline);
    await Promise.all(servers.map(server => new Promise(resolve => { server.close(resolve); server.closeAllConnections(); })));
    manifest.stoppedAt = new Date().toISOString(); save(join(directory, 'manifest.json'), manifest); persistCounters();
    console.log(JSON.stringify({ event: 'fixture_stopped', pid: process.pid, directory, counters }));
  };
  const handler = wrongHostname => (req, res) => {
    const url = new URL(req.url, 'https://127.0.0.1');
    const json = (status, body) => { res.writeHead(status, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' }); res.end(JSON.stringify(body)); };
    if (req.headers.origin || !authorized(req.headers.authorization, token)) { counters.unauthorizedRequests++; persistCounters(); return json(401, { error: { code: 'unauthorized', message: 'Fixture token required.' } }); }
    if (wrongHostname) counters.wrongHostnameHTTPRequests++;
    if (req.method === 'POST' && url.pathname === '/fixture/stop') { json(200, { stopping: true }); res.once('finish', () => void stop()); return; }
    if (req.method !== 'GET') return json(405, { error: { code: 'method_not_allowed', message: 'Fixture supports read-only acceptance.' } });
    if (url.pathname === '/health') { counters.healthRequests++; if (url.searchParams.get('via') === 'redirect') counters.redirectTargetRequests++; persistCounters(); return json(200, { ok: true }); }
    if (url.pathname === '/v1/status') return json(200, { hostName: 'Loopback TLS acceptance fixture', connectionStatus: 'connected', zcodeVersion: 'fixture', limitations: ['No real ZCode runtime is connected.'] });
    if (['/events', '/v1/events'].includes(url.pathname)) {
      counters.eventRequests++; persistCounters();
      res.writeHead(200, { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-store' });
      res.end('id: tls-fixture-1\nevent: ready\ndata: ' + JSON.stringify({ id: 'tls-fixture-1', type: 'ready', timestamp: new Date().toISOString(), data: { connectionStatus: 'connected' } }) + '\n\n'); return;
    }
    if (url.pathname === '/redirect') { counters.redirectRequests++; persistCounters(); res.writeHead(302, { Location: '/health?via=redirect', 'Cache-Control': 'no-store' }); res.end(); return; }
    if (url.pathname === '/fixture/counters') return json(200, counters);
    return json(404, { error: { code: 'not_found', message: 'Fixture endpoint unavailable.' } });
  };
  for (const [cert, key, wrong] of [[identity.cert, identity.key, false], [readFileSync(wrongCert), readFileSync(wrongKey), true]]) {
    const server = createServer({ cert, key, minVersion: 'TLSv1.2', maxHeaderSize: 16384 }, handler(wrong)); servers.push(server);
    server.on('tlsClientError', () => { counters.tlsClientErrors++; persistCounters(); });
    await new Promise((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolve); });
  }
  const config = { baseURL: 'https://127.0.0.1:' + servers[0].address().port, token, certificateSHA256: identity.certificateSHA256,
    wrongPin: (identity.certificateSHA256[0] === '0' ? '1' : '0') + identity.certificateSHA256.slice(1),
    wrongHostnameBaseURL: 'https://127.0.0.1:' + servers[1].address().port, wrongHostnameCertificateSHA256: hash(new X509Certificate(readFileSync(wrongCert)).raw),
    healthPath: 'health', eventsPath: 'v1/events', redirectPath: 'redirect', countersPath: 'fixture/counters' };
  save(join(directory, 'tls-acceptance.json'), config); save(join(directory, 'manifest.json'), manifest); persistCounters();
  deadline = setTimeout(() => void stop(), 30 * 60_000);
  process.once('SIGINT', () => void stop()); process.once('SIGTERM', () => void stop());
  console.log(JSON.stringify({ event: 'fixture_ready', pid: process.pid, directory, configPath: join(directory, 'tls-acceptance.json'), baseURL: config.baseURL, wrongHostnameBaseURL: config.wrongHostnameBaseURL, expiresAt: manifest.expiresAt, realZCodeConnected: false }));
}
