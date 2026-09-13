import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import tls from 'node:tls';
import { createHash, X509Certificate } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { fixture, peer, authenticate } from './helpers.mjs';
import { createPassHash } from '../src/auth.mjs';

test('actual loopback WSS preserves system TLS hostname checks and rejects wrong pin before upgrade', async (t) => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'zcode-relay-tls-'));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const config = path.join(directory, 'openssl.cnf'); const keyFile = path.join(directory, 'key.pem'); const certFile = path.join(directory, 'cert.pem');
  fs.writeFileSync(config, '[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n[dn]\nCN=localhost\n[ext]\nsubjectAltName=DNS:localhost,IP:127.0.0.1\nbasicConstraints=critical,CA:TRUE\nkeyUsage=critical,digitalSignature,keyEncipherment,keyCertSign\nextendedKeyUsage=serverAuth\n', { mode: 0o600 });
  execFileSync('/usr/bin/openssl', ['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1', '-config', config, '-keyout', keyFile, '-out', certFile], { stdio: 'ignore' });
  fs.chmodSync(keyFile, 0o600); fs.chmodSync(certFile, 0o600);
  const cert = fs.readFileSync(certFile); const key = fs.readFileSync(keyFile);
  const fingerprint = createHash('sha256').update(new X509Certificate(cert).raw).digest('hex');
  const f = await fixture(t, { server: { tls: { cert, key } } });
  const permit = f.registry.issueEnrollment('tls-device'); const passHash = createPassHash('synthetic-tls');
  const { sid } = f.registry.register('tls-device', passHash, permit.enrollmentToken);
  const url = f.baseURL.replace('ws:', 'wss:');
  const pinned = (expectedPin, hostname) => ({ ca: cert, rejectUnauthorized: true,
    checkServerIdentity: (host, certificate) => {
      const failure = tls.checkServerIdentity(hostname || host, certificate); if (failure) return failure;
      const actual = createHash('sha256').update(certificate.raw).digest('hex');
      if (actual !== expectedPin) return Object.assign(new Error('CERT_PIN_MISMATCH'), { code: 'CERT_PIN_MISMATCH' });
    } });
  const good = await peer(url, pinned(fingerprint));
  assert.equal(good.socket._socket.getProtocol(), 'TLSv1.3');
  assert.equal((await authenticate(good, { sid, passHash }, 'terminal')).pair_status, 'waiting');
  const count = f.server.diagnostics().acceptedSockets;
  await assert.rejects(peer(url, pinned('0'.repeat(64))), { code: 'CERT_PIN_MISMATCH' });
  await assert.rejects(peer(url, pinned(fingerprint, 'wrong-host.invalid')), { code: 'ERR_TLS_CERT_ALTNAME_INVALID' });
  await assert.rejects(peer(url), (error) => ['DEPTH_ZERO_SELF_SIGNED_CERT', 'SELF_SIGNED_CERT_IN_CHAIN'].includes(error.code));
  assert.equal(f.server.diagnostics().acceptedSockets, count);
});
