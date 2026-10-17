import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { BridgeService } from '../src/service.mjs';
import { normalizeMessages } from '../src/history.mjs';

// Synthetic regression sequence; never contacts CLI or the running bridge.
const retained = JSON.parse(readFileSync(new URL('../../tests/fixtures/bridge/refresh-events.json', import.meta.url)));
const saved = JSON.parse(readFileSync(new URL('../../tests/fixtures/bridge/refresh-rows.json', import.meta.url)));
const realEvents = retained.events.filter(event => event.type === 'runtime.event').map(event => event.data.event);
const terminal = realEvents.find(event => event.type === 'turn.completed');
const finalText = terminal.payload.response;
const rows = saved.rows.map(row => ({ info: { ...row.info, id: row.id }, parts: row.parts }));
const completeMessages = normalizeMessages(rows);
const finalMessage = completeMessages.find(message => message.role === 'assistant' && message.text === finalText);
assert.ok(finalMessage);
const finalRowIndex = rows.findIndex(row => row.info.id === finalMessage.id);
const clone = value => structuredClone(value);
const gate = () => { let resolve, reject; const promise = new Promise((a, b) => { resolve = a; reject = b; }); return { promise, resolve, reject }; };
const pause = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));
const until = async predicate => { const deadline = Date.now() + 1500; while (!predicate()) { assert.ok(Date.now() < deadline, 'bounded offline refresh did not finish'); await pause(5); } };
function snapshot(status, final = false) {
  const messages = clone(rows);
  if (!final) { messages[finalRowIndex].parts = []; delete messages[finalRowIndex].info.finish; if (messages[finalRowIndex].info.time) delete messages[finalRowIndex].info.time.completed; }
  return { session: { sessionId: terminal.sessionId, status }, runtime: { ...(status === 'running' ? { activeTurnId: terminal.turnId } : {}), eventSeq: final ? terminal.seq : terminal.seq - 5 }, settings: { mode: { current: 'plan' } }, messages };
}
function fixture(t, read) {
  const root = mkdtempSync(join(tmpdir(), 'zcode-refresh-race-'));
  const zcodeRoot = join(root, 'unused-desktop'); mkdirSync(join(zcodeRoot, 'v2'), { recursive: true });
  writeFileSync(join(zcodeRoot, 'v2/config.json'), JSON.stringify({ provider: { retained: { name: 'Offline fixture', kind: 'openai-compatible', options: { baseURL: 'https://provider.invalid/v1' }, models: { 'GLM-5.3-test': {} } } } }));
  class Protocol extends EventEmitter {
    ready = true; interactions = new Map(); calls = [];
    async start() {}
    async request(method, params) { this.calls.push({ method, params }); assert.equal(method, 'session/read'); return read(this.calls.length, params); }
    async close() {}
  }
  const protocol = new Protocol(), history = { sessions: () => [], projects: () => [], latestModel: () => undefined };
  const service = new BridgeService({ runtimeDir: root, zcodeRoot, acceptanceWorkspace: join(root, 'acceptance-workspace'), protocol, history, ownedHistory: history });
  const id = terminal.sessionId;
  service.registry.sessions[id] = { id, title: 'Retained feedback replay', path: join(root, 'acceptance-workspace'), status: 'running', mode: 'plan', permissionMode: 'build', selection: { modelId: 'GLM-5.3-test', providerId: 'retained', thoughtLevel: 'max' } };
  service.snapshots.set(id, snapshot('running'));
  service.initialized.add(id);
  t.after(async () => { await service.close(); rmSync(root, { recursive: true, force: true }); });
  return { service, protocol, id };
}

test('synthetic feedback terminal events drain a final read and cannot be overwritten by the in-flight running snapshot', async t => {
  const stale = gate();
  const { service, protocol, id } = fixture(t, count => count === 1 ? stale.promise : snapshot('idle', true));
  const active = service.refresh(id); await until(() => protocol.calls.length === 1);
  // Replay terminal events after the last streaming refresh starts.
  for (const event of realEvents.filter(event => event.seq >= terminal.seq - 6 && event.seq <= terminal.seq)) service.onRuntimeEvent(clone(event));
  await pause(240); // The old implementation's scheduled terminal refresh joins the stale promise here.
  stale.resolve(snapshot('running')); await active;
  await until(() => !service.refreshing.has(id) && !service.refreshTimers.has(id));
  assert.equal(protocol.calls.length, 2, 'a pending refresh must be drained after the first read');
  assert.equal(service.registry.sessions[id].status, 'completed');
  assert.equal(normalizeMessages(service.snapshots.get(id).messages).find(message => message.id === finalMessage.id)?.text, finalText);
  const events = service.events.entries, finalEventIndex = events.findIndex(event => event.type === 'runtime.event' && event.data.event.type === 'turn.completed');
  assert.ok(events.slice(finalEventIndex + 1).filter(event => event.type === 'session.updated').every(event => event.data.session.status === 'completed'));
  assert.ok(events.some(event => event.type === 'message.updated' && event.data.message.id === finalMessage.id && event.data.message.text === finalText));
  assert.ok(protocol.calls.every(call => call.method === 'session/read'));
});

test('concurrent explicit refresh requests wait for a read made after the newer request', async t => {
  const stale = gate(), fresh = gate();
  const { service, protocol, id } = fixture(t, count => count === 1 ? stale.promise : fresh.promise);
  const first = service.refresh(id); await until(() => protocol.calls.length === 1);
  let finished = false; const joined = service.refresh(id).then(() => { finished = true; });
  stale.resolve(snapshot('running')); await until(() => protocol.calls.length === 2);
  assert.equal(finished, false);
  fresh.resolve(snapshot('idle', true)); await Promise.all([first, joined]);
  assert.equal(protocol.calls.length, 2);
  assert.equal(normalizeMessages(service.snapshots.get(id).messages).find(message => message.id === finalMessage.id)?.text, finalText);
});

test('streaming updates still publish intermediate text while a newer read is pending', async t => {
  const firstRead = gate(), secondRead = gate();
  const { service, protocol, id } = fixture(t, count => count === 1 ? firstRead.promise : secondRead.promise);
  const active = service.refresh(id); await until(() => protocol.calls.length === 1);
  service.onRuntimeEvent(clone(realEvents.find(event => event.type === 'model.streaming')));
  const partial = snapshot('running'); partial.messages[finalRowIndex].parts = [{ type: 'text', text: 'NATIVE_PLAN_FEEDBACK_' }];
  firstRead.resolve(partial); await until(() => protocol.calls.length === 2);
  assert.ok(service.events.entries.some(event => event.type === 'message.updated' && event.data.message.text === 'NATIVE_PLAN_FEEDBACK_'));
  secondRead.resolve(snapshot('idle', true)); await active;
  assert.equal(normalizeMessages(service.snapshots.get(id).messages).find(message => message.id === finalMessage.id)?.text, finalText);
});

test('a pending question cannot be rolled back to running by an older read', async t => {
  const stale = gate();
  const { service, protocol, id } = fixture(t, count => count === 1 ? stale.promise : snapshot('waiting'));
  const active = service.refresh(id); await until(() => protocol.calls.length === 1);
  const interactionId = 'offline-question', frame = { method: 'interaction/requestUserInput', params: { requestId: interactionId, sessionId: id, toolName: 'AskUserQuestion', questions: [] } };
  protocol.interactions.set(interactionId, frame); service.onInteraction(interactionId, frame);
  stale.resolve(snapshot('running')); await active;
  assert.equal(protocol.calls.length, 2);
  assert.equal(service.registry.sessions[id].status, 'waiting');
  assert.equal(service.pendingInteractions(id).length, 1);
  assert.ok(service.events.entries.filter(event => event.type === 'session.updated').every(event => event.data.session.status === 'waiting'));
});

test('a cancelled terminal result stays idle and is saved before the final read returns', async t => {
  const stale = gate();
  const { service, protocol, id } = fixture(t, count => count === 1 ? stale.promise : snapshot('idle', true));
  const active = service.refresh(id); await until(() => protocol.calls.length === 1);
  const cancelled = clone(terminal); cancelled.payload.resultType = 'cancelled';
  service.onRuntimeEvent(cancelled);
  assert.equal(JSON.parse(readFileSync(service.registryPath)).sessions[id].status, 'idle');
  stale.resolve(snapshot('running')); await active;
  assert.equal(service.registry.sessions[id].status, 'idle');
  assert.equal(protocol.calls.length, 2);
  assert.ok(service.events.entries.filter(event => event.type === 'session.updated').every(event => event.data.session.status === 'idle'));
});

test('an in-flight read failure cannot consume the final refresh requested by a terminal event', async t => {
  const stale = gate();
  const { service, protocol, id } = fixture(t, count => count === 1 ? stale.promise : snapshot('idle', true));
  const active = service.refresh(id); const failed = assert.rejects(active, /offline read failure/);
  await until(() => protocol.calls.length === 1); service.onRuntimeEvent(clone(terminal));
  stale.reject(new Error('offline read failure')); await failed;
  assert.equal(service.registry.sessions[id].status, 'completed');
  await until(() => protocol.calls.length === 2 && !service.refreshing.has(id));
  assert.equal(service.registry.sessions[id].status, 'completed');
  assert.equal(normalizeMessages(service.snapshots.get(id).messages).find(message => message.id === finalMessage.id)?.text, finalText);
});

test('closing a service stops queued refreshes and prevents late snapshots being published', async t => {
  const stale = gate();
  const { service, protocol, id } = fixture(t, () => stale.promise);
  const active = service.refresh(id); await until(() => protocol.calls.length === 1);
  service.onRuntimeEvent(clone(terminal)); await service.close(); const eventCount = service.events.entries.length;
  service.onRuntimeEvent({ ...clone(terminal), type: 'turn.started' });
  service.onInteraction('late-question', { method: 'interaction/requestUserInput', params: { sessionId: id } });
  stale.resolve(snapshot('running')); await active; await pause(230);
  assert.equal(protocol.calls.length, 1); assert.equal(service.events.entries.length, eventCount);
  assert.equal(service.registry.sessions[id].status, 'completed');
});

test('a terminal read failure is retried without needing any later runtime event', async t => {
  const { service, protocol, id } = fixture(t, count => { if (count === 1) throw new Error('offline terminal read failure'); return snapshot('idle', true); });
  service.onRuntimeEvent(clone(terminal));
  await until(() => protocol.calls.length === 2 && !service.refreshing.has(id));
  assert.equal(service.registry.sessions[id].status, 'completed');
  assert.equal(normalizeMessages(service.snapshots.get(id).messages).find(message => message.id === finalMessage.id)?.text, finalText);
  assert.equal(protocol.calls.length, 2);
});

test('terminal read retries stop after two retries and report an explicit resync requirement', async t => {
  const { service, protocol, id } = fixture(t, () => { throw new Error('offline persistent read failure'); });
  service.onRuntimeEvent(clone(terminal));
  await until(() => service.events.entries.some(event => event.type === 'resync.required' && event.data.reason === 'session_snapshot_read_failed'));
  await pause(250);
  assert.equal(protocol.calls.length, 3, 'one initial read and at most two autonomous retries');
  assert.equal(service.registry.sessions[id].status, 'completed');
  assert.equal(service.events.entries.filter(event => event.type === 'resync.required').length, 1);
  assert.equal(service.refreshing.size, 0); assert.equal(service.refreshTimers.size, 0);
});

test('live terminal delivery before the subscribe response is refreshed after initialization', async t => {
  const { service, protocol, id } = fixture(t, () => snapshot('idle', true));
  service.initialized.delete(id); const read = protocol.request.bind(protocol);
  protocol.request = async (method, params) => {
    if (method === 'session/resume') { protocol.calls.push({ method, params }); return snapshot('running'); }
    if (method === 'session/subscribe') {
      protocol.calls.push({ method, params }); service.onRuntimeEvent(clone(terminal));
      assert.equal(service.initialized.has(id), false);
      return {};
    }
    return read(method, params);
  };
  await service.ensureInitialized(id);
  await until(() => protocol.calls.some(call => call.method === 'session/read') && !service.refreshing.has(id));
  assert.equal(service.registry.sessions[id].status, 'completed');
  assert.equal(normalizeMessages(service.snapshots.get(id).messages).find(message => message.id === finalMessage.id)?.text, finalText);
  assert.equal(protocol.calls.filter(call => call.method === 'session/read').length, 1);
  assert.ok(!protocol.calls.some(call => call.method === 'v4/command'));
});

test('continuous streaming yields after two reads and still drains the eventual final event', async t => {
  let ended = false;
  const { service, protocol, id } = fixture(t, async () => { await pause(12); return snapshot(ended ? 'idle' : 'running', ended); });
  const streaming = realEvents.find(event => event.type === 'model.streaming');
  const timer = setInterval(() => service.onRuntimeEvent(clone(streaming)), 3); t.after(() => clearInterval(timer));
  const started = Date.now(); await service.refresh(id);
  assert.ok(Date.now() - started < 150, 'continuous events must not retain the joined promise');
  await pause(55); assert.equal(protocol.calls.length, 2, 'follow-up reads are throttled rather than driven at streaming frequency');
  clearInterval(timer); ended = true; service.onRuntimeEvent(clone(terminal));
  await until(() => !service.refreshing.has(id) && !service.refreshTimers.has(id));
  assert.equal(service.registry.sessions[id].status, 'completed');
  assert.equal(normalizeMessages(service.snapshots.get(id).messages).find(message => message.id === finalMessage.id)?.text, finalText);
});

test('stop retains its ten-second confirmation deadline when a shared read never returns', { timeout: 15000 }, async t => {
  const stalled = gate();
  const { service, protocol, id } = fixture(t, () => stalled.promise); const read = protocol.request.bind(protocol);
  protocol.request = async (method, params) => {
    if (method === 'v4/command') { protocol.calls.push({ method, params }); assert.equal(params.type, 'stop'); return { commandId: params.commandId, status: 'accepted', revisionAtDecision: 1 }; }
    return read(method, params);
  };
  const started = Date.now();
  await assert.rejects(service.stop(id), { code: 'stop_not_confirmed' });
  assert.ok(Date.now() - started < 12000, 'a stalled shared read must not extend the confirmation deadline');
  assert.equal(protocol.calls.filter(call => call.method === 'v4/command').length, 1);
  assert.equal(protocol.calls.filter(call => call.method === 'session/read').length, 1);
  await service.close(); stalled.resolve(snapshot('running'));
});
