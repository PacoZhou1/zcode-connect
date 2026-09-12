import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import { chmodSync, existsSync, mkdirSync, readFileSync, unlinkSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { createBridgeServer } from '../../src/server.mjs';
import { authorized, BridgeError } from '../../src/util.mjs';
import { listWorkspaceFiles, readWorkspaceFile, searchWorkspaceFiles } from '../../src/files.mjs';

/** A test-only read facade over genuine saved parent/child data, never a CLI facade. */
export function subagentReadOnlyFacade({ service, source, parentID, childID }) {
  const record = service.registry.sessions[parentID];
  assert.ok(record?.archived && !['running', 'waiting'].includes(record.status));
  assert.equal(service.getSubagent(childID)?.rootSessionId, parentID);
  assert.equal(source.sessionId, parentID);
  assert.deepEqual(source.final.hostActivity.subagents.childSessionIds, [childID]);
  assert.equal(source.final.hostActivity.subagents.running.length, 0);
  const readOnlyCapabilities = Object.fromEntries(Object.keys(service.ownedDTO(record).capabilities).map(key => [key, key === 'read']));
  const parentDTO = () => ({ ...service.ownedDTO(record), source: 'bridge-readonly-fixture', statusSource: 'persisted', capabilities: readOnlyCapabilities });
  const project = { id: parentDTO().projectId, name: '子智能体只读验收', path: record.path, sessionCount: 1 };
  const fixture = { kind: 'retained-subagent-acceptance', readOnly: true, capturedAt: source.finishedAt,
    parentID, childID, originalParentArchived: true, liveRuntime: false, protocolRequestsAllowed: false };
  const requireSession = id => { if (![parentID, childID].includes(id)) throw new BridgeError(404, 'not_found', 'Task not found in this read-only acceptance endpoint.'); };
  const requireProject = id => { if (id !== project.id) throw new BridgeError(404, 'not_found', 'Project not found in this read-only acceptance endpoint.'); };
  const deny = () => { throw new BridgeError(409, 'read_only_fixture', 'This endpoint only reads retained acceptance records. It cannot change or run tasks.'); };
  const activity = structuredClone(source.final.hostActivity);
  assert.ok(activity.rows.window.some(row => row.kind === 'subagent' && row.childSessionId === childID));
  activity.availability = Object.fromEntries(Object.keys(activity.availability ?? {}).map(key => [key, { allowed: false, reasonCode: 'readOnlyAcceptance' }]));
  activity.source = 'persisted-acceptance'; activity.capturedAt = source.finishedAt;
  const facade = Object.create(service);
  Object.assign(facade, {
    status: () => ({ hostName: '子智能体只读验收', connectionStatus: 'connected', version: '0.1.0-readonly-acceptance', fixture,
      capabilities: { projects: true, sessions: true, history: true, sse: true, hostActivity: true, createSession: false,
        send: false, stop: false, approvals: false, changes: false, models: false, sessionSettings: false, attachments: false,
        files: true, rename: false, archive: false, pin: false, markUnread: false, goalPause: false, goalResume: false, goalRemove: false,
        desktopControl: false, remoteRelay: false },
      limitations: ['Read-only test endpoint over a retained genuine acceptance task.', 'Archived state and captured activity are preserved; no live CLI is connected.',
        'Only the saved parent and its verified child are exposed. This endpoint does not accept task changes.'] }),
    projects: () => [project],
    models: () => ({ models: [], modes: [] }),
    sessions: ({ includeArchived = false, project: projectID } = {}) => includeArchived && (!projectID || projectID === project.id) ? [parentDTO()] : [],
    sessionPage: ({ project: projectID, limit = 100, includeArchived = false, search = '', cursor } = {}) => {
      if (typeof search !== 'string' || search.length > 200) throw new BridgeError(422, 'invalid_request', 'Invalid task search.');
      return service.sessionPages.page({ cursor, limit, filters: { project: projectID || null, includeArchived, search } }, () => ({
        sessions: includeArchived && (!projectID || projectID === project.id) && `${record.title}\n${project.name}`.toLocaleLowerCase().includes(search.trim().toLocaleLowerCase()) ? [parentDTO()] : [], truncated: false }));
    },
    detail: async id => {
      requireSession(id);
      if (id === childID) return { ...await service.detail(id), fixture };
      // Bypass owned detail initialization. These are actual saved messages and an
      // explicitly historical activity projection whose child relation is verified.
      return { session: parentDTO(), ...service.ownedHistory.transcript(parentID), pendingInteractions: [], hostActivity: structuredClone(activity), fixture };
    },
    transcript: (id, options = {}) => { requireSession(id); return service.transcript(id, options); },
    projectSettings: projectID => { if (projectID !== project.id) throw new BridgeError(404, 'not_found', 'Project not found.'); return { projectId: projectID, model: record.selection, mode: record.mode, inheritance: 'retained-acceptance-selection', mutable: false }; },
    files: (projectID, path, search) => { requireProject(projectID); return search === undefined ? listWorkspaceFiles(record.path, path) : searchWorkspaceFiles(record.path, search, path); },
    file: (projectID, path) => { requireProject(projectID); return readWorkspaceFile(record.path, path); },
    changes: deny, settings: deny, create: deny, metadata: deny, updateSettings: deny, upload: deny,
    send: deny, stop: deny, fork: deny, goalAction: deny, respond: deny, ensureInitialized: deny,
  });
  return { facade, fixture };
}

export async function serveSubagentReadOnly({ service, source, parentID, childID, root, evidenceRoot, originalStoreUnchanged,
  counters, port = 18793, stateDir = join(root, '.runtime/subagent-readonly-server') }) {
  assert.ok(Number.isInteger(port) && port > 0 && port < 65536 && ![18789, 18790].includes(port), 'Use a separate non-production loopback port.');
  stateDir = resolve(stateDir);
  assert.ok(stateDir.startsWith(resolve(root, '.runtime') + '/'), 'Test state must remain under this bridge private runtime.');
  mkdirSync(stateDir, { recursive: true, mode: 0o700 }); chmodSync(stateDir, 0o700);
  const pidFile = join(stateDir, 'server.pid'), tokenFile = join(stateDir, 'pairing-token'), connectionFile = join(stateDir, 'connection.json');
  if (existsSync(pidFile)) {
    const pid = Number(readFileSync(pidFile, 'utf8').trim());
    try { if (Number.isInteger(pid) && pid > 0) { process.kill(pid, 0); throw new Error(`Read-only service process ${pid} is still active.`); } }
    catch (error) { if (error.code !== 'ESRCH') throw error; }
  }
  const { facade, fixture } = subagentReadOnlyFacade({ service, source, parentID, childID });
  const token = randomBytes(32).toString('base64url');
  const http = createBridgeServer({ service: facade, token });
  const handler = http.listeners('request')[0]; http.removeAllListeners('request');
  const evidence = { startedAt: new Date().toISOString(), fixture, parentID, childID, requestCount: 0, rejectedWrites: 0,
    unauthenticatedRequests: 0, selfChecks: [], protocolCalls: 0, writesAttempted: 0, newModelRequests: 0, officialRelayPaired: false };
  function reject(response, status, code, message) {
    response.writeHead(status, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
    response.end(JSON.stringify({ error: { code, message, retryable: false } }));
  }
  http.on('request', (request, response) => {
    evidence.requestCount++; response.setHeader('X-ZCode-Data-Source', 'retained-acceptance-readonly');
    if (!authorized(request.headers.authorization, token)) {
      evidence.unauthenticatedRequests++; return reject(response, 401, 'unauthorized', 'A valid test token is required.');
    }
    if (request.method !== 'GET') {
      evidence.rejectedWrites++; return reject(response, 409, 'read_only_fixture', 'This acceptance endpoint permits only reads.');
    }
    void handler(request, response);
  });
  await new Promise((resolve, reject) => { http.once('error', reject); http.listen(port, '127.0.0.1', resolve); });
  const baseURL = `http://127.0.0.1:${http.address().port}`;
  const connection = { baseURL, tokenFile, parentID, childID, parentArchived: true, pid: process.pid, pidFile, fixture,
    stop: `kill -TERM ${process.pid}` };
  writeFileSync(tokenFile, token + '\n', { mode: 0o600 }); chmodSync(tokenFile, 0o600);
  writeFileSync(pidFile, String(process.pid) + '\n', { mode: 0o600 });
  writeFileSync(connectionFile, JSON.stringify(connection, null, 2) + '\n', { mode: 0o600 });
  const saveEvidence = () => {
    Object.assign(evidence, counters(), { baseURL, originalStoreUnchanged: originalStoreUnchanged(), pid: process.pid });
    writeFileSync(join(evidenceRoot, 'subagent-readonly-serve.json'), JSON.stringify(evidence, null, 2) + '\n');
  };
  let stopping = false;
  const close = async () => {
    if (stopping) return; stopping = true;
    http.closeAllConnections(); await new Promise(resolve => http.close(resolve)); await service.close();
    evidence.finishedAt = new Date().toISOString(); evidence.stopped = true;
    saveEvidence();
    if (existsSync(pidFile) && readFileSync(pidFile, 'utf8').trim() === String(process.pid)) unlinkSync(pidFile);
    if (existsSync(tokenFile) && readFileSync(tokenFile, 'utf8').trim() === token) unlinkSync(tokenFile);
    writeFileSync(connectionFile, JSON.stringify({ ...connection, stopped: true }, null, 2) + '\n', { mode: 0o600 });
    console.log(JSON.stringify({ event: 'readonly_stopped', baseURL, ...counters(), originalStoreUnchanged: evidence.originalStoreUnchanged }));
  };
  process.once('SIGTERM', close); process.once('SIGINT', close);
  const headers = { Authorization: 'Bearer ' + token, 'Content-Type': 'application/json' };
  try {
    const api = async (path, expected = 200, method = 'GET', body) => {
      const response = await fetch(baseURL + path, { method, headers, ...(body ? { body: JSON.stringify(body) } : {}), signal: AbortSignal.timeout(5000) });
      const result = await response.json(); assert.equal(response.status, expected);
      evidence.selfChecks.push({ method, path, status: response.status }); return result;
    };
    assert.equal((await api('/v1/status')).fixture.readOnly, true);
    assert.equal((await api('/v1/sessions')).sessions.length, 0);
    assert.equal((await api('/v1/sessions?includeArchived=true')).sessions[0].id, parentID);
    const parent = await api('/v1/sessions/' + parentID), child = await api('/v1/sessions/' + childID);
    assert.equal(parent.session.archived, true); assert.equal(parent.session.capabilities.send, false);
    assert.equal(parent.hostActivity.subagents.childSessionIds[0], childID);
    assert.ok(parent.hostActivity.rows.window.some(row => row.childSessionId === childID));
    assert.equal(child.session.parentSessionId, parentID); assert.equal(child.session.capabilities.send, false);
    assert.ok(child.messages.some(message => message.text.includes('ZCODE_SUBAGENT_READ_OK')));
    const project = facade.projects()[0];
    const files = await api('/v1/projects/' + project.id + '/files'); assert.ok(Array.isArray(files.files));
    await api('/v1/projects/' + project.id + '/files?search=README');
    await api('/v1/projects/' + project.id + '/file?path=README.md');
    await api('/v1/projects/' + project.id + '/file?path=../sessions.json', 422);
    await api('/v1/projects/' + project.id + '/file?path=.env', 403);
    await api('/v1/projects/unknown-project/files', 404);
    await api('/v1/sessions/unknown-task', 404);
    for (const id of [parentID, childID]) {
      for (const [method, suffix, body] of [['PATCH', '', { archived: false }], ['POST', '/messages', { text: 'BLOCKED' }], ['POST', '/stop', {}],
        ['POST', '/fork', {}], ['PATCH', '/settings', { thoughtLevel: 'low' }], ['POST', '/attachments', {}], ['POST', '/goal/resume', {}]]) {
        const result = await api('/v1/sessions/' + id + suffix, 409, method, body); assert.equal(result.error.code, 'read_only_fixture');
      }
    }
    const unauthorized = await fetch(baseURL + '/v1/status', { signal: AbortSignal.timeout(5000) }); assert.equal(unauthorized.status, 401);
    const foreignProject = await api('/v1/projects/unknown-project/settings', 404); assert.equal(foreignProject.error.code, 'not_found');
    assert.deepEqual(counters(), { protocolCalls: 0, writesAttempted: 0 }); assert.equal(originalStoreUnchanged(), true);
    evidence.passed = true; saveEvidence();
    console.log(JSON.stringify({ event: 'readonly_ready', ...connection, connectionFile, selfChecks: evidence.selfChecks.length, originalStoreUnchanged: true }));
  } catch (error) { evidence.passed = false; evidence.failure = { name: error.name, message: error.message }; await close(); throw error; }
  return { http, close, connection };
}
