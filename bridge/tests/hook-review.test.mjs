import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { randomUUID } from 'node:crypto';
import { mkdtempSync, mkdirSync, readFileSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { BridgeService } from '../src/service.mjs';
import { createBridgeServer } from '../src/server.mjs';
import { hookCanonicalJSON, hookInteractions, hookOperation, hookOperationFingerprint, validateHookReview, swiftStringCompare } from '../src/hook-review.mjs';

const golden = JSON.parse(readFileSync(new URL('../../docs/backend/evidence/hook-review-contract.json', import.meta.url), 'utf8')).vectors.request;
const copy = value => structuredClone(value), at = 1800000000000;
function review(patch = {}) { return { ...copy(golden), createdAt: at - 1000, deadlineAt: at + 600000, ...patch }; }
function bodyFor(request, action = 'respond', clientCommandId = randomUUID(), fields = {}) {
  const body = { clientCommandId, request: copy(request), ...(action === 'toggle' ? { reviewItemId: request.items[0].reviewItemId, enabled: false } : { reviewItemIds: [request.items[0].reviewItemId] }), ...fields };
  const { operation } = hookOperation(action, body, request);
  body.confirmation = { action: operation.action, fingerprint: hookOperationFingerprint(request, operation), confirmedAt: at };
  return body;
}
function projection(request, seq = 1) {
  return { protocolVersion: 1, sessionId: request.sessionId, revision: seq, seq, logEpoch: 'hook-fixture-epoch',
    pendingInteractions: [{ interactionId: request.interactionId, kind: 'workspaceHookReview', anchorRowId: null, createdAt: request.createdAt, payload: copy(request) }],
    workspaceHookAdmission: { pendingCount: request.summary.pendingCount, bundleDigest: request.bundleDigest, workspaceIdentity: request.workspaceIdentity },
    goal: null, subagents: { revision: 0, childSessionIds: [], running: [], endedTotal: 0 }, availability: {}, rows: { window: [], totalCount: 0, firstRowId: null } };
}
class SpyProtocol extends EventEmitter {
  ready = true; interactions = new Map(); calls = []; starts = 0;
  async start() { this.starts++; }
  async close() {}
  async request(method, params) {
    this.calls.push({ method, params: copy(params) });
    if (method === 'v4/command') return this.onCommand ? this.onCommand(params) : { commandId: params.commandId, status: 'accepted', revisionAtDecision: 1 };
    if (method === 'v4/commands/query') return this.onQuery ? this.onQuery(params) : { results: params.commands.map(key => ({ key, result: 'unknown' })) };
    if (method === 'v4/conversation/resync') return this.onResync ? this.onResync(params) : {};
    if (method === 'session/read') return { session: { sessionId: params.sessionId, status: 'idle' }, messages: [] };
    throw new Error('Out-of-scope protocol request: ' + method);
  }
  respond() { throw new Error('A hook review must never use the legacy permission callback.'); }
}
function fixture(t, initial = review()) {
  const root = mkdtempSync(join(tmpdir(), 'zcode-hook-test-')), runtimeDir = join(root, 'runtime'), workspace = join(root, 'workspace');
  mkdirSync(workspace);
  const transcript = () => ({ messages: [], history: { hasMore: false, beforeRowId: null, firstRowId: null, logEpoch: 'fixture', atSeq: 0, loadedRowCount: 0, totalRowCount: 0 } });
  const history = { session: id => id === 'desktop' ? { id, capabilities: { read: true } } : undefined, sessions: () => [], projects: () => [], transcript };
  const ownedHistory = { transcript, subagentSession: id => id === 'child' ? { id, source: 'bridge-subagent', capabilities: { read: true } } : undefined };
  const protocols = [], services = [], servers = [];
  function make() {
    const protocol = new SpyProtocol(), service = new BridgeService({ runtimeDir, zcodeRoot: join(root, 'empty-desktop'), acceptanceWorkspace: workspace, history, ownedHistory, protocol });
    service.hooks.now = () => at; protocols.push(protocol); services.push(service); return { service, protocol };
  }
  const { service, protocol } = make(), id = initial.sessionId;
  service.registry.sessions[id] = { id, path: workspace, title: 'Synthetic hook review acceptance', status: 'waiting', mode: 'plan',
    selection: { providerId: 'fixture', modelId: 'fixture', thoughtLevel: 'max' }, createdAt: new Date(at).toISOString(), updatedAt: new Date(at).toISOString(), archived: false };
  service.initialized.add(id); service.hostActivity.projections.set(id, projection(initial)); service.persist();
  t.after(async () => { for (const server of servers) { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); } for (const current of services) await current.close(); rmSync(root, { recursive: true, force: true }); });
  async function http() {
    const token = 'test-only-hook-token-never-a-user-credential', server = createBridgeServer({ service, token }); servers.push(server);
    await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
    const base = `http://127.0.0.1:${server.address().port}`, headers = { Authorization: 'Bearer ' + token, 'Content-Type': 'application/json' };
    const api = async (path, method = 'GET', body) => { const response = await fetch(base + path, { method, headers, ...(body === undefined ? {} : { body: JSON.stringify(body) }), signal: AbortSignal.timeout(5000) }); return { status: response.status, body: await response.json() }; };
    return { api, base, headers };
  }
  return { service, protocol, id, root, runtimeDir, make, http, initial };
}
const commands = protocol => protocol.calls.filter(call => call.method === 'v4/command');

test('hook canonical JSON matches Foundation numeric and Unicode ordering conventions', () => {
  assert.equal(hookCanonicalJSON({ z: 1e-7, a: 1e-6, b: -0, text: '汉字/😀\u2028\n\t' }), '{"a":1e-06,"b":-0,"text":"汉字/😀\u2028\\n\\t","z":1e-07}');
  assert.deepEqual(['😀', '\uE000', 'é', 'f', '\u{10000}', 'A'].sort(swiftStringCompare), ['A', 'f', 'é', '\uE000', '\u{10000}', '😀']);
  assert.throws(() => hookCanonicalJSON(Infinity), { code: 'hook_review_invalid' });
});

test('strict hook request and operation validation rejects malformed or expanded approval scope', () => {
  const value = review(); assert.equal(validateHookReview(value), value);
  for (const patch of [{ generation: 0 }, { bundleDigest: 'X'.repeat(64) }, { unknown: true }, { createdAt: NaN }, { summary: { ...value.summary, pendingCount: 0 } }, { remoteSessionId: '' }]) assert.throws(() => validateHookReview({ ...value, ...patch }), { code: 'hook_review_invalid' });
  for (const patch of [{ resolvedTimeoutMs: 0 }, { trustState: 'allow_once' }, { editable: 1 }, { matcher: false }, { displayCommand: '' }]) assert.throws(() => validateHookReview({ ...value, items: [{ ...value.items[0], ...patch }] }), { code: 'hook_review_invalid' });
  for (const ids of [[], ['missing'], [value.items[0].reviewItemId, value.items[0].reviewItemId], ['é', 'e\u0301']]) assert.throws(() => hookOperation('respond', { reviewItemIds: ids }, value), { code: 'hook_review_selection_invalid' });
  assert.throws(() => hookOperation('toggle', { reviewItemId: value.items[0].reviewItemId, enabled: true }, { ...value, items: [{ ...value.items[0], editable: false }] }), { code: 'hook_review_item_read_only' });
  assert.throws(() => hookOperation('respond', { reviewItemIds: [value.items[0].reviewItemId] }, { ...value, items: [{ ...value.items[0], trustState: 'blocked_policy' }] }), { code: 'hook_review_selection_invalid' });
});

test('detail maps genuine-shaped v4 hook requests with capability and never uses legacy permissions', async t => {
  const { service, id } = fixture(t);
  assert.equal(service.ownedDTO(service.registry.sessions[id]).capabilities.hookReview, true);
  const detail = await service.detail(id); assert.equal(detail.pendingInteractions[0].kind, 'workspaceHookReview');
  assert.deepEqual(detail.pendingInteractions[0].hookReview, review());
  assert.throws(() => service.respond(review().interactionId, { decision: 'allow' }), { code: 'hook_review_route_required' });
  service.registry.sessions[id].archived = true; assert.equal(service.ownedDTO(service.registry.sessions[id]).capabilities.hookReview, false);
  service.protocol.ready = false; assert.equal(service.ownedDTO(service.registry.sessions[id]).capabilities.hookReview, false);
  const invalid = projection(review()); invalid.pendingInteractions[0].autoResolution = {};
  assert.equal(hookInteractions(invalid, id)[0].hookReview, undefined);
  assert.equal(hookInteractions(invalid, id)[0].unsupportedReason, 'hook_review_invalid');
});

test('all four HTTP routes construct exact dedicated commands without transmitting confirmation', async t => {
  const { service, protocol, id, http, runtimeDir } = fixture(t), { api } = await http();
  protocol.onCommand = envelope => {
    const saved = JSON.parse(readFileSync(join(runtimeDir, 'sessions.json'), 'utf8')).hookCommands[envelope.commandId];
    assert.equal(saved.attempted, true); assert.deepEqual(saved.envelope, envelope);
    assert.equal(envelope.payload.sessionId, id); assert.equal(envelope.payload.confirmation, undefined); assert.equal(envelope.baseRevision, undefined);
    return { commandId: envelope.commandId, status: 'accepted', revisionAtDecision: 2 };
  };
  for (const action of ['request', 'respond', 'toggle', 'revoke']) {
    const body = action === 'request' ? { clientCommandId: randomUUID(), workspaceIdentity: review().workspaceIdentity, bundleDigest: review().bundleDigest } : bodyFor(review(), action);
    const result = await api(`/v1/sessions/${id}/hooks/review/${action}`, 'POST', body);
    assert.equal(result.status, 200); assert.equal(result.body.accepted, true); assert.equal(result.body.sessionId, id);
  }
  assert.deepEqual(commands(protocol).map(call => call.params.type), ['requestWorkspaceHookReview', 'respondWorkspaceHookReview', 'toggleWorkspaceHookReviewItem', 'revokeWorkspaceHookTrust']);
  assert.deepEqual(commands(protocol)[1].params.payload.decision, { action: 'trust_selected', reviewItemIds: ['fixture-item'] });
  assert.equal(service.registry.sessions[id].selection.thoughtLevel, 'max');
});

test('explicit confirmation, exact displayed content, and immutable target guards run before any command', async t => {
  const { service, protocol, id } = fixture(t);
  const cases = [];
  for (const change of [body => delete body.confirmation, body => { body.confirmation.fingerprint = 'a'.repeat(64); }, body => { body.confirmation.action = 'allow_once'; }, body => { body.extra = true; }, body => { body.confirmation.confirmedAt = Infinity; }]) { const body = bodyFor(review()); change(body); cases.push(body); }
  for (const patch of [{ runId: 'other-run' }, { taskId: 'other-task' }, { workspaceIdentity: 'other-workspace' }, { bundleDigest: 'b'.repeat(64) }, { remoteSessionId: 'other-remote' },
    { items: [{ ...review().items[0], displayCommand: 'CHANGED_AFTER_DISPLAY' }] }, { sourceFiles: [{ ...review().sourceFiles[0], displayPath: 'different file' }] }]) cases.push(bodyFor(review(patch)));
  for (const body of cases) await assert.rejects(service.hookReview(id, 'respond', body));
  assert.equal(protocol.calls.length, 0); assert.equal(Object.keys(service.registry.hookCommands).length, 0);
});

test('old generation, settled review, expiry and admission mismatch cannot reuse approval', async t => {
  const { service, protocol, id } = fixture(t), body = bodyFor(review());
  service.hostActivity.projections.set(id, projection(review({ generation: 2, interactionId: 'new-review' })));
  await assert.rejects(service.hookReview(id, 'respond', body), { code: 'workspace_hooks_review_superseded' });
  service.hostActivity.projections.set(id, { ...projection(review()), pendingInteractions: [] });
  await assert.rejects(service.hookReview(id, 'respond', body), { code: 'workspace_hooks_review_superseded' });
  service.hostActivity.projections.set(id, projection(review())); service.hooks.now = () => at + 600001;
  await assert.rejects(service.hookReview(id, 'respond', body), { code: 'hook_review_expired' });
  service.hooks.now = () => at; const p = projection(review()); p.workspaceHookAdmission.bundleDigest = 'b'.repeat(64); service.hostActivity.projections.set(id, p);
  await assert.rejects(service.hookReview(id, 'respond', body), { code: 'workspace_hooks_bundle_changed' });
  assert.equal(commands(protocol).length, 0);
});

test('read-only desktop, derived child, archived task, unknown IDs and expanded request scope cannot control hooks', async t => {
  const { service, protocol, id } = fixture(t);
  for (const task of ['desktop', 'child']) await assert.rejects(service.hookReview(task, 'respond', bodyFor(review())), { code: 'session_read_only' });
  await assert.rejects(service.hookReview('unknown', 'respond', bodyFor(review())), { code: 'not_found' });
  service.registry.sessions[id].archived = true;
  await assert.rejects(service.hookReview(id, 'respond', bodyFor(review())), { code: 'session_archived' });
  service.registry.sessions[id].archived = false;
  for (const patch of [{ workspaceIdentity: 'elsewhere' }, { bundleDigest: 'b'.repeat(64) }, { remoteSessionId: 'unverified-remote' }]) await assert.rejects(service.hookReview(id, 'request', { clientCommandId: randomUUID(), workspaceIdentity: review().workspaceIdentity, bundleDigest: review().bundleDigest, ...patch }), { code: 'workspace_hooks_snapshot_mismatch' });
  assert.equal(commands(protocol).length, 0);
});

test('same and concurrent new client IDs reuse one admitted whole-request operation', async t => {
  const { service, protocol, id } = fixture(t), first = bodyFor(review());
  const results = await Promise.all([service.hookReview(id, 'respond', first), service.hookReview(id, 'respond', { ...first, clientCommandId: randomUUID() })]);
  assert.deepEqual(results[0], results[1]); assert.equal(commands(protocol).length, 1);
  service.registry.sessions[id].archived = true; service.hostActivity.projections.clear(); service.initialized.clear(); service.hooks.now = () => at + 99999999;
  assert.deepEqual(await service.hookReview(id, 'respond', { ...first, clientCommandId: randomUUID() }), results[0]);
  assert.equal(commands(protocol).length, 1); assert.equal(protocol.calls.length, 1);
  const changed = bodyFor(review(), 'toggle', first.clientCommandId);
  await assert.rejects(service.hookReview(id, 'toggle', changed), { code: 'hook_review_conflict' });
});

test('lost ACK followed by a new UI UUID queries the old command without executing it again', async t => {
  const { service, protocol, id } = fixture(t), first = bodyFor(review()); let acknowledgement;
  protocol.onCommand = envelope => { acknowledgement = { commandId: envelope.commandId, status: 'accepted', revisionAtDecision: 1 }; throw new Error('simulated lost ACK'); };
  await assert.rejects(service.hookReview(id, 'respond', first), { code: 'hook_review_uncertain' });
  protocol.onQuery = ({ commands: keys }) => ({ results: keys.map(key => ({ key, result: acknowledgement })) });
  service.hostActivity.projections.clear(); service.initialized.clear();
  const result = await service.hookReview(id, 'respond', { ...first, clientCommandId: randomUUID() });
  assert.equal(result.acknowledgement.commandId, acknowledgement.commandId); assert.equal(commands(protocol).length, 1);
  assert.deepEqual(protocol.calls.map(call => call.method), ['v4/command', 'v4/commands/query']);
});

test('unknown result replays the exact original envelope only while the same review remains current', async t => {
  const { service, protocol, id } = fixture(t), first = bodyFor(review());
  protocol.onCommand = () => { throw new Error('simulated connection failure'); };
  await assert.rejects(service.hookReview(id, 'respond', first), { code: 'hook_review_uncertain' });
  const envelope = copy(commands(protocol)[0].params);
  protocol.onCommand = command => ({ commandId: command.commandId, status: 'accepted', revisionAtDecision: 1 });
  await service.hookReview(id, 'respond', { ...first, clientCommandId: randomUUID() });
  assert.deepEqual(commands(protocol)[1].params, envelope); assert.equal(Object.keys(service.registry.hookCommands).length, 1);
});

test('unknown result after review replacement or runtime restart never generates another command', async t => {
  const { service, protocol, id, make } = fixture(t), first = bodyFor(review());
  protocol.onCommand = () => { throw new Error('simulated connection failure'); };
  await assert.rejects(service.hookReview(id, 'respond', first), { code: 'hook_review_uncertain' });
  service.hostActivity.projections.set(id, projection(review({ generation: 2, interactionId: 'new-review' })));
  await assert.rejects(service.hookReview(id, 'respond', { ...first, clientCommandId: randomUUID() }), { code: 'workspace_hooks_review_superseded' });
  assert.equal(commands(protocol).length, 1);
  const restarted = make();
  await assert.rejects(restarted.service.hookReview(id, 'respond', { ...first, clientCommandId: randomUUID() }), { code: 'hook_review_uncertain' });
  assert.deepEqual(restarted.protocol.calls.map(call => call.method), ['v4/commands/query']);
});

test('durable original command is recovered after bridge object restart without session resume', async t => {
  const { service, protocol, id, make } = fixture(t), first = bodyFor(review()); let acknowledgement;
  protocol.onCommand = command => { acknowledgement = { commandId: command.commandId, status: 'accepted', revisionAtDecision: 5 }; throw new Error('lost response'); };
  await assert.rejects(service.hookReview(id, 'respond', first), { code: 'hook_review_uncertain' });
  const restarted = make(); restarted.protocol.onQuery = ({ commands: keys }) => ({ results: keys.map(key => ({ key, result: acknowledgement })) });
  assert.equal((await restarted.service.hookReview(id, 'respond', { ...first, clientCommandId: randomUUID() })).acknowledgement.commandId, acknowledgement.commandId);
  assert.deepEqual(restarted.protocol.calls.map(call => call.method), ['v4/commands/query']);
});

test('definite host rejection is retained; only another explicit client ID may start a new attempt', async t => {
  const { service, protocol, id } = fixture(t), first = bodyFor(review());
  protocol.onCommand = command => ({ commandId: command.commandId, status: 'rejected', reasonCode: 'workspace_hooks_blocked_by_policy', message: 'Fixture policy refusal', revisionAtDecision: 1 });
  await assert.rejects(service.hookReview(id, 'respond', first), { code: 'workspace_hooks_blocked_by_policy' });
  await assert.rejects(service.hookReview(id, 'respond', first), { code: 'workspace_hooks_blocked_by_policy' });
  assert.equal(commands(protocol).length, 1);
  protocol.onCommand = command => ({ commandId: command.commandId, status: 'accepted', revisionAtDecision: 2 });
  await service.hookReview(id, 'respond', { ...first, clientCommandId: randomUUID() });
  assert.equal(commands(protocol).length, 2); assert.notEqual(commands(protocol)[0].params.commandId, commands(protocol)[1].params.commandId);
});

test('failure to persist authorization and foreign acknowledgements never become success', async t => {
  const { service, protocol, id } = fixture(t), persist = service.persist.bind(service);
  service.persist = () => { throw new Error('Synthetic disk write failure'); };
  await assert.rejects(service.hookReview(id, 'respond', bodyFor(review())), /Synthetic disk/); assert.equal(protocol.calls.length, 0);
  service.registry.hookCommands = Object.create(null); service.persist = persist;
  protocol.onCommand = () => ({ commandId: 'another-command', status: 'accepted' });
  await assert.rejects(service.hookReview(id, 'respond', bodyFor(review())), { code: 'hook_review_uncertain' });
  assert.equal(Object.values(service.registry.hookCommands)[0].acknowledgement, undefined);
});

test('projection-only review/admission changes emit real HTTP SSE and refresh pending detail', async t => {
  const { service, protocol, id, http } = fixture(t), { api, base, headers } = await http();
  const initial = projection(review()); initial.pendingInteractions = []; initial.workspaceHookAdmission = null;
  service.hostActivity.projections.set(id, initial); service.hostActivity.subscriptions.set('hook-subscription', id);
  const controller = new AbortController(), response = await fetch(base + '/v1/events', { headers, signal: controller.signal }), reader = response.body.getReader();
  let wire = new TextDecoder().decode((await reader.read()).value); assert.match(wire, /event: ready/);
  const push = (next, ordinal) => protocol.emit('conversationFrame', { wireVersion: 3, topic: 'conversation/' + id, subscriptionId: 'hook-subscription', kind: 'complete',
    logicalFrameId: 'hook-frame-' + ordinal, logicalFrameOrdinal: ordinal, deliveryKind: 'online', frame: { topic: 'conversation/' + id, subscriptionId: 'hook-subscription', fromSeq: ordinal, toSeq: ordinal + 1, payload: { kind: 'snapshot', snapshot: next } } });
  push(projection(review(), 2), 1);
  assert.equal((await api('/v1/sessions/' + id)).body.pendingInteractions[0].hookReview.interactionId, review().interactionId);
  push(projection(review({ interactionId: 'second-review', generation: 2 }), 3), 2);
  const settled = projection(review(), 4); settled.pendingInteractions = []; settled.workspaceHookAdmission = null; push(settled, 3);
  await new Promise(resolve => setImmediate(resolve));
  const entries = service.events.entries;
  assert.equal(entries.filter(event => event.type === 'interaction.requested').length, 2);
  assert.equal(entries.filter(event => event.type === 'interaction.resolved').length, 2);
  assert.ok(entries.some(event => event.type === 'host.activity' && event.data.hostActivity.workspaceHookAdmission?.pendingCount === 1));
  assert.equal((await api('/v1/sessions/' + id)).body.pendingInteractions.length, 0);
  wire += new TextDecoder().decode((await reader.read()).value); assert.match(wire, /event: interaction.requested/); assert.match(wire, /workspaceHookReview/);
  controller.abort(); await reader.cancel().catch(() => {});
  assert.equal(commands(protocol).length, 0);
});

test('admitted hook command resyncs the actual projection and publishes its settled interaction', async t => {
  const { service, protocol, id } = fixture(t);
  service.hostActivity.subscriptions.set('hook-ack-subscription', id);
  protocol.onResync = params => {
    assert.equal(params.forceSnapshot, true); assert.equal(params.base, null);
    const settled = projection(review(), 2); settled.pendingInteractions = []; settled.workspaceHookAdmission = null;
    protocol.emit('conversationFrame', { wireVersion: 3, topic: 'conversation/' + id, subscriptionId: 'hook-ack-subscription', kind: 'complete',
      logicalFrameId: 'hook-after-ack', logicalFrameOrdinal: 1, deliveryKind: 'recovery', frame: { topic: 'conversation/' + id,
        subscriptionId: 'hook-ack-subscription', fromSeq: 1, toSeq: 2, payload: { kind: 'snapshot', snapshot: settled } } });
    return {};
  };
  const result = await service.hookReview(id, 'respond', bodyFor(review()));
  assert.equal(result.accepted, true);
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(service.hostActivity.stale.has(id), false);
  assert.equal((await service.detail(id)).pendingInteractions.length, 0);
  assert.equal(service.registry.sessions[id].status, 'idle');
  assert.ok(service.events.entries.some(event => event.type === 'interaction.resolved' && event.data.interactionId === review().interactionId));
  assert.equal(protocol.calls.filter(call => call.method === 'v4/conversation/resync').length, 1);
  assert.equal(commands(protocol).length, 1);
});

test('request-only reopening after settlement uses a new command while its original client ID remains idempotent', async t => {
  const { service, protocol, id, http } = fixture(t), { api } = await http();
  const path = `/v1/sessions/${id}/hooks/review/request`;
  const first = { clientCommandId: randomUUID(), workspaceIdentity: review().workspaceIdentity, bundleDigest: review().bundleDigest };
  const initial = await api(path, 'POST', first); assert.equal(initial.status, 200);
  const settled = projection(review(), 2); settled.pendingInteractions = []; service.hostActivity.projections.set(id, settled);
  const reopened = await api(path, 'POST', { ...first, clientCommandId: randomUUID() });
  assert.equal(reopened.status, 200); assert.equal(commands(protocol).length, 2);
  assert.notEqual(reopened.body.acknowledgement.commandId, initial.body.acknowledgement.commandId);
  assert.deepEqual((await api(path, 'POST', first)).body, initial.body); assert.equal(commands(protocol).length, 2);
  assert.equal(Object.keys(service.registry.hookCommands).length, 2);
});

test('request-only unknown outcome with a new UUID reconciles the original command before a later explicit reopening', async t => {
  const { service, protocol, id } = fixture(t);
  const first = { clientCommandId: randomUUID(), workspaceIdentity: review().workspaceIdentity, bundleDigest: review().bundleDigest };
  let acknowledgement;
  protocol.onCommand = envelope => { acknowledgement = { commandId: envelope.commandId, status: 'accepted' }; throw new Error('Lost request-only ACK'); };
  await assert.rejects(service.hookReview(id, 'request', first), { code: 'hook_review_uncertain' });
  protocol.onQuery = ({ commands: keys }) => ({ results: keys.map(key => ({ key, result: acknowledgement })) });
  const reconciled = await service.hookReview(id, 'request', { ...first, clientCommandId: randomUUID() });
  assert.equal(reconciled.acknowledgement.commandId, acknowledgement.commandId); assert.equal(commands(protocol).length, 1);
  assert.equal(Object.keys(service.registry.hookCommands).length, 1);
  protocol.onCommand = envelope => ({ commandId: envelope.commandId, status: 'accepted' });
  const reopened = await service.hookReview(id, 'request', { ...first, clientCommandId: randomUUID() });
  assert.notEqual(reopened.acknowledgement.commandId, acknowledgement.commandId); assert.equal(commands(protocol).length, 2);
  assert.equal(protocol.calls.filter(call => call.method === 'v4/commands/query').length, 1);
});

function emitSettled(protocol, id, subscriptionId, ordinal = 1) {
  const settled = projection(review(), ordinal + 1); settled.pendingInteractions = []; settled.workspaceHookAdmission = null;
  protocol.emit('conversationFrame', { wireVersion: 3, topic: 'conversation/' + id, subscriptionId, kind: 'complete',
    logicalFrameId: `hook-reconciled-${ordinal}`, logicalFrameOrdinal: ordinal, deliveryKind: 'recovery',
    frame: { topic: 'conversation/' + id, subscriptionId, fromSeq: ordinal, toSeq: ordinal + 1, payload: { kind: 'snapshot', snapshot: settled } } });
}

test('queried admitted hook ACKs resync existing subscriptions and settle pending detail without another command', async t => {
  for (const status of ['accepted', 'duplicate', 'noop']) {
    const { service, protocol, id } = fixture(t), body = bodyFor(review()), subscription = 'hook-query-' + status;
    service.hostActivity.subscriptions.set(subscription, id);
    let acknowledgement;
    protocol.onCommand = envelope => { acknowledgement = { commandId: envelope.commandId, status, revisionAtDecision: 2 }; throw new Error('Lost hook ACK'); };
    await assert.rejects(service.hookReview(id, 'respond', body), { code: 'hook_review_uncertain' });
    protocol.onQuery = ({ commands: keys }) => ({ results: keys.map(key => ({ key, result: acknowledgement })) });
    protocol.onResync = params => { assert.equal(params.forceSnapshot, true); assert.equal(params.base, null); emitSettled(protocol, id, subscription); return {}; };
    const result = await service.hookReview(id, 'respond', { ...body, clientCommandId: randomUUID() });
    assert.equal(result.accepted, true); await new Promise(resolve => setImmediate(resolve));
    assert.equal(protocol.calls.filter(call => call.method === 'v4/conversation/resync').length, 1);
    assert.equal((await service.detail(id)).pendingInteractions.length, 0); assert.equal(service.registry.sessions[id].status, 'idle');
    assert.ok(service.events.entries.some(event => event.type === 'interaction.resolved' && event.data.interactionId === review().interactionId));
    assert.equal(commands(protocol).length, 1);
  }
});

test('cached admitted hook ACK retries refresh a stale subscription without resending the command', async t => {
  const { service, protocol, id } = fixture(t), body = bodyFor(review()), subscription = 'hook-cached-ack';
  service.hostActivity.subscriptions.set(subscription, id);
  protocol.onResync = () => ({}); // The first response does not deliver the requested projection.
  const original = await service.hookReview(id, 'respond', body);
  await new Promise(resolve => setImmediate(resolve)); assert.equal(service.hostActivity.stale.has(id), true);
  protocol.onResync = () => { emitSettled(protocol, id, subscription); return {}; };
  assert.deepEqual(await service.hookReview(id, 'respond', body), original);
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(protocol.calls.filter(call => call.method === 'v4/conversation/resync').length, 2);
  assert.equal(service.hostActivity.stale.has(id), false); assert.equal((await service.detail(id)).pendingInteractions.length, 0);
  assert.equal(commands(protocol).length, 1);
});

test('hook writes recheck ownership and archive state after asynchronous initialization or projection reads', async t => {
  for (const waitAt of ['initialize', 'projection']) {
    const { service, protocol, id } = fixture(t); service.registry.sessions[id].status = 'idle'; service.persist();
    let entered, resume;
    const waiting = new Promise(resolve => { entered = resolve; }), blocked = new Promise(resolve => { resume = resolve; });
    const delay = async () => { entered(); await blocked; };
    if (waitAt === 'initialize') service.ensureInitialized = delay;
    else service.hostActivity.ensure = async () => { await delay(); return projection(review()); };
    const operation = service.hookReview(id, 'respond', bodyFor(review()));
    await waiting; await service.metadata(id, { archived: true }); resume();
    await assert.rejects(operation, { code: 'session_archived' });
    assert.equal(service.registry.sessions[id].archived, true); assert.equal(commands(protocol).length, 0);
    assert.equal(Object.keys(service.registry.hookCommands).length, 0);
  }
  const { service, protocol, id } = fixture(t);
  service.hostActivity.ensure = async () => { delete service.registry.sessions[id]; return projection(review()); };
  await assert.rejects(service.hookReview(id, 'respond', bodyFor(review())), { code: 'not_found' });
  assert.equal(commands(protocol).length, 0); assert.equal(Object.keys(service.registry.hookCommands).length, 0);
});

test('hook requests changed by credential redaction expose only a non-actionable HTTP and SSE fallback', async t => {
  const placeholder = 'Bearer synthetic-qa-placeholder-not-a-real-key';
  const redactedReview = review({ items: [{ ...review().items[0], displayCommand: `printf '${placeholder}'` }] });
  const { service, protocol, id, http } = fixture(t, redactedReview), { api, base, headers } = await http();
  const detail = await api('/v1/sessions/' + id), pending = detail.body.pendingInteractions[0];
  assert.equal(detail.status, 200); assert.equal(pending.kind, 'workspaceHookReview');
  assert.equal(pending.hookReview, undefined); assert.equal(pending.unsupportedReason, 'hook_review_redacted');
  assert.equal(JSON.stringify(detail.body).includes(placeholder), false);
  for (const action of ['respond', 'toggle', 'revoke']) {
    const reply = await api(`/v1/sessions/${id}/hooks/review/${action}`, 'POST', bodyFor(redactedReview, action));
    assert.equal(reply.status, 422); assert.equal(reply.body.error.code, 'hook_review_redacted');
  }
  const initial = projection(review()); initial.pendingInteractions = []; initial.workspaceHookAdmission = null;
  service.hostActivity.projections.set(id, initial); service.hostActivity.subscriptions.set('hook-sensitive-subscription', id);
  const controller = new AbortController(), response = await fetch(base + '/v1/events', { headers, signal: controller.signal }), reader = response.body.getReader();
  const decoder = new TextDecoder(); let wire = decoder.decode((await reader.read()).value, { stream: true });
  protocol.emit('conversationFrame', { wireVersion: 3, topic: 'conversation/' + id, subscriptionId: 'hook-sensitive-subscription', kind: 'complete',
    logicalFrameId: 'hook-redaction-frame', logicalFrameOrdinal: 1, deliveryKind: 'online', frame: { topic: 'conversation/' + id,
      subscriptionId: 'hook-sensitive-subscription', fromSeq: 1, toSeq: 2, payload: { kind: 'snapshot', snapshot: projection(redactedReview, 2) } } });
  wire += decoder.decode((await reader.read()).value, { stream: true });
  assert.match(wire, /interaction.requested/); assert.match(wire, /hook_review_redacted/);
  assert.equal(wire.includes(placeholder), false);
  const requested = wire.split('\n').filter(line => line.startsWith('data: ')).map(line => JSON.parse(line.slice(6))).filter(event => event.type === 'interaction.requested');
  assert.equal(requested.length, 1); assert.equal(requested[0].data.interaction.hookReview, undefined);
  controller.abort(); await reader.cancel().catch(() => {});
  assert.equal(commands(protocol).length, 0); assert.equal(Object.keys(service.registry.hookCommands).length, 0);
});
