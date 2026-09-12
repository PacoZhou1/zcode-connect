import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync, rmSync, statSync, symlinkSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { execFileSync } from 'node:child_process';
import { request as httpRequest } from 'node:http';
import { BridgeService } from '../src/service.mjs';
import { ZCodeProtocol } from '../src/protocol.mjs';
import { createBridgeServer } from '../src/server.mjs';
import { HistoryReader, normalizeMessages } from '../src/history.mjs';
import { DatabaseSync } from 'node:sqlite';
import { EventJournal } from '../src/events.mjs';
import { AttachmentStore } from '../src/attachments.mjs';
import { listWorkspaceFiles, readWorkspaceFile, searchWorkspaceFiles } from '../src/files.mjs';
import { ensureToken, authorized, sanitize, projectId } from '../src/util.mjs';
import { acquireRuntimeLock } from '../src/runtime-lock.mjs';
import { workspaceChanges } from '../src/git.mjs';

const temp = t => { const root = mkdtempSync(join(tmpdir(), 'zcode-mobile-test-')); t.after(() => rmSync(root, { recursive: true, force: true })); return root; };
class FakeProtocol extends EventEmitter {
  ready = true; interactions = new Map(); calls = [];
  async start() {}
  async close() {}
  async request(method, params) {
    this.calls.push({ method, params });
    if (method === 'session/create') return { session: { sessionId: `owned_${this.calls.length}`, createdAt: Date.now(), status: 'idle' }, messages: [] };
    if (method === 'session/read' || method === 'session/resume') return { session: { sessionId: params.sessionId, status: 'idle' }, messages: [] };
    if (method === 'v4/command') { await new Promise(resolve => setTimeout(resolve, 5)); return { commandId: params.commandId, status: 'accepted', revisionAtDecision: 1 }; }
    await new Promise(resolve => setTimeout(resolve, 5)); return {};
  }
}
function fixture(t) {
  const root = temp(t), zcodeRoot = join(root, 'desktop'), runtimeDir = join(root, 'runtime'), acceptanceWorkspace = join(runtimeDir, 'acceptance-workspace');
  mkdirSync(join(zcodeRoot, 'v2'), { recursive: true });
  const config = { provider: { local: {
    name: 'Test model', kind: 'openai-compatible', options: { baseURL: 'https://provider.invalid/v1', apiKey: 'PRIVATE_TEST_SENTINEL' },
    models: { 'GLM-5.3-test': { limit: { context: 10000 }, modalities: { input: ['text', 'image'] } } },
  } } };
  writeFileSync(join(zcodeRoot, 'v2/config.json'), JSON.stringify(config));
  const protocol = new FakeProtocol();
  const desktop = { id: 'desktop_1', title: 'Desktop', projectId: projectId(root), projectName: 'Desktop', workspacePath: root, updatedAt: new Date().toISOString(), capabilities: { read: true, send: false } };
  const history = { sessions: () => [desktop], projects: () => [{ id: projectId(root), name: 'Desktop', path: root, sessionCount: 1 }], messages: () => [], transcript: () => ({ messages: [], history: { hasMore: false, beforeRowId: null, firstRowId: null, logEpoch: 'fixture', atSeq: 0, loadedRowCount: 0, totalRowCount: 0 } }), latestModel: () => ({ providerId: 'local', modelId: 'GLM-5.3-test', thoughtLevel: 'max' }) };
  const service = new BridgeService({ root, zcodeRoot, runtimeDir, acceptanceWorkspace, protocol, history, ownedHistory: history });
  t.after(() => service.close()); return { service, protocol, root, acceptanceWorkspace };
}

test('message IDs remain unique and stable across protocol and database shapes', () => {
  const rows = [{ info: { messageId: 'user_1', role: 'user', time: { created: 100 } }, parts: [{ type: 'text', text: 'Hello' }] }, { info: { messageId: 'assistant_1', role: 'assistant', time: { created: 200 } }, parts: [{ type: 'text', text: 'First chunk' }] }];
  const before = normalizeMessages(rows), after = normalizeMessages([{ ...rows[1], parts: [{ type: 'text', text: 'More text' }] }]);
  assert.deepEqual(before.map(m => m.id), ['user_1', 'assistant_1']); assert.equal(after[0].id, before[1].id); assert.equal(after[0].isStreaming, true);
  assert.equal(normalizeMessages([{ info: { id: 'database_1', role: 'assistant', finish: 'stop', time: { created: 200 } }, parts: [{ type: 'text', text: 'Finished' }] }])[0].id, 'database_1');
});

test('host visibility metadata hides control reminders while preserving real user text and controlOnly inputs', () => {
  const evidence = JSON.parse(readFileSync(new URL('../../docs/backend/evidence/goal-control-message-metadata.json', import.meta.url), 'utf8'));
  const rows = evidence.rows.map(row => ({ info: { ...row.info, id: row.id }, parts: row.parts.map(part => ({ ...part.data, id: part.id })) }));
  const messages = normalizeMessages(rows);
  assert.equal(messages.length, 1); assert.equal(messages[0].role, 'user'); assert.match(messages[0].text, /^\/goal /);
  const reminderText = rows[1].parts[0].text;
  const visible = { info: { id: 'real-user', role: 'user', semantics: { origin: 'real_user', uiVisibility: 'visible', transcriptVisibility: 'visible' } }, parts: [{ type: 'text', text: reminderText }] };
  assert.equal(normalizeMessages([visible])[0].text, reminderText);
  const mixed = { info: { id: 'mixed', role: 'assistant' }, parts: [{ type: 'text', text: 'Visible' }, { type: 'text', text: 'Hidden', metadata: { visibility: 'model-only' } }, { type: 'text', text: 'Hidden semantic', semantics: { uiVisibility: 'hidden' } }] };
  assert.equal(normalizeMessages([mixed])[0].text, 'Visible');
  for (const metadata of [{ semantics: { uiVisibility: 'hidden' } }, { semantics: { transcriptVisibility: 'hidden' } }, { visibility: 'model-only' }, { metadata: { visibility: 'model-only' } }]) {
    assert.deepEqual(normalizeMessages([{ ...visible, info: { ...visible.info, ...metadata } }]), []);
  }
  assert.equal(normalizeMessages([{ ...visible, info: { ...visible.info, synthetic: true } }]).length, 1);
});

test('authentication is constant length checked and tokens use private file permissions', t => {
  const tokenPath = join(temp(t), 'pairing-token'), token = ensureToken(tokenPath);
  assert.equal(statSync(tokenPath).mode & 0o777, 0o600); assert.equal(ensureToken(tokenPath), token);
  assert.equal(authorized(`Bearer ${token}`, token), true); assert.equal(authorized('Bearer wrong', token), false); assert.equal(authorized(undefined, token), false);
  assert.deepEqual(sanitize({ apiKey: 'sensitive', nested: { Authorization: 'sensitive' }, text: 'Bearer abc.def' }), { apiKey: '[redacted]', nested: { Authorization: '[redacted]' }, text: 'Bearer [redacted]' });
});

test('desktop-owned sessions reject every control path without a protocol call', async t => {
  const { service, protocol } = fixture(t);
  for (const operation of [() => service.send('desktop_1', 'Hello'), () => service.stop('desktop_1'), () => service.metadata('desktop_1', { title: 'Changed' }), () => service.metadata('desktop_1', { unread: true }), () => service.updateSettings('desktop_1', { mode: 'plan' }), () => service.upload('desktop_1', {})]) await assert.rejects(async () => operation(), { code: 'session_read_only' });
  assert.equal(protocol.calls.length, 0);
  await assert.rejects(service.metadata('__proto__', { pinned: true }), { code: 'not_found' }); assert.equal(Object.prototype.pinned, undefined);
});

test('empty draft rename stays explicit bridge metadata until real persistence then synchronizes the runtime title', async t => {
  const { service, protocol, acceptanceWorkspace } = fixture(t);
  const created = await service.create({ project: projectId(acceptanceWorkspace) });
  assert.equal(protocol.calls.find(call => call.method === 'session/create').params.persistence, 'deferred');
  let persisted = false;
  service.ownedHistory.hasSession = () => persisted;
  const count = protocol.calls.length;
  const changed = await service.metadata(created.id, { title: 'Named empty draft' });
  assert.equal(changed.metadataScope, 'bridge'); assert.equal(changed.runtimeTitleStatus, 'pending-persistence');
  assert.equal(service.registry.sessions[created.id].pendingRuntimeTitle, 'Named empty draft'); assert.equal(protocol.calls.length, count);
  await service.syncPendingTitle(created.id); assert.equal(protocol.calls.length, count);
  const request = protocol.request.bind(protocol);
  protocol.request = async (method, params, ...rest) => {
    const result = await request(method, params, ...rest);
    if (method === 'session/read') result.session.title = 'Named empty draft';
    return result;
  };
  persisted = true; await service.syncPendingTitle(created.id);
  assert.equal(service.registry.sessions[created.id].pendingRuntimeTitle, undefined);
  assert.equal(protocol.calls.filter(call => call.method === 'v4/command' && call.params.type === 'renameSession').length, 1);
  assert.equal(protocol.calls.some(call => call.method === 'v4/command' && call.params.type === 'sendText'), false);
});

test('bridge unread markers persist without runtime calls and compare-and-clear preserves a newer marker', async t => {
  const { service, protocol, acceptanceWorkspace } = fixture(t), created = await service.create({ project: projectId(acceptanceWorkspace) });
  const calls = protocol.calls.length;
  assert.equal(created.unread, false); assert.equal(created.unreadAt, null); assert.equal(created.unreadScope, 'bridge');
  const first = await service.metadata(created.id, { unread: true });
  assert.equal(first.session.unread, true); assert.equal(first.session.unreadScope, 'bridge'); assert.equal(first.unreadApplied, true);
  assert.equal(Number.isSafeInteger(first.session.unreadAt), true);
  const newer = await service.metadata(created.id, { unread: true });
  assert.ok(newer.session.unreadAt > first.session.unreadAt);
  const stale = await service.metadata(created.id, { unread: false, expectedUnreadAt: first.session.unreadAt });
  assert.equal(stale.unreadApplied, false); assert.equal(stale.session.unreadAt, newer.session.unreadAt);
  const restored = new BridgeService({ runtimeDir: service.runtimeDir, zcodeRoot: service.zcodeRoot, acceptanceWorkspace, protocol: new FakeProtocol(), history: service.history, ownedHistory: service.ownedHistory });
  t.after(() => restored.close());
  assert.equal(restored.ownedDTO(restored.registry.sessions[created.id]).unreadAt, newer.session.unreadAt);
  const cleared = await restored.metadata(created.id, { unread: false, expectedUnreadAt: newer.session.unreadAt });
  assert.equal(cleared.session.unread, false); assert.equal(cleared.session.unreadAt, null); assert.equal(cleared.unreadApplied, true);
  for (const body of [{ unread: false }, { unread: false, expectedUnreadAt: 1.5 }, { unread: true, expectedUnreadAt: 1 }, { unread: 'true' }]) {
    await assert.rejects(service.metadata(created.id, body), { code: 'invalid_request' });
  }
  assert.equal(protocol.calls.length, calls); assert.equal(restored.protocol.calls.length, 0);
});

test('desktop unread timestamps are exposed read-only with exact millisecond precision', t => {
  const root = temp(t); mkdirSync(join(root, 'cli/db'), { recursive: true }); mkdirSync(join(root, 'v2'), { recursive: true });
  const sessions = new DatabaseSync(join(root, 'cli/db/db.sqlite')), tasks = new DatabaseSync(join(root, 'v2/tasks-index.sqlite'));
  t.after(() => { sessions.close(); tasks.close(); });
  sessions.exec("CREATE TABLE session(id TEXT,title TEXT,path TEXT,directory TEXT,time_created INTEGER,time_updated INTEGER,summary_additions INTEGER,summary_deletions INTEGER,parent_id TEXT,time_archived INTEGER,task_type TEXT)");
  sessions.prepare('INSERT INTO session VALUES(?,?,?,?,?,?,?,?,?,?,?)').run('desktop-unread', 'Task', root, root, 1000, 2000, 0, 0, null, null, 'interactive');
  tasks.exec('CREATE TABLE tasks(task_id TEXT,title TEXT,task_status TEXT,model TEXT,mode TEXT,archived INTEGER,deleted INTEGER,unread_at INTEGER)');
  tasks.prepare('INSERT INTO tasks VALUES(?,?,?,?,?,?,?,?)').run('desktop-unread', 'Task', 'completed', 'host/model', 'build', 0, 0, 1700000000123);
  const item = new HistoryReader(root).session('desktop-unread');
  assert.equal(item.unread, true); assert.equal(item.unreadAt, 1700000000123); assert.equal(item.unreadScope, 'desktop'); assert.equal(item.capabilities.markUnread, false);
  assert.equal(tasks.prepare('SELECT unread_at FROM tasks WHERE task_id = ?').get('desktop-unread').unread_at, 1700000000123);
});

test('concurrent retries start exactly one turn and reject conflicting payloads', async t => {
  const { service, protocol, acceptanceWorkspace } = fixture(t), session = await service.create({ project: projectId(acceptanceWorkspace) });
  const results = await Promise.all([service.send(session.id, 'Same input', 'same-id'), service.send(session.id, 'Same input', 'same-id')]);
  assert.equal(results.filter(result => result.duplicate).length, 1); assert.equal(protocol.calls.filter(call => call.method === 'v4/command' && call.params.type === 'sendText').length, 1);
  await assert.rejects(service.send(session.id, 'Different input', 'same-id'), { code: 'input_conflict' });
  await assert.rejects(service.send(session.id, 'New input', 'new-id'), { code: 'session_busy' });
  assert.equal(service.registry.sessions[session.id].selection.thoughtLevel, 'max');
});

test('uncertain sends retain their deduplication key and cannot silently repeat', async t => {
  const { service, protocol, acceptanceWorkspace } = fixture(t), session = await service.create({ project: projectId(acceptanceWorkspace) });
  protocol.request = async method => { if (method === 'v4/command') throw Object.assign(new Error('timeout'), { code: 'runtime_timeout' }); return {}; };
  await assert.rejects(service.send(session.id, 'Hello', 'uncertain'), { code: 'runtime_timeout' });
  await assert.rejects(service.send(session.id, 'Hello', 'uncertain'), { code: 'input_pending' });
});

test('concurrent task creation reuses one persisted draft ID and rejects changed intent', async t => {
  const { service, protocol, acceptanceWorkspace } = fixture(t), body = { project: projectId(acceptanceWorkspace), title: 'Draft', clientDraftId: 'draft-one' };
  const [first, second] = await Promise.all([service.create(body), service.create({ ...body, mode: 'build' })]);
  assert.equal(first.id, second.id); assert.equal(protocol.calls.filter(call => call.method === 'session/create').length, 1);
  service.history.latestModel = () => ({ providerId: 'local', modelId: 'GLM-5.3-test', thoughtLevel: 'high' });
  const retry = await service.create(body); assert.equal(retry.id, first.id); assert.equal(retry.thoughtLevel, 'max');
  for (const change of [{ title: 'Changed' }, { mode: 'plan' }, { model: { providerId: 'local', modelId: 'GLM-5.3-test', thoughtLevel: 'max' } }, { project: 'different-project' }]) await assert.rejects(service.create({ ...body, ...change }), { code: 'draft_conflict' });
  const restoredProtocol = new FakeProtocol(), restored = new BridgeService({ runtimeDir: service.runtimeDir, zcodeRoot: service.zcodeRoot, acceptanceWorkspace, protocol: restoredProtocol, history: service.history, ownedHistory: service.ownedHistory });
  t.after(() => restored.close()); assert.equal((await restored.create(body)).id, first.id); assert.equal(restoredProtocol.calls.length, 0);
  assert.notEqual((await service.create({ ...body, clientDraftId: 'draft-two' })).id, first.id);
});

test('a failed subscription preserves the created task ID and retries subscription before sending', async t => {
  const { service, protocol, acceptanceWorkspace } = fixture(t), body = { project: projectId(acceptanceWorkspace), clientDraftId: 'subscribe-failed' }, request = protocol.request.bind(protocol);
  let fail = true;
  protocol.request = async (method, params) => { if (method === 'session/subscribe' && fail) { fail = false; throw Object.assign(new Error('subscription timed out'), { code: 'runtime_timeout' }); } return request(method, params); };
  await assert.rejects(service.create(body), { code: 'runtime_timeout' });
  const session = await service.create(body); assert.equal(service.initialized.has(session.id), false);
  assert.equal(protocol.calls.filter(call => call.method === 'session/create').length, 1);
  await service.send(session.id, 'Hello', 'after-subscribe-retry'); assert.equal(service.initialized.has(session.id), true);
  assert.equal(protocol.calls.filter(call => call.method === 'session/subscribe').length, 1);
});

test('uncertain task creation cannot be repeated after a timeout or interrupted pending ledger', async t => {
  const { service, protocol, acceptanceWorkspace } = fixture(t), body = { project: projectId(acceptanceWorkspace), clientDraftId: 'uncertain-create' };
  let createCalls = 0;
  protocol.request = async method => { if (method === 'session/create') { createCalls++; throw Object.assign(new Error('timeout'), { code: 'runtime_timeout' }); } return {}; };
  await assert.rejects(service.create(body), { code: 'runtime_timeout' });
  await assert.rejects(service.create(body), { code: 'draft_uncertain', retryable: false }); assert.equal(createCalls, 1);
  Object.values(service.registry.drafts)[0].status = 'pending'; service.persist();
  const restoredProtocol = new FakeProtocol(), restored = new BridgeService({ runtimeDir: service.runtimeDir, zcodeRoot: service.zcodeRoot, acceptanceWorkspace, protocol: restoredProtocol, history: service.history, ownedHistory: service.ownedHistory });
  t.after(() => restored.close()); await assert.rejects(restored.create(body), { code: 'draft_uncertain' }); assert.equal(restoredProtocol.calls.length, 0);
});

test('HTTP creation survives a disconnected client and rejects invalid draft IDs', async t => {
  const { service, protocol, acceptanceWorkspace } = fixture(t), token = 'c'.repeat(43), server = createBridgeServer({ service, token });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve)); t.after(() => { server.closeAllConnections(); server.close(); });
  const url = `http://127.0.0.1:${server.address().port}/v1/sessions`, headers = { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' }, body = { projectId: projectId(acceptanceWorkspace), clientDraftId: 'disconnected-client', title: 'Create retry' };
  const request = protocol.request.bind(protocol); let entered; const started = new Promise(resolve => { entered = resolve; }); let continueCreate; const resumed = new Promise(resolve => { continueCreate = resolve; });
  protocol.request = async (method, params) => { if (method === 'session/create') { entered(); await resumed; } return request(method, params); };
  const controller = new AbortController(), abandoned = fetch(url, { method: 'POST', headers, body: JSON.stringify(body), signal: controller.signal }).then(() => 'unexpected response', error => error.name);
  await started; controller.abort(); assert.equal(await abandoned, 'AbortError'); continueCreate();
  const retry = await fetch(url, { method: 'POST', headers, body: JSON.stringify(body) }); assert.equal(retry.status, 201); assert.ok((await retry.json()).session.id);
  assert.equal(protocol.calls.filter(call => call.method === 'session/create').length, 1);
  for (const clientDraftId of ['', 123, 'a'.repeat(129)]) {
    const invalid = await fetch(url, { method: 'POST', headers, body: JSON.stringify({ ...body, clientDraftId }) }); assert.equal(invalid.status, 422); assert.equal((await invalid.json()).error.code, 'invalid_request');
  }
});

test('task metadata persists and archiving blocks sending without stopping work implicitly', async t => {
  const { service, acceptanceWorkspace } = fixture(t), session = await service.create({ project: projectId(acceptanceWorkspace) });
  await service.metadata(session.id, { title: 'Renamed', pinned: true, archived: true });
  assert.equal(service.sessions().some(s => s.id === session.id), false);
  assert.equal(service.sessions({ includeArchived: true })[0].title, 'Renamed');
  await assert.rejects(service.send(session.id, 'Hello'), { code: 'session_archived' });
  await service.metadata(session.id, { archived: false }); await service.send(session.id, 'Hello');
  await assert.rejects(service.metadata(session.id, { archived: true }), { code: 'session_busy' });
});

test('settings use explicit verified choices and never persist desktop workspace defaults', async t => {
  const { service, protocol, acceptanceWorkspace } = fixture(t), session = await service.create({ project: projectId(acceptanceWorkspace) });
  const result = await service.updateSettings(session.id, { thoughtLevel: 'high', mode: 'plan' });
  assert.equal(result.model.thoughtLevel, 'high'); assert.equal(result.mode, 'plan');
  const thought = protocol.calls.find(call => call.method === 'session/setThoughtLevel'); assert.equal(thought.params.persistAsWorkspaceLastUsed, false);
  await assert.rejects(service.updateSettings(session.id, { thoughtLevel: 'ultra' }), { code: 'thought_level_unsupported' });
  assert.equal(JSON.stringify(service.models()).includes('PRIVATE_TEST_SENTINEL'), false);
});

test('attachments enforce session ownership, content integrity, and image capabilities', t => {
  const root = temp(t), store = new AttachmentStore(root), attachment = store.create('one', { fileName: 'note.txt', mimeType: 'text/plain', base64: Buffer.from('ATTACHMENT_ACCEPTANCE').toString('base64') });
  assert.equal(store.resolve('one', [attachment.id])[0].kind, 'file');
  assert.throws(() => store.resolve('two', [attachment.id]), { code: 'attachment_not_found' });
  assert.throws(() => store.create('one', { fileName: '../escape', mimeType: 'text/plain', base64: 'YQ==' }), { code: 'invalid_file_name' });
  assert.throws(() => store.create('one', { fileName: 'bad.txt', mimeType: 'text/plain', base64: '??' }), { code: 'invalid_attachment' });
  assert.throws(() => store.create('one', { fileName: 'wrong.png', mimeType: 'image/png', base64: 'YQ==' }), { code: 'attachment_type_mismatch' });
  const image = store.create('one', { fileName: 'image.png', mimeType: 'image/png', base64: 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aX2kAAAAASUVORK5CYII=' });
  assert.throws(() => store.resolve('one', [image.id], { supportsImages: false }), { code: 'model_does_not_support_images' });
  const pdf = store.create('one', { fileName: 'minimal.pdf', mimeType: 'application/pdf', base64: Buffer.from('%PDF-1.4\n').toString('base64') });
  assert.throws(() => store.resolve('one', [pdf.id], { supportsPDF: false }), { code: 'model_does_not_support_pdf' });
  writeFileSync(join(root, 'attachments', attachment.id), 'modified'); assert.throws(() => store.resolve('one', [attachment.id]), { code: 'attachment_changed' });
});

test('full access requires explicit confirmation and planning preserves the prior permission mode in mocked runtime', async t => {
  const { service, protocol, acceptanceWorkspace } = fixture(t), project = projectId(acceptanceWorkspace);
  await assert.rejects(service.create({ project, mode: 'yolo' }), { code: 'full_access_confirmation_required' }); assert.equal(protocol.calls.length, 0);
  const session = await service.create({ project }); assert.equal(session.mode, 'build');
  await assert.rejects(service.updateSettings(session.id, { mode: 'yolo' }), { code: 'full_access_confirmation_required' });
  await service.updateSettings(session.id, { mode: 'yolo', confirmFullAccess: true });
  await service.updateSettings(session.id, { mode: 'plan' }); assert.equal(service.settings(session.id).permissionMode, 'yolo');
  const before = protocol.calls.length; await service.updateSettings(session.id, { permissionMode: 'edit' });
  assert.equal(service.settings(session.id).mode, 'plan'); assert.equal(service.settings(session.id).permissionMode, 'edit'); assert.equal(protocol.calls.length, before);
  await service.updateSettings(session.id, { mode: 'edit' }); assert.equal(service.settings(session.id).mode, 'edit');
  await assert.rejects(service.updateSettings(session.id, { mode: 'build', permissionMode: 'edit' }), { code: 'invalid_request' });
  await assert.rejects(service.updateSettings(session.id, { mode: 'auto' }), { code: 'invalid_request' });
});

test('project settings report the exact selection used for default task creation', async t => {
  const { service, acceptanceWorkspace } = fixture(t), project = projectId(acceptanceWorkspace), defaults = service.projectSettings(project), session = await service.create({ project });
  assert.deepEqual(defaults.model, { providerId: session.providerId, modelId: session.model, thoughtLevel: session.thoughtLevel }); assert.equal(defaults.mode, session.mode);
});

test('file search spans nested safe folders and reports bounded incomplete results', async t => {
  const root = temp(t); mkdirSync(join(root, 'Sources', 'Deep'), { recursive: true }); mkdirSync(join(root, '.private'));
  writeFileSync(join(root, 'Sources', 'Deep', 'MainView.swift'), 'Swift'); writeFileSync(join(root, 'MainOther.swift'), 'Swift'); writeFileSync(join(root, '.private', 'MainSecret.swift'), 'Secret'); symlinkSync('/etc', join(root, 'linked'));
  const results = await searchWorkspaceFiles(root, 'main'); assert.equal(results.files.length, 2); assert.equal(results.searchComplete, true); assert.ok(results.files.some(file => file.path === 'Sources/Deep/MainView.swift'));
  const bounded = await searchWorkspaceFiles(root, 'main', '', { maxResults: 1 }); assert.equal(bounded.files.length, 1); assert.equal(bounded.truncated, true);
});

test('project file reads reject traversal, secrets, symlinks, binary and oversized files', async t => {
  const root = temp(t), project = join(root, 'project'); mkdirSync(project);
  writeFileSync(join(project, 'visible.txt'), 'Hello 文件'); writeFileSync(join(project, '.env'), 'SECRET'); writeFileSync(join(root, 'outside.txt'), 'Outside'); symlinkSync(join(root, 'outside.txt'), join(project, 'link.txt')); writeFileSync(join(project, 'binary.dat'), Buffer.from([0, 1, 2])); writeFileSync(join(project, 'large.txt'), Buffer.alloc(513 * 1024, 65));
  const listing = await listWorkspaceFiles(project); assert.equal(listing.files.some(file => file.name === '.env' || file.name === 'link.txt'), false);
  assert.equal((await readWorkspaceFile(project, 'visible.txt')).content, 'Hello 文件');
  for (const [path, code] of [['../outside.txt', 'invalid_path'], ['/etc/passwd', 'invalid_path'], ['.env', 'file_restricted'], ['link.txt', 'symlink_restricted'], ['binary.dat', 'binary_file'], ['large.txt', 'file_too_large']]) await assert.rejects(readWorkspaceFile(project, path), { code });
});

test('event replay returns retained events and requests resync across epochs', () => {
  const journal = new EventJournal(2), first = journal.publish('one'), second = journal.publish('two');
  assert.deepEqual(journal.replay(first.id).events, [second]); journal.publish('three'); assert.equal(journal.replay(first.id).resync, true); assert.equal(journal.replay('previous:1').resync, true);
});

test('permission protocol preserves the original RPC id and rejects invalid decisions', () => {
  const protocol = new ZCodeProtocol({}), frames = []; protocol.write = frame => frames.push(frame);
  protocol.onFrame({ id: 'rpc_77', method: 'interaction/requestPermission', params: { requestId: 'permission_1', sessionId: 'owned', toolName: 'Bash' } });
  assert.throws(() => protocol.respond('permission_1', { decision: 'maybe' }), { code: 'invalid_request' });
  assert.throws(() => protocol.respond('permission_1', { decision: 'allow', permissionUpdates: [{ type: 'always' }] }), { code: 'invalid_request' });
  assert.equal(protocol.respond('permission_1', { decision: 'deny', reason: 'Acceptance test' }), 'owned'); assert.deepEqual(frames[0], { id: 'rpc_77', result: { decision: 'deny', reason: 'Acceptance test' } });
  assert.throws(() => protocol.respond('permission_1', { decision: 'allow' }), { code: 'not_found' });
});

test('question DTOs keep their timestamp and accept multiple answers without persistent permissions', t => {
  const { service } = fixture(t), protocol = new ZCodeProtocol({}), frames = [];
  service.protocol = protocol; protocol.write = frame => frames.push(frame);
  protocol.onFrame({ id: 'rpc_question', method: 'interaction/requestUserInput', params: { requestId: 'question', sessionId: 'owned', toolName: 'AskUserQuestion', questions: [{ question: 'Pick?', header: 'Choice', multiSelect: true, options: [{ label: 'Alpha', value: 'alpha' }] }] } });
  const first = service.pendingInteractions('owned')[0];
  assert.equal(service.pendingInteractions('owned')[0].createdAt, first.createdAt);
  assert.equal(first.questions[0].multiSelect, true);
  protocol.respond('question', { action: 'accept', content: { answers: { 'Pick?': ['alpha', 'custom'] } } });
  assert.deepEqual(frames[0].result.content.answers, { 'Pick?': ['alpha', 'custom'] });
});

test('runtime lock rejects a second owner and releases only its own lock', t => {
  const root = temp(t), release = acquireRuntimeLock(root);
  assert.throws(() => acquireRuntimeLock(root), /already owns/); release();
  const second = acquireRuntimeLock(root); release(); assert.throws(() => acquireRuntimeLock(root), /already owns/); second();
});

test('change previews exclude secret and symlink paths and preserve unusual filenames', async t => {
  const root = temp(t), git = args => execFileSync('/usr/bin/git', args, { cwd: root, stdio: 'pipe' });
  git(['init', '-q']);
  writeFileSync(join(root, 'ordinary.txt'), 'before\n'); writeFileSync(join(root, '.env'), 'SECRET_BEFORE');
  git(['add', '--', 'ordinary.txt', '.env']);
  writeFileSync(join(root, 'ordinary.txt'), 'after\n'); writeFileSync(join(root, '.env'), 'SECRET_AFTER');
  writeFileSync(join(root, 'secret.key'), 'SECRET_UNTRACKED'); writeFileSync(join(root, 'odd\tname\n.txt'), 'visible\n'); symlinkSync('/etc/passwd', join(root, 'linked.txt'));
  const changes = await workspaceChanges(root), serialized = JSON.stringify(changes);
  assert.equal(serialized.includes('SECRET'), false); assert.equal(serialized.includes('.env'), false); assert.equal(serialized.includes('linked.txt'), false);
  assert.ok(changes.files.some(file => file.path === 'odd\tname\n.txt' && file.diff.includes('+visible')));
  assert.ok(changes.files.some(file => file.path === 'ordinary.txt' && file.diff.includes('+after')));
});

test('HTTP requires a bearer token, rejects browser origins, and streams replay events', async t => {
  const { service } = fixture(t), token = 't'.repeat(43), server = createBridgeServer({ service, token });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve)); t.after(() => { server.closeAllConnections(); server.close(); });
  const base = `http://127.0.0.1:${server.address().port}`, auth = { Authorization: `Bearer ${token}` };
  assert.equal((await fetch(base + '/health')).status, 200); assert.equal((await fetch(base + '/v1/projects')).status, 401);
  assert.equal((await fetch(base + '/v1/projects', { headers: { ...auth, Origin: 'https://example.invalid' } })).status, 403);
  const first = service.events.publish('session.updated', { safe: true }, 'one'); service.events.publish('message.updated', { message: { id: 'message_2' } }, 'one');
  const controller = new AbortController(), stream = await fetch(base + `/v1/events?after=${first.id}&sessionId=one`, { headers: auth, signal: controller.signal }), reader = stream.body.getReader();
  const chunk = new TextDecoder().decode((await reader.read()).value); assert.match(chunk, /event: ready/); assert.match(chunk, /message_2/); controller.abort();
  const bad = await fetch(base + '/v1/sessions?limit=not-a-number', { headers: auth }); assert.equal(bad.status, 422); assert.equal((await bad.json()).error.code, 'invalid_request');
  const project = service.projects().find(project => project.isAcceptanceWorkspace), created = await service.create({ project: project.id }), message = '  中文代码\n    缩进保留  ';
  await new Promise((resolve, reject) => {
    const request = httpRequest(base + `/v1/sessions/${created.id}/messages`, { method: 'POST', headers: { ...auth, 'Content-Type': 'application/json' } }, response => { response.resume(); response.on('end', () => { try { assert.equal(response.statusCode, 202); resolve(); } catch (error) { reject(error); } }); });
    request.on('error', reject); const bytes = Buffer.from(JSON.stringify({ text: message, inputId: 'unicode-chunks' })); for (const byte of bytes) request.write(Buffer.from([byte])); request.end();
  });
  assert.equal(service.protocol.calls.find(call => call.params?.commandId === 'unicode-chunks').params.payload.text, message);
});
