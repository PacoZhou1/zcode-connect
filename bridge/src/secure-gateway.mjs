import { createServer as createHTTPSServer } from 'node:https';
import { request as httpRequest } from 'node:http';
import { networkInterfaces } from 'node:os';
import { isIP } from 'node:net';
import { X509Certificate } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { chmodSync, existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { authorized, hash } from './util.mjs';

export function isPrivateIPv4(address) {
  if (isIP(address) !== 4) return false;
  const [a, b] = address.split('.').map(Number);
  return a === 10 || a === 172 && b >= 16 && b <= 31 || a === 192 && b === 168 || a === 100 && b >= 64 && b <= 127 || a === 127;
}
export function networkCandidates(interfaces = networkInterfaces()) {
  return Object.entries(interfaces).flatMap(([name, entries]) => (entries ?? []).filter(entry => entry.family === 'IPv4' && !entry.internal && isPrivateIPv4(entry.address)).map(entry => ({ interface: name, address: entry.address, kind: entry.address.startsWith('100.') ? 'private-overlay' : 'private-network' })));
}
export function validateGatewayHost(host, interfaces = networkInterfaces()) {
  if (!isPrivateIPv4(host)) throw new Error('Select one explicit private IPv4 address; wildcard, public, and DNS bindings are disabled.');
  if (host !== '127.0.0.1' && !networkCandidates(interfaces).some(candidate => candidate.address === host)) throw new Error('The selected private address is not assigned to this Mac.');
  return host;
}
export function tlsPaths(runtimeDir, host) {
  validateGatewayHost(host);
  const root = join(runtimeDir, 'tls', host); return { root, cert: join(root, 'certificate.pem'), key: join(root, 'private-key.pem') };
}
export function readTLSIdentity(runtimeDir, host) {
  const paths = tlsPaths(runtimeDir, host);
  if (!existsSync(paths.cert) || !existsSync(paths.key)) throw new Error('Prepare this HTTPS identity before starting the gateway.');
  const cert = readFileSync(paths.cert), key = readFileSync(paths.key), certificate = new X509Certificate(cert);
  if (new Date(certificate.validTo).getTime() <= Date.now()) throw new Error('The HTTPS certificate has expired. Prepare a new identity and pair again.');
  if (!certificate.checkIP(host)) throw new Error('The certificate does not match the selected private address.');
  return { ...paths, cert, key, certificateSHA256: hash(certificate.raw), expiresAt: new Date(certificate.validTo).toISOString() };
}
export function prepareTLSIdentity(runtimeDir, host) {
  const paths = tlsPaths(runtimeDir, host);
  if (existsSync(paths.cert) && existsSync(paths.key)) { const identity = readTLSIdentity(runtimeDir, host); return { certificateSHA256: identity.certificateSHA256, expiresAt: identity.expiresAt }; }
  if (existsSync(paths.cert) || existsSync(paths.key)) throw new Error('An incomplete HTTPS identity exists. Review it before replacing either file.');
  mkdirSync(paths.root, { recursive: true, mode: 0o700 });
  const configPath = join(paths.root, 'openssl.cnf');
  writeFileSync(configPath, `[req]\ndistinguished_name=dn\nx509_extensions=extensions\nprompt=no\n[dn]\nCN=ZCode Mobile Bridge\n[extensions]\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=IP:${host}\n`, { mode: 0o600 });
  execFileSync('/usr/bin/openssl', ['req', '-x509', '-newkey', 'rsa:3072', '-nodes', '-sha256', '-days', '30', '-keyout', paths.key, '-out', paths.cert, '-config', configPath], { stdio: 'pipe', timeout: 30000 });
  chmodSync(paths.key, 0o600); chmodSync(paths.cert, 0o600);
  const identity = readTLSIdentity(runtimeDir, host); return { certificateSHA256: identity.certificateSHA256, expiresAt: identity.expiresAt };
}
const hopHeaders = new Set(['connection', 'keep-alive', 'proxy-authenticate', 'proxy-authorization', 'te', 'trailer', 'transfer-encoding', 'upgrade']);
const headersForProxy = headers => Object.fromEntries(Object.entries(headers).filter(([name]) => !hopHeaders.has(name.toLowerCase())));
export function createSecureGateway({ identity, token, upstreamPort = 18789 }) {
  if (!Number.isInteger(upstreamPort) || upstreamPort < 1 || upstreamPort > 65535) throw new Error('Invalid local bridge port.');
  const server = createHTTPSServer({ key: identity.key, cert: identity.cert, minVersion: 'TLSv1.2', maxHeaderSize: 16384 }, (request, response) => {
    const fail = (status, code, message) => { response.writeHead(status, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' }); response.end(JSON.stringify({ error: { code, message, retryable: status >= 500 } })); };
    if (request.headers.origin) return fail(403, 'origin_not_allowed', 'Browser origins are not enabled.');
    if (!authorized(request.headers.authorization, token)) return fail(401, 'unauthorized', 'A valid pairing token is required.');
    if (!request.url.startsWith('/v1/') && request.url !== '/health') return fail(404, 'not_found', 'Endpoint not found.');
    const outgoing = httpRequest({ host: '127.0.0.1', port: upstreamPort, path: request.url, method: request.method, headers: { ...headersForProxy(request.headers), host: `127.0.0.1:${upstreamPort}` } }, incoming => {
      response.writeHead(incoming.statusCode ?? 502, headersForProxy(incoming.headers)); incoming.pipe(response);
      response.on('close', () => incoming.destroy());
    });
    outgoing.on('error', () => { if (!response.headersSent) fail(503, 'bridge_unavailable', 'The local bridge is not running.'); else response.destroy(); });
    request.on('aborted', () => outgoing.destroy()); response.on('close', () => outgoing.destroy()); request.pipe(outgoing);
  });
  server.maxHeadersCount = 64;
  return server;
}
