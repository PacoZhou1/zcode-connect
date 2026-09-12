import test from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import { EventEmitter } from 'node:events';
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { HistoryReader } from '../src/history.mjs';
import { BridgeService } from '../src/service.mjs';
import { createBridgeServer } from '../src/server.mjs';
import { projectId } from '../src/util.mjs';

function fixture(t, messageCount = 4) {
  const root = mkdtempSync(join(tmpdir(), 'zcode-subagent-readonly-'));
  const runtimeDir = join(root, 'runtime'), workspace = join(runtimeDir, 'acceptance-workspace'), zcodeRoot = join(root, 'desktop');
  const ownedRoot = join(runtimeDir, 'zcode'); mkdirSync(join(ownedRoot, 'cli/db'), { recursive: true });
  mkdirSync(workspace, { recursive: true }); writeFileSync(join(workspace, 'README.md'), 'Same parent workspace\n');
  writeFileSync(join(workspace, '.env'), 'PRIVATE_TEST_SENTINEL');
  const db = new DatabaseSync(join(ownedRoot, 'cli/db/db.sqlite'));
  db.exec(`CREATE TABLE session(id TEXT PRIMARY KEY,parent_id TEXT,task_type TEXT,title TEXT,path TEXT,directory TEXT,time_created INTEGER,time_updated INTEGER,time_archived INTEGER);
    CREATE TABLE message(id TEXT PRIMARY KEY,session_id TEXT,time_created INTEGER,time_updated INTEGER,data TEXT,sequence INTEGER);
    CREATE TABLE part(id TEXT PRIMARY KEY,message_id TEXT,session_id TEXT,time_created INTEGER,time_updated INTEGER,data TEXT,sequence INTEGER);`);
  const addSession = (id, parent = null, type = 'subagent_child', path = workspace) => db.prepare('INSERT INTO session VALUES(?,?,?,?,?,?,?,?,?)').run(id, parent, type, 'Host ' + id, path, path, 1700000000000, 1700000001000, null);
  addSession('owned-parent', null, 'interactive'); addSession('child', 'owned-parent'); addSession('grandchild', 'child');
  const append = (id, index, extra = {}) => {
    const key = id + '-message-' + index, at = 1700000000000 + index;
    const info = { role: index % 2 ? 'user' : 'assistant', time: { created: at, completed: at }, finish: 'stop', modelID: 'actual-child-model', providerID: 'actual-child-provider', ...extra };
    db.prepare('INSERT INTO message VALUES(?,?,?,?,?,?)').run(key, id, at, at, JSON.stringify(info), index);
    db.prepare('INSERT INTO part VALUES(?,?,?,?,?,?,?)').run(key + '-part', key, id, at, at, JSON.stringify({ type: 'text', text: id + ' message ' + index }), 1);
  };
  db.exec('BEGIN'); for (let index = 1; index <= messageCount; index++) append('child', index); db.exec('COMMIT');
  const protocol = new EventEmitter(); let calls = 0, writes = 0;
  Object.assign(protocol, { ready: true, interactions: new Map(), close: async () => {},
    request: async () => { calls++; throw new Error('Read-only child must never reach runtime.'); },
    respond: () => { calls++; throw new Error('Read-only child must never approve.'); } });
  const history = { session: () => undefined, sessions: () => [], projects: () => [] };
  const reader = new HistoryReader(ownedRoot);
  const service = new BridgeService({ runtimeDir, zcodeRoot, acceptanceWorkspace: workspace, protocol, history, ownedHistory: reader });
  service.registry.sessions['owned-parent'] = { id: 'owned-parent', path: workspace, title: 'Parent', status: 'completed', archived: true, mode: 'build',
    selection: { providerId: 'parent-provider', modelId: 'parent-model', thoughtLevel: 'max' }, createdAt: new Date().toISOString(), updatedAt: new Date().toISOString() };
  service.persist = () => { writes++; throw new Error('Child access must never persist the registry.'); };
  const servers = [];
  t.after(async () => {
    for (const server of servers) { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); }
    await service.close(); db.close(); rmSync(root, { recursive: true, force: true });
  });
  return { root, workspace, db, service, reader, protocol, addSession, append, counts: () => ({ calls, writes }), servers };
}

test('persisted child detail derives authority from owned ancestry without registering, resuming or inheriting model settings', async t => {
  const { service, counts, workspace } = fixture(t);
  const before = JSON.stringify(service.registry);
  const detail = await service.detail('child');
  assert.equal(detail.session.source, 'bridge-subagent');
  assert.equal(detail.session.parentSessionId, 'owned-parent'); assert.equal(detail.session.rootSessionId, 'owned-parent');
  assert.equal(detail.session.projectId, projectId(workspace)); assert.equal(detail.session.status, 'completed');
  assert.equal(detail.session.model, 'actual-child-model'); assert.equal(detail.session.providerId, 'actual-child-provider');
  assert.equal(detail.session.thoughtLevel, undefined, 'Do not invent the child thinking level from parent settings.');
  assert.equal(detail.messages.length, 4); assert.ok(detail.messages.every(message => !message.isStreaming && !message.forkTarget));
  assert.deepEqual(detail.pendingInteractions, []); assert.equal(detail.hostActivity.supported, false); assert.equal(detail.hostActivity.reasonCode, 'subagentReadOnly');
  assert.deepEqual(Object.entries(detail.session.capabilities).filter(([, value]) => value), [['read', true]]);
  const nested = await service.detail('grandchild');
  assert.equal(nested.session.parentSessionId, 'child'); assert.equal(nested.session.rootSessionId, 'owned-parent');
  assert.equal(service.sessions({ includeArchived: true }).some(session => session.id === 'child'), false);
  assert.equal(service.sessionPage({ includeArchived: true }).sessions.some(session => session.id === 'child'), false);
  assert.equal(JSON.stringify(service.registry), before); assert.deepEqual(counts(), { calls: 0, writes: 0 });
});

test('child IDs cannot bypass actual task type, registered root, workspace, cycle or depth boundaries', async t => {
  const { service, db, addSession, counts } = fixture(t);
  addSession('unowned-root', null, 'interactive'); addSession('unrelated', 'unowned-root');
  addSession('orphan', 'not-a-parent'); addSession('wrong-kind', 'owned-parent', 'fork');
  addSession('different-workspace', 'owned-parent', 'subagent_child', '/unrelated/workspace');
  addSession('directory-mismatch', 'owned-parent'); db.prepare('UPDATE session SET directory=? WHERE id=?').run('/unrelated/workspace', 'directory-mismatch');
  addSession('cycle-a', 'cycle-b'); addSession('cycle-b', 'cycle-a');
  let parent = 'owned-parent'; for (let depth = 0; depth < 34; depth++) { const id = 'deep-' + depth; addSession(id, parent); parent = id; }
  for (const id of ['arbitrary', '__proto__', 'unowned-root', 'unrelated', 'orphan', 'wrong-kind', 'different-workspace', 'directory-mismatch', 'cycle-a', 'deep-33']) {
    await assert.rejects(service.detail(id), { code: 'not_found' });
    assert.throws(() => service.transcript(id), { code: 'not_found' });
  }
  delete service.registry.sessions['owned-parent'];
  await assert.rejects(service.detail('child'), { code: 'not_found' });
  assert.deepEqual(counts(), { calls: 0, writes: 0 });
});

test('every child control, metadata, approval, settings, attachment and diff path fails before runtime or persistence', async t => {
  const { service, protocol, counts } = fixture(t);
  protocol.interactions.set('child-permission', { params: { sessionId: 'child' } });
  const operations = [
    () => service.send('child', 'Never send'), () => service.stop('child'), () => service.fork('child', { clientForkId: 'never-fork' }),
    ...[{ title: 'No rename' }, { pinned: true }, { archived: true }, { archived: false }, { unread: true }, { unread: false, expectedUnreadAt: 1 }].map(body => () => service.metadata('child', body)),
    () => service.settings('child'), () => service.updateSettings('child', { thoughtLevel: 'high' }),
    () => service.upload('child', { fileName: 'x.txt', mimeType: 'text/plain', base64: 'eA==' }),
    () => service.goalAction('child', 'pause'), () => service.goalAction('child', 'resume'), () => service.goalAction('child', 'remove'),
    () => service.respond('child-permission', { decision: 'allow' }), () => service.changes('child'),
  ];
  for (const operation of operations) await assert.rejects(async () => operation(), { status: 409, code: 'session_read_only' });
  assert.equal(Object.hasOwn(service.registry.sessions, 'child'), false); assert.deepEqual(counts(), { calls: 0, writes: 0 });
});

test('authorized child HTTP detail and older history retain pagination; child file IDs do not grant new workspace access', async t => {
  const { service, db, workspace, counts, servers } = fixture(t, 705);
  const token = 'subagent-readonly-test-token'.repeat(3), server = createBridgeServer({ service, token }); servers.push(server);
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const base = 'http://127.0.0.1:' + server.address().port, headers = { Authorization: 'Bearer ' + token, 'Content-Type': 'application/json' };
  const api = async (path, method = 'GET', body) => {
    const response = await fetch(base + path, { method, headers, ...(body ? { body: JSON.stringify(body) } : {}) });
    return { status: response.status, body: await response.json() };
  };
  assert.equal((await fetch(base + '/v1/sessions/child')).status, 401);
  const first = await api('/v1/sessions/child'); assert.equal(first.status, 200); assert.equal(first.body.messages.length, 500);
  let page = first.body;
  while (page.history.hasMore) {
    const result = await api('/v1/sessions/child/messages?beforeRowId=' + page.history.beforeRowId + '&logEpoch=' + page.history.logEpoch + '&limit=200');
    assert.equal(result.status, 200); page = result.body;
  }
  assert.equal(page.messages.length, 705); assert.equal(new Set(page.messages.map(message => message.id)).size, 705);
  assert.equal(page.messages[0].id, 'child-message-1'); assert.equal(page.messages.at(-1).id, 'child-message-705');
  const failure = await api('/v1/sessions/child', 'PATCH', { archived: false }); assert.equal(failure.status, 409); assert.equal(failure.body.error.code, 'session_read_only');
  assert.equal((await api('/v1/sessions/child/changes')).status, 409);
  assert.equal((await api('/v1/projects/child/files')).status, 404);
  const parentFiles = await api('/v1/projects/' + projectId(workspace) + '/files'); assert.equal(parentFiles.status, 200); assert.equal(parentFiles.body.files.length, 1);
  assert.equal((await api('/v1/projects/' + projectId(workspace) + '/file?path=.env')).status, 403);
  assert.equal(db.prepare('SELECT COUNT(*) AS count FROM message WHERE session_id=?').get('child').count, 705);
  assert.deepEqual(counts(), { calls: 0, writes: 0 });
});
