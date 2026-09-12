import { randomUUID } from 'node:crypto';
import { BridgeError } from './util.mjs';

// A cursor addresses immutable DTOs, not a moving offset in a live sorted list.
export class SessionPages {
  constructor({ now = Date.now, maxRows = 5000, maxBytes = 16 * 1024 * 1024 } = {}) {
    this.now = now; this.maxRows = maxRows; this.maxBytes = maxBytes; this.snapshots = new Map();
  }
  page({ cursor, limit = 100, filters }, build) {
    if (!Number.isInteger(limit) || limit < 1 || limit > 1000) throw new BridgeError(422, 'invalid_request', 'limit must be an integer from 1 to 1000.');
    const now = this.now(), fingerprint = JSON.stringify({ filters, limit });
    for (const [id, snapshot] of this.snapshots) if (now - snapshot.at > 300000) this.snapshots.delete(id);
    let snapshot, offset = 0;
    if (cursor !== undefined) {
      if (typeof cursor !== 'string' || cursor.length > 128 || !/^[a-f0-9-]{36}\.[0-9]+$/.test(cursor)) throw new BridgeError(422, 'invalid_request', 'Invalid session cursor.');
      const [id, position] = cursor.split('.'); offset = Number(position); snapshot = this.snapshots.get(id);
      if (!snapshot) throw new BridgeError(409, 'session_cursor_expired', 'Reload the task list to obtain a current cursor.', true);
      if (snapshot.fingerprint !== fingerprint) throw new BridgeError(409, 'session_cursor_mismatch', 'Restart the task list after changing its filters.', false);
      if (!Number.isSafeInteger(offset) || offset < 0 || offset >= snapshot.sessions.length) throw new BridgeError(422, 'invalid_request', 'Session cursor is outside its snapshot.');
    } else {
      const source = build(), sessions = []; let bytes = 0;
      for (const item of source.sessions) {
        const size = Buffer.byteLength(JSON.stringify(item));
        if (sessions.length >= this.maxRows || bytes + size > this.maxBytes) break;
        sessions.push(structuredClone(item)); bytes += size;
      }
      snapshot = { id: randomUUID(), at: now, fingerprint, sessions, total: source.truncated ? null : source.sessions.length, truncated: Boolean(source.truncated || sessions.length < source.sessions.length) };
      while (this.snapshots.size >= 4) this.snapshots.delete(this.snapshots.keys().next().value);
      this.snapshots.set(snapshot.id, snapshot);
    }
    const sessions = snapshot.sessions.slice(offset, offset + limit), next = offset + sessions.length, hasMore = next < snapshot.sessions.length;
    return { sessions: structuredClone(sessions), pagination: { snapshotId: snapshot.id, total: snapshot.total, hasMore, nextCursor: hasMore ? `${snapshot.id}.${next}` : null, truncated: snapshot.truncated } };
  }
}
