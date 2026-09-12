import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createServer } from 'node:http';
import { request } from 'node:https';
import { checkServerIdentity } from 'node:tls';
import { createSecureGateway, isPrivateIPv4, networkCandidates, validateGatewayHost, prepareTLSIdentity, readTLSIdentity } from '../src/secure-gateway.mjs';
import { hash } from '../src/util.mjs';

test('secure route accepts explicit assigned private addresses only', () => {
  for (const address of ['0.0.0.0', '8.8.8.8', '172.15.1.2', '172.32.1.2', '100.63.1.2', 'hostname.local', '::']) assert.equal(isPrivateIPv4(address), false);
  for (const address of ['10.0.0.1', '172.20.10.7', '192.168.1.2', '100.64.0.1', '127.0.0.1']) assert.equal(isPrivateIPv4(address), true);
  const interfaces = { en0: [{ family: 'IPv4', address: '172.20.10.7', internal: false }], lo0: [{ family: 'IPv4', address: '127.0.0.1', internal: true }] };
  assert.equal(networkCandidates(interfaces).length, 1); assert.equal(validateGatewayHost('172.20.10.7', interfaces), '172.20.10.7');
  assert.throws(() => validateGatewayHost('192.168.1.2', interfaces), /not assigned/);
});

test('HTTPS gateway validates TLS identity and bearer auth before forwarding', async t => {
  const root = mkdtempSync(join(tmpdir(), 'zcode-tls-test-')); t.after(() => rmSync(root, { recursive: true, force: true }));
  const prepared = prepareTLSIdentity(root, '127.0.0.1'), identity = readTLSIdentity(root, '127.0.0.1'); assert.equal(prepared.certificateSHA256, identity.certificateSHA256);
  const upstream = createServer((request, response) => { response.writeHead(200, { 'Content-Type': 'application/json' }); response.end(JSON.stringify({ path: request.url, authorizationPresent: !!request.headers.authorization })); });
  await new Promise(resolve => upstream.listen(0, '127.0.0.1', resolve));
  const gateway = createSecureGateway({ identity, token: 'test-only-token', upstreamPort: upstream.address().port }); await new Promise(resolve => gateway.listen(0, '127.0.0.1', resolve));
  t.after(() => { gateway.closeAllConnections(); gateway.close(); upstream.closeAllConnections(); upstream.close(); });
  const get = (headers = {}, fingerprint = identity.certificateSHA256) => new Promise((resolve, reject) => {
    const r = request({ host: '127.0.0.1', port: gateway.address().port, path: '/v1/status', ca: identity.cert, agent: false, headers,
      checkServerIdentity: (host, certificate) => checkServerIdentity(host, certificate) || (hash(certificate.raw) === fingerprint ? undefined : new Error('Certificate pin mismatch')) }, response => { let text = ''; response.setEncoding('utf8'); response.on('data', chunk => text += chunk); response.on('end', () => resolve({ status: response.statusCode, data: JSON.parse(text) })); }); r.on('error', reject); r.end();
  });
  assert.equal((await get()).status, 401); assert.equal((await get({ Authorization: 'Bearer wrong' })).status, 401);
  const ok = await get({ Authorization: 'Bearer test-only-token' }); assert.equal(ok.status, 200); assert.equal(ok.data.authorizationPresent, true);
  assert.equal((await get({ Authorization: 'Bearer test-only-token', Origin: 'https://untrusted.invalid' })).status, 403);
  await assert.rejects(get({ Authorization: 'Bearer test-only-token' }, '0'.repeat(64)), /Certificate pin mismatch/);
});
