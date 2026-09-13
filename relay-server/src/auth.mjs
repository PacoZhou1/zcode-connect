import { createHash, createHmac, randomBytes, timingSafeEqual } from 'node:crypto';

export const MAX_FRAME_BYTES = 1024 * 1024;
export const token = () => randomBytes(32).toString('base64url');
export const digest = (text) => createHash('sha256').update(text, 'utf8').digest('hex');
export const createPassHash = (password) => createHash('sha256').update(password, 'utf8').digest('base64');

// The official desktop uses the literal base64 text as the HMAC key, not decoded bytes.
export function calculateProof(passHash, nonce, role, sid) {
  return createHmac('sha256', passHash).update(`${nonce}|${role}|${sid}`, 'utf8').digest('base64url');
}

export function equalSecret(left, right) {
  if (typeof left !== 'string' || typeof right !== 'string') return false;
  const a = Buffer.from(left); const b = Buffer.from(right);
  return a.length === b.length && timingSafeEqual(a, b);
}

export function validPassHash(value) {
  return typeof value === 'string' && /^[A-Za-z0-9+/]{43}=$/.test(value)
    && Buffer.from(value, 'base64').length === 32
    && Buffer.from(value, 'base64').toString('base64') === value;
}

export function validID(value) {
  return typeof value === 'string' && value.length >= 1 && value.length <= 256
    && /^[\x21-\x7e]+$/.test(value);
}

export const isObject = (value) => value !== null && typeof value === 'object' && !Array.isArray(value);
export function validMeta(value) {
  return value === undefined || (isObject(value) && Object.keys(value).length <= 8
    && Object.entries(value).every(([key, text]) => key.length <= 32
      && typeof text === 'string' && text.length <= 256 && !/[\x00-\x1f]/.test(text)));
}

export function validClientEnvelope(message, allowedKeys) {
  return isObject(message) && Object.keys(message).every((key) => allowedKeys.includes(key))
    && Number.isSafeInteger(message.client_ts) && message.client_ts >= 0;
}

export class RelayPolicyError extends Error {
  constructor(code) { super(code); this.name = 'RelayPolicyError'; this.code = code; }
}
