import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import vm from 'node:vm';
import { WebSocket } from 'ws';
import { sourceContracts } from '../scripts/installed-source.mjs';
import { calculateProof, createPassHash } from '../src/auth.mjs';
import { fixture, peer, authenticate, pause, matchedPair, register } from './helpers.mjs';

const contract = sourceContracts();
const quiet = { info() {}, warn() {} };
function observedSocket(sent) {
  return class ObservedSocket extends WebSocket {
    send(value, ...args) { sent.push(JSON.parse(String(value))); return super.send(value, ...args); }
  };
}
async function until(condition, timeout = 1500) {
  const start = Date.now();
  while (!condition()) { if (Date.now() - start > timeout) throw new Error('STATE_TIMEOUT'); await pause(10); }
}

test('installed desktop HMAC implementation matches literal-key proof and password hash vectors', () => {
  const { authProvider } = contract.runtime();
  for (const [password, nonce, sid] of [
    ['synthetic-ascii', 'nonce_one', 'sid_one'], ['合成中文密钥', 'nonce_2-~', 'sid.two'], ['🚀/test', 'c'.repeat(43), 'd_third']
  ]) {
    const hash = createPassHash(password); assert.equal(authProvider.createPassHash(password), hash);
    for (const role of ['device', 'terminal']) assert.equal(authProvider.calculateProof(hash, nonce, role, sid), calculateProof(hash, nonce, role, sid));
  }
  const one = authProvider.createPassword(); const two = authProvider.createPassword();
  assert.equal(Buffer.from(one, 'base64url').length, 24); assert.notEqual(one, two);
});

test('installed desktop transport receives unknown-scope error: no proof, no registration, no retry', async (t) => {
  const f = await fixture(t); const sent = []; const states = []; let resets = 0;
  const { DeviceTransport, authProvider } = contract.runtime(observedSocket(sent));
  const fakeOldHash = createPassHash('SYNTHETIC_OLD_OFFICIAL_CREDENTIAL');
  const transport = new DeviceTransport({ relayWsUrl: f.baseURL, deviceMid: 'synthetic-old-mid',
    auth: { mode: 'persisted', deviceSid: 'synthetic-foreign-service-sid', passHash: fakeOldHash },
    meta: { platform: 'darwin', version: '3.11.2', name: 'synthetic-desktop' }, authProvider, logger: quiet,
    onStateChange: (state) => states.push(state), onRegisteredAuth() {}, onPayload() {}, onError() {},
    onInvalidPersistedAuth: async () => { resets++; }, reconnectDelayMs: 20 });
  t.after(() => transport.dispose()); transport.start();
  await until(() => states.includes('error')); await pause(70);
  assert.deepEqual(sent.map((m) => m.type), ['auth_init']);
  assert.equal(sent[0].role, 'device'); assert.equal(Number.isInteger(sent[0].client_ts), true);
  assert.ok(!JSON.stringify(sent).includes(fakeOldHash)); assert.equal(resets, 0);
  assert.equal(f.server.diagnostics().registered, 0); assert.equal(f.server.diagnostics().acceptedSockets, 1);
});

test('negative control: installed AUTH_FAILED branch really would re-register the old pass_hash', async (t) => {
  const sent = []; let attempts = 0;
  class FakeSocket extends EventEmitter {
    static OPEN = 1; readyState = 1; extensions = '';
    constructor() { super(); attempts++; queueMicrotask(() => this.emit('open')); }
    send(value) {
      const message = JSON.parse(value); sent.push(message);
      if (message.type === 'auth_init') queueMicrotask(() => this.emit('message', Buffer.from('{"type":"error","code":"AUTH_FAILED"}')));
    }
    close() { if (this.readyState !== 1) return; this.readyState = 3; queueMicrotask(() => this.emit('close')); }
  }
  const { DeviceTransport, authProvider } = contract.runtime(FakeSocket);
  const syntheticHash = createPassHash('SYNTHETIC_FOR_NEGATIVE_CONTROL');
  const transport = new DeviceTransport({ relayWsUrl: 'ws://127.0.0.1:1/zcode/ws', deviceMid: 'synthetic-mid',
    auth: { mode: 'persisted', deviceSid: 'synthetic-sid', passHash: syntheticHash }, authProvider, logger: quiet,
    onStateChange() {}, onRegisteredAuth() {}, onPayload() {}, onError() {}, onInvalidPersistedAuth: async () => {} });
  t.after(() => transport.dispose()); transport.start();
  await until(() => sent.some((m) => m.type === 'device_register_init'));
  assert.equal(sent.find((m) => m.type === 'device_register_init').pass_hash, syntheticHash);
  assert.equal(attempts, 2); // This fake never opens a real network socket.
});

test('installed stop retains auth; exact reset method clears before choosing fresh random registration', async () => {
  const { authProvider } = contract.runtime(); const old = { deviceSid: 'synthetic-old', passHash: createPassHash('old') };
  let stored = old; const calls = [];
  const e = { featureGate: { assertEnabled() {} }, logger: quiet, authProvider,
    authStorageProvider: { async load() { return stored; }, async clear() { stored = undefined; calls.push('auth.clear'); } },
    startupRestoreStorageProvider: { async clear() { calls.push('startup.clear'); } } };
  const context = vm.createContext({ e, g() {}, A: async () => calls.push('detach'),
    RK: async (storage) => storage.clear() });
  const choose = vm.runInContext(`(async()=>{${contract.choice.source}; return ct;})`, context);
  const manager = vm.runInContext(`({${contract.stop.source},${contract.reset.source}})`, context);
  manager.start = async () => choose();
  await manager.stop(1); assert.equal(stored, old); assert.deepEqual(calls, ['detach', 'startup.clear']);
  const fresh = await manager.resetPairing(1, {});
  assert.equal(fresh.mode, 'register'); assert.notEqual(fresh.passHash, old.passHash);
  assert.deepEqual(calls.slice(2), ['detach', 'auth.clear']);
});

test('installed fresh desktop transport registers and pairs through actual loopback server', async (t) => {
  const f = await fixture(t); const mid = 'synthetic-installed-desktop'; const permit = f.registry.issueEnrollment(mid);
  const endpoint = new URL(f.baseURL); endpoint.searchParams.set('enroll', permit.enrollmentToken);
  const sent = []; const states = []; let registered;
  const { DeviceTransport, authProvider } = contract.runtime(observedSocket(sent));
  const passHash = authProvider.createPassHash(authProvider.createPassword());
  const transport = new DeviceTransport({ relayWsUrl: endpoint.href, deviceMid: mid,
    auth: { mode: 'register', passHash }, meta: { platform: 'darwin', version: '3.11.2', name: 'Synthetic Desktop' },
    authProvider, logger: quiet, onStateChange: (state) => states.push(state),
    onRegisteredAuth: (identity) => { registered = identity; }, onPayload() {}, onError() {},
    onInvalidPersistedAuth: async () => {}, heartbeatIntervalMs: 30, heartbeatAckTimeoutMs: 200 });
  t.after(() => transport.dispose()); transport.start();
  await until(() => states.includes('waiting_terminal'));
  assert.deepEqual(sent.slice(0, 3).map((m) => m.type), ['device_register_init', 'auth_init', 'auth_response']);
  const terminal = await peer(f.baseURL);
  assert.equal((await authenticate(terminal, { sid: registered.deviceSid, passHash }, 'terminal')).pair_status, 'matched');
  await until(() => states.includes('paired'));
  await until(() => sent.some((m) => m.type === 'pair_status_query'));
  assert.equal(sent.every((m) => Number.isInteger(m.client_ts)), true);
  assert.equal(f.server.diagnostics().authenticated, 2);
});

test('installed persisted desktop transport reconnects same SID without registration or new secret', async (t) => {
  const f = await fixture(t); const mid = 'synthetic-persisted'; const permit = f.registry.issueEnrollment(mid);
  const hash = createPassHash('synthetic-persisted-hash'); const { sid } = f.registry.register(mid, hash, permit.enrollmentToken);
  const sent = []; const states = [];
  const { DeviceTransport, authProvider } = contract.runtime(observedSocket(sent));
  const transport = new DeviceTransport({ relayWsUrl: f.baseURL, deviceMid: mid,
    auth: { mode: 'persisted', deviceSid: sid, passHash: hash }, authProvider, logger: quiet,
    onStateChange: (state) => states.push(state), onRegisteredAuth() { throw new Error('UNEXPECTED_REGISTER'); },
    onPayload() {}, onError() {}, onInvalidPersistedAuth: async () => { throw new Error('UNEXPECTED_RESET'); },
    reconnectDelayMs: 20, heartbeatIntervalMs: 500 });
  t.after(() => transport.dispose()); transport.start();
  await until(() => states.includes('waiting_terminal'));
  transport.socket.terminate();
  await until(() => f.server.diagnostics().authenticated === 2);
  assert.equal(sent.filter((m) => m.type === 'auth_init').length, 2);
  assert.equal(sent.filter((m) => m.type === 'device_register_init').length, 0);
  assert.ok(!JSON.stringify(sent).includes(hash));
});

test('installed reconnect waits out a half-open old device lease and pairs without manual retry', async (t) => {
  const f = await fixture(t, { server: { idleTTL: 120, sweepInterval: 5 } });
  const old = await matchedPair(f);
  // Keep the terminal active. The old device TCP remains open but sends no application heartbeat.
  const heartbeat = setInterval(() => old.terminal.send({ type: 'pair_status_query', device_sid: old.sid }), 20);
  t.after(() => clearInterval(heartbeat));
  const sent = []; const states = []; const failures = [];
  const { DeviceTransport, authProvider } = contract.runtime(observedSocket(sent));
  const transport = new DeviceTransport({ relayWsUrl: f.baseURL, deviceMid: old.mid,
    auth: { mode: 'persisted', deviceSid: old.sid, passHash: old.passHash }, authProvider, logger: quiet,
    onStateChange: (state) => states.push(state), onRegisteredAuth() { throw new Error('UNEXPECTED_REGISTER'); },
    onPayload() {}, onError: (error) => failures.push(error.message), onInvalidPersistedAuth: async () => {},
    reconnectDelayMs: 15, heartbeatIntervalMs: 20, heartbeatAckTimeoutMs: 200 });
  t.after(() => transport.dispose()); transport.start();
  await until(() => states.includes('paired'));
  assert.ok(failures.includes('DEVICE_IN_USE_RETRY'));
  assert.ok(sent.filter((m) => m.type === 'auth_init').length > 1);
  assert.equal(transport.terminalClose, false); assert.equal(f.server.diagnostics().pairedDevices, 1);
  assert.equal(sent.filter((m) => m.type === 'device_register_init').length, 0);
  assert.equal(f.server.diagnostics().kickedTerminals, 0);
});

test('installed competing device stops after bounded recovery window while existing heartbeat lease stays live', async (t) => {
  const f = await fixture(t, { server: { idleTTL: 80, sweepInterval: 5 } });
  const old = await register(f); await authenticate(old.device, old, 'device');
  const heartbeat = setInterval(() => old.device.send({ type: 'pair_status_query', device_sid: old.sid }), 15);
  t.after(() => clearInterval(heartbeat));
  const sent = []; const failures = [];
  const { DeviceTransport, authProvider } = contract.runtime(observedSocket(sent));
  const transport = new DeviceTransport({ relayWsUrl: f.baseURL, deviceMid: old.mid,
    auth: { mode: 'persisted', deviceSid: old.sid, passHash: old.passHash }, authProvider, logger: quiet,
    onStateChange() {}, onRegisteredAuth() {}, onPayload() {}, onError: (error) => failures.push(error.message),
    onInvalidPersistedAuth: async () => {}, reconnectDelayMs: 15 });
  t.after(() => transport.dispose()); transport.start();
  await until(() => transport.terminalClose);
  assert.equal(failures.at(-1), 'DEVICE_IN_USE');
  const attempts = sent.length; await pause(60); assert.equal(sent.length, attempts);
  assert.equal(old.device.socket.readyState, WebSocket.OPEN);
  assert.equal(f.server.diagnostics().kickedTerminals, 0);
});

test('exhausted contender window resets after quiet interval so later real network recovery still works', async (t) => {
  const f = await fixture(t, { server: { idleTTL: 100, sweepInterval: 5 } });
  const old = await matchedPair(f);
  const oldHeartbeat = setInterval(() => old.device.send({ type: 'pair_status_query', device_sid: old.sid }), 15);
  const phoneHeartbeat = setInterval(() => old.terminal.send({ type: 'pair_status_query', device_sid: old.sid }), 15);
  t.after(() => { clearInterval(oldHeartbeat); clearInterval(phoneHeartbeat); });
  const { DeviceTransport, authProvider } = contract.runtime();
  const create = () => new DeviceTransport({ relayWsUrl: f.baseURL, deviceMid: old.mid,
    auth: { mode: 'persisted', deviceSid: old.sid, passHash: old.passHash }, authProvider, logger: quiet,
    onStateChange() {}, onRegisteredAuth() {}, onPayload() {}, onError() {}, onInvalidPersistedAuth: async () => {},
    reconnectDelayMs: 15, heartbeatIntervalMs: 20 });
  const competitor = create(); t.after(() => competitor.dispose()); competitor.start();
  await until(() => competitor.terminalClose);
  await pause(125); // No competing attempts, but the old desktop still refreshes its lease.
  clearInterval(oldHeartbeat); // A later network change leaves the original TCP half-open.
  const recovered = create(); t.after(() => recovered.dispose()); recovered.start();
  await until(() => recovered.state === 'paired');
  assert.equal(recovered.terminalClose, false); assert.equal(f.server.diagnostics().pairedDevices, 1);
});
