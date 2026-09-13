import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { once } from 'node:events';
import { WebSocket } from 'ws';
import { RelayRegistry } from '../src/registry.mjs';
import { createRelayServer } from '../src/server.mjs';
import { calculateProof, createPassHash } from '../src/auth.mjs';

export const pause = (ms = 30) => new Promise((resolve) => setTimeout(resolve, ms));
export async function fixture(t, options = {}) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'zcode-relay-test-'));
  const registry = new RelayRegistry({ directory, ...(options.registry || {}) });
  const server = createRelayServer({ registry, ...options.server });
  const address = await server.listen(); const baseURL = `ws://127.0.0.1:${address.port}${server.wsPath}`;
  t.after(async () => { await server.close(); registry.close(); fs.rmSync(directory, { recursive: true, force: true }); });
  return { directory, registry, server, address, baseURL };
}

export async function peer(url, options = {}) {
  const socket = new WebSocket(url, options); const messages = []; const all = []; const pending = [];
  socket.on('message', (raw) => {
    const value = { json: JSON.parse(raw.toString()), raw: raw.toString() };
    all.push(value);
    if (pending.length) pending.shift()(value); else messages.push(value);
  });
  // The explicit wait for open catches network failures; later close/error is inspected by tests.
  await once(socket, 'open');
  return { socket, all,
    send: (message) => socket.send(typeof message === 'string' ? message : JSON.stringify({ client_ts: Date.now(), ...message })),
    next: (timeout = 1_000) => new Promise((resolve, reject) => {
      if (messages.length) { resolve(messages.shift()); return; }
      const done = (message) => { clearTimeout(timer); resolve(message); };
      const timer = setTimeout(() => { const at = pending.indexOf(done); if (at >= 0) pending.splice(at, 1); reject(new Error('MESSAGE_TIMEOUT')); }, timeout);
      pending.push(done);
    }),
    async close() { if (socket.readyState === WebSocket.CLOSED) return; const closed = once(socket, 'close'); socket.close(); await closed; }
  };
}

export async function register(f, mid = 'synthetic-device', password = 'synthetic-password') {
  const permit = f.registry.issueEnrollment(mid); const passHash = createPassHash(password);
  const url = new URL(f.baseURL); url.searchParams.set('mid', mid); url.searchParams.set('enroll', permit.enrollmentToken);
  const device = await peer(url); device.send({ type: 'device_register_init', device_mid: mid, pass_hash: passHash });
  const ack = (await device.next()).json;
  if (ack.type !== 'device_register_ack') throw new Error(`REGISTRATION_FAILED_${ack.code}`);
  return { device, sid: ack.device_sid, passHash, mid, permit };
}

export async function authenticate(client, identity, role, proofTransform = (proof) => proof) {
  client.send({ type: 'auth_init', role, device_sid: identity.sid });
  const challenge = (await client.next()).json;
  if (challenge.type !== 'auth_challenge') return challenge;
  client.send({ type: 'auth_response', device_sid: identity.sid,
    proof: proofTransform(calculateProof(identity.passHash, challenge.nonce, role, identity.sid), challenge) });
  return (await client.next()).json;
}

export async function matchedPair(f, mid = 'synthetic-device') {
  const identity = await register(f, mid);
  await authenticate(identity.device, identity, 'device');
  const terminal = await peer(f.baseURL); await authenticate(terminal, identity, 'terminal');
  await identity.device.next();
  return { ...identity, terminal };
}
