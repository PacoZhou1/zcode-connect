import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { BridgeService } from '../src/service.mjs';
import { BridgeError, hash } from '../src/util.mjs';
import { createBridgeServer } from '../src/server.mjs';

class SendProtocol extends EventEmitter {
  ready = true; interactions = new Map(); calls = []; acknowledgements = new Map(); turns = 0;
  status = 'idle'; lose = false; unknown = false; dropBeforeAdmission = false;
  ackStatus = 'accepted'; reasonCode; queryTransform = value => value; commandTransform = value => value;
  async start() {} async close() {}
  async request(method, params) {
    this.calls.push({ method, params: structuredClone(params) });
    if (method === 'v4/command') {
      assert.equal(params.type, 'sendText');
      const saved = JSON.parse(readFileSync(this.registryPath, 'utf8')).inputs[`${params.sessionId}:${params.commandId}`];
      assert.deepEqual(saved.envelope, params, 'persist the complete immutable wire before every write');
      assert.equal(saved.attempted, true);
      if (this.dropBeforeAdmission) { this.dropBeforeAdmission = false; throw new BridgeError(504, 'runtime_timeout', 'Write outcome unavailable', true); }
      let ack = this.acknowledgements.get(params.commandId);
      if (!ack) {
        ack = { commandId: params.commandId, status: this.ackStatus, revisionAtDecision: 1, ...(this.reasonCode ? { reasonCode: this.reasonCode } : {}) };
        this.acknowledgements.set(params.commandId, ack);
        if (!['rejected', 'stale'].includes(ack.status)) { this.turns++; this.status = 'running'; }
      }
      if (this.lose) { this.lose = false; throw new BridgeError(504, 'runtime_timeout', 'Lost CLI acknowledgement', true); }
      return this.commandTransform(ack);
    }
    if (method === 'v4/commands/query') return this.queryTransform({ results: params.commands.map(key => ({ key, result: this.unknown ? 'unknown' : this.acknowledgements.get(key.commandId) ?? 'unknown' })) });
    if (method === 'session/read') return { session: { sessionId: params.sessionId, status: this.status }, messages: [] };
    if (method === 'v4/attachment/begin') return { state: 'committed', ref: `opaque-ref:${params.uploadId}` };
    throw new Error(`Unexpected protocol call: ${method}`);
  }
}
function fixture(t) {
  const root = mkdtempSync(join(tmpdir(), 'zcode-send-recovery-'));
  const options = { runtimeDir: join(root, 'runtime'), zcodeRoot: join(root, 'desktop'), acceptanceWorkspace: join(root, 'workspace'),
    protocol: new SendProtocol(), history: { sessions: () => [], projects: () => [], latestModel: () => null } };
  options.ownedHistory = options.history;
  mkdirSync(join(options.zcodeRoot, 'v2'), { recursive: true });
  writeFileSync(join(options.zcodeRoot, 'v2/config.json'), JSON.stringify({ provider: { test: { kind: 'openai-compatible', options: { baseURL: 'https://model.invalid/v1', apiKey: 'offline-only' }, models: { 'GLM-test': { modalities: { input: ['text', 'image'] } } } } } }));
  const services = [], makeService = () => { const service = new BridgeService(options); services.push(service); return service; };
  const service = makeService(), protocol = options.protocol;
  protocol.registryPath = service.registryPath;
  service.registry.sessions.owned = { id: 'owned', path: options.acceptanceWorkspace, title: 'Recovery test', customTitle: true, mode: 'build',
    selection: { providerId: 'test', modelId: 'GLM-test', thoughtLevel: 'max' }, createdAt: new Date().toISOString(), updatedAt: new Date().toISOString(), status: 'idle' };
  service.initialized.add('owned'); service.persist();
  t.after(async () => { for (const item of services) await item.close(); rmSync(root, { recursive: true, force: true }); });
  return { service, protocol, makeService, disk: () => JSON.parse(readFileSync(service.registryPath, 'utf8')) };
}
const commands = protocol => protocol.calls.filter(call => call.method === 'v4/command');
const pending = reasonCode => error => error.code === 'input_pending' && error.details?.reasonCode === reasonCode;

test('a lost CLI send ACK is queried after completion and releases the original input without another turn', async t => {
  const { service, protocol, disk } = fixture(t); protocol.lose = true;
  await assert.rejects(service.send('owned', 'Original input', 'lost-ack'), { code: 'runtime_timeout' });
  protocol.status = 'completed'; await service.refresh('owned');
  assert.equal(service.registry.sessions.owned.status, 'completed');
  const recovered = await service.send('owned', 'Original input', 'lost-ack');
  assert.deepEqual(recovered, { accepted: true, sessionId: 'owned', inputId: 'lost-ack', duplicate: true });
  assert.equal(protocol.turns, 1); assert.equal(protocol.calls.filter(call => call.method === 'v4/command').length, 1);
  assert.deepEqual(protocol.calls.find(call => call.method === 'v4/commands/query').params, { commands: [{ sessionId: 'owned', commandId: 'lost-ack' }] });
  assert.equal(service.registry.sessions.owned.status, 'completed'); assert.equal(disk().inputs['owned:lost-ack'].status, 'accepted');
});

test('same-runtime unknown retry preserves command ID, timestamp, payload and uploaded attachment refs', async t => {
  const { service, protocol, disk } = fixture(t);
  const attachment = service.upload('owned', { fileName: 'note.txt', mimeType: 'text/plain', base64: Buffer.from('offline attachment').toString('base64') }).attachment;
  protocol.lose = true; protocol.unknown = true;
  await assert.rejects(service.send('owned', 'Read this file', 'frozen', [attachment.id]), { code: 'runtime_timeout' });
  const first = structuredClone(commands(protocol)[0].params);
  assert.deepEqual(disk().inputs['owned:frozen'].envelope, first);
  const recovered = await service.send('owned', 'Read this file', 'frozen', [attachment.id]);
  assert.equal(recovered.accepted, true); assert.equal(protocol.turns, 1);
  assert.deepEqual(commands(protocol).map(call => call.params), [first, first]);
  assert.equal(protocol.calls.filter(call => call.method.startsWith('v4/attachment/')).length, 1);
  assert.equal(first.payload.attachments[0].ref, `opaque-ref:${attachment.id}`);
});

test('unknown before initial admission retries the frozen input once under concurrent HTTP submissions', async t => {
  const { service, protocol } = fixture(t); protocol.dropBeforeAdmission = true;
  await assert.rejects(service.send('owned', 'Retry once', 'not-admitted'), { code: 'runtime_timeout' });
  assert.equal(protocol.turns, 0);
  const results = await Promise.all(Array.from({ length: 4 }, () => service.send('owned', 'Retry once', 'not-admitted')));
  assert.ok(results.every(result => result.accepted)); assert.equal(protocol.turns, 1); assert.equal(commands(protocol).length, 2);
  assert.deepEqual(commands(protocol)[0].params, commands(protocol)[1].params);
});

test('journal restart queries a persisted accepted command without session resume or a new stdio command', async t => {
  const { service, protocol, makeService } = fixture(t); protocol.lose = true;
  await assert.rejects(service.send('owned', 'Survive restart', 'restart'), { code: 'runtime_timeout' });
  const restored = makeService(), before = protocol.calls.length;
  const recovered = await restored.send('owned', 'Survive restart', 'restart');
  assert.equal(recovered.accepted, true); assert.equal(protocol.turns, 1);
  assert.deepEqual(protocol.calls.slice(before).map(call => call.method), ['v4/commands/query']);
  assert.equal(restored.initialized.has('owned'), false);
});

test('unknown after restart remains pending and cannot be replaced with another input ID', async t => {
  const { service, protocol, makeService, disk } = fixture(t); protocol.lose = true; protocol.unknown = true;
  await assert.rejects(service.send('owned', 'Uncertain restart', 'old-runtime'), { code: 'runtime_timeout' });
  const first = disk().inputs['owned:old-runtime'].envelope, restored = makeService();
  restored.initialized.add('owned');
  await assert.rejects(restored.send('owned', 'Uncertain restart', 'old-runtime'), pending('runtime_changed'));
  await assert.rejects(restored.send('owned', 'Uncertain restart', 'replacement'), pending('previous_input_unresolved'));
  assert.equal(commands(protocol).length, 1); assert.deepEqual(disk().inputs['owned:old-runtime'].envelope, first);
  assert.equal(disk().inputs['owned:replacement'], undefined);
});

test('CLI disconnect invalidates unknown replay even if a later action initialized the task again', async t => {
  const { service, protocol } = fixture(t); protocol.lose = true; protocol.unknown = true;
  await assert.rejects(service.send('owned', 'Disconnected', 'disconnect'), { code: 'runtime_timeout' });
  protocol.emit('disconnected', 'offline test'); service.initialized.add('owned');
  await assert.rejects(service.send('owned', 'Disconnected', 'disconnect'), pending('runtime_changed'));
  assert.equal(commands(protocol).length, 1);
});

test('legacy hash-only ledgers can recover an accepted command but never reconstruct unknown wire', async t => {
  const { service, protocol } = fixture(t);
  service.registry.inputs['owned:legacy'] = { hash: hash('Legacy input'), status: 'pending', at: new Date().toISOString() }; service.persist();
  await assert.rejects(service.send('owned', 'Legacy input', 'legacy'), pending('legacy_envelope_unavailable'));
  assert.equal(commands(protocol).length, 0);
  protocol.acknowledgements.set('legacy', { commandId: 'legacy', status: 'accepted', revisionAtDecision: 0 });
  assert.equal((await service.send('owned', 'Legacy input', 'legacy')).accepted, true);
  assert.equal(commands(protocol).length, 0);
});

test('conflicting text or attachment identity is rejected before querying or writing the host', async t => {
  const { service, protocol } = fixture(t); protocol.lose = true;
  await assert.rejects(service.send('owned', 'Immutable', 'conflict'), { code: 'runtime_timeout' });
  const count = protocol.calls.length;
  await assert.rejects(service.send('owned', 'Changed', 'conflict'), { code: 'input_conflict' });
  await assert.rejects(service.send('owned', 'Immutable', 'conflict', ['different-attachment']), { code: 'input_conflict' });
  assert.equal(protocol.calls.length, count);
});

test('only matched admission rejection or stale ACK releases the input for a new explicit request', async t => {
  for (const status of ['rejected', 'stale']) {
    const { service, protocol, disk } = fixture(t); protocol.ackStatus = status; protocol.reasonCode = 'guard.offlineTest'; protocol.lose = true;
    await assert.rejects(service.send('owned', 'Rejected input', status), { code: 'runtime_timeout' });
    const rejected = error => error.code === 'input_rejected' && error.retryable === false && error.details?.commandStatus === status;
    await assert.rejects(service.send('owned', 'Rejected input', status), rejected);
    assert.equal(disk().inputs[`owned:${status}`].status, 'rejected');
    const count = protocol.calls.length;
    await assert.rejects(service.send('owned', 'Rejected input', status), rejected); assert.equal(protocol.calls.length, count);
    protocol.ackStatus = 'accepted'; protocol.reasonCode = undefined;
    assert.equal((await service.send('owned', 'New explicit input', `${status}-new`)).accepted, true);
    assert.equal(protocol.turns, 1);
  }
});

test('failed execution is retained as unresolved because it may already have had side effects', async t => {
  const { service, protocol, disk } = fixture(t); protocol.ackStatus = 'failed'; protocol.reasonCode = 'fault.command.executionFailed';
  await assert.rejects(service.send('owned', 'May have executed', 'failed'), pending('fault.command.executionFailed'));
  assert.equal(protocol.turns, 1); assert.equal(disk().inputs['owned:failed'].acknowledgement.status, 'failed');
  const count = protocol.calls.length;
  await assert.rejects(service.send('owned', 'May have executed', 'failed'), pending('fault.command.executionFailed'));
  await assert.rejects(service.send('owned', 'May have executed', 'new-id'), pending('previous_input_unresolved'));
  assert.equal(protocol.calls.length, count); assert.equal(protocol.turns, 1);
});

test('host queryUnavailable is not persisted as a failed outcome and a later real ACK still recovers', async t => {
  const { service, protocol, disk } = fixture(t); protocol.lose = true;
  await assert.rejects(service.send('owned', 'Transient lookup', 'lookup'), { code: 'runtime_timeout' });
  protocol.queryTransform = value => ({ results: value.results.map(item => ({ ...item, result: { commandId: 'lookup', status: 'failed', revisionAtDecision: 0, reasonCode: 'fault.command.queryUnavailable' } })) });
  await assert.rejects(service.send('owned', 'Transient lookup', 'lookup'), pending('fault.command.queryUnavailable'));
  assert.equal(disk().inputs['owned:lookup'].acknowledgement, undefined);
  protocol.queryTransform = value => value;
  assert.equal((await service.send('owned', 'Transient lookup', 'lookup')).accepted, true); assert.equal(commands(protocol).length, 1);
});

test('malformed or foreign query answers preserve pending status without accepting or replaying', async t => {
  const { service, protocol, disk } = fixture(t); protocol.lose = true;
  await assert.rejects(service.send('owned', 'Strict query', 'strict'), { code: 'runtime_timeout' });
  for (const answer of [{}, { results: [] }, { results: [{ key: { sessionId: 'other', commandId: 'strict' }, result: 'unknown' }] },
    { results: [{ key: { sessionId: 'owned', commandId: 'other' }, result: 'unknown' }] },
    { results: [{ key: { sessionId: 'owned', commandId: 'strict' }, result: { commandId: 'other', status: 'accepted', revisionAtDecision: 1 } }] },
    { results: [{ key: { sessionId: 'owned', commandId: 'strict' }, result: { commandId: 'strict', status: 'accepted' } }] }]) {
    protocol.queryTransform = () => answer;
    await assert.rejects(service.send('owned', 'Strict query', 'strict'), { code: 'input_pending' });
    assert.equal(disk().inputs['owned:strict'].status, 'uncertain'); assert.equal(disk().inputs['owned:strict'].acknowledgement, undefined);
  }
  protocol.queryTransform = () => { throw new BridgeError(503, 'runtime_unavailable', 'Query unavailable', true); };
  await assert.rejects(service.send('owned', 'Strict query', 'strict'), pending('command_query_unavailable'));
  assert.equal(commands(protocol).length, 1);
});

test('invalid direct ACK and an unclassified transport error never become definite rejection', async t => {
  const { service, protocol, disk } = fixture(t);
  protocol.commandTransform = value => ({ ...value, commandId: 'another-input' });
  await assert.rejects(service.send('owned', 'Strict direct ACK', 'direct'), pending('invalid_acknowledgement'));
  assert.equal(disk().inputs['owned:direct'].acknowledgement, undefined);
  assert.equal((await service.send('owned', 'Strict direct ACK', 'direct')).accepted, true);
  protocol.status = 'completed'; await service.refresh('owned');
  protocol.commandTransform = () => { throw new BridgeError(409, 'session_busy', 'RPC error without command outcome'); };
  await assert.rejects(service.send('owned', 'RPC uncertainty', 'rpc-error'), pending('command_ack_unavailable'));
  assert.equal(disk().inputs['owned:rpc-error'].status, 'uncertain');
});

test('unknown retry respects archive, live turn and configuration changes without rebuilding the envelope', async t => {
  const { service, protocol, disk } = fixture(t); protocol.lose = true; protocol.unknown = true;
  await assert.rejects(service.send('owned', 'Respect current task', 'guards'), { code: 'runtime_timeout' });
  const first = disk().inputs['owned:guards'].envelope, record = service.registry.sessions.owned;
  record.archived = true;
  await assert.rejects(service.send('owned', 'Respect current task', 'guards'), pending('session_not_ready'));
  record.archived = false; record.status = 'waiting';
  await assert.rejects(service.send('owned', 'Respect current task', 'guards'), pending('session_not_ready'));
  record.status = 'idle'; record.mode = 'plan';
  await assert.rejects(service.send('owned', 'Respect current task', 'guards'), pending('configuration_changed'));
  assert.equal(commands(protocol).length, 1); assert.deepEqual(disk().inputs['owned:guards'].envelope, first);
  protocol.unknown = false; record.archived = true;
  assert.equal((await service.send('owned', 'Respect current task', 'guards')).accepted, true);
  assert.equal(commands(protocol).length, 1);
});

test('the HTTP route resolves a lower-hop timeout with the same inputId and no second model turn', async t => {
  const { service, protocol } = fixture(t), server = createBridgeServer({ service, token: 'offline-recovery-token' });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => { server.closeAllConnections(); server.close(); }); protocol.lose = true;
  const request = () => fetch(`http://127.0.0.1:${server.address().port}/v1/sessions/owned/messages`, { method: 'POST', headers: { Authorization: 'Bearer offline-recovery-token', 'Content-Type': 'application/json' }, body: JSON.stringify({ text: 'HTTP recovery', inputId: 'http-retry' }) });
  const first = await request(); assert.equal(first.status, 504); assert.equal((await first.json()).error.code, 'runtime_timeout');
  protocol.status = 'completed'; await service.refresh('owned');
  const second = await request(); assert.equal(second.status, 202); assert.equal((await second.json()).duplicate, true);
  assert.equal(protocol.turns, 1); assert.equal(commands(protocol).length, 1);
});
