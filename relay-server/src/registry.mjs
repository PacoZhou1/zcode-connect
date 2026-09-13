import fs from 'node:fs';
import path from 'node:path';
import fsExt from 'fs-ext';
import { digest, equalSecret, RelayPolicyError, token, validID, validPassHash } from './auth.mjs';

function policy(code) { throw new RelayPolicyError(code); }
function privatePath(file, type) {
  const stat = fs.lstatSync(file);
  if (stat.isSymbolicLink() || (type === 'dir' ? !stat.isDirectory() : !stat.isFile())
      || (stat.mode & 0o077) !== 0 || (process.getuid && stat.uid !== process.getuid())) {
    policy('PRIVATE_STATE_REQUIRED');
  }
}

// This store contains bearer-equivalent pass hashes. Never serialize it into HTTP or logs.
// A process lock prevents two relay processes from disagreeing about controller ownership.
export class RelayRegistry {
  #state; #lock; #closed = false;
  constructor({ directory, now = Date.now, maxDevices = 64 }) {
    this.directory = path.resolve(directory); this.now = now; this.maxDevices = maxDevices;
    fs.mkdirSync(this.directory, { recursive: true, mode: 0o700 });
    privatePath(this.directory, 'dir');
    this.file = path.join(this.directory, 'registry.json');
    this.lockFile = path.join(this.directory, 'registry.lock');
    try {
      this.#lock = fs.openSync(this.lockFile, fs.constants.O_RDWR | fs.constants.O_CREAT | fs.constants.O_NOFOLLOW, 0o600);
      privatePath(this.lockFile, 'file');
      fsExt.flockSync(this.#lock, 'exnb');
    } catch (error) {
      if (this.#lock !== undefined) { fs.closeSync(this.#lock); this.#lock = undefined; }
      if (error?.code === 'PRIVATE_STATE_REQUIRED') throw error;
      policy('REGISTRY_LOCKED');
    }
    try {
      fs.ftruncateSync(this.#lock, 0);
      fs.writeFileSync(this.#lock, `${process.pid}\n`); fs.fsyncSync(this.#lock);
      if (fs.existsSync(this.file)) {
        privatePath(this.file, 'file');
        if (fs.statSync(this.file).size > 1024 * 1024) policy('INVALID_REGISTRY');
        this.#state = JSON.parse(fs.readFileSync(this.file, 'utf8'));
        const s = this.#state;
        if (s.version !== 1 || !Array.isArray(s.devices) || !Array.isArray(s.permits)
          || s.devices.length > maxDevices || s.permits.length > 128
          || s.devices.some((d) => !validID(d.sid) || !validID(d.mid) || !validPassHash(d.passHash))
          || new Set(s.devices.map((d) => d.sid)).size !== s.devices.length
          || new Set(s.devices.map((d) => d.mid)).size !== s.devices.length
          || s.permits.some((p) => !validID(p.mid) || !/^[a-f0-9]{64}$/.test(p.tokenDigest)
            || !Number.isSafeInteger(p.expiresAt))) policy('INVALID_REGISTRY');
      } else {
        this.#state = { version: 1, devices: [], permits: [] }; this.#save();
      }
    } catch (error) { this.close(); throw error; }
  }

  #save() {
    if (this.#closed) policy('REGISTRY_CLOSED');
    const temporary = `${this.file}.${token()}.tmp`;
    let fd;
    try {
      fd = fs.openSync(temporary, 'wx', 0o600);
      fs.writeFileSync(fd, `${JSON.stringify(this.#state)}\n`); fs.fsyncSync(fd);
      fs.closeSync(fd); fd = undefined;
      fs.renameSync(temporary, this.file);
      const dir = fs.openSync(this.directory, 'r');
      try { fs.fsyncSync(dir); } finally { fs.closeSync(dir); }
    } finally {
      if (fd !== undefined) fs.closeSync(fd);
      if (fs.existsSync(temporary)) fs.unlinkSync(temporary);
    }
  }

  issueEnrollment(mid, ttlMs = 10 * 60_000, { rotate = false } = {}) {
    if (!validID(mid) || !Number.isInteger(ttlMs) || ttlMs < 1_000 || ttlMs > 15 * 60_000) policy('INVALID_ENROLLMENT');
    const existing = this.#state.devices.find((d) => d.mid === mid);
    if (existing && !rotate) policy('DEVICE_ALREADY_ENROLLED');
    if (!existing && rotate) policy('ROTATION_REQUIRES_EXISTING_DEVICE');
    const permits = this.#state.permits.filter((p) => p.expiresAt > this.now() && p.mid !== mid);
    if (permits.length >= 128) policy('ENROLLMENT_LIMIT');
    const secret = token(); const expiresAt = this.now() + ttlMs;
    const before = this.#state;
    this.#state = { ...before, permits: [...permits, { mid, expiresAt, tokenDigest: digest(secret),
      ...(existing ? { replacesSID: existing.sid } : {}) }] };
    try { this.#save(); } catch (error) { this.#state = before; throw error; }
    return { enrollmentToken: secret, expiresAt, deviceMid: mid, rotation: !!existing };
  }

  register(mid, passHash, enrollmentToken) {
    if (!validID(mid) || !validPassHash(passHash)) policy('WRONG_PARAM');
    const existing = this.#state.devices.find((d) => d.mid === mid);
    if (existing && equalSecret(existing.passHash, passHash)) {
      // ACK loss is idempotent. A different secret never changes the existing SID or trust.
      return { sid: existing.sid };
    }
    if (typeof enrollmentToken !== 'string' || enrollmentToken.length > 128) policy('REGISTRATION_DENIED');
    const tokenDigest = digest(enrollmentToken);
    const permit = this.#state.permits.find((p) => p.mid === mid && p.expiresAt > this.now()
      && equalSecret(p.tokenDigest, tokenDigest));
    if (!permit || (existing ? permit.replacesSID !== existing.sid : permit.replacesSID !== undefined)
      || (!existing && this.#state.devices.length >= this.maxDevices)) policy('REGISTRATION_DENIED');
    const sid = `d_${token()}`;
    const before = this.#state;
    this.#state = { ...before,
      devices: [...before.devices.filter((d) => d !== existing), { sid, mid, passHash, createdAt: this.now() }],
      permits: before.permits.filter((p) => p !== permit)
    };
    try { this.#save(); } catch (error) { this.#state = before; throw error; }
    return { sid, ...(existing ? { replacedSID: existing.sid } : {}) };
  }

  // Used only by the relay authentication state machine; never exposed as a service route.
  lookup(sid) {
    if (this.#closed) policy('REGISTRY_CLOSED');
    const row = this.#state.devices.find((d) => d.sid === sid);
    return row ? { ...row } : undefined;
  }

  close() {
    if (this.#closed) return;
    this.#closed = true;
    if (this.#lock !== undefined) {
      // Never unlink the inode: another process may already have opened it for flock.
      // The kernel releases ownership even after SIGKILL; stale PID text is informational only.
      fs.closeSync(this.#lock); this.#lock = undefined;
    }
  }
}
