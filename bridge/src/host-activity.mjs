import { crc32 } from './relay/codec.mjs';
import { BridgeError, sanitize } from './util.mjs';

const MAX_MESSAGE = 16 * 1024 * 1024;
const integer = (value, min = 0, max = Number.MAX_SAFE_INTEGER) => Number.isSafeInteger(value) && value >= min && value <= max;
const object = value => value !== null && typeof value === 'object' && !Array.isArray(value);
const invalid = message => new BridgeError(502, 'activity_protocol_error', message, true);
const size = value => Buffer.byteLength(JSON.stringify(value));

export function emptyHostActivity(reasonCode = 'projectionUnavailable') {
  return { goal: null, subagents: { revision: 0, childSessionIds: [], running: [], endedTotal: 0 }, availability: { pauseGoal: { allowed: false, reasonCode }, resumeGoal: { allowed: false, reasonCode } }, supported: false, reasonCode };
}
export function activityFromProjection(projection) {
  return sanitize({ goal: projection.goal ?? null, subagents: projection.subagents ?? { revision: 0, childSessionIds: [], running: [], endedTotal: 0 }, availability: projection.availability ?? {},
    workspaceHookAdmission: projection.workspaceHookAdmission ?? null,
    rows: { window: (projection.rows?.window ?? []).filter(row => row.kind === 'subagent') }, supported: true,
    revision: projection.revision, logEpoch: projection.logEpoch, seq: projection.seq });
}

/** Inner conversation framing, distinct from official relay's outer IPC frames. */
export class ConversationAssembler {
  constructor() { this.assemblies = new Map(); this.settled = new Map(); this.bytes = 0; }
  accept(wire, now = Date.now()) {
    const { topic, subscriptionId, logicalFrameId: id, logicalFrameOrdinal: ordinal, deliveryKind } = wire;
    if (wire.wireVersion !== 3 || typeof topic !== 'string' || !topic.startsWith('conversation/') || topic.length > 2048 || typeof subscriptionId !== 'string' || !subscriptionId || subscriptionId.length > 1024 || typeof id !== 'string' || !id || id.length > 1024 || !integer(ordinal, 1) || !['initial', 'online', 'recovery'].includes(deliveryKind) || size(wire) > 1024 * 1024) throw invalid('Invalid conversation wire metadata.');
    const route = topic + '\0' + subscriptionId, prior = this.settled.get(route);
    if (prior && ordinal < prior.ordinal) return null;
    if (prior && ordinal === prior.ordinal) { if (prior.id !== id) throw invalid('Conflicting conversation frame ordinal.'); return null; }
    let frame;
    if (wire.kind === 'complete') frame = wire.frame;
    else if (wire.kind === 'fragment') {
      const { fragmentCount: count, fragmentIndex: index, logicalBytes: logicalSize, checksum, dataBase64 } = wire;
      if (!integer(count, 1, 1024) || !integer(index, 0, count - 1) || !integer(logicalSize, count, MAX_MESSAGE) || checksum?.algorithm !== 'crc32' || !/^[a-f0-9]{8}$/.test(checksum.value) || typeof dataBase64 !== 'string') throw invalid('Invalid conversation fragment metadata.');
      const bytes = Buffer.from(dataBase64, 'base64'), key = route + '\0' + id;
      if (!bytes.length || bytes.toString('base64') !== dataBase64 || bytes.length > logicalSize) throw invalid('Invalid conversation fragment bytes.');
      const existing = this.assemblies.get(key), current = existing ?? { route, subscriptionId, ordinal, id, deliveryKind, count, logicalSize, checksum: checksum.value, at: now, chunks: new Map(), bytes: 0 };
      if (current.ordinal !== ordinal || current.deliveryKind !== deliveryKind || current.count !== count || current.logicalSize !== logicalSize || current.checksum !== checksum.value || now - current.at > 30000) throw invalid('Conversation assembly changed or expired.');
      const duplicate = current.chunks.get(index);
      if (duplicate) { if (!duplicate.equals(bytes)) throw invalid('Conflicting conversation fragment replay.'); return null; }
      if (!existing && this.assemblies.size >= 32 || this.bytes + bytes.length > 32 * 1024 * 1024 || current.bytes + bytes.length > logicalSize) throw invalid('Conversation assembly memory limit exceeded.');
      current.chunks.set(index, bytes); current.bytes += bytes.length; this.bytes += bytes.length; this.assemblies.set(key, current);
      if (current.chunks.size !== count) return null;
      const complete = Buffer.concat(Array.from({ length: count }, (_, i) => current.chunks.get(i)));
      if (complete.length !== logicalSize || crc32(complete) !== checksum.value) throw invalid('Conversation checksum mismatch.');
      frame = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(complete));
    } else throw invalid('Unknown conversation wire kind.');
    if (!object(frame) || frame.topic !== topic || frame.subscriptionId !== subscriptionId || !object(frame.payload) || !integer(frame.fromSeq) || !integer(frame.toSeq, frame.fromSeq)) throw invalid('Logical conversation identity mismatch.');
    this.settled.set(route, { ordinal, id });
    for (const [key, assembly] of this.assemblies) if (assembly.route === route && assembly.ordinal <= ordinal) { this.bytes -= assembly.bytes; this.assemblies.delete(key); }
    return frame;
  }
  discard(subscriptionId) {
    for (const [key, assembly] of this.assemblies) if (assembly.subscriptionId === subscriptionId) { this.bytes -= assembly.bytes; this.assemblies.delete(key); }
    for (const key of this.settled.keys()) if (key.endsWith('\0' + subscriptionId)) this.settled.delete(key);
  }
  expire(now = Date.now()) {
    const ids = new Set();
    for (const assembly of this.assemblies.values()) if (now - assembly.at > 30000) ids.add(assembly.subscriptionId);
    for (const id of ids) this.discard(id); return [...ids];
  }
}

/** Atomically apply official v3 deltas; fromSeq equals the prior seq. */
export function reduceConversation(current, frame, sessionId) {
  if (frame.topic !== 'conversation/' + sessionId || !integer(frame.fromSeq) || !integer(frame.toSeq, frame.fromSeq)) throw invalid('Conversation sequence mismatch.');
  const { payload } = frame; let next;
  if (payload.kind === 'snapshot') {
    next = structuredClone(payload.snapshot);
    if (current && next.logEpoch === current.logEpoch && frame.toSeq < current.seq) return current;
  } else if (payload.kind === 'deltas') {
    if (!current) throw invalid('A snapshot is required before conversation deltas.');
    if (frame.toSeq <= current.seq) return current;
    if (frame.fromSeq !== current.seq || !Array.isArray(payload.deltas) || payload.deltas.length > 10000) throw invalid('Conversation delta sequence gap.');
    next = structuredClone(current);
    for (const delta of payload.deltas) {
      const rows = next.rows.window;
      switch (delta.op) {
        case 'state.updated':
          if (!object(delta.patch) || Object.keys(delta.patch).some(key => ['sessionId', 'logEpoch', 'seq', 'rows', 'protocolVersion', '__proto__', 'constructor', 'prototype'].includes(key))) throw invalid('Invalid conversation state patch.');
          Object.assign(next, delta.patch); break;
        case 'row.appended':
          if (!integer(delta.row?.rowId) || rows.some(row => row.rowId === delta.row.rowId) || rows.length >= 10000) throw invalid('Invalid appended conversation row.');
          rows.push(delta.row); next.rows.totalCount = (next.rows.totalCount ?? rows.length - 1) + 1; next.rows.firstRowId ??= delta.row.rowId; break;
        case 'row.upserted': {
          if (!integer(delta.row?.rowId)) throw invalid('Invalid replacement conversation row.');
          const index = rows.findIndex(row => row.rowId === delta.row.rowId); if (index >= 0) rows[index] = delta.row; break;
        }
        case 'row.removed': {
          if (!integer(delta.fromRowId)) throw invalid('Invalid removed conversation row.');
          const before = rows.length; next.rows.window = rows.filter(row => row.rowId < delta.fromRowId);
          const cleared = next.rows.firstRowId !== null && delta.fromRowId <= next.rows.firstRowId;
          next.rows.totalCount = cleared ? 0 : Math.max(0, next.rows.totalCount - (before - next.rows.window.length)); if (cleared) next.rows.firstRowId = null; break;
        }
        case 'row.delta': {
          if (!integer(delta.rowId) || !['text', 'inputText', 'output.text', 'summaryText'].includes(delta.path) || typeof delta.append !== 'string') throw invalid('Invalid conversation text delta.');
          const row = rows.find(row => row.rowId === delta.rowId); if (!row) break;
          if (delta.path === 'text' && ['assistantText', 'reasoning'].includes(row.kind) || delta.path === 'inputText' && row.kind === 'toolCall' || delta.path === 'summaryText' && row.kind === 'subagent') row[delta.path] = (row[delta.path] ?? '') + delta.append;
          if (delta.path === 'output.text' && row.kind === 'toolCall' && object(row.output)) row.output.text = (row.output.text ?? '') + delta.append;
          break;
        }
        default: throw invalid('Unknown conversation delta operation.');
      }
    }
  } else throw invalid('Unknown conversation payload.');
  next.seq = frame.toSeq;
  if (next.protocolVersion !== 1 || next.sessionId !== sessionId || typeof next.logEpoch !== 'string' || !next.logEpoch || !integer(next.revision) || !Array.isArray(next.rows?.window) || next.rows.window.length > 10000 || next.rows.window.some(row => !integer(row.rowId)) || new Set(next.rows.window.map(row => row.rowId)).size !== next.rows.window.length || size(next) > MAX_MESSAGE) throw invalid('Invalid conversation projection.');
  return next;
}

export class HostActivity {
  constructor({ protocol, events, isOwned, onProjection }) {
    Object.assign(this, { protocol, events, isOwned, onProjection }); this.connectionId = events.epoch;
    this.assembler = new ConversationAssembler(); this.projections = new Map(); this.subscriptions = new Map(); this.opening = new Map(); this.early = new Map(); this.earlyBytes = 0; this.recovering = new Set(); this.stale = new Set();
    this.listener = wire => this.receive(wire); protocol.on('conversationFrame', this.listener);
    this.timer = setInterval(() => { for (const subscriptionId of this.assembler.expire()) this.recover(subscriptionId, 'fragmentExpired'); }, 2500); this.timer.unref();
  }
  reset() { this.assembler = new ConversationAssembler(); this.projections.clear(); this.subscriptions.clear(); this.early.clear(); this.earlyBytes = 0; this.stale.clear(); }
  close() { clearInterval(this.timer); this.protocol.off('conversationFrame', this.listener); this.reset(); }
  async ensure(sessionId) {
    if (!this.isOwned(sessionId)) throw new BridgeError(409, 'session_read_only', 'Desktop-owned activity is unavailable through this isolated runtime.');
    if (this.opening.has(sessionId)) return this.opening.get(sessionId);
    if (this.projections.has(sessionId) && !this.stale.has(sessionId)) return this.projections.get(sessionId);
    if (this.subscriptions.size + this.opening.size >= 64 && ![...this.subscriptions.values()].includes(sessionId)) throw new BridgeError(429, 'activity_subscription_limit', 'The activity subscription limit was reached.');
    const operation = Promise.resolve().then(async () => {
      let subscriptionId = [...this.subscriptions].find(([, id]) => id === sessionId)?.[0];
      if (!subscriptionId) {
        const result = await this.protocol.request('v4/conversation/subscribe', { connectionId: this.connectionId, topic: 'conversation/' + sessionId, clientMode: 'web-remote-replayable', visibility: 'foreground' });
        subscriptionId = result?.ack?.subscriptionId;
        if (typeof subscriptionId !== 'string' || !subscriptionId) throw invalid('The runtime omitted its activity subscription ID.');
        this.subscriptions.set(subscriptionId, sessionId);
        const early = this.early.get(subscriptionId) ?? []; this.early.delete(subscriptionId);
        for (const wire of early) { this.earlyBytes -= size(wire); this.receive(wire); }
      }
      return this.waitFor(sessionId, () => true);
    });
    this.opening.set(sessionId, operation);
    try { return await operation; } finally { this.opening.delete(sessionId); }
  }
  async waitFor(sessionId, predicate, timeout = 10000) {
    const deadline = Date.now() + timeout;
    do {
      const projection = this.projections.get(sessionId);
      if (projection && !this.stale.has(sessionId) && predicate(projection)) return projection;
      if (!this.protocol.ready) throw new BridgeError(503, 'runtime_unavailable', 'The activity runtime disconnected.', true);
      await new Promise(resolve => setTimeout(resolve, 30));
    } while (Date.now() < deadline);
    throw new BridgeError(504, 'activity_not_confirmed', 'The runtime has not confirmed its current activity state.', true);
  }
  receive(wire) {
    const sessionId = typeof wire?.topic === 'string' ? wire.topic.slice('conversation/'.length) : null;
    if (!sessionId || !this.isOwned(sessionId) || !wire.topic.startsWith('conversation/')) return;
    const known = this.subscriptions.get(wire.subscriptionId);
    if (!known) {
      if (!this.opening.has(sessionId)) return;
      const bytes = size(wire), queue = this.early.get(wire.subscriptionId) ?? [];
      if (queue.length >= 1024 || this.earlyBytes + bytes > 32 * 1024 * 1024) return;
      queue.push(wire); this.early.set(wire.subscriptionId, queue); this.earlyBytes += bytes; return;
    }
    if (known !== sessionId) return;
    try {
      const frame = this.assembler.accept(wire); if (!frame) return;
      const before = this.projections.get(sessionId), after = reduceConversation(before, frame, sessionId);
      this.projections.set(sessionId, after); if (frame.payload.kind === 'snapshot') this.stale.delete(sessionId);
      const a = before && activityFromProjection(before), b = activityFromProjection(after);
      if (!a || JSON.stringify([a.goal, a.subagents, a.availability, a.rows, a.workspaceHookAdmission]) !== JSON.stringify([b.goal, b.subagents, b.availability, b.rows, b.workspaceHookAdmission])) this.events.publish('host.activity', { hostActivity: b }, sessionId);
      this.onProjection?.(sessionId, after, before);
    } catch { this.recover(wire.subscriptionId, 'projectionGap'); }
  }
  recover(subscriptionId, reason) {
    const sessionId = this.subscriptions.get(subscriptionId); if (!sessionId || this.recovering.has(subscriptionId)) return;
    this.stale.add(sessionId); this.assembler.discard(subscriptionId); this.recovering.add(subscriptionId);
    this.events.publish('resync.required', { reason }, sessionId);
    this.protocol.request('v4/conversation/resync', { topic: 'conversation/' + sessionId, subscriptionId, connectionId: this.connectionId, base: null, forceSnapshot: true })
      .catch(() => {}).finally(() => this.recovering.delete(subscriptionId));
  }
}
