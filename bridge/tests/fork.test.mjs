import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { BridgeService } from '../src/service.mjs';
import { BridgeError } from '../src/util.mjs';
import { forkRows, withForkTargets } from '../src/fork.mjs';
import { createBridgeServer } from '../src/server.mjs';

const target = { rowId: 9, entityId: 'assistant-boundary' };
const projection = () => ({ sessionId: 'parent', logEpoch: 'source-epoch', revision: 7, availability: { fork: { allowed: true } }, rows: { window: [
  { rowId: 8, entityId: 'thinking', kind: 'reasoning', state: 'complete', actions: { canFork: true } },
  { ...target, assistantResponseId: 'message-a', kind: 'assistantText', state: 'complete', actions: { canFork: true } },
  { rowId: 10, entityId: 'streaming', kind: 'assistantText', state: 'streaming', actions: { canFork: true } },
] } });
class ForkProtocol extends EventEmitter {
  ready = true; interactions = new Map(); calls = []; acknowledgements = new Map(); lose = false; unknown = false;
  async start() {} async close() {}
  async request(method, params) {
    this.calls.push({ method, params: structuredClone(params) });
    if (method === 'v4/command') {
      const saved = JSON.parse(readFileSync(this.registryPath)).forks;
      assert.deepEqual(Object.values(saved).find(item => item.envelope.commandId === params.commandId)?.envelope, params, 'persist full envelope before write');
      assert.equal(params.type, 'forkAssistant');
      const old = this.acknowledgements.get(params.commandId), ack = old ?? { commandId: params.commandId, status: 'accepted', revisionAtDecision: 7, result: { type: 'forkAssistant', sessionId: 'child-' + this.acknowledgements.size } };
      this.acknowledgements.set(params.commandId, ack);
      if (this.lose) { this.lose = false; throw new BridgeError(504, 'runtime_timeout', 'Lost ACK', true); }
      return ack;
    }
    if (method === 'v4/commands/query') return { results: params.commands.map(key => ({ key, result: this.unknown ? 'unknown' : this.acknowledgements.get(key.commandId) ?? 'unknown' })) };
    if (method === 'session/read') return { session: { sessionId: params.sessionId, title: 'Real host fork title', status: 'completed' }, settings: { model: { current: { providerId: 'same-host', modelId: 'GLM-5.3-fork-test' } }, thoughtLevel: { current: 'max' }, mode: { current: 'build' } }, messages: [] };
    return {};
  }
}
function fixture(t, protocol = new ForkProtocol()) {
  const root = mkdtempSync(join(tmpdir(), 'zcode-fork-test-')); t.after(() => rmSync(root, { recursive: true, force: true }));
  const history = { sessions: () => [{ id: 'desktop' }], projects: () => [], latestModel: () => null };
  const options = { runtimeDir: root, acceptanceWorkspace: join(root, 'acceptance'), zcodeRoot: join(root, 'desktop'), protocol, history, ownedHistory: history };
  mkdirSync(join(options.zcodeRoot, 'v2'), { recursive: true });
  writeFileSync(join(options.zcodeRoot, 'v2/config.json'), JSON.stringify({ provider: { 'same-host': { kind: 'openai-compatible', options: { baseURL: 'https://invalid.test/v1', apiKey: 'test-only' }, models: { 'GLM-5.3-fork-test': {} } } } }));
  const service = new BridgeService(options); t.after(() => service.close()); protocol.registryPath = service.registryPath;
  service.registry.sessions.parent = { id: 'parent', title: 'Original', path: options.acceptanceWorkspace, mode: 'build', selection: { providerId: 'same-host', modelId: 'same-model', thoughtLevel: 'max' }, createdAt: new Date().toISOString(), updatedAt: new Date().toISOString(), status: 'completed' };
  service.initialized.add('parent'); service.hostActivity.ensure = async () => projection(); service.persist();
  return { service, protocol, options };
}

test('fork maps only the exact host-approved completed assistant identity', async t => {
  const { service, protocol } = fixture(t);
  assert.equal(forkRows(projection()).length, 1);
  assert.deepEqual(withForkTargets([{ id: 'message-a', role: 'assistant' }, { id: 'other', role: 'assistant' }], projection()), [{ id: 'message-a', role: 'assistant', forkTarget: target }, { id: 'other', role: 'assistant' }]);
  const result = await service.fork('parent', { clientForkId: 'fixed', target });
  assert.equal(result.parentSessionId, 'parent'); assert.equal(result.forkedSessionId, 'child-0');
  assert.equal(result.session.title, 'Real host fork title'); assert.equal(result.session.thoughtLevel, 'max');
  assert.equal(protocol.calls.find(call => call.method === 'v4/command').params.baseLogEpoch, 'source-epoch');
  await assert.rejects(service.fork('parent', { clientForkId: 'fixed', target: { rowId: 11, entityId: 'other' } }), { code: 'fork_conflict' });
  assert.equal(protocol.acknowledgements.size, 1);
});

test('fork lost ACK recovers after bridge reload without creating another child or changing its target', async t => {
  const { service, protocol, options } = fixture(t); protocol.lose = true;
  await assert.rejects(service.fork('parent', { clientForkId: 'restart' }), { code: 'runtime_timeout' });
  const envelope = structuredClone(protocol.calls.find(call => call.method === 'v4/command').params);
  const restored = new BridgeService(options); t.after(() => restored.close()); restored.initialized.add('parent');
  restored.hostActivity.ensure = async () => { throw new Error('Replay must not select a fresh boundary'); };
  const result = await restored.fork('parent', { clientForkId: 'restart' });
  assert.equal(result.forkedSessionId, 'child-0'); assert.equal(protocol.acknowledgements.size, 1);
  assert.deepEqual(protocol.calls.filter(call => call.method === 'v4/command').map(call => call.params), [envelope]);
  assert.ok(protocol.calls.some(call => call.method === 'v4/commands/query'));
});

test('fork query unknown resubmits the identical full command and returns one host child', async t => {
  const { service, protocol } = fixture(t); protocol.lose = true; protocol.unknown = true;
  await assert.rejects(service.fork('parent', { clientForkId: 'unknown' }), { code: 'runtime_timeout' });
  const result = await service.fork('parent', { clientForkId: 'unknown' });
  const sent = protocol.calls.filter(call => call.method === 'v4/command').map(call => call.params);
  assert.equal(sent.length, 2); assert.deepEqual(sent[0], sent[1]); assert.equal(result.forkedSessionId, 'child-0'); assert.equal(protocol.acknowledgements.size, 1);
  service.registry.sessions.parent.archived = true;
  assert.equal((await service.fork('parent', { clientForkId: 'unknown' })).forkedSessionId, 'child-0');
});

test('fork rejects read-only hosts, invalid or stale targets and unavailable boundaries before writing commands', async t => {
  const { service, protocol } = fixture(t);
  await assert.rejects(service.fork('desktop', { clientForkId: 'desktop' }), { code: 'session_read_only' });
  await assert.rejects(service.fork('parent', { clientForkId: 'bad', target: { rowId: -1, entityId: 'x' } }), { code: 'invalid_request' });
  await assert.rejects(service.fork('parent', { clientForkId: 'stale', target: { rowId: 9, entityId: 'changed' } }), { code: 'fork_target_stale' });
  service.hostActivity.ensure = async () => ({ ...projection(), availability: { fork: { allowed: false } } });
  await assert.rejects(service.fork('parent', { clientForkId: 'blocked' }), { code: 'fork_unavailable' });
  assert.equal(protocol.calls.length, 0);
});

test('authenticated HTTP fork route returns a distinct host-confirmed task and idempotent retries', async t => {
  const { service } = fixture(t), server = createBridgeServer({ service, token: 'test-fork-token' });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve)); t.after(() => { server.close(); server.closeAllConnections(); });
  const request = () => fetch(`http://127.0.0.1:${server.address().port}/v1/sessions/parent/fork`, { method: 'POST', headers: { Authorization: 'Bearer test-fork-token', 'Content-Type': 'application/json' }, body: JSON.stringify({ clientForkId: 'http' }) });
  const first = await request(), second = await request(); assert.equal(first.status, 201); assert.equal(second.status, 201);
  assert.equal((await first.json()).forkedSessionId, (await second.json()).forkedSessionId);
});
