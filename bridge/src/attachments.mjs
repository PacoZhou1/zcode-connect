import { randomUUID } from 'node:crypto';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { BridgeError, hash, iso, readJSON, requireString, saveJSON } from './util.mjs';

export const MAX_ATTACHMENT_BYTES = 8 * 1024 * 1024;
const MIME_KINDS = new Map([['image/png', 'image'], ['image/jpeg', 'image'], ['image/webp', 'image'], ['image/gif', 'image'], ['application/pdf', 'pdf'], ['text/plain', 'file'], ['text/markdown', 'file'], ['text/csv', 'file'], ['application/json', 'file']]);
export class AttachmentStore {
  constructor(runtimeDir) { this.root = join(runtimeDir, 'attachments'); this.indexPath = join(this.root, 'index.json'); this.index = readJSON(this.indexPath, {}); }
  create(sessionId, { fileName, mimeType, base64 }) {
    fileName = requireString(fileName, 'fileName', 180);
    if (/[\\/\0\r\n]/.test(fileName) || fileName.startsWith('.')) throw new BridgeError(422, 'invalid_file_name', 'Attachment names must be plain file names.');
    const kind = MIME_KINDS.get(mimeType);
    if (!kind) throw new BridgeError(422, 'attachment_type_unsupported', 'Supported attachments are PNG, JPEG, WebP, GIF, PDF, and UTF-8 text.', false, { supportedMimeTypes: [...MIME_KINDS.keys()] });
    if (typeof base64 !== 'string' || base64.length > Math.ceil(MAX_ATTACHMENT_BYTES / 3) * 4 || !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(base64)) throw new BridgeError(422, 'invalid_attachment', 'Attachment content must be valid base64 within the 8 MB limit.');
    const bytes = Buffer.from(base64, 'base64');
    if (!bytes.length || bytes.length > MAX_ATTACHMENT_BYTES) throw new BridgeError(413, 'attachment_too_large', 'Attachments must contain 1 byte to 8 MB.');
    const signatureMatches = {
      'image/png': () => bytes.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10])),
      'image/jpeg': () => bytes[0] === 255 && bytes[1] === 216 && bytes[2] === 255,
      'image/webp': () => bytes.subarray(0, 4).toString() === 'RIFF' && bytes.subarray(8, 12).toString() === 'WEBP',
      'image/gif': () => ['GIF87a', 'GIF89a'].includes(bytes.subarray(0, 6).toString()),
      'application/pdf': () => bytes.subarray(0, 5).toString() === '%PDF-',
    };
    if (signatureMatches[mimeType] && !signatureMatches[mimeType]()) throw new BridgeError(422, 'attachment_type_mismatch', 'The file signature does not match its declared MIME type.');
    if (kind === 'file') {
      if (bytes.length > 64 * 1024) throw new BridgeError(413, 'attachment_too_large', 'Text attachments are limited to 64 KB.');
      try { if (bytes.includes(0)) throw new Error(); new TextDecoder('utf-8', { fatal: true }).decode(bytes); } catch { throw new BridgeError(422, 'invalid_attachment', 'Text attachments must contain UTF-8 text.'); }
    }
    const id = `attachment_${randomUUID()}`, record = { id, sessionId, fileName, mimeType, kind, bytes: bytes.length, sha256: hash(bytes), createdAt: iso() };
    mkdirSync(this.root, { recursive: true, mode: 0o700 }); writeFileSync(join(this.root, id), bytes, { mode: 0o600, flag: 'wx' });
    this.index[id] = record; saveJSON(this.indexPath, this.index); return this.dto(record);
  }
  dto(record) { const { kind, ...result } = record; return result; }
  resolve(sessionId, ids = [], { supportsImages = true, supportsPDF = true } = {}) {
    if (!Array.isArray(ids) || ids.length > 6 || ids.some(id => typeof id !== 'string') || new Set(ids).size !== ids.length) throw new BridgeError(422, 'invalid_request', 'attachmentIds must contain up to 6 unique attachment IDs.');
    return ids.map(id => {
      const record = this.index[id];
      if (!record || record.sessionId !== sessionId) throw new BridgeError(404, 'attachment_not_found', 'Attachment is unavailable for this task.');
      if (record.kind === 'image' && !supportsImages) throw new BridgeError(422, 'model_does_not_support_images', 'The selected model does not accept images.');
      if (record.kind === 'pdf' && !supportsPDF) throw new BridgeError(422, 'model_does_not_support_pdf', 'The selected model does not accept PDF input. Use a model that supports PDF, or attach extracted text or page images.');
      const bytes = readFileSync(join(this.root, record.id));
      if (hash(bytes) !== record.sha256) throw new BridgeError(409, 'attachment_changed', 'Attachment integrity check failed.');
      return { kind: record.kind, filename: record.fileName, mimeType: record.mimeType, sizeBytes: record.bytes, dataBase64: bytes.toString('base64') };
    });
  }
}
