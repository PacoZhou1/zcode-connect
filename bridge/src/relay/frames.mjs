import { EventEmitter } from 'node:events';
import { crc32 } from './codec.mjs';
const MAX_MESSAGE = 16 * 1024 * 1024, MAX_FRAME = 1024 * 1024;
const keyFields = ['bridgeSessionId', 'bridgeGeneration', 'recoveryId'];
export function frameIdentity(value) {
  const result = {};
  for (const key of ['bridgeSessionId', 'recoveryId']) if (value[key] !== undefined) { if (typeof value[key] !== 'string' || !/^[A-Za-z0-9._~-]{1,256}$/.test(value[key])) throw new Error('Invalid bridge identity'); result[key] = value[key]; }
  if (!result.bridgeSessionId) throw new Error('Missing bridge session ID');
  if (value.bridgeGeneration !== undefined) { if (!Number.isSafeInteger(value.bridgeGeneration) || value.bridgeGeneration < 0) throw new Error('Invalid bridge generation'); result.bridgeGeneration = value.bridgeGeneration; }
  return result;
}
export function fragmentRPC(bytes, identity, firstSeq = 1, messageSeq = 1, chunkSize = 512 * 1024) {
  bytes = Buffer.from(bytes); identity = frameIdentity(identity);
  if (!bytes.length || bytes.length > MAX_MESSAGE || !Number.isSafeInteger(firstSeq) || firstSeq < 1 || !Number.isSafeInteger(messageSeq) || messageSeq < 1 || !Number.isInteger(chunkSize) || chunkSize < 1 || chunkSize > 512 * 1024) throw new Error('Invalid relay message');
  const fragmentCount = Math.ceil(bytes.length / chunkSize); if (fragmentCount > 64) throw new Error('Relay fragment limit exceeded');
  const checksum = { algorithm: 'crc32', value: crc32(bytes) };
  return Array.from({ length: fragmentCount }, (_, fragmentIndex) => ({ zcode_type: 'rpc-frame', ...identity, seq: firstSeq + fragmentIndex, messageSeq, fragmentIndex, fragmentCount, messageBytes: bytes.length, checksum, dataBase64: bytes.subarray(fragmentIndex * chunkSize, (fragmentIndex + 1) * chunkSize).toString('base64') }));
}
export class RelayFrames extends EventEmitter {
  constructor(identity, send, { now = Date.now } = {}) { super(); this.identity = frameIdentity(identity); this.sendPayload = send; this.now = now; this.nextPhysical = 1; this.nextMessage = 1; this.expectedPhysical = 1; this.expectedMessage = 1; this.outbox = new Map(); this.outboxBytes = 0; this.seen = new Map(); this.active = null; this.failed = false; }
  send(bytes) {
    if (this.failed) throw new Error('Relay transport is degraded');
    const frames = fragmentRPC(bytes, this.identity, this.nextPhysical, this.nextMessage), cost = frames.reduce((total, frame) => total + Buffer.byteLength(JSON.stringify(frame)), 0);
    if (this.outboxBytes + cost > 8 * 1024 * 1024) throw new Error('Relay replay buffer exceeded');
    const seq = this.nextMessage++; this.nextPhysical += frames.length; this.outboxBytes += cost;
    this.outbox.set(seq, { frames, cost, at: this.now() }); for (const frame of frames) this.sendPayload(frame); return seq;
  }
  replay() { this.checkDeadline(); for (const batch of this.outbox.values()) for (const frame of batch.frames) this.sendPayload(frame); }
  checkDeadline() { if (this.active && this.now() - this.active.at > 30000) throw this.fail('Relay assembly timeout'); if (this.outbox.size && this.now() - this.outbox.values().next().value.at > 45000) throw this.fail('Relay acknowledgement timeout'); }
  fail(message) { this.failed = true; this.active = null; this.outbox.clear(); this.outboxBytes = 0; const error = new Error(message); this.emit('degraded', error); return error; }
  accept(frame) {
    if (keyFields.some(key => frame[key] !== this.identity[key])) return false;
    if (this.failed) return false; this.checkDeadline();
    if (frame.zcode_type === 'rpc-frame-ack') {
      if (!Number.isSafeInteger(frame.ackMessageSeq) || frame.ackMessageSeq < 1 || frame.ackMessageSeq >= this.nextMessage) throw this.fail('Invalid relay acknowledgement');
      for (const [seq, batch] of this.outbox) if (seq <= frame.ackMessageSeq) { this.outboxBytes -= batch.cost; this.outbox.delete(seq); } return true;
    }
    if (frame.zcode_type !== 'rpc-frame') return false;
    if (Buffer.byteLength(JSON.stringify(frame)) > MAX_FRAME || !Number.isSafeInteger(frame.seq) || frame.seq < 1 || !Number.isSafeInteger(frame.messageSeq) || frame.messageSeq < 1 || !Number.isInteger(frame.fragmentCount) || frame.fragmentCount < 1 || frame.fragmentCount > 64 || !Number.isInteger(frame.fragmentIndex) || frame.fragmentIndex < 0 || frame.fragmentIndex >= frame.fragmentCount || !Number.isInteger(frame.messageBytes) || frame.messageBytes < 1 || frame.messageBytes > MAX_MESSAGE || frame.checksum?.algorithm !== 'crc32' || !/^[0-9a-f]{8}$/.test(frame.checksum.value) || typeof frame.dataBase64 !== 'string' || !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(frame.dataBase64)) throw this.fail('Invalid relay frame');
    const bytes = Buffer.from(frame.dataBase64, 'base64'); if (!bytes.length || bytes.toString('base64') !== frame.dataBase64) throw this.fail('Invalid relay base64');
    const fingerprint = JSON.stringify(frame), prior = this.seen.get(frame.seq);
    if (prior !== undefined && prior !== fingerprint) throw this.fail('Conflicting relay replay');
    if (frame.seq < this.expectedPhysical) { if (this.expectedMessage > 1) this.ack(this.expectedMessage - 1); return true; }
    if (frame.seq !== this.expectedPhysical || frame.messageSeq !== this.expectedMessage || frame.fragmentIndex !== (this.active?.chunks.length ?? 0)) throw this.fail('Relay sequence gap');
    if (!this.active) this.active = { at: this.now(), chunks: [], bytes: 0, size: frame.messageBytes, count: frame.fragmentCount, checksum: frame.checksum.value };
    const active = this.active;
    if (active.size !== frame.messageBytes || active.count !== frame.fragmentCount || active.checksum !== frame.checksum.value || active.bytes + bytes.length > active.size) throw this.fail('Relay fragment metadata mismatch');
    active.chunks.push(bytes); active.bytes += bytes.length; this.expectedPhysical++; this.seen.set(frame.seq, fingerprint);
    if (active.chunks.length === active.count) {
      const message = Buffer.concat(active.chunks);
      if (message.length !== active.size || crc32(message) !== active.checksum) throw this.fail('Relay checksum mismatch');
      this.active = null; this.expectedMessage++; this.ack(frame.messageSeq); this.emit('message', message);
      while (this.seen.size > 128) this.seen.delete(this.seen.keys().next().value);
    }
    return true;
  }
  ack(seq) { this.sendPayload({ zcode_type: 'rpc-frame-ack', ...this.identity, ackMessageSeq: seq }); }
}
