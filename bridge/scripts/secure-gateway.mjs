import { dirname, resolve, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { readFileSync } from 'node:fs';
import { networkCandidates, validateGatewayHost, prepareTLSIdentity, readTLSIdentity, createSecureGateway } from '../src/secure-gateway.mjs';
import { acquireRuntimeLock } from '../src/runtime-lock.mjs';
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..'), runtimeDir = process.env.ZCODE_MOBILE_RUNTIME_DIR || join(root, '.runtime');
const args = process.argv.slice(2), value = name => args[args.indexOf(name) + 1];
const mode = ['--plan', '--prepare', '--pair', '--serve'].filter(flag => args.includes(flag));
if (mode.length > 1 || args.some(arg => arg.startsWith('--') && !['--plan', '--prepare', '--pair', '--serve', '--host', '--port'].includes(arg))) throw new Error('Use one of --plan, --prepare, --pair, or --serve, plus --host and optional --port.');
const host = args.includes('--host') ? validateGatewayHost(value('--host')) : undefined, port = args.includes('--port') ? Number(value('--port')) : 18790;
if (!Number.isInteger(port) || port < 1024 || port > 65535 || port === 18789) throw new Error('Use an unused HTTPS port from 1024 to 65535, separate from 18789.');
const plan = { candidates: networkCandidates(), host, port, listening: false, next: 'Select a reachable private address, run --prepare, review the certificate fingerprint, then explicitly run --serve and pair the phone.' };
if (!mode.length || mode[0] === '--plan') console.log(JSON.stringify(plan, null, 2));
else {
  if (!host) throw new Error('An explicit --host private address is required.');
  if (mode[0] === '--prepare') console.log(JSON.stringify({ ...plan, ...prepareTLSIdentity(runtimeDir, host), prepared: true }, null, 2));
  else {
    const identity = readTLSIdentity(runtimeDir, host), token = readFileSync(join(runtimeDir, 'pairing-token'), 'utf8').trim();
    if (mode[0] === '--pair') {
      if (!process.stdout.isTTY) throw new Error('Pairing credentials are displayed only in an interactive local terminal.');
      console.log(JSON.stringify({ version: 1, url: `https://${host}:${port}`, token, certificateSHA256: identity.certificateSHA256 }));
    } else {
      const release = acquireRuntimeLock(identity.root), server = createSecureGateway({ identity, token });
      server.once('error', error => { release(); console.error(error.code || 'https_start_failed'); process.exitCode = 1; });
      server.listen(port, host, () => console.log(JSON.stringify({ event: 'https_listening', url: `https://${host}:${port}`, certificateSHA256: identity.certificateSHA256, expiresAt: identity.expiresAt })));
      const close = () => { server.closeAllConnections(); server.close(() => { release(); process.exit(0); }); };
      process.once('SIGINT', close); process.once('SIGTERM', close);
    }
  }
}
