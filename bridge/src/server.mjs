import { createServer } from 'node:http';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { dirname, join, resolve } from 'node:path';
import { homedir } from 'node:os';
import { BridgeService } from './service.mjs';
import { acquireRuntimeLock } from './runtime-lock.mjs';
import { BridgeError, authorized, ensureToken, requireString, sanitize, iso } from './util.mjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
export const defaults = {
  runtimeDir: process.env.ZCODE_MOBILE_RUNTIME_DIR || join(root, '.runtime'),
  zcodeRoot: process.env.ZCODE_MOBILE_DESKTOP_ROOT || join(homedir(), '.zcode'),
  cliPath: process.env.ZCODE_MOBILE_CLI_PATH || '/Applications/ZCode.app/Contents/Resources/glm/zcode.cjs',
  host: process.env.ZCODE_MOBILE_HOST || '127.0.0.1', port: Number(process.env.ZCODE_MOBILE_PORT || 18789),
};

function json(response, status, value) {
  response.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' });
  response.end(JSON.stringify(sanitize(value)));
}
async function readBody(request, maxBytes = 256 * 1024) {
  const chunks = []; let bytes = 0;
  for await (const chunk of request) {
    bytes += chunk.length;
    if (bytes > maxBytes) throw new BridgeError(413, 'payload_too_large', `Request exceeds the ${maxBytes} byte limit.`);
    chunks.push(Buffer.from(chunk));
  }
  let value;
  try { const body = new TextDecoder('utf-8', { fatal: true }).decode(Buffer.concat(chunks)); value = JSON.parse(body || '{}'); } catch { throw new BridgeError(422, 'invalid_request', 'Request body must be UTF-8 JSON.'); }
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new BridgeError(422, 'invalid_request', 'Request body must be a JSON object.');
  return value;
}
function streamEvents(request, response, service, url) {
  const sessionId = url.searchParams.get('sessionId'), after = request.headers['last-event-id'] || url.searchParams.get('after');
  response.writeHead(200, { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache, no-transform', Connection: 'keep-alive', 'X-Accel-Buffering': 'no' });
  let closed = false;
  const write = event => {
    if (closed || sessionId && event.sessionId && event.sessionId !== sessionId) return;
    if (response.writableLength > 1024 * 1024) { response.destroy(); return; }
    response.write(`${event.id ? `id: ${event.id}\n` : ''}event: ${event.type}\ndata: ${JSON.stringify(sanitize(event))}\n\n`);
  };
  const replay = service.events.replay(after);
  write({ type: 'ready', timestamp: iso(), data: { connectionStatus: service.status().connectionStatus, epoch: service.events.epoch } });
  if (replay.resync) write({ type: 'resync.required', timestamp: iso(), data: { reason: 'event_cursor_expired' } });
  for (const event of replay.events) write(event);
  service.events.on('event', write);
  const heartbeat = setInterval(() => { if (!closed) response.write(': heartbeat\n\n'); }, 15000);
  response.on('close', () => { closed = true; clearInterval(heartbeat); service.events.off('event', write); });
}

export function createBridgeServer({ service, token }) {
  return createServer(async (request, response) => {
    try {
      const url = new URL(request.url, 'http://localhost'), path = url.pathname;
      if (path === '/health' && request.method === 'GET') return json(response, 200, { status: 'ok', service: 'zcode-mobile-bridge', version: '0.1.0' });
      if (!authorized(request.headers.authorization, token)) throw new BridgeError(401, 'unauthorized', 'A valid pairing token is required.');
      // Native URLSession sends no Origin. Reject browser cross-origin use even if a token leaks into a page.
      if (request.headers.origin) throw new BridgeError(403, 'origin_not_allowed', 'Browser origins are not enabled for this bridge.');
      if (path === '/v1/status' && request.method === 'GET') return json(response, 200, service.status());
      if (path === '/v1/models' && request.method === 'GET') return json(response, 200, service.models());
      if (path === '/v1/projects' && request.method === 'GET') return json(response, 200, { projects: service.projects() });
      const projectFiles = path.match(/^\/v1\/projects\/([^/]+)\/(files|file|settings)$/);
      if (projectFiles && request.method === 'GET') {
        const id = decodeURIComponent(projectFiles[1]), filePath = url.searchParams.get('path') ?? '';
        if (projectFiles[2] === 'settings') return json(response, 200, service.projectSettings(id));
        return json(response, 200, projectFiles[2] === 'files' ? await service.files(id, filePath, url.searchParams.has('search') ? url.searchParams.get('search') : undefined) : await service.file(id, requireString(filePath, 'path', 2048)));
      }
      if (path === '/v1/sessions' && request.method === 'GET') {
        const limit = Number(url.searchParams.get('limit') || 100);
        if (!Number.isInteger(limit) || limit < 1 || limit > 1000) throw new BridgeError(422, 'invalid_request', 'limit must be an integer from 1 to 1000.');
        const archived = url.searchParams.get('includeArchived');
        if (archived !== null && !['true', 'false'].includes(archived)) throw new BridgeError(422, 'invalid_request', 'includeArchived must be true or false.');
        return json(response, 200, service.sessionPage({ project: url.searchParams.get('projectId'), limit, includeArchived: archived === 'true', search: url.searchParams.get('search') ?? '', cursor: url.searchParams.has('cursor') ? url.searchParams.get('cursor') : undefined }));
      }
      if (path === '/v1/sessions' && request.method === 'POST') {
        const body = await readBody(request);
        const session = await service.create({ project: requireString(body.projectId, 'projectId', 100), title: body.title === undefined ? undefined : requireString(body.title, 'title', 200), mode: body.mode, model: body.model, confirmFullAccess: body.confirmFullAccess, clientDraftId: body.clientDraftId });
        return json(response, 201, { session });
      }
      if (path === '/v1/events' && request.method === 'GET') return streamEvents(request, response, service, url);
      const hookReview = path.match(/^\/v1\/sessions\/([^/]+)\/hooks\/review\/(request|respond|toggle|revoke)$/);
      if (hookReview && request.method === 'POST') return json(response, 200, await service.hookReview(decodeURIComponent(hookReview[1]), hookReview[2], await readBody(request, 768 * 1024)));
      const goal = path.match(/^\/v1\/sessions\/([^/]+)\/goal\/([^/]+)$/);
      if (goal && request.method === 'POST') {
        const body = await readBody(request);
        if (Object.keys(body).length) throw new BridgeError(422, 'invalid_request', 'Goal pause/resume accepts an empty body.');
        return json(response, 200, await service.goalAction(decodeURIComponent(goal[1]), goal[2]));
      }
      const task = path.match(/^\/v1\/sessions\/([^/]+)(?:\/(messages|stop|fork|changes|settings|attachments))?$/);
      if (task) {
        const id = decodeURIComponent(task[1]), action = task[2];
        if (!action && request.method === 'GET') return json(response, 200, await service.detail(id));
        if (!action && request.method === 'PATCH') return json(response, 200, await service.metadata(id, await readBody(request)));
        if (action === 'settings' && request.method === 'GET') return json(response, 200, service.settings(id));
        if (action === 'settings' && request.method === 'PATCH') return json(response, 200, await service.updateSettings(id, await readBody(request)));
        if (action === 'attachments' && request.method === 'POST') return json(response, 201, service.upload(id, await readBody(request, 12 * 1024 * 1024)));
        if (action === 'changes' && request.method === 'GET') return json(response, 200, await service.changes(id));
        if (action === 'stop' && request.method === 'POST') return json(response, 200, await service.stop(id));
        if (action === 'fork' && request.method === 'POST') return json(response, 201, await service.fork(id, await readBody(request)));
        if (action === 'messages' && request.method === 'GET') {
          if (!url.searchParams.has('beforeRowId') || !url.searchParams.has('logEpoch')) throw new BridgeError(422, 'invalid_request', 'Read the task detail first, then provide beforeRowId and logEpoch.');
          return json(response, 200, service.transcript(id, { beforeRowId: Number(url.searchParams.get('beforeRowId')), logEpoch: url.searchParams.get('logEpoch'), limit: url.searchParams.has('limit') ? Number(url.searchParams.get('limit')) : 200 }));
        }
        if (action === 'messages' && request.method === 'POST') {
          const body = await readBody(request);
          if (!(body.text === '' && Array.isArray(body.attachmentIds) && body.attachmentIds.length)) requireString(body.text, 'text');
          const text = body.text;
          const inputId = body.inputId === undefined ? undefined : requireString(body.inputId, 'inputId', 128);
          return json(response, 202, await service.send(id, text, inputId, body.attachmentIds));
        }
      }
      const interaction = path.match(/^\/v1\/interactions\/([^/]+)\/respond$/);
      if (interaction && request.method === 'POST') return json(response, 200, service.respond(decodeURIComponent(interaction[1]), await readBody(request)));
      throw new BridgeError(404, 'not_found', 'Endpoint not found.');
    } catch (error) {
      if (response.headersSent) { response.end(); return; }
      json(response, error.status || 500, { error: { code: error.code || 'internal_error', message: error.status ? error.message : 'The bridge encountered an internal error.', retryable: error.retryable ?? false, ...(error.details ? { details: error.details } : {}) } });
    }
  });
}

export async function main(config = defaults) {
  if (!['127.0.0.1', '::1', 'localhost'].includes(config.host)) throw new Error('This build only binds to loopback. Configure a secure, authenticated route before enabling remote access.');
  const releaseLock = acquireRuntimeLock(config.runtimeDir);
  try {
  const token = ensureToken(join(config.runtimeDir, 'pairing-token'));
  const service = new BridgeService({ ...config, acceptanceWorkspace: join(config.runtimeDir, 'acceptance-workspace') });
  const server = createBridgeServer({ service, token });
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(config.port, config.host, resolve); });
  console.log(JSON.stringify({ event: 'listening', url: `http://${config.host}:${config.port}`, tokenFile: join(config.runtimeDir, 'pairing-token') }));
  service.start().then(() => console.log(JSON.stringify({ event: 'runtime_ready' }))).catch(error => console.error(JSON.stringify({ event: 'runtime_unavailable', code: error.code || 'startup_failed', message: error.message })));
  const stop = async () => {
    server.close(); server.closeAllConnections(); await service.close(); releaseLock(); process.exit(0);
  };
  process.once('SIGINT', stop); process.once('SIGTERM', stop);
  return { server, service, releaseLock };
  } catch (error) { releaseLock(); throw error; }
}
if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) main().catch(error => { console.error(error.message); process.exitCode = 1; });
