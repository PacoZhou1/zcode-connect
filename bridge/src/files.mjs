import { constants } from 'node:fs';
import { lstat, open, readdir, realpath } from 'node:fs/promises';
import { isAbsolute, join, relative, resolve, sep } from 'node:path';
import { BridgeError } from './util.mjs';

export const MAX_FILE_BYTES = 512 * 1024;
const restrictedNames = /^(?:id_(?:rsa|ed25519|ecdsa)|credentials(?:\..*)?|secrets?(?:\..*)?|pairing-token|.*\.(?:pem|p12|pfx|key|keychain|sqlite(?:-shm|-wal)?|db(?:-shm|-wal)?))$/i;
export function restrictedPath(path) {
  return path.split(/[\\/]/).some(part => part.startsWith('.') || restrictedNames.test(part) || ['node_modules', 'vendor', 'DerivedData', 'build', 'Pods'].includes(part));
}
export async function workspacePath(root, path = '') {
  if (typeof path !== 'string' || path.length > 2048 || path.includes('\0') || path.includes('\\') || isAbsolute(path) || path.split('/').includes('..')) throw new BridgeError(422, 'invalid_path', 'Use a relative path within this project.');
  if (restrictedPath(path)) throw new BridgeError(403, 'file_restricted', 'Hidden, credential, database, and generated paths are not exposed.');
  const base = await realpath(root).catch(() => { throw new BridgeError(404, 'not_found', 'Project folder is unavailable.'); });
  const target = resolve(base, path), rel = relative(base, target);
  if (rel.startsWith(`..${sep}`) || rel === '..' || isAbsolute(rel)) throw new BridgeError(403, 'path_outside_project', 'The path is outside this project.');
  let current = base;
  for (const part of rel.split(sep).filter(Boolean)) {
    current = join(current, part);
    const stat = await lstat(current).catch(() => { throw new BridgeError(404, 'not_found', 'File or folder not found.'); });
    if (stat.isSymbolicLink()) throw new BridgeError(403, 'symlink_restricted', 'Symbolic links are not exposed by the file browser.');
  }
  const canonical = await realpath(target);
  if (canonical !== base && !canonical.startsWith(base + sep)) throw new BridgeError(403, 'path_outside_project', 'The path is outside this project.');
  return { base, target: canonical, relativePath: rel.split(sep).join('/') };
}
export async function listWorkspaceFiles(root, path = '') {
  const { target, relativePath } = await workspacePath(root, path);
  if (!(await lstat(target)).isDirectory()) throw new BridgeError(422, 'not_directory', 'This path is not a folder.');
  const entries = (await readdir(target, { withFileTypes: true })).filter(entry => !restrictedPath(entry.name) && !entry.isSymbolicLink() && (entry.isFile() || entry.isDirectory())).sort((a, b) => Number(b.isDirectory()) - Number(a.isDirectory()) || a.name.localeCompare(b.name));
  const files = await Promise.all(entries.slice(0, 500).map(async entry => {
    const stat = await lstat(join(target, entry.name));
    return { name: entry.name, path: [relativePath, entry.name].filter(Boolean).join('/'), kind: entry.isDirectory() ? 'directory' : 'file', size: stat.size, modifiedAt: stat.mtime.toISOString() };
  }));
  return { path: relativePath, files, truncated: entries.length > 500 };
}
export async function readWorkspaceFile(root, path) {
  const { target, relativePath } = await workspacePath(root, path);
  const file = await open(target, constants.O_RDONLY | constants.O_NOFOLLOW);
  try {
    const stat = await file.stat();
    if (!stat.isFile()) throw new BridgeError(422, 'not_file', 'This path is not a regular file.');
    if (stat.size > MAX_FILE_BYTES) throw new BridgeError(413, 'file_too_large', 'Text preview is limited to 512 KB.', false, { maxBytes: MAX_FILE_BYTES, size: stat.size });
    const buffer = Buffer.alloc(Math.min(stat.size + 1, MAX_FILE_BYTES + 1)), { bytesRead } = await file.read(buffer, 0, buffer.length, 0), bytes = buffer.subarray(0, bytesRead);
    if (bytes.length > MAX_FILE_BYTES) throw new BridgeError(413, 'file_too_large', 'Text preview is limited to 512 KB.');
    let content;
    try { if (bytes.includes(0)) throw new Error(); content = new TextDecoder('utf-8', { fatal: true }).decode(bytes); }
    catch { throw new BridgeError(422, 'binary_file', 'This file cannot be previewed as UTF-8 text.'); }
    return { path: relativePath, content, encoding: 'utf-8', size: bytes.length, modifiedAt: stat.mtime.toISOString(), truncated: false };
  } finally { await file.close(); }
}

export async function searchWorkspaceFiles(root, search, path = '', { maxResults = 200, maxEntries = 50000, timeoutMs = 5000 } = {}) {
  if (typeof search !== 'string' || !search.trim() || search.length > 200) throw new BridgeError(422, 'invalid_request', 'search must contain 1 to 200 characters.');
  const start = await workspacePath(root, path), query = search.trim().normalize('NFC').toLocaleLowerCase(), queue = [start.relativePath], files = [], deadline = Date.now() + timeoutMs;
  let scannedEntries = 0, complete = true;
  while (queue.length) {
    if (scannedEntries >= maxEntries || Date.now() > deadline || files.length >= maxResults) { complete = false; break; }
    const directory = queue.shift(); let entries;
    try { const { target } = await workspacePath(root, directory); entries = await readdir(target, { withFileTypes: true }); } catch { continue; }
    for (const entry of entries) {
      if (++scannedEntries > maxEntries || Date.now() > deadline || files.length >= maxResults) { complete = false; break; }
      const relativePath = [directory, entry.name].filter(Boolean).join('/');
      if (restrictedPath(relativePath) || entry.isSymbolicLink()) continue;
      if (entry.isDirectory()) { queue.push(relativePath); continue; }
      if (!entry.isFile() || !relativePath.normalize('NFC').toLocaleLowerCase().includes(query)) continue;
      const stat = await lstat(join(start.base, relativePath)).catch(() => null); if (!stat?.isFile() || stat.isSymbolicLink()) continue;
      files.push({ name: entry.name, path: relativePath, kind: 'file', size: stat.size, modifiedAt: stat.mtime.toISOString() });
    }
    if (!complete) break;
  }
  return { path: start.relativePath, search: search.trim(), files: files.sort((a, b) => a.path.localeCompare(b.path)), truncated: !complete, searchComplete: complete, scannedEntries };
}
