import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { spawn, spawnSync } from 'node:child_process';
import { once } from 'node:events';
import { fileURLToPath } from 'node:url';
import { createPassHash } from '../src/auth.mjs';
import { peer, authenticate } from './helpers.mjs';

const cli = fileURLToPath(new URL('../src/cli.mjs', import.meta.url));
const run = (args) => spawnSync(process.execPath, [cli, ...args], { encoding: 'utf8' });

test('CLI private enrollment, actual listener, SIGKILL restart, persisted auth and cleanup', async (t) => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'zcode-relay-cli-'));
  const children = [];
  t.after(async () => {
    for (const child of children) if (child.exitCode === null && child.signalCode === null) {
      const exited = once(child, 'exit'); child.kill('SIGTERM'); await exited;
    }
    fs.rmSync(directory, { recursive: true, force: true });
  });
  const state = path.join(directory, 'state'); const out = path.join(directory, 'enrollment.json');
  const common = ['--state-dir', state, '--origin', 'https://relay.example.test:8443'];
  const enrolled = run(['enroll', ...common, '--mid', 'synthetic-cli', '--out', out]);
  assert.equal(enrolled.status, 0); const secretConfig = JSON.parse(fs.readFileSync(out));
  assert.equal(fs.statSync(out).mode & 0o777, 0o600);
  assert.ok(!enrolled.stdout.includes(secretConfig.enrollmentToken));
  async function start() {
    const child = spawn(process.execPath, [cli, 'start', ...common, '--port', '0'], { stdio: ['ignore', 'pipe', 'pipe'] });
    children.push(child); let buffer = '';
    const meta = await new Promise((resolve, reject) => {
      const timeout = setTimeout(() => reject(new Error('CLI_START_TIMEOUT')), 3000);
      child.stdout.on('data', (data) => { buffer += data; if (buffer.includes('\n')) { clearTimeout(timeout); resolve(JSON.parse(buffer.split('\n')[0])); } });
      child.once('error', reject);
      child.once('exit', () => { if (!buffer) { clearTimeout(timeout); reject(new Error('CLI_EXITED_BEFORE_LISTEN')); } });
    });
    assert.equal(meta.host, '127.0.0.1'); assert.equal(meta.pid, child.pid);
    assert.equal((await fetch(`http://127.0.0.1:${meta.port}/zcode/health`)).status, 200);
    return { child, url: `ws://127.0.0.1:${meta.port}/zcode/ws`, meta };
  }
  const first = await start();
  const passHash = createPassHash('synthetic-cli-password');
  const device = await peer(`${first.url}?enroll=${secretConfig.enrollmentToken}`);
  device.send({ type: 'device_register_init', device_mid: 'synthetic-cli', pass_hash: passHash });
  const ack = (await device.next()).json; assert.equal(ack.type, 'device_register_ack');
  assert.equal((await authenticate(device, { sid: ack.device_sid, passHash }, 'device')).pair_status, 'waiting');
  const denied = run(['enroll', ...common, '--mid', 'other', '--out', path.join(directory, 'other.json')]);
  assert.notEqual(denied.status, 0); assert.equal(denied.stderr.trim(), 'REGISTRY_LOCKED');
  const exited = once(first.child, 'exit'); first.child.kill('SIGKILL'); await exited;
  const restarted = await start();
  const resumed = await peer(restarted.url);
  assert.equal((await authenticate(resumed, { sid: ack.device_sid, passHash }, 'device')).pair_status, 'waiting');
  await resumed.close(); await device.close();
});

test('CLI rejects unsafe options without echoing unknown argument secrets', () => {
  const invalid = run(['start', '--unknown=SYNTHETIC_DO_NOT_ECHO']);
  assert.notEqual(invalid.status, 0); assert.ok(!invalid.stderr.includes('SYNTHETIC_DO_NOT_ECHO'));
  assert.equal(invalid.stderr.trim(), 'ERR_PARSE_ARGS_UNKNOWN_OPTION');
});
