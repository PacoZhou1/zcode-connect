// Wire-compatible service IPC inferred from the official Remote Control v4 client.
// No runtime code from the downloaded client is imported here.
const MAX_BYTES = 16 * 1024 * 1024;
const marker = '__zcode_rpc_nested_uint8array_v1';
function varint(number) {
  let value = number >>> 0; const bytes = [];
  do { const byte = value & 127; value >>>= 7; bytes.push(byte | (value ? 128 : 0)); } while (value);
  return Buffer.from(bytes);
}
function encode(value, depth = 0) {
  if (depth > 100) throw new Error('IPC nesting limit exceeded');
  if (value === undefined) return Buffer.from([0]);
  if (typeof value === 'string') { const bytes = Buffer.from(value); return Buffer.concat([Buffer.from([1]), varint(bytes.length), bytes]); }
  if (value instanceof Uint8Array) { const bytes = Buffer.from(value); return Buffer.concat([Buffer.from([2]), varint(bytes.length), bytes]); }
  if (Array.isArray(value)) return Buffer.concat([Buffer.from([4]), varint(value.length), ...value.map(item => encode(item, depth + 1))]);
  if (typeof value === 'number' && (value | 0) === value) return Buffer.concat([Buffer.from([6]), varint(value)]);
  const bytes = Buffer.from(JSON.stringify(value, (key, item) => item instanceof Uint8Array ? { [marker]: true, base64: Buffer.from(item).toString('base64') } : item));
  return Buffer.concat([Buffer.from([5]), varint(bytes.length), bytes]);
}
export function encodeIPC(header, body) {
  const bytes = Buffer.concat([encode(header), encode(body)]);
  if (bytes.length > MAX_BYTES) throw new Error('IPC message exceeds 16 MB'); return bytes;
}
export function decodeIPC(input) {
  const bytes = Buffer.from(input); let offset = 0;
  if (bytes.length > MAX_BYTES) throw new Error('IPC message exceeds 16 MB');
  const read = length => { if (length < 0 || offset + length > bytes.length) throw new Error('Truncated IPC frame'); const result = bytes.subarray(offset, offset + length); offset += length; return result; };
  const integer = () => { let value = 0; for (let shift = 0; shift < 35; shift += 7) { const byte = read(1)[0]; value |= (byte & 127) << shift; if (!(byte & 128)) return value; } throw new Error('Invalid IPC varint'); };
  const value = (depth = 0) => {
    if (depth > 100) throw new Error('IPC nesting limit exceeded');
    const tag = read(1)[0];
    if (tag === 0) return undefined;
    if (tag === 6) return integer();
    const length = integer(); if (length < 0 || length > MAX_BYTES) throw new Error('Invalid IPC length');
    if (tag === 4) { if (length > 100000) throw new Error('IPC array is too large'); return Array.from({ length }, () => value(depth + 1)); }
    const payload = read(length);
    if (tag === 2 || tag === 3) return Uint8Array.from(payload);
    const text = new TextDecoder('utf-8', { fatal: true }).decode(payload);
    if (tag === 1) return text;
    if (tag === 5) return JSON.parse(text, (key, item) => item && typeof item === 'object' && Object.keys(item).length === 2 && item[marker] === true && typeof item.base64 === 'string' ? Uint8Array.from(Buffer.from(item.base64, 'base64')) : item);
    throw new Error('Unknown IPC type');
  };
  const header = value(), body = value(); if (offset !== bytes.length || !Array.isArray(header)) throw new Error('Invalid IPC envelope'); return { header, body };
}
export function crc32(bytes) {
  let value = 0xffffffff;
  for (const byte of bytes) { value ^= byte; for (let bit = 0; bit < 8; bit++) value = value >>> 1 ^ (value & 1 ? 0xedb88320 : 0); }
  return ((value ^ 0xffffffff) >>> 0).toString(16).padStart(8, '0');
}
export function relayProof(passHash, nonce, deviceSid, hmac) {
  // passHash is the literal UTF-8 QR value, not decoded hex or base64.
  return hmac(passHash, `${nonce}|terminal|${deviceSid}`);
}
