import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { RelayRegistry } from '../src/registry.mjs';
import { createPassHash } from '../src/auth.mjs';

function store(t, options = {}) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'zcode-relay-registry-'));
  const registry = new RelayRegistry({ directory, ...options });
  t.after(() => { registry.close(); fs.rmSync(directory, { recursive: true, force: true }); });
  return { directory, registry };
}
const hash = createPassHash('synthetic-only-not-a-user-secret');

test('closed enrollment does not allocate a SID or reveal existing credentials', (t) => {
  const { registry } = store(t);
  assert.throws(() => registry.register('known-mid', hash), { code: 'REGISTRATION_DENIED' });
  assert.throws(() => registry.register('known-mid', hash, 'wrong'), { code: 'REGISTRATION_DENIED' });
  assert.equal(registry.lookup('attacker-chosen-sid'), undefined);
});

test('permit is MID-bound, expires, and cannot be reused for another identity', (t) => {
  let now = 1000; const { registry } = store(t, { now: () => now });
  const permit = registry.issueEnrollment('mid-a', 1000);
  assert.throws(() => registry.register('mid-b', hash, permit.enrollmentToken), { code: 'REGISTRATION_DENIED' });
  now = 2000;
  assert.throws(() => registry.register('mid-a', hash, permit.enrollmentToken), { code: 'REGISTRATION_DENIED' });
  const fresh = registry.issueEnrollment('mid-a', 1000);
  const { sid } = registry.register('mid-a', hash, fresh.enrollmentToken);
  assert.ok(sid.startsWith('d_'));
  assert.throws(() => registry.register('mid-b', hash, fresh.enrollmentToken), { code: 'REGISTRATION_DENIED' });
});

test('registration ACK loss is stable but same MID with a changed secret never reclaims SID', (t) => {
  const { registry } = store(t);
  const permit = registry.issueEnrollment('mid');
  const a = registry.register('mid', hash, permit.enrollmentToken);
  assert.deepEqual(registry.register('mid', hash), a);
  assert.throws(() => registry.register('mid', createPassHash('different'), permit.enrollmentToken), { code: 'REGISTRATION_DENIED' });
  assert.equal(registry.lookup(a.sid).passHash, hash);
});

test('explicit operator rotation revokes old SID only when fresh registration succeeds', (t) => {
  const { registry } = store(t); const permit = registry.issueEnrollment('mid');
  const original = registry.register('mid', hash, permit.enrollmentToken);
  assert.throws(() => registry.issueEnrollment('mid'), { code: 'DEVICE_ALREADY_ENROLLED' });
  const rotation = registry.issueEnrollment('mid', 1000, { rotate: true });
  assert.ok(registry.lookup(original.sid));
  assert.throws(() => registry.register('mid', createPassHash('new'), 'wrong'), { code: 'REGISTRATION_DENIED' });
  assert.ok(registry.lookup(original.sid));
  const replacement = registry.register('mid', createPassHash('new'), rotation.enrollmentToken);
  assert.notEqual(replacement.sid, original.sid); assert.equal(replacement.replacedSID, original.sid);
  assert.equal(registry.lookup(original.sid), undefined);
  assert.equal(registry.lookup(replacement.sid).passHash, createPassHash('new'));
  assert.throws(() => registry.register('mid', hash, permit.enrollmentToken), { code: 'REGISTRATION_DENIED' });
});

test('private atomic registry survives restart and rejects simultaneous owner', (t) => {
  const { registry, directory } = store(t); const permit = registry.issueEnrollment('mid');
  const original = registry.register('mid', hash, permit.enrollmentToken);
  assert.throws(() => new RelayRegistry({ directory }), { code: 'REGISTRY_LOCKED' });
  assert.equal(fs.statSync(path.join(directory, 'registry.json')).mode & 0o777, 0o600);
  registry.close();
  const restarted = new RelayRegistry({ directory });
  assert.equal(restarted.lookup(original.sid).passHash, hash); restarted.close();
});

test('SIGKILL releases kernel lock without unlinking lock inode; competing owners still fail', async (t) => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'zcode-relay-kill-'));
  const source = new URL('../src/registry.mjs', import.meta.url).href;
  const child = spawn(process.execPath, ['--input-type=module', '-e',
    `import { RelayRegistry } from ${JSON.stringify(source)}; const registry = new RelayRegistry({ directory: process.argv[1] }); process.send('locked'); setInterval(() => {}, 1000);`, directory],
  { stdio: ['ignore', 'ignore', 'ignore', 'ipc'] });
  t.after(() => { child.kill('SIGKILL'); fs.rmSync(directory, { recursive: true, force: true }); });
  await once(child, 'message');
  const inode = fs.statSync(path.join(directory, 'registry.lock')).ino;
  assert.throws(() => new RelayRegistry({ directory }), { code: 'REGISTRY_LOCKED' });
  const exited = once(child, 'exit'); child.kill('SIGKILL'); await exited;
  const restored = new RelayRegistry({ directory });
  assert.equal(fs.statSync(path.join(directory, 'registry.lock')).ino, inode);
  assert.throws(() => new RelayRegistry({ directory }), { code: 'REGISTRY_LOCKED' });
  restored.close();
});

test('unsafe directory, symlink registry, and malformed persisted identity fail closed', (t) => {
  const { registry, directory } = store(t); registry.close();
  fs.chmodSync(directory, 0o755);
  assert.throws(() => new RelayRegistry({ directory }), { code: 'PRIVATE_STATE_REQUIRED' });
  fs.chmodSync(directory, 0o700);
  const file = path.join(directory, 'registry.json');
  fs.writeFileSync(file, '{}');
  assert.throws(() => new RelayRegistry({ directory }), { code: 'INVALID_REGISTRY' });
  fs.unlinkSync(file); fs.symlinkSync(path.join(directory, 'registry.lock'), file);
  assert.throws(() => new RelayRegistry({ directory }), { code: 'PRIVATE_STATE_REQUIRED' });
});
