import test from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import { EventEmitter } from 'node:events';
import { mkdtempSync, mkdirSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { HistoryReader } from '../src/history.mjs';
import { TranscriptPages } from '../src/transcript-pages.mjs';
import { BridgeService } from '../src/service.mjs';
import { createBridgeServer } from '../src/server.mjs';

const messageID = index => 'message_' + String(index).padStart(5, '0');
function fixture(t, count) {
  const root = mkdtempSync(join(tmpdir(), 'zcode-history-test-'));
  mkdirSync(join(root, 'cli/db'), { recursive: true });
  const db = new DatabaseSync(join(root, 'cli/db/db.sqlite'));
  db.exec(`CREATE TABLE message(id TEXT PRIMARY KEY,session_id TEXT NOT NULL,time_created INTEGER NOT NULL,time_updated INTEGER NOT NULL,data TEXT NOT NULL,sequence INTEGER);
    CREATE TABLE part(id TEXT PRIMARY KEY,message_id TEXT NOT NULL,session_id TEXT NOT NULL,time_created INTEGER NOT NULL,time_updated INTEGER NOT NULL,data TEXT NOT NULL,sequence INTEGER);`);
  const message = db.prepare('INSERT INTO message VALUES(?,?,?,?,?,?)'), part = db.prepare('INSERT INTO part VALUES(?,?,?,?,?,?,?)');
  const append = index => {
    const id = messageID(index), time = 1700000000000 + index;
    message.run(id, 'test-session', time, time, JSON.stringify({ id, role: index % 2 ? 'user' : 'assistant', finish: 'stop', time: { created: time, completed: time } }), index);
    part.run('part_' + index, id, 'test-session', time, time, JSON.stringify({ type: 'text', text: 'Message ' + index }), 1);
  };
  db.exec('BEGIN'); for (let i = 1; i <= count; i++) append(i); db.exec('COMMIT');
  t.after(() => { db.close(); rmSync(root, { recursive: true, force: true }); });
  return { root, db, append, reader: new HistoryReader(root) };
}
const next = page => ({ beforeRowId: page.history.beforeRowId, logEpoch: page.history.logEpoch, limit: 200 });

test('read-only persisted history over 500 starts at the newest messages and loads every older message without duplicates', t => {
  const { reader, db } = fixture(t, 1205);
  db.prepare('UPDATE message SET data = ? WHERE id = ?').run(JSON.stringify({ role: 'user', semantics: { uiVisibility: 'hidden', transcriptVisibility: 'hidden' } }), messageID(50));
  const first = reader.transcript('test-session');
  assert.equal(first.messages.length, 500); assert.equal(first.messages[0].id, messageID(706)); assert.equal(first.messages.at(-1).id, messageID(1205));
  assert.equal(first.history.totalRowCount, 1205); assert.equal(first.history.beforeRowId, 706); assert.equal(first.history.hasMore, true);
  let page = first; const loaded = [page.history.loadedRowCount];
  while (page.history.hasMore) { page = reader.transcript('test-session', next(page)); loaded.push(page.history.loadedRowCount); }
  assert.deepEqual(loaded, [500, 700, 900, 1100, 1205]); assert.equal(page.messages.length, 1204);
  const expected = Array.from({ length: 1205 }, (_, i) => messageID(i + 1)).filter(id => id !== messageID(50));
  assert.deepEqual(page.messages.map(message => message.id), expected); assert.equal(new Set(page.messages.map(message => message.id)).size, 1204);
  assert.equal(page.history.hasMore, false); assert.equal(page.history.firstRowId, 1); assert.equal(page.history.beforeRowId, 1);
  assert.deepEqual(reader.transcript('test-session'), page, 'A detail reread must retain all already loaded history');
  assert.equal(db.prepare('SELECT COUNT(*) AS count FROM message').get().count, 1205);
});

test('older pages retain live tail updates, append safely, reread older edits, and replay without advancing twice', t => {
  const { reader, db, append } = fixture(t, 650);
  let live = [{ info: { messageId: messageID(651), role: 'assistant', time: { created: 1700000000651 } }, parts: [{ type: 'text', text: 'Streaming first' }] }];
  const first = reader.transcript('test-session', {}, live), cursor = next(first);
  assert.equal(first.messages.at(-1).isStreaming, true);
  append(651); append(652);
  live = [{ info: { messageId: messageID(652), role: 'assistant', time: { created: 1700000000652 } }, parts: [{ type: 'text', text: 'Streaming latest' }] }];
  db.prepare('UPDATE part SET data = ? WHERE id = ?').run(JSON.stringify({ type: 'text', text: 'Older content edited by host' }), 'part_20');
  const page = reader.transcript('test-session', cursor, live);
  assert.equal(page.history.totalRowCount, 652); assert.equal(page.messages.length, 652); assert.equal(page.history.hasMore, false);
  assert.equal(page.messages.find(message => message.id === messageID(20)).text, 'Older content edited by host');
  assert.equal(page.messages.at(-1).text, 'Streaming latest'); assert.equal(page.messages.at(-1).isStreaming, true);
  assert.deepEqual(reader.transcript('test-session', cursor, live), page);
  db.prepare('DELETE FROM part WHERE message_id = ?').run(messageID(10)); db.prepare('DELETE FROM message WHERE id = ?').run(messageID(10));
  assert.throws(() => reader.transcript('test-session', cursor, live), { code: 'relay_history_changed' });
  assert.notEqual(reader.transcript('test-session', {}, live).history.logEpoch, page.history.logEpoch);
});

test('HTTP detail and older-message routes deliver compatible history for more than 500 desktop messages without a runtime control call', async t => {
  const { reader, root } = fixture(t, 705), protocol = new EventEmitter(); let calls = 0;
  Object.assign(protocol, { ready: false, interactions: new Map(), request: async () => { calls++; throw new Error('Desktop history must remain read-only'); }, close: async () => {} });
  reader.session = id => id === 'test-session' ? { id, title: 'History acceptance', workspacePath: root, capabilities: { read: true, send: false } } : undefined;
  const service = new BridgeService({ runtimeDir: join(root, 'runtime'), zcodeRoot: root, acceptanceWorkspace: join(root, 'acceptance'), protocol, history: reader, ownedHistory: reader });
  const token = 'history-test-token'.repeat(3), server = createBridgeServer({ service, token });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(async () => { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); await service.close(); });
  const base = `http://127.0.0.1:${server.address().port}/v1/sessions/test-session`, headers = { Authorization: 'Bearer ' + token };
  const detail = await (await fetch(base, { headers })).json();
  assert.equal(detail.messages.length, 500); assert.equal(detail.history.totalRowCount, 705); assert.equal(detail.session.capabilities.send, false);
  const query = new URLSearchParams(next(detail)), page = await (await fetch(base + '/messages?' + query, { headers })).json();
  assert.equal(page.messages.length, 700); assert.equal(page.history.hasMore, true);
  const last = await (await fetch(base + '/messages?' + new URLSearchParams(next(page)), { headers })).json();
  assert.equal(last.messages.length, 705); assert.equal(last.history.hasMore, false); assert.equal(calls, 0);
  const unauthorized = await fetch(base + '/messages?' + query); assert.equal(unauthorized.status, 401);
  const missing = await fetch(base + '/messages', { headers }); assert.equal(missing.status, 422);
  const wrongEpoch = await fetch(base + '/messages?' + new URLSearchParams({ ...next(detail), logEpoch: 'other' }), { headers });
  assert.equal(wrongEpoch.status, 409); assert.equal((await wrongEpoch.json()).error.code, 'relay_history_changed');
});

test('history limits and expired cursors fail explicitly without partially advancing the loaded window', () => {
  let now = 0; const pager = new TranscriptPages({ now: () => now, initialRows: 2, maxLoadedRows: 3, maxBytes: 200 });
  const ids = ['a', 'b', 'c', 'd'], read = keys => keys.map(id => ({ id, text: id }));
  const first = pager.page('one', ids, read);
  assert.throws(() => pager.page('one', ids, read, next(first)), { code: 'history_limit' });
  assert.deepEqual(pager.page('one', ids, read), first);
  const allowed = pager.page('one', ids, read, { ...next(first), limit: 1 }); assert.equal(allowed.history.loadedRowCount, 3);
  assert.throws(() => pager.page('one', ids, () => [{ text: 'a'.repeat(201) }]), { code: 'history_limit' });
  for (const options of [{ ...next(first), limit: 0 }, { ...next(first), limit: 501 }, { beforeRowId: 1 }, { logEpoch: first.history.logEpoch }]) {
    assert.throws(() => pager.page('one', ids, read, options), { code: 'invalid_request' });
  }
  now = 30 * 60 * 1000 + 1;
  assert.throws(() => pager.page('one', ids, read, { ...next(allowed), limit: 1 }), { code: 'relay_history_changed' });
});
