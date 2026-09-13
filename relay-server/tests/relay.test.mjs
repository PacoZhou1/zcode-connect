import test from 'node:test';
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { calculateProof, createPassHash, MAX_FRAME_BYTES } from '../src/auth.mjs';
import { fixture, peer, register, authenticate, matchedPair, pause } from './helpers.mjs';

test('official register → challenge → waiting → terminal matched and heartbeat contract', async (t) => {
  const f = await fixture(t); const i = await register(f);
  assert.deepEqual(await authenticate(i.device, i, 'device'), { type: 'auth_ack', pair_status: 'waiting' });
  const terminal = await peer(f.baseURL);
  assert.deepEqual(await authenticate(terminal, i, 'terminal'), { type: 'auth_ack', pair_status: 'matched' });
  assert.equal((await i.device.next()).json.pair_status, 'matched');
  terminal.send({ type: 'pair_status_query', device_sid: i.sid });
  assert.equal((await terminal.next()).json.pair_status, 'matched');
  assert.equal(f.server.diagnostics().pairedDevices, 1);
});

test('unknown SID returns scope error before challenge and never registers anything', async (t) => {
  const f = await fixture(t); const client = await peer(f.baseURL);
  client.send({ type: 'auth_init', role: 'device', device_sid: 'synthetic-official-sid' });
  assert.equal((await client.next()).json.code, 'AUTH_SCOPE_MISMATCH');
  await pause(); assert.equal(client.all.length, 1);
  assert.equal(f.server.diagnostics().registered, 0);
});

test('new registrations require permit; ACK has SID only and never returns pass_hash', async (t) => {
  const f = await fixture(t); const denied = await peer(f.baseURL);
  denied.send({ type: 'device_register_init', device_mid: 'attacker-mid', pass_hash: createPassHash('attacker') });
  const error = (await denied.next()).json;
  assert.equal(error.code, 'REGISTRATION_DENIED'); assert.equal('device_sid' in error, false);
  const i = await register(f);
  assert.deepEqual(Object.keys(i.device.all[0].json).sort(), ['device_sid', 'type']);
  assert.ok(!JSON.stringify(i.device.all).includes(i.passHash));
});

test('same MID with different hash cannot replace SID even with old enrollment token', async (t) => {
  const f = await fixture(t); const i = await matchedPair(f);
  const bad = await peer(`${f.baseURL}?enroll=${i.permit.enrollmentToken}`);
  bad.send({ type: 'device_register_init', device_mid: i.mid, pass_hash: createPassHash('changed') });
  assert.equal((await bad.next()).json.code, 'REGISTRATION_DENIED');
  assert.equal(f.server.diagnostics().pairedDevices, 1);
});

test('HMAC proofs are bound to role, SID, and challenge; no unauthorized takeover', async (t) => {
  const f = await fixture(t); const i = await matchedPair(f);
  for (const transform of [
    (_, c) => calculateProof(i.passHash, c.nonce, 'device', i.sid),
    (_, c) => calculateProof(i.passHash, c.nonce, 'terminal', 'different-sid'),
    (_, c) => calculateProof(i.passHash, `${c.nonce}-changed`, 'terminal', i.sid),
    () => calculateProof('wrong-secret', 'wrong-nonce', 'terminal', i.sid)
  ]) {
    const bad = await peer(f.baseURL); assert.equal((await authenticate(bad, i, 'terminal', transform)).code, 'AUTH_FAILED');
  }
  assert.equal(f.server.diagnostics().kickedTerminals, 0); assert.equal(f.server.diagnostics().pairedDevices, 1);
});

test('challenge cannot be replayed across sockets or reused after successful authentication', async (t) => {
  const f = await fixture(t); const i = await register(f);
  const a = await peer(f.baseURL); const b = await peer(f.baseURL);
  a.send({ type: 'auth_init', role: 'terminal', device_sid: i.sid });
  b.send({ type: 'auth_init', role: 'terminal', device_sid: i.sid });
  const ca = (await a.next()).json; const cb = (await b.next()).json; assert.notEqual(ca.nonce, cb.nonce);
  const proof = calculateProof(i.passHash, ca.nonce, 'terminal', i.sid);
  b.send({ type: 'auth_response', device_sid: i.sid, proof }); assert.equal((await b.next()).json.code, 'AUTH_FAILED');
  a.send({ type: 'auth_response', device_sid: i.sid, proof }); assert.equal((await a.next()).json.type, 'auth_ack');
  a.send({ type: 'auth_response', device_sid: i.sid, proof }); assert.equal((await a.next()).json.code, 'AUTH_FAILED');
});

test('expired challenge fails with correct proof; fractional timestamps fail before challenge', async (t) => {
  let now = Date.now(); const f = await fixture(t, { server: { now: () => now, challengeTTL: 10 } });
  const i = await register(f); const a = await peer(f.baseURL);
  a.send({ type: 'auth_init', role: 'terminal', device_sid: i.sid }); const challenge = (await a.next()).json;
  now += 10;
  a.send({ type: 'auth_response', device_sid: i.sid, proof: calculateProof(i.passHash, challenge.nonce, 'terminal', i.sid) });
  assert.equal((await a.next()).json.code, 'AUTH_FAILED');
  const b = await peer(f.baseURL);
  b.send({ type: 'auth_init', role: 'terminal', device_sid: i.sid, client_ts: 1.5 });
  assert.equal((await b.next()).json.code, 'WRONG_PARAM');
});

test('only one terminal owns control; authenticated replacement KICKED precedes stale data', async (t) => {
  const f = await fixture(t); const i = await matchedPair(f);
  const replacement = await peer(f.baseURL);
  assert.equal((await authenticate(replacement, i, 'terminal')).pair_status, 'matched');
  assert.equal((await i.terminal.next()).json.code, 'KICKED');
  assert.equal((await i.device.next()).json.pair_status, 'matched');
  const staleCount = f.server.diagnostics().forwardedFrames;
  try { i.terminal.send({ type: 'data', payload: { marker: 'stale' } }); } catch {}
  await pause(); assert.equal(f.server.diagnostics().forwardedFrames, staleCount);
  replacement.send({ type: 'data', payload: { marker: 'current' } });
  assert.equal((await i.device.next()).json.payload.marker, 'current');
  assert.equal(f.server.diagnostics().kickedTerminals, 1);
});

test('second device cannot KICK the active desktop and start a reconnect fight', async (t) => {
  const f = await fixture(t); const i = await matchedPair(f);
  const second = await peer(f.baseURL);
  const occupied = await authenticate(second, i, 'device');
  assert.equal(occupied.code, 'INTERNAL'); assert.equal(occupied.message, 'DEVICE_IN_USE_RETRY');
  assert.equal(f.server.diagnostics().pairedDevices, 1);
  i.terminal.send({ type: 'data', payload: { live: true } }); assert.equal((await i.device.next()).json.payload.live, true);
});

test('opaque data bytes route within SID; payload cannot select another device or alter envelope', async (t) => {
  const f = await fixture(t); const a = await matchedPair(f, 'mid-a'); const b = await matchedPair(f, 'mid-b');
  const raw = `{ "type":"data", "payload":{"zcode_type":"rpc-frame","device_sid":"${b.sid}","seq":1,"marker":"中文"},"client_ts":123 }`;
  a.terminal.send(raw); assert.equal((await a.device.next()).raw, raw);
  await pause(); assert.equal(b.device.all.filter((m) => m.json.type === 'data').length, 0);
  a.device.send({ type: 'data', payload: { zcode_type: 'bootstrap-response', success: true } });
  assert.equal((await a.terminal.next()).json.payload.zcode_type, 'bootstrap-response');
  a.terminal.send({ type: 'data', device_sid: b.sid, payload: {} }); assert.equal((await a.terminal.next()).json.code, 'WRONG_PARAM');
});

test('unauthenticated data rejected; waiting data is not buffered into later terminal', async (t) => {
  const f = await fixture(t); const bad = await peer(f.baseURL);
  bad.send({ type: 'data', payload: { forbidden: true } }); assert.equal((await bad.next()).json.code, 'WRONG_PARAM');
  const i = await register(f); await authenticate(i.device, i, 'device');
  i.device.send({ type: 'data', payload: { old: true } }); assert.equal((await i.device.next()).json.pair_status, 'waiting');
  const terminal = await peer(f.baseURL); await authenticate(terminal, i, 'terminal'); await i.device.next();
  await pause(); assert.equal(terminal.all.filter((m) => m.json.type === 'data').length, 0);
});

test('disconnect detaches, waiting notification then same SID reconnect returns matched', async (t) => {
  const f = await fixture(t); const i = await matchedPair(f);
  await i.device.close(); assert.equal((await i.terminal.next()).json.pair_status, 'waiting');
  const reconnected = await peer(f.baseURL); assert.equal((await authenticate(reconnected, i, 'device')).pair_status, 'matched');
  assert.equal((await i.terminal.next()).json.pair_status, 'matched');
  assert.equal(f.server.diagnostics().pairedDevices, 1);
});

test('heartbeat SID substitution rejects only the offender and cannot poll another pair', async (t) => {
  const f = await fixture(t); const a = await matchedPair(f, 'a'); const b = await matchedPair(f, 'b');
  a.terminal.send({ type: 'pair_status_query', device_sid: b.sid });
  assert.equal((await a.terminal.next()).json.code, 'WRONG_PARAM');
  assert.equal((await a.device.next()).json.pair_status, 'waiting');
  assert.equal(f.server.diagnostics().pairedDevices, 1);
});

test('MID header/query identity and Origin checks do not replace proof authentication', async (t) => {
  const f = await fixture(t); const i = await register(f, 'real-mid');
  await assert.rejects(peer(f.baseURL, { origin: 'https://evil.invalid' }), /403/);
  await assert.rejects(peer(`${f.baseURL}?mid=a`, { headers: { 'X-Device-ID': 'b' } }), /400/);
  const client = await peer(`${f.baseURL}?mid=wrong-mid`);
  assert.equal((await authenticate(client, i, 'device')).code, 'AUTH_SCOPE_MISMATCH');
});

test('oversized and binary frames close the socket without data forwarding', async (t) => {
  const f = await fixture(t); const a = await peer(f.baseURL);
  const closed = once(a.socket, 'close'); a.socket.send('x'.repeat(MAX_FRAME_BYTES + 1));
  assert.equal((await closed)[0], 1009);
  const b = await peer(f.baseURL); b.socket.send(Buffer.from('{}'));
  assert.equal((await b.next()).json.code, 'WRONG_PARAM');
  assert.equal(f.server.diagnostics().forwardedFrames, 0);
});

test('handshake timeout and per-socket rate budget are bounded', async (t) => {
  const f = await fixture(t, { server: { unauthenticatedTTL: 20, sweepInterval: 5, messagesPerSecond: 1 } });
  const stalled = await peer(f.baseURL); assert.equal((await stalled.next()).json.code, 'TIMEOUT');
  const i = await register(f); // register + auth_init exhausts the two-message burst.
  i.device.send({ type: 'auth_init', role: 'device', device_sid: i.sid }); const c = (await i.device.next()).json;
  i.device.send({ type: 'auth_response', device_sid: i.sid, proof: calculateProof(i.passHash, c.nonce, 'device', i.sid) });
  assert.equal((await i.device.next()).json.code, 'RATE_LIMITED');
});

test('explicit re-enrollment rotates SID and disconnects old authenticated roles', async (t) => {
  const f = await fixture(t); const old = await matchedPair(f);
  const permit = f.registry.issueEnrollment(old.mid, 1000, { rotate: true });
  const replacement = await peer(`${f.baseURL}?enroll=${permit.enrollmentToken}`);
  const newHash = createPassHash('new-synthetic-password');
  replacement.send({ type: 'device_register_init', device_mid: old.mid, pass_hash: newHash });
  const ack = (await replacement.next()).json; assert.equal(ack.type, 'device_register_ack');
  assert.notEqual(ack.device_sid, old.sid);
  const oldDeviceError = (await old.device.next()).json;
  assert.equal(oldDeviceError.code, 'PAIRING_REVOKED');
  // Depending on detach order the other role first sees waiting, then definitive revocation.
  let terminalError = (await old.terminal.next()).json;
  if (terminalError.type === 'pair_status_ack') terminalError = (await old.terminal.next()).json;
  assert.equal(terminalError.code, 'PAIRING_REVOKED');
  const oldRetry = await peer(f.baseURL);
  assert.equal((await authenticate(oldRetry, old, 'terminal')).code, 'AUTH_SCOPE_MISMATCH');
});

test('health and pairing helper expose no registry, secrets, model endpoint or task service', async (t) => {
  const f = await fixture(t); await register(f);
  const base = `http://127.0.0.1:${f.address.port}`;
  const health = await fetch(`${base}/zcode/health`); assert.equal(health.status, 200);
  assert.deepEqual(await health.json(), { ok: true, service: 'zcode-private-relay', protocol: 1 });
  const helper = await fetch(`${base}/zcode/remote/v4?hash=DO_NOT_ECHO&sid=synthetic`);
  assert.equal(helper.headers.get('referrer-policy'), 'no-referrer');
  assert.ok(!(await helper.text()).includes('DO_NOT_ECHO'));
  assert.equal((await fetch(`${base}/zcode/registry`)).status, 404);
  assert.equal((await fetch(`${base}/v1/sessions`)).status, 404);
  await assert.rejects(f.server.listen({ host: '0.0.0.0' }), /LOOPBACK_BIND_REQUIRED/);
});
