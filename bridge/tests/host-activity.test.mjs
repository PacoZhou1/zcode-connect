import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { readFileSync } from 'node:fs';
import { ConversationAssembler, reduceConversation, activityFromProjection, emptyHostActivity, HostActivity } from '../src/host-activity.mjs';
import { EventJournal } from '../src/events.mjs';
import { crc32 } from '../src/relay/codec.mjs';

const fixture = JSON.parse(readFileSync(new URL('../../tests/fixtures/bridge/host-activity.json', import.meta.url), 'utf8')).wires[0];
const sessionId = fixture.frame.payload.snapshot.sessionId;
const delta = (from, to, deltas) => ({ topic: fixture.topic, subscriptionId: fixture.subscriptionId, fromSeq: from, toSeq: to, payload: { kind: 'deltas', deltas } });

test('real CLI empty activity preserves original goal, agents and action availability', () => {
  const assembler = new ConversationAssembler(), frame = assembler.accept(fixture), projection = reduceConversation(null, frame, sessionId), activity = activityFromProjection(projection);
  assert.equal(activity.goal, null); assert.equal(activity.subagents.endedTotal, 0); assert.deepEqual(activity.subagents.childSessionIds, []);
  assert.equal(activity.availability.pauseGoal.reasonCode, 'noGoalToPause'); assert.equal(activity.availability.resumeGoal.allowed, false);
  assert.equal(assembler.accept(fixture), null);
  assert.equal(emptyHostActivity('desktopReadOnly').supported, false);
});

test('fragmented v3 activity validates CRC, duplicate fragments, order, identity and deadline', () => {
  const frame = structuredClone(fixture.frame); frame.payload.snapshot.meta.title = '真实状态'.repeat(90000);
  const bytes = Buffer.from(JSON.stringify(frame)), count = Math.ceil(bytes.length / 160000);
  const wires = Array.from({ length: count }, (_, index) => ({ wireVersion: 3, kind: 'fragment', topic: fixture.topic, subscriptionId: fixture.subscriptionId, deliveryKind: 'initial', logicalFrameId: 'large', logicalFrameOrdinal: 1, fragmentIndex: index, fragmentCount: count, logicalBytes: bytes.length, checksum: { algorithm: 'crc32', value: crc32(bytes) }, dataBase64: bytes.subarray(index * 160000, (index + 1) * 160000).toString('base64') }));
  const assembler = new ConversationAssembler(); assert.equal(assembler.accept(wires[1], 0), null); assert.equal(assembler.accept(wires[1], 0), null);
  let result; for (const wire of wires.filter((_, index) => index !== 1)) result = assembler.accept(wire, 0) ?? result;
  assert.deepEqual(result, frame); assert.equal(assembler.bytes, 0); assert.equal(assembler.accept(wires[0], 0), null);
  const conflicting = new ConversationAssembler(); conflicting.accept(wires[0], 0); assert.throws(() => conflicting.accept({ ...wires[0], dataBase64: Buffer.from('changed').toString('base64') }, 0));
  assert.deepEqual(conflicting.expire(30001), [fixture.subscriptionId]); assert.equal(conflicting.bytes, 0);
  assert.throws(() => new ConversationAssembler().accept({ ...fixture, frame: { ...fixture.frame, topic: 'conversation/other' } }));
});

test('atomic activity deltas keep real goals and agent counts, reject gaps and prevent prototype mutation', () => {
  const initial = reduceConversation(null, fixture.frame, sessionId), goal = { targetId: 'host-goal', objective: 'Host objective', status: 'active', timeUsedSeconds: 17, activeRunStartedAtMs: 1000, iteration: 2 };
  const agents = { revision: 5, childSessionIds: ['child-a', 'child-ended'], running: [{ childSessionId: 'child-a', status: 'running' }], endedTotal: 1 };
  const next = reduceConversation(initial, delta(0, 1, [{ op: 'state.updated', patch: { goal, subagents: agents, revision: 1 } }]), sessionId);
  assert.equal(initial.goal, null); assert.deepEqual(activityFromProjection(next).goal, goal); assert.deepEqual(activityFromProjection(next).subagents, agents);
  assert.equal(reduceConversation(next, delta(0, 1, []), sessionId), next);
  assert.throws(() => reduceConversation(next, delta(2, 3, []), sessionId));
  assert.throws(() => reduceConversation(next, delta(1, 2, [{ op: 'state.updated', patch: { goal: null } }, { op: 'unexpected' }]), sessionId)); assert.deepEqual(next.goal, goal);
  const polluting = JSON.parse('{"__proto__":{"polluted":true}}'); assert.throws(() => reduceConversation(next, delta(1, 2, [{ op: 'state.updated', patch: polluting }]), sessionId)); assert.equal({}.polluted, undefined);
  const cleared = reduceConversation(next, delta(1, 2, [{ op: 'state.updated', patch: { goal: null, subagents: { revision: 6, childSessionIds: [], running: [], endedTotal: 0 } } }]), sessionId);
  assert.equal(activityFromProjection(cleared).goal, null); assert.deepEqual(activityFromProjection(cleared).subagents.childSessionIds, []);
});

test('subscription listener captures a snapshot before ACK and resyncs once after a sequence gap', async t => {
  class Protocol extends EventEmitter {
    ready = true; calls = [];
    async request(method, params) {
      this.calls.push({ method, params });
      if (method === 'v4/conversation/subscribe') { this.emit('conversationFrame', fixture); return { ack: { subscriptionId: fixture.subscriptionId, mode: 'snapshot', logEpoch: fixture.frame.payload.snapshot.logEpoch } }; }
      if (method === 'v4/conversation/resync') { this.emit('conversationFrame', { ...fixture, deliveryKind: 'recovery', logicalFrameId: 'recovery', logicalFrameOrdinal: 3 }); return {}; }
      throw new Error('Unexpected request');
    }
  }
  const protocol = new Protocol(), events = new EventJournal(), activity = new HostActivity({ protocol, events, isOwned: id => id === sessionId }); t.after(() => activity.close());
  const [first, second] = await Promise.all([activity.ensure(sessionId), activity.ensure(sessionId)]); assert.equal(first.sessionId, sessionId); assert.equal(second, first); assert.equal(protocol.calls.length, 1);
  protocol.emit('conversationFrame', { ...fixture, deliveryKind: 'online', logicalFrameId: 'gap', logicalFrameOrdinal: 2, frame: delta(4, 5, []) });
  await new Promise(resolve => setImmediate(resolve)); assert.equal(protocol.calls.filter(call => call.method.endsWith('/resync')).length, 1);
  assert.equal(activity.stale.has(sessionId), false); assert.equal(activity.projections.get(sessionId).goal, null);
  await assert.rejects(activity.ensure('desktop-owned'), { code: 'session_read_only' });
  assert.equal(events.entries.filter(event => event.type === 'host.activity').length, 1);
});
