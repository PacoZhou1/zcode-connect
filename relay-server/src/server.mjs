import http from 'node:http';
import https from 'node:https';
import fs from 'node:fs';
import { WebSocket, WebSocketServer } from 'ws';
import {
  calculateProof, equalSecret, isObject, MAX_FRAME_BYTES, token,
  validClientEnvelope, validID, validMeta, validPassHash
} from './auth.mjs';

export function normalizedOrigin(value) {
  const url = new URL(value);
  if (url.protocol !== 'https:' || url.username || url.password || url.search || url.hash
      || url.pathname !== '/') throw new Error('PUBLIC_ORIGIN_MUST_BE_HTTPS_ORIGIN');
  if (['zcode.z.ai', 'zcode.chatglm.site'].includes(url.hostname)) throw new Error('OFFICIAL_ORIGIN_NOT_SELF_HOSTED');
  return url.origin;
}

export function createRelayServer({ registry, publicOrigin = 'https://relay.invalid', prefix = '/zcode',
  tls, now = Date.now, challengeTTL = 15_000, unauthenticatedTTL = 20_000,
  idleTTL = 45_000, maxConnections = 64, maxBufferedBytes = 8 * 1024 * 1024,
  sweepInterval = 1_000, messagesPerSecond = 1_000, bytesPerSecond = 8 * 1024 * 1024 } = {}) {
  if (!registry) throw new Error('REGISTRY_REQUIRED');
  publicOrigin = normalizedOrigin(publicOrigin);
  if (!/^\/[a-zA-Z0-9_-]+(?:\/[a-zA-Z0-9_-]+)*$/.test(prefix)) throw new Error('INVALID_PREFIX');
  const wsPath = `${prefix}/ws`; const pairingPath = `${prefix}/remote/v4`;
  const wsURL = new URL(wsPath, publicOrigin); wsURL.protocol = 'wss:';
  const helperScript = fs.readFileSync(new URL('../web/pairing.js', import.meta.url), 'utf8');
  const peers = new Set(); const pairs = new Map(); let stopped = false;
  const counters = { acceptedSockets: 0, rejectedUpgrades: 0, registered: 0, authenticated: 0,
    forwardedFrames: 0, forwardedBytes: 0, kickedTerminals: 0, policyFailures: 0, timedOut: 0 };

  const handler = (request, response) => {
    // Never record the request URL: the desktop QR contains an access credential in its query.
    let url;
    try { url = new URL(request.url, publicOrigin); } catch { response.writeHead(400); response.end(); return; }
    const security = { 'Cache-Control': 'no-store', 'Referrer-Policy': 'no-referrer',
      'X-Content-Type-Options': 'nosniff', 'X-Frame-Options': 'DENY' };
    if (request.method !== 'GET') { response.writeHead(405, security); response.end(); return; }
    if (url.pathname === `${prefix}/health`) {
      response.writeHead(200, { ...security, 'Content-Type': 'application/json' });
      response.end(JSON.stringify({ ok: !stopped, service: 'zcode-private-relay', protocol: 1 })); return;
    }
    if (url.pathname === pairingPath || url.pathname === `${pairingPath}/`) {
      const scriptPath = `${prefix}/pairing.js`;
      response.writeHead(200, { ...security, 'Content-Type': 'text/html; charset=utf-8',
        'Content-Security-Policy': "default-src 'none'; script-src 'self'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'" });
      response.end(`<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>ZCode 专属中转配对</title><style>body{font:17px system-ui;max-width:48rem;margin:3rem auto;padding:1rem;line-height:1.6}textarea{width:100%;height:12rem}button{padding:.7rem 1rem}#payload{display:none}</style><body data-origin="${publicOrigin}" data-prefix="${prefix}"><h1>ZCode 专属中转配对</h1><p>连接原电脑上的 ZCode。中转服务器不创建或运行任务。</p><p id="status">正在检查配对地址。</p><section id="payload"><p>把以下专属连接信息复制到原生 App。它具有控制权限，请勿分享。</p><textarea readonly id="json" aria-label="专属 Relay 连接信息"></textarea><button id="copy">复制连接信息</button></section><script src="${scriptPath}"></script></body></html>`); return;
    }
    if (url.pathname === `${prefix}/pairing.js`) {
      response.writeHead(200, { ...security, 'Content-Type': 'text/javascript; charset=utf-8' });
      response.end(helperScript); return;
    }
    response.writeHead(404, security); response.end();
  };
  const server = tls ? https.createServer({ ...tls, minVersion: 'TLSv1.2' }, handler) : http.createServer(handler);
  server.requestTimeout = 10_000; server.headersTimeout = 10_000; server.keepAliveTimeout = 5_000;
  server.maxHeadersCount = 40;
  const wss = new WebSocketServer({ noServer: true, maxPayload: MAX_FRAME_BYTES,
    perMessageDeflate: false, clientTracking: false });

  const status = (pair) => pair?.device && pair?.terminal ? 'matched' : 'waiting';
  const owned = (peer) => peer.state === 'authenticated' && pairs.get(peer.sid)?.[peer.role] === peer;
  function send(peer, value) {
    if (peer.socket.readyState !== WebSocket.OPEN) return false;
    peer.socket.send(JSON.stringify(value), { binary: false }, (error) => { if (error) detach(peer); });
    return true;
  }
  function notify(pair) {
    if (!pair) return;
    for (const role of ['device', 'terminal']) if (pair[role]) {
      send(pair[role], { type: 'pair_status_ack', pair_status: status(pair) });
    }
  }
  function detach(peer) {
    if (peer.state === 'closed') return;
    peer.state = 'closed'; peer.challenge = undefined; peers.delete(peer);
    const pair = pairs.get(peer.sid);
    if (pair?.[peer.role] === peer) {
      pair[peer.role] = undefined;
      if (!pair.device && !pair.terminal) pairs.delete(peer.sid);
      else notify(pair);
    }
  }
  function fail(peer, code, closeCode = 1008, message = code) {
    if (peer.state === 'closed') return;
    counters.policyFailures++;
    detach(peer);
    send(peer, { type: 'error', code, message });
    peer.socket.close(closeCode, code);
    const timer = setTimeout(() => peer.socket.terminate(), 1_000); timer.unref();
  }
  function rejectUpgrade(socket, code = 403) {
    counters.rejectedUpgrades++;
    socket.end(`HTTP/1.1 ${code} Rejected\r\nConnection: close\r\nContent-Length: 0\r\n\r\n`);
  }

  server.on('upgrade', (request, socket, head) => {
    // Loopback binding is mandatory below. Reverse-proxy access still needs a valid protocol proof.
    let url;
    try { url = new URL(request.url, publicOrigin); } catch { rejectUpgrade(socket, 400); return; }
    if (stopped || peers.size >= maxConnections) { rejectUpgrade(socket, 503); return; }
    if (url.pathname !== wsPath) { rejectUpgrade(socket, 404); return; }
    if (request.headers.origin && request.headers.origin !== publicOrigin) { rejectUpgrade(socket); return; }
    if ([...url.searchParams.keys()].some((key) => !['mid', 'enroll'].includes(key))
      || url.searchParams.getAll('mid').length > 1 || url.searchParams.getAll('enroll').length > 1) {
      rejectUpgrade(socket, 400); return;
    }
    const mid = url.searchParams.get('mid') || undefined;
    const headerMid = request.headers['x-device-id'];
    const enrollmentToken = url.searchParams.get('enroll') || undefined;
    if ((mid && !validID(mid)) || (headerMid && (!validID(headerMid) || (mid && headerMid !== mid)))
      || (enrollmentToken && !/^[a-zA-Z0-9_-]{43}$/.test(enrollmentToken))) {
      rejectUpgrade(socket, 400); return;
    }
    wss.handleUpgrade(request, socket, head, (ws) => {
      const peer = { socket: ws, state: 'new', role: undefined, sid: undefined, mid: mid || headerMid,
        enrollmentToken, createdAt: now(), lastSeen: now(), rateAt: now(), messageBudget: messagesPerSecond * 2,
        byteBudget: bytesPerSecond * 2 };
      peers.add(peer); counters.acceptedSockets++;
      ws.on('message', (data, binary) => {
        if (peer.state === 'closed') return;
        const elapsed = Math.max(0, now() - peer.rateAt) / 1000; peer.rateAt = now();
        peer.messageBudget = Math.min(messagesPerSecond * 2, peer.messageBudget + elapsed * messagesPerSecond) - 1;
        peer.byteBudget = Math.min(bytesPerSecond * 2, peer.byteBudget + elapsed * bytesPerSecond) - data.byteLength;
        if (peer.messageBudget < 0 || peer.byteBudget < 0) { fail(peer, 'RATE_LIMITED'); return; }
        if (binary || data.byteLength > MAX_FRAME_BYTES) { fail(peer, 'WRONG_PARAM', 1009); return; }
        let value;
        try { value = JSON.parse(data.toString('utf8')); } catch { fail(peer, 'WRONG_PARAM'); return; }
        if (!isObject(value) || typeof value.type !== 'string') { fail(peer, 'WRONG_PARAM'); return; }
        try { handle(peer, value, data); }
        catch (error) { fail(peer, error?.code || 'INTERNAL'); }
      });
      ws.on('error', () => detach(peer)); ws.on('close', () => detach(peer));
    });
  });

  function handle(peer, message, raw) {
    switch (message.type) {
      case 'device_register_init': {
        if (peer.state !== 'new' || !validClientEnvelope(message,
          ['type', 'device_mid', 'pass_hash', 'meta', 'client_ts']) || !validID(message.device_mid)
          || !validPassHash(message.pass_hash) || !validMeta(message.meta)
          || (peer.mid && peer.mid !== message.device_mid)) { fail(peer, 'WRONG_PARAM'); return; }
        const { sid, replacedSID } = registry.register(message.device_mid, message.pass_hash, peer.enrollmentToken);
        if (replacedSID) {
          const previousPair = pairs.get(replacedSID);
          for (const role of ['device', 'terminal']) if (previousPair?.[role]) fail(previousPair[role], 'PAIRING_REVOKED');
        }
        peer.mid = message.device_mid; peer.sid = sid; peer.state = 'registered';
        peer.enrollmentToken = undefined; counters.registered++;
        send(peer, { type: 'device_register_ack', device_sid: sid }); return;
      }
      case 'auth_init': {
        if (!['new', 'registered'].includes(peer.state) || !validClientEnvelope(message,
          ['type', 'role', 'device_sid', 'meta', 'client_ts']) || !['device', 'terminal'].includes(message.role)
          || !validID(message.device_sid) || !validMeta(message.meta)
          || (peer.state === 'registered' && (message.role !== 'device' || message.device_sid !== peer.sid))) {
          fail(peer, 'WRONG_PARAM'); return;
        }
        const identity = registry.lookup(message.device_sid);
        // Critical migration gate: AUTH_FAILED makes the official desktop re-register its OLD
        // pass_hash. No challenge and this non-AUTH_FAILED code prevent that credential leakage.
        if (!identity) { fail(peer, 'AUTH_SCOPE_MISMATCH'); return; }
        if (peer.mid && peer.mid !== identity.mid) { fail(peer, 'AUTH_SCOPE_MISMATCH'); return; }
        peer.role = message.role; peer.sid = message.device_sid;
        peer.challenge = { nonce: token(), expiresAt: now() + challengeTTL };
        peer.state = 'challenged';
        send(peer, { type: 'auth_challenge', nonce: peer.challenge.nonce }); return;
      }
      case 'auth_response': {
        if (peer.state !== 'challenged' || !validClientEnvelope(message,
          ['type', 'device_sid', 'proof', 'client_ts']) || message.device_sid !== peer.sid
          || typeof message.proof !== 'string' || !/^[A-Za-z0-9_-]{43}$/.test(message.proof)) {
          fail(peer, 'AUTH_FAILED'); return;
        }
        const challenge = peer.challenge; peer.challenge = undefined;
        const identity = registry.lookup(peer.sid);
        if (!identity || challenge.expiresAt <= now()
          || !equalSecret(message.proof, calculateProof(identity.passHash, challenge.nonce, peer.role, peer.sid))) {
          fail(peer, 'AUTH_FAILED'); return;
        }
        const pair = pairs.get(peer.sid) || {};
        if (peer.role === 'device' && pair.device) {
          // A half-open previous socket can retain the lease after the desktop reconnects.
          // INTERNAL is the installed transport's recoverable branch. Never kick the old
          // device; give its idle lease time to expire, then stop competing if it stays live.
          if (pair.lastContenderAt === undefined || now() - pair.lastContenderAt >= idleTTL) pair.contenderStartedAt = now();
          pair.lastContenderAt = now();
          if (now() - pair.contenderStartedAt < idleTTL * 2) fail(peer, 'INTERNAL', 1008, 'DEVICE_IN_USE_RETRY');
          else fail(peer, 'DEVICE_IN_USE');
          return;
        }
        const previous = pair[peer.role];
        pair[peer.role] = peer; pairs.set(peer.sid, pair);
        if (peer.role === 'device') { pair.contenderStartedAt = undefined; pair.lastContenderAt = undefined; }
        peer.state = 'authenticated'; peer.lastSeen = now(); peer.enrollmentToken = undefined;
        if (previous) { counters.kickedTerminals++; fail(previous, 'KICKED'); }
        counters.authenticated++;
        send(peer, { type: 'auth_ack', pair_status: status(pair) });
        const other = pair[peer.role === 'device' ? 'terminal' : 'device'];
        if (other) send(other, { type: 'pair_status_ack', pair_status: status(pair) });
        return;
      }
      case 'pair_status_query': {
        if (!owned(peer) || !validClientEnvelope(message, ['type', 'device_sid', 'client_ts'])
          || message.device_sid !== peer.sid) { fail(peer, 'WRONG_PARAM'); return; }
        peer.lastSeen = now();
        send(peer, { type: 'pair_status_ack', pair_status: status(pairs.get(peer.sid)) }); return;
      }
      case 'data': {
        if (!owned(peer) || !validClientEnvelope(message, ['type', 'payload', 'client_ts'])
          || !isObject(message.payload)) { fail(peer, 'WRONG_PARAM'); return; }
        const pair = pairs.get(peer.sid); const other = pair?.[peer.role === 'device' ? 'terminal' : 'device'];
        peer.lastSeen = now();
        if (!other || !owned(other)) {
          // Never buffer application data while unpaired or replay a mutation on a later peer.
          send(peer, { type: 'pair_status_ack', pair_status: 'waiting' }); return;
        }
        if (other.socket.readyState !== WebSocket.OPEN || other.socket.bufferedAmount + raw.byteLength > maxBufferedBytes) {
          fail(other, 'SLOW_PEER'); return;
        }
        // Preserve the outer JSON bytes exactly. RPC framing, IDs, replay and ACKs remain end-to-end.
        other.socket.send(raw, { binary: false }, (error) => { if (error) detach(other); });
        counters.forwardedFrames++; counters.forwardedBytes += raw.byteLength; return;
      }
      default: fail(peer, 'WRONG_PARAM');
    }
  }

  const sweep = setInterval(() => {
    for (const peer of peers) {
      if ((peer.state === 'authenticated' && now() - peer.lastSeen >= idleTTL)
        || (peer.state !== 'authenticated' && now() - peer.createdAt >= unauthenticatedTTL)) {
        counters.timedOut++; fail(peer, 'TIMEOUT');
      }
    }
  }, sweepInterval); sweep.unref();

  return {
    wsPath, pairingPath, publicOrigin, relayURL: wsURL.href,
    diagnostics: () => ({ ...counters, connections: peers.size, pairedDevices: [...pairs.values()].filter((p) => status(p) === 'matched').length }),
    async listen({ host = '127.0.0.1', port = 0 } = {}) {
      if (!['127.0.0.1', '::1'].includes(host)) throw new Error('LOOPBACK_BIND_REQUIRED');
      if (!Number.isInteger(port) || port < 0 || port > 65535) throw new Error('INVALID_PORT');
      await new Promise((resolve, reject) => { server.once('error', reject); server.listen(port, host, resolve); });
      const address = server.address(); return { host, port: address.port, protocol: tls ? 'https' : 'http' };
    },
    async close() {
      if (stopped) return;
      stopped = true; clearInterval(sweep);
      for (const peer of [...peers]) { detach(peer); peer.socket.terminate(); }
      await new Promise((resolve) => wss.close(resolve));
      server.closeAllConnections();
      await new Promise((resolve) => server.close(resolve));
    }
  };
}
