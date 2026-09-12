import { randomUUID } from 'node:crypto';
import { BridgeError, hash } from './util.mjs';

export const MAX_TRANSCRIPT_ROWS = 50000;
export const MAX_LOADED_ROWS = 10000;
export const MAX_TRANSCRIPT_BYTES = 16 * 1024 * 1024;
const changed = () => new BridgeError(409, 'relay_history_changed', 'The conversation history changed or its cursor expired. Refresh the task before loading earlier messages.', true);
export const historyLimit = (message, details) => new BridgeError(413, 'history_limit', message, false, details);

// HTTP cursors address an ordered message-ID index, not vendor projection row IDs.
// Only indexes/cursors are cached; every response rereads the loaded messages.
export class TranscriptPages {
  constructor({ now = Date.now, initialRows = 500, maxLoadedRows = MAX_LOADED_ROWS, maxBytes = MAX_TRANSCRIPT_BYTES } = {}) {
    Object.assign(this, { now, initialRows, maxLoadedRows, maxBytes }); this.windows = new Map();
  }
  page(sessionId, ids, read, { beforeRowId, logEpoch, limit = 200 } = {}) {
    const paging = beforeRowId !== undefined || logEpoch !== undefined;
    if (paging && (!Number.isSafeInteger(beforeRowId) || beforeRowId < 1 || typeof logEpoch !== 'string' || !logEpoch || logEpoch.length > 128)
      || !Number.isInteger(limit) || limit < 1 || limit > 500) throw new BridgeError(422, 'invalid_request', 'Use beforeRowId, logEpoch, and a limit from 1 to 500.');
    if (ids.length > MAX_TRANSCRIPT_ROWS) throw historyLimit('The conversation exceeds the safely indexed history limit.', { maxRows: MAX_TRANSCRIPT_ROWS, totalRowCount: ids.length });
    if (ids.some(id => typeof id !== 'string' || !id) || new Set(ids).size !== ids.length) throw new BridgeError(502, 'invalid_history', 'The host returned invalid or duplicate message identities.');
    const now = this.now();
    for (const [id, item] of this.windows) if (now - item.at > 30 * 60 * 1000) this.windows.delete(id);
    const prior = this.windows.get(sessionId);
    const appendOnly = prior && prior.ids.length <= ids.length && prior.ids.every((id, index) => ids[index] === id);
    if (paging && (!prior || prior.epoch !== logEpoch || !appendOnly)) throw changed();
    const window = appendOnly ? { ...prior, ids: [...ids], requests: new Set(prior.requests) }
      : { ids: [...ids], start: Math.max(0, ids.length - this.initialRows), epoch: 'http-history-' + randomUUID(), seq: 0, requests: new Set() };
    if (paging) {
      const request = `${beforeRowId}:${limit}`;
      if (beforeRowId === window.start + 1 && window.start > 0) {
        window.start = Math.max(0, window.start - limit); window.requests.add(request);
      } else if (!window.requests.has(request)) throw changed();
    }
    const loadedRowCount = ids.length - window.start;
    if (loadedRowCount > this.maxLoadedRows) throw historyLimit('Loading more history would exceed the safe response size. The earlier messages remain on the host.', { maxLoadedRowCount: this.maxLoadedRows, loadedRowCount, totalRowCount: ids.length });
    const messages = read(ids.slice(window.start)), encoded = JSON.stringify(messages);
    if (Buffer.byteLength(encoded) > this.maxBytes) throw historyLimit('The loaded history exceeds the safe response byte limit. The earlier messages remain on the host.', { maxBytes: this.maxBytes, totalRowCount: ids.length });
    const digest = hash(encoded + '\n' + ids.length + ':' + window.start);
    if (digest !== window.digest) window.seq += 1;
    window.digest = digest; window.at = now;
    this.windows.delete(sessionId);
    while (this.windows.size >= 8) this.windows.delete(this.windows.keys().next().value);
    this.windows.set(sessionId, window);
    return { messages, history: { hasMore: window.start > 0, beforeRowId: ids.length ? window.start + 1 : null, firstRowId: ids.length ? 1 : null,
      logEpoch: window.epoch, atSeq: window.seq, loadedRowCount, totalRowCount: ids.length } };
  }
}
