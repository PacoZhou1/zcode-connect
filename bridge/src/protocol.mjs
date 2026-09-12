import { EventEmitter } from 'node:events';
import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { randomUUID } from 'node:crypto';
import { mkdirSync } from 'node:fs';
import { join } from 'node:path';
import { BridgeError, iso, sanitize } from './util.mjs';

export class ZCodeProtocol extends EventEmitter {
  constructor({ cliPath, runtimeDir, cwd, preferences = {} }) {
    super(); Object.assign(this, { cliPath, runtimeDir, cwd, preferences });
    this.pending = new Map(); this.interactions = new Map(); this.ready = false; this.child = null;
  }
  async start() {
    if (this.ready) return;
    if (this.starting) return this.starting;
    this.starting = this.launch();
    try { await this.starting; } finally { this.starting = null; }
  }
  async launch() {
    mkdirSync(join(this.runtimeDir, 'zcode/cli/db'), { recursive: true, mode: 0o700 });
    this.child = spawn(process.execPath, [this.cliPath, 'app-server', '--stdio', '--surface', 'terminal'], {
      cwd: this.cwd, stdio: ['pipe', 'pipe', 'pipe'],
      env: { ...process.env, ZCODE_STORAGE_DIR: join(this.runtimeDir, 'zcode'), ZCODE_SESSION_DB_PATH: join(this.runtimeDir, 'zcode/cli/db/db.sqlite') },
    });
    const child = this.child;
    const lines = createInterface({ input: child.stdout });
    lines.on('line', line => {
      try { this.onFrame(JSON.parse(line)); }
      catch { this.emit('diagnostic', { kind: 'invalid_protocol_frame', bytes: Buffer.byteLength(line) }); }
    });
    // Do not retain CLI logs, which can include prompt bodies and provider metadata.
    child.stderr.on('data', data => this.emit('diagnostic', { kind: 'runtime_stderr', bytes: data.length }));
    child.on('error', error => { if (this.child === child) this.exited(error.message); });
    child.on('exit', (code, signal) => { lines.close(); if (this.child === child) this.exited(`CLI exited (${code ?? signal}).`); });
    try { await this.request('session/list', { limit: 1 }, 15000); }
    catch (error) { await this.close(); throw error; }
    this.ready = true;
    this.emit('ready');
  }
  exited(message) {
    this.ready = false; this.child = null;
    for (const { reject, timer } of this.pending.values()) { clearTimeout(timer); reject(new BridgeError(503, 'runtime_unavailable', message, true)); }
    this.pending.clear(); this.interactions.clear(); this.emit('disconnected', message);
  }
  write(frame) {
    if (!this.child?.stdin.writable) throw new BridgeError(503, 'runtime_unavailable', 'ZCode runtime is not connected.', true);
    this.child.stdin.write(JSON.stringify(frame) + '\n');
  }
  request(method, params = {}, timeout = 30000) {
    const id = randomUUID();
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => { this.pending.delete(id); reject(new BridgeError(504, 'runtime_timeout', `ZCode did not answer ${method} before the deadline.`, true)); }, timeout);
      this.pending.set(id, { resolve, reject, timer });
      try { this.write({ id, method, params }); } catch (error) { clearTimeout(timer); this.pending.delete(id); reject(error); }
    });
  }
  onFrame(frame) {
    if (frame.id !== undefined && frame.method) { this.onRequest(frame); return; }
    if (frame.id !== undefined) {
      const request = this.pending.get(frame.id); if (!request) return;
      clearTimeout(request.timer); this.pending.delete(frame.id);
      if (frame.error) request.reject(new BridgeError(frame.error.code === -32010 ? 409 : 502, frame.error.code === -32010 ? 'session_busy' : 'zcode_error', frame.error.message || 'ZCode protocol error.', false, sanitize({ protocolCode: frame.error.code, data: frame.error.data })));
      else request.resolve(frame.result);
      return;
    }
    if (frame.method === 'session/event') this.emit('sessionEvent', sanitize(frame.params));
    // Internal bytes must remain exact for checksum validation; only the validated activity DTO is exposed/sanitized.
    else if (frame.method === 'v4/conversation/frame') this.emit('conversationFrame', frame.params);
  }
  onRequest(frame) {
    if (frame.method === 'session/requestRuntimePreferences') {
      this.write({ id: frame.id, result: { nativeSearchEnhancementsEnabled: this.preferences.nativeSearchEnhancementsEnabled ?? true,
        memoryEnabled: false, askUserQuestionAutoResolutionEnabled: false, modelContextBudgetStrategy: 'preflight-v1' } }); return;
    }
    if (frame.method === 'interaction/requestProviderRuntimeHeaders') {
      this.write({ id: frame.id, result: { headersApplied: false } }); return;
    }
    if (['interaction/requestPermission', 'interaction/requestUserInput'].includes(frame.method)) {
      const id = frame.params.requestId ?? String(frame.id);
      this.interactions.set(id, { ...frame, receivedAt: iso() }); this.emit('interaction', { id, frame: sanitize(frame) }); return;
    }
    this.write({ id: frame.id, error: { code: -32601, message: `Mobile bridge does not implement ${frame.method}.` } });
  }
  respond(id, response) {
    const frame = this.interactions.get(id);
    if (!frame) throw new BridgeError(404, 'not_found', 'This request is no longer pending.');
    const permission = frame.method === 'interaction/requestPermission', allowed = permission ? ['decision', 'reason'] : ['action', 'content'];
    if (Object.keys(response).some(key => !allowed.includes(key))) throw new BridgeError(422, 'invalid_request', `Response fields are limited to ${allowed.join(' and ')}.`);
    if (permission && !['allow', 'deny'].includes(response.decision)) throw new BridgeError(422, 'invalid_request', 'Permission decisions must be allow or deny.');
    if (permission && response.reason !== undefined && (typeof response.reason !== 'string' || response.reason.length > 4000)) throw new BridgeError(422, 'invalid_request', 'reason must be text of at most 4000 characters.');
    if (!permission && !['accept', 'decline', 'cancel'].includes(response.action)) throw new BridgeError(422, 'invalid_request', 'Question responses must be accept, decline, or cancel.');
    if (!permission && response.content !== undefined) {
      const content = response.content, validAnswer = value => typeof value === 'string' && value.length <= 16000 || Array.isArray(value) && value.length <= 30 && value.every(item => typeof item === 'string' && item.length <= 4000);
      if (!content || typeof content !== 'object' || Array.isArray(content) || Object.keys(content).some(key => !['answer', 'answers'].includes(key)) || content.answer !== undefined && !validAnswer(content.answer) || content.answers !== undefined && (!content.answers || typeof content.answers !== 'object' || Array.isArray(content.answers) || Object.keys(content.answers).length > 30 || !Object.values(content.answers).every(validAnswer))) throw new BridgeError(422, 'invalid_request', 'content accepts answer or answers keyed by the exact question text.');
    }
    this.write({ id: frame.id, result: response }); this.interactions.delete(id);
    return frame.params.sessionId;
  }
  async close() {
    if (!this.child) return;
    const child = this.child;
    await new Promise(resolve => {
      const timer = setTimeout(() => { child.kill('SIGTERM'); resolve(); }, 2500);
      child.once('exit', () => { clearTimeout(timer); resolve(); }); child.stdin.end();
    });
  }
}
