import { readFileSync } from 'node:fs';
import { dirname, resolve, join } from 'node:path';
import { fileURLToPath } from 'node:url';
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const token = readFileSync(join(process.env.ZCODE_MOBILE_RUNTIME_DIR || join(root, '.runtime'), 'pairing-token'), 'utf8').trim();
const base = process.env.ZCODE_MOBILE_URL || 'http://127.0.0.1:18789';
for (const path of ['/health', '/v1/status', '/v1/projects', '/v1/sessions?limit=5']) {
  const response = await fetch(base + path, { headers: { Authorization: `Bearer ${token}` }, signal: AbortSignal.timeout(10000) });
  const result = await response.json();
  console.log(JSON.stringify({ path, status: response.status, ...(result.projects ? { projectCount: result.projects.length } : result.sessions ? { sessionCount: result.sessions.length, sources: [...new Set(result.sessions.map(s => s.source))] } : result) }));
  if (!response.ok) process.exitCode = 1;
}
