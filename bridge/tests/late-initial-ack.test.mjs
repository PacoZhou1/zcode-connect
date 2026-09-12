import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { BridgeService } from '../src/service.mjs';

const gate = () => { let resolve; const promise = new Promise(done => { resolve = done; }); return { promise, resolve }; };
function fixture(t) {
  const root = mkdtempSync(join(tmpdir(), 'zcode-late-ack-guard-')), ack = gate();
  class Protocol extends EventEmitter {
    ready = true; interactions = new Map(); calls = []; status = 'idle';
    async request(method, params) {
      this.calls.push({ method, params: structuredClone(params) });
      if (method === 'v4/command') return ack.promise;
      assert.equal(method, 'session/read', 'No protocol method beyond fake command/read is allowed');
      return { session: { sessionId: 'owned', status: this.status }, messages: [] };
    }
    async close() {}
  }
  const protocol = new Protocol(), history = { sessions: () => [], projects: () => [], latestModel: () => undefined };
  const service = new BridgeService({ runtimeDir: root, zcodeRoot: join(root, 'unused-desktop'),
    acceptanceWorkspace: join(root, 'workspace'), protocol, history, ownedHistory: history });
  const id = 'owned', inputId = 'frozen-input', at = new Date().toISOString();
  const input = { status: 'pending', envelope: { commandId: inputId, sessionId: id, type: 'sendText', issuedAt: 1,
    baseRevision: 0, payload: { text: 'Offline text', attachments: [{ ref: 'opaque-frozen-ref' }] } } };
  service.registry.sessions[id] = { id, title: 'Offline task', customTitle: true, path: join(root, 'workspace'), status: 'idle',
    mode: 'build', selection: { providerId: 'offline', modelId: 'offline', thoughtLevel: 'max' }, createdAt: at, updatedAt: at };
  service.registry.inputs[`${id}:${inputId}`] = input;
  service.initialized.add(id);
  const acknowledgement = { commandId: inputId, status: 'accepted', revisionAtDecision: 1 };
  const disk = () => JSON.parse(readFileSync(service.registryPath));
  const event = (type, payload = {}) => protocol.emit('sessionEvent', { type, sessionId: id, turnId: 'offline-turn', seq: 1, payload });
  const settle = () => ack.resolve(acknowledgement);
  const submit = (recovered = false) => service.submitInput(id, inputId, input, recovered);
  function verifyAdmission() {
    assert.equal(input.status, 'accepted');
    assert.equal(disk().inputs[`${id}:${inputId}`].status, 'accepted', 'Late ACK must remain durably accepted');
    assert.deepEqual(input.acknowledgement, acknowledgement);
    assert.deepEqual(protocol.calls.find(call => call.method === 'v4/command')?.params, input.envelope, 'Frozen wire must remain unchanged');
    assert.equal(protocol.calls.filter(call => call.method === 'v4/command').length, 1, 'Exactly one fake send command');
  }
  t.after(async () => { await service.close(); rmSync(root, { recursive: true, force: true }); });
  return { service, protocol, input, id, inputId, acknowledgement, disk, event, settle, submit, verifyAdmission };
}

test('ordinary accepted ACK still marks running and persists accepted input', async t => {
  const f = fixture(t), pending = f.submit(); f.settle();
  assert.equal((await pending).accepted, true);
  assert.equal(f.service.registry.sessions[f.id].status, 'running'); f.verifyAdmission();
});

test('turn.started before the initial ACK keeps its running lifecycle', async t => {
  const f = fixture(t), pending = f.submit(); f.event('turn.started');
  const version = f.service.sessionStateVersions.get(f.id); f.settle(); await pending;
  assert.equal(f.service.registry.sessions[f.id].status, 'running');
  assert.equal(f.service.sessionStateVersions.get(f.id), version, 'Admission must not invent another lifecycle transition'); f.verifyAdmission();
});

test('pending question before initial ACK remains waiting', async t => {
  const f = fixture(t), pending = f.submit();
  const frame = { method: 'interaction/requestUserInput', params: { sessionId: f.id, requestId: 'question', toolName: 'AskUserQuestion', questions: [] } };
  f.protocol.interactions.set('question', frame); f.service.onInteraction('question', frame);
  f.protocol.status = 'waiting'; await f.service.refresh(f.id); f.settle(); await pending;
  assert.equal(f.service.registry.sessions[f.id].status, 'waiting');
  assert.equal(f.service.pendingInteractions(f.id).length, 1); f.verifyAdmission();
});

for (const scenario of [
  { label: 'completed', event: 'turn.completed', payload: { resultType: 'completed' }, status: 'completed' },
  { label: 'cancelled', event: 'turn.completed', payload: { resultType: 'cancelled' }, status: 'idle' },
  { label: 'failed', event: 'turn.failed', payload: {}, status: 'error' },
  { label: 'stop then failed', event: 'turn.failed', payload: {}, status: 'idle', stopped: true },
]) {
  test(`${scenario.label} and final read before initial ACK cannot return to running`, async t => {
    const f = fixture(t), pending = f.submit();
    f.event('turn.started');
    if (scenario.stopped) f.service.registry.sessions[f.id].stopRequestedAt = new Date().toISOString();
    f.event(scenario.event, scenario.payload); f.protocol.status = scenario.status;
    await f.service.refresh(f.id);
    const eventCount = f.service.events.entries.length;
    const version = f.service.sessionStateVersions.get(f.id);
    assert.equal(f.service.refreshing.size + f.service.refreshTimers.size, 0);
    f.settle(); await pending;
    assert.equal(f.service.registry.sessions[f.id].status, scenario.status);
    assert.equal(f.disk().sessions[f.id].status, scenario.status);
    assert.equal(f.service.sessionStateVersions.get(f.id), version);
    assert.ok(f.service.events.entries.slice(eventCount).filter(event => event.type === 'session.updated')
      .every(event => event.data.session.status === scenario.status));
    f.verifyAdmission();
  });
}

for (const state of ['waiting', 'completed', 'idle', 'error']) {
  test(`recovered frozen submission ACK preserves ${state}`, async t => {
    const f = fixture(t); f.service.registry.sessions[f.id].status = state; f.protocol.status = state;
    const pending = f.submit(true); f.settle();
    assert.equal((await pending).duplicate, true);
    assert.equal(f.service.registry.sessions[f.id].status, state); f.verifyAdmission();
  });
}

test('known accepted ACK recovery preserves completion without another command', async t => {
  const f = fixture(t);
  f.input.acknowledgement = f.acknowledgement;
  f.service.registry.sessions[f.id].status = 'completed'; f.protocol.status = 'completed';
  assert.equal((await f.service.recoverInput(f.id, f.inputId, f.input)).accepted, true);
  assert.equal(f.service.registry.sessions[f.id].status, 'completed');
  assert.equal(f.disk().inputs[`${f.id}:${f.inputId}`].status, 'accepted');
  assert.ok(f.protocol.calls.every(call => call.method === 'session/read'));
});

test('closing while the initial ACK is pending cannot start a lifecycle', async t => {
  const f = fixture(t), pending = f.submit(); await f.service.close(); f.settle(); await pending;
  assert.equal(f.service.registry.sessions[f.id].status, 'idle'); f.verifyAdmission();
});

test('runtime disconnect during initial ACK cannot overwrite disconnected error', async t => {
  const f = fixture(t), pending = f.submit(); f.event('turn.started');
  f.protocol.ready = false; f.protocol.emit('disconnected', 'Offline test disconnect');
  assert.equal(f.service.registry.sessions[f.id].status, 'error'); f.settle(); await pending;
  assert.equal(f.service.registry.sessions[f.id].status, 'error');
  assert.equal(f.service.initialized.has(f.id), false); f.verifyAdmission();
});
