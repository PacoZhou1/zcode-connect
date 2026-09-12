import test from 'node:test';
import assert from 'node:assert/strict';
import { SessionPages } from '../src/session-pages.mjs';

test('task pages retain stable order and exact retries across live catalogue mutations', () => {
  const pager = new SessionPages(), filters = { project: null, includeArchived: true, search: '' };
  const rows = Array.from({ length: 205 }, (_, id) => ({ id: String(id), title: `Task ${id}` }));
  let builds = 0;
  const first = pager.page({ filters }, () => { builds++; return { sessions: rows, truncated: false }; });
  assert.equal(first.sessions.length, 100); assert.equal(first.pagination.total, 205); assert.equal(first.pagination.hasMore, true);
  rows.unshift({ id: 'new', title: 'New task' }); rows[2].title = 'Changed';
  const next = pager.page({ filters, cursor: first.pagination.nextCursor }, () => { throw new Error('Must not rebuild a cursor page'); });
  assert.deepEqual(next, pager.page({ filters, cursor: first.pagination.nextCursor }));
  const last = pager.page({ filters, cursor: next.pagination.nextCursor });
  assert.equal(last.sessions.length, 5); assert.equal(last.pagination.nextCursor, null); assert.equal(last.pagination.hasMore, false);
  const all = [...first.sessions, ...next.sessions, ...last.sessions]; assert.equal(new Set(all.map(s => s.id)).size, 205); assert.equal(all[1].title, 'Task 1'); assert.equal(builds, 1);
  assert.throws(() => pager.page({ filters: { ...filters, search: 'other' }, cursor: next.pagination.nextCursor }), { code: 'session_cursor_mismatch' });
});

test('task paging explicitly reports caps, unknown source totals, expired cursors and invalid limits', () => {
  let now = 0; const pager = new SessionPages({ now: () => now, maxRows: 3 });
  const query = { filters: {}, limit: 2 }, build = () => ({ sessions: [1, 2, 3, 4].map(id => ({ id })), truncated: false });
  const first = pager.page(query, build), last = pager.page({ ...query, cursor: first.pagination.nextCursor });
  assert.equal(first.pagination.total, 4); assert.equal(last.pagination.truncated, true); assert.equal(last.pagination.hasMore, false);
  const incomplete = pager.page(query, () => ({ ...build(), truncated: true })); assert.equal(incomplete.pagination.total, null); assert.equal(incomplete.pagination.truncated, true);
  now = 300001; assert.throws(() => pager.page({ ...query, cursor: first.pagination.nextCursor }), { code: 'session_cursor_expired' });
  for (const limit of [0, -1, 1001, 1.5]) assert.throws(() => pager.page({ ...query, limit }, build), { code: 'invalid_request' });
  assert.throws(() => pager.page({ ...query, cursor: 'bad' }), { code: 'invalid_request' });
});
