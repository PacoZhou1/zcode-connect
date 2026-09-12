import { createHash, randomBytes, timingSafeEqual } from 'node:crypto';
import { mkdirSync, readFileSync, writeFileSync, renameSync, chmodSync, existsSync } from 'node:fs';
import { dirname } from 'node:path';

export class BridgeError extends Error {
  constructor(status, code, message, retryable = false, details) {
    super(message);
    Object.assign(this, { status, code, retryable, details });
  }
}

export const iso = value => new Date(value || Date.now()).toISOString();
export const hash = text => createHash('sha256').update(text).digest('hex');
export const projectId = path => `project_${hash(path).slice(0, 20)}`;
export function readJSON(path, fallback = {}) {
  try { return JSON.parse(readFileSync(path, 'utf8')); }
  catch (error) { if (error.code === 'ENOENT') return fallback; throw error; }
}
export function saveJSON(path, value) {
  mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
  const temp = `${path}.${process.pid}.tmp`;
  writeFileSync(temp, JSON.stringify(value, null, 2) + '\n', { mode: 0o600 });
  renameSync(temp, path);
}
export function ensureToken(path) {
  mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
  if (!existsSync(path)) writeFileSync(path, randomBytes(32).toString('base64url') + '\n', { mode: 0o600, flag: 'wx' });
  chmodSync(path, 0o600);
  const token = readFileSync(path, 'utf8').trim();
  if (token.length < 32) throw new Error('Pairing token must contain at least 32 characters.');
  return token;
}
export function authorized(header, token) {
  const value = typeof header === 'string' && header.startsWith('Bearer ') ? header.slice(7) : '';
  const a = Buffer.from(value), b = Buffer.from(token);
  return a.length === b.length && timingSafeEqual(a, b);
}
export function sanitize(value) {
  if (Array.isArray(value)) return value.map(sanitize);
  if (value && typeof value === 'object') return Object.fromEntries(Object.entries(value).map(([k, v]) => [k, /api.?key|access.?token|refresh.?token|authorization|credential|password|secret/i.test(k) ? '[redacted]' : sanitize(v)]));
  return typeof value === 'string' ? value.replace(/\bBearer\s+[A-Za-z0-9._~+/=-]+/gi, 'Bearer [redacted]') : value;
}
export function requireString(value, name, max = 32000) {
  if (typeof value !== 'string' || !value.trim() || value.length > max) throw new BridgeError(422, 'invalid_request', `${name} must be a nonempty string of at most ${max} characters.`);
  return value.trim();
}
