import test from 'node:test';
import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { encodeIPC, decodeIPC, crc32 } from '../src/relay/codec.mjs';
import { RelayFrames, fragmentRPC } from '../src/relay/frames.mjs';
import { OfficialRelayClient, parseOfficialPairing } from '../src/relay/client.mjs';

const identity = { bridgeSessionId: 'bridge-test', bridgeGeneration: 1, recoveryId: 'recovery-test' };
test('IPC codec matches independently extracted official web client vectors', () => {
  const evidence = JSON.parse(readFileSync(new URL('../../docs/backend/evidence/relay-ipc-vectors.json', import.meta.url)));
  for (const vector of evidence.vectors) { const encoded = encodeIPC(vector.header, vector.body); assert.equal(encoded.toString('hex'), vector.hex); assert.deepEqual(decodeIPC(encoded), { header: vector.header, body: vector.body }); }
  assert.equal(crc32(Buffer.from('123456789')), 'cbf43926');
  assert.throws(() => decodeIPC(Buffer.from([4, 3, 1])), /Truncated/);
});

test('relay framing reassembles, acknowledges, deduplicates, and rejects corrupt or missing fragments', () => {
  const messages = [], acks = [], receiver = new RelayFrames(identity, frame => acks.push(frame)), content = Buffer.alloc(700000, 73), frames = fragmentRPC(content, identity);
  receiver.on('message', bytes => messages.push(bytes)); receiver.accept(frames[0]); receiver.accept(frames[0]); receiver.accept(frames[1]); receiver.accept(frames[1]);
  assert.equal(messages.length, 1); assert.ok(messages[0].equals(content)); assert.equal(acks.at(-1).ackMessageSeq, 1);
  const wrongIdentity = { ...frames[0], bridgeSessionId: 'other' }; assert.equal(receiver.accept(wrongIdentity), false);
  assert.throws(() => new RelayFrames(identity, () => {}).accept(frames[1]), /sequence gap/);
  const corrupt = fragmentRPC(Buffer.from('original'), identity)[0]; corrupt.dataBase64 = Buffer.from('modified').toString('base64'); assert.throws(() => new RelayFrames(identity, () => {}).accept(corrupt), /metadata mismatch|checksum mismatch/);
  assert.throws(() => receiver.accept({ ...frames[1], checksum: { algorithm: 'crc32', value: '00000000' } }), /Conflicting/);
});

test('relay outbox retains uncertain sends until acknowledgement and bounds recovery time', () => {
  const sent = []; let now = 0; const sender = new RelayFrames(identity, frame => sent.push(frame), { now: () => now });
  sender.send(Buffer.from('one')); sender.replay(); assert.equal(sent.length, 2);
  sender.accept({ zcode_type: 'rpc-frame-ack', ...identity, ackMessageSeq: 1 }); assert.equal(sender.outbox.size, 0);
  sender.send(Buffer.from('two')); now = 46000; assert.throws(() => sender.checkDeadline(), /acknowledgement timeout/);
});

const passHash = 'mock-pairing-value-0123456789-abcdef', pairingURL = 'https://zcode.z.ai/remote/v4?sid=mock-desktop&hash=' + passHash;
class MockSocket extends EventTarget {
  static calls = []; readyState = 0;
  constructor(url) { super(); assert.equal(new URL(url).origin, 'wss://zcode.z.ai'); queueMicrotask(() => { this.readyState = 1; this.dispatchEvent(new Event('open')); }); }
  deliver(value) { this.dispatchEvent(new MessageEvent('message', { data: JSON.stringify(value) })); }
  payload(value) { this.deliver({ type: 'data', payload: value }); }
  send(text) {
    const frame = JSON.parse(text);
    if (frame.type === 'auth_init') queueMicrotask(() => this.deliver({ type: 'auth_challenge', nonce: 'nonce-test' }));
    else if (frame.type === 'auth_response') { assert.equal(frame.proof, createHmac('sha256', passHash).update('nonce-test|terminal|mock-desktop').digest('base64url')); queueMicrotask(() => this.deliver({ type: 'auth_ack', pair_status: 'matched' })); }
    else if (frame.type === 'data') {
      const payload = frame.payload;
      if (payload.zcode_type === 'bootstrap-request') queueMicrotask(() => this.payload({ zcode_type: 'bootstrap-response', requestId: payload.requestId, success: true, result: { workspaces: [{ workspacePath: '/workspace', kind: 'local' }] } }));
      else if (payload.zcode_type === 'workspace-bridge-open') {
        const bridge = { bridgeSessionId: payload.bridgeSessionId, bridgeGeneration: payload.bridgeGeneration, workspaceKey: '/workspace', workspacePath: '/workspace', kind: 'local' };
        this.frames = new RelayFrames(bridge, frame => queueMicrotask(() => this.payload(frame)));
        this.frames.on('message', bytes => { const { header, body } = decodeIPC(bytes); MockSocket.calls.push({ header, body }); if (header[0] === 100) this.frames.send(encodeIPC([201, header[1]], [{ taskId: 'existing-original-runtime', title: 'Original desktop task' }])); });
        queueMicrotask(() => { this.payload({ zcode_type: 'workspace-bridge-ready', bridgeSessionId: bridge.bridgeSessionId, bridge }); queueMicrotask(() => this.frames.send(encodeIPC([200], undefined))); });
      } else this.frames.accept(payload);
    }
  }
  close() { this.readyState = 3; this.dispatchEvent(new Event('close')); }
}

test('official relay flow confirms controller replacement, authenticates, bootstraps and reads the original host service', async t => {
  assert.throws(() => parseOfficialPairing(pairingURL.replace('https:', 'http:')), /official HTTPS/);
  assert.throws(() => parseOfficialPairing(pairingURL.replace('zcode.z.ai', 'untrusted.invalid')), /official HTTPS/);
  assert.throws(() => parseOfficialPairing(pairingURL + '&sid=second'), /Ambiguous/);
  const client = new OfficialRelayClient({ WebSocketClass: MockSocket, requestTimeout: 500 }); t.after(() => client.disconnect());
  await assert.rejects(client.connect(pairingURL), { code: 'controller_confirmation_required' });
  await client.connect(pairingURL, { confirmedControllerReplacement: true }); assert.equal(client.safeStatus().state, 'paired'); assert.equal(JSON.stringify(client.safeStatus()).includes(passHash), false);
  assert.equal((await client.bootstrap()).workspaces.length, 1); await client.openWorkspace('/workspace');
  const tasks = await client.rpc('zcode-task', 'listTasks'); assert.equal(tasks[0].taskId, 'existing-original-runtime');
  assert.deepEqual(MockSocket.calls.at(-1).body, [{ workspacePath: '/workspace' }]);
  await assert.rejects(client.rpc('credential', 'get'), { code: 'relay_method_unsupported' });
  await assert.rejects(client.rpc('zcode-task', 'archiveTask', { taskId: 'original' }), { code: 'explicit_action_required' });
  client.socket.deliver({ type: 'error', code: 'KICKED' }); assert.equal(client.state, 'replaced'); assert.equal(client.socket, undefined);
});
