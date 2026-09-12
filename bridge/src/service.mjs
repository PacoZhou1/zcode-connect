import { EventEmitter } from 'node:events';
import { basename, join } from 'node:path';
import { hostname } from 'node:os';
import { existsSync, mkdirSync } from 'node:fs';
import { randomUUID } from 'node:crypto';
import { BridgeError, hash, iso, projectId, readJSON, requireString, saveJSON, sanitize } from './util.mjs';
import { HistoryReader, normalizeMessages } from './history.mjs';
import { SessionPages } from './session-pages.mjs';
import { modelCatalog, selectedRuntimeModel, SUPPORTED_MODES, validateSelection } from './model.mjs';
import { ZCodeProtocol } from './protocol.mjs';
import { EventJournal } from './events.mjs';
import { workspaceChanges } from './git.mjs';
import { listWorkspaceFiles, readWorkspaceFile, searchWorkspaceFiles } from './files.mjs';
import { AttachmentStore } from './attachments.mjs';
import { HostActivity, activityFromProjection, emptyHostActivity } from './host-activity.mjs';
import { forkSession, forkRows, withForkTargets } from './fork.mjs';

export class BridgeService extends EventEmitter {
  constructor({ runtimeDir, zcodeRoot, cliPath, acceptanceWorkspace, protocol, history, ownedHistory }) {
    super(); Object.assign(this, { runtimeDir, zcodeRoot, cliPath, acceptanceWorkspace });
    mkdirSync(acceptanceWorkspace, { recursive: true });
    this.history = history ?? new HistoryReader(zcodeRoot);
    this.ownedHistory = ownedHistory ?? new HistoryReader(join(runtimeDir, 'zcode'));
    this.attachments = new AttachmentStore(runtimeDir);
    this.registryPath = join(runtimeDir, 'sessions.json');
    this.registry = readJSON(this.registryPath, { sessions: {}, inputs: {}, drafts: {} });
    this.registry.sessions = Object.assign(Object.create(null), this.registry.sessions); this.registry.inputs = Object.assign(Object.create(null), this.registry.inputs); this.registry.drafts = Object.assign(Object.create(null), this.registry.drafts);
    this.registry.forks = Object.assign(Object.create(null), this.registry.forks);
    for (const record of Object.values(this.registry.sessions)) if (['running', 'waiting'].includes(record.status)) { record.status = 'error'; record.recoveryReason = 'The bridge restarted before the previous turn was confirmed complete.'; }
    for (const draft of Object.values(this.registry.drafts)) if (draft.status === 'pending') draft.status = 'uncertain';
    this.snapshots = new Map(); this.initialized = new Set(); this.initializing = new Map(); this.refreshing = new Map(); this.refreshTimers = new Map(); this.mutations = new Map();
    this.events = new EventJournal();
    this.sessionPages = new SessionPages();
    this.protocol = protocol ?? new ZCodeProtocol({ cliPath, runtimeDir, cwd: acceptanceWorkspace, preferences: readJSON(join(zcodeRoot, 'v2/setting.json')) });
    this.hostActivity = new HostActivity({ protocol: this.protocol, events: this.events, isOwned: id => Object.hasOwn(this.registry.sessions, id) });
    this.protocol.on('sessionEvent', event => this.onRuntimeEvent(event));
    this.protocol.on('interaction', ({ id, frame }) => this.onInteraction(id, frame));
    this.protocol.on('ready', () => this.events.publish('connection.changed', { connectionStatus: 'connected' }));
    this.protocol.on('disconnected', message => {
      this.initialized.clear();
      this.hostActivity.reset();
      for (const record of Object.values(this.registry.sessions)) if (record.status === 'running' || record.status === 'waiting') record.status = 'error';
      this.persist(); this.events.publish('connection.changed', { connectionStatus: 'disconnected', message });
    });
  }
  persist() { saveJSON(this.registryPath, this.registry); }
  async start() { await this.protocol.start(); }
  status() {
    let selectedModel;
    try { const model = this.history.latestModel(this.acceptanceWorkspace); selectedModel = model && { providerId: model.providerId, modelId: model.modelId, thoughtLevel: model.thoughtLevel }; } catch {}
    return { hostName: hostname().replace(/\.local$/, ''), connectionStatus: this.protocol.ready ? 'connected' : 'disconnected', version: '0.1.0',
      zcodeVersion: '3.11.2', cliVersion: '0.16.5', selectedModel,
      capabilities: { projects: true, sessions: true, history: true, createSession: true, send: true, stop: true, approvals: true, changes: true, sse: true, models: true, sessionSettings: true, attachments: true, files: true, rename: true, archive: true, pin: true, markUnread: true, hostActivity: true, goalPause: true, goalResume: true, goalRemove: false, desktopControl: false, remoteRelay: false },
      limitations: ['Desktop-owned sessions are read-only.', 'New mobile tasks run in an isolated ZCode session store.', 'External network and physical-device routing are not verified.'] };
  }
  projects() {
    const result = new Map(this.history.projects().map(project => [project.id, project]));
    const local = { id: projectId(this.acceptanceWorkspace), name: 'Mobile Acceptance', path: this.acceptanceWorkspace, sessionCount: 0, isAcceptanceWorkspace: true };
    result.set(local.id, local);
    for (const record of Object.values(this.registry.sessions)) {
      const id = projectId(record.path), current = result.get(id) ?? { id, name: basename(record.path), path: record.path, sessionCount: 0 };
      current.sessionCount += 1; result.set(id, current);
    }
    return [...result.values()];
  }
  ownedDTO(record) {
    const active = this.protocol.ready;
    return { id: record.id, title: record.title, projectId: projectId(record.path), projectName: basename(record.path), status: record.status ?? 'idle', statusSource: 'runtime',
      createdAt: record.createdAt, updatedAt: record.updatedAt, source: 'bridge', mode: record.mode, recoveryReason: record.recoveryReason,
      model: record.selection.modelId, providerId: record.selection.providerId, thoughtLevel: record.selection.thoughtLevel, pinned: record.pinned ?? false, archived: record.archived ?? false,
      unread: typeof record.unreadAt === 'number', unreadAt: record.unreadAt ?? null, unreadScope: 'bridge',
      capabilities: { read: true, send: active && !record.archived, stop: active && ['running', 'waiting'].includes(record.status), approve: active, changes: true, settings: active && !record.archived, attachments: active && !record.archived, rename: true, archive: true, pin: true, markUnread: true, fork: active && !record.archived && forkRows(this.hostActivity.projections.get(record.id)).length > 0 } };
  }
  sessions({ project, limit = 100, includeArchived = false } = {}) {
    const desktop = this.history.sessions(1000).map(({ workspacePath, ...rest }) => rest);
    const owned = Object.values(this.registry.sessions).map(record => this.ownedDTO(record));
    return [...owned, ...desktop].filter(session => (includeArchived || !session.archived) && (!project || session.projectId === project)).sort((a, b) => Number(b.pinned ?? false) - Number(a.pinned ?? false) || b.updatedAt.localeCompare(a.updatedAt)).slice(0, limit);
  }
  sessionPage({ project, limit = 100, includeArchived = false, search = '', cursor } = {}) {
    if (typeof search !== 'string' || search.length > 200) throw new BridgeError(422, 'invalid_request', 'search must be text up to 200 characters.');
    const query = search.trim().toLocaleLowerCase();
    return this.sessionPages.page({ cursor, limit, filters: { project: project || null, includeArchived, search: query } }, () => {
      const source = this.history.sessionIndex?.(5000) ?? { sessions: this.history.sessions(5001), truncated: false };
      const desktop = source.sessions.map(({ workspacePath, ...rest }) => rest), owned = Object.values(this.registry.sessions).map(record => this.ownedDTO(record));
      const unique = new Map([...desktop, ...owned].map(session => [session.id, session]));
      const sessions = [...unique.values()].filter(session => (includeArchived || !session.archived) && (!project || session.projectId === project)
        && (!query || `${session.title}\n${session.projectName}`.toLocaleLowerCase().includes(query)))
        .sort((a, b) => Number(b.pinned ?? false) - Number(a.pinned ?? false) || b.updatedAt.localeCompare(a.updatedAt) || b.id.localeCompare(a.id));
      return { sessions, truncated: source.truncated };
    });
  }
  models() { return { models: modelCatalog(this.zcodeRoot), modes: SUPPORTED_MODES }; }
  workspace(id) { const project = this.projects().find(project => project.id === id); if (!project) throw new BridgeError(404, 'not_found', 'Project not found.'); return project; }
  projectSettings(id) { const workspace = this.workspace(id); return { projectId: id, model: validateSelection(this.zcodeRoot, this.history.latestModel(workspace.path)), mode: 'build', inheritance: 'desktop-persisted-selection' }; }
  files(project, path, search) { return search === undefined ? listWorkspaceFiles(this.workspace(project).path, path) : searchWorkspaceFiles(this.workspace(project).path, search, path); }
  file(project, path) { return readWorkspaceFile(this.workspace(project).path, path); }
  getDesktop(id) { return this.history.session ? this.history.session(id) : this.history.sessions(5000).find(session => session.id === id); }
  requireOwned(id) {
    const record = this.registry.sessions[id];
    if (record) return record;
    if (this.getDesktop(id)) throw new BridgeError(409, 'session_read_only', 'This task is owned by the desktop. Mobile control is available for tasks created by this bridge.');
    throw new BridgeError(404, 'not_found', 'Task not found.');
  }
  pendingInteractions(sessionId) {
    return [...this.protocol.interactions].filter(([, frame]) => frame.params.sessionId === sessionId).map(([id, frame]) => {
      const p = frame.params;
      return { id, sessionId, kind: frame.method.endsWith('requestPermission') ? 'permission' : 'userInput', title: p.toolName || 'Answer needed',
        reason: p.reason ?? p.prompt, toolName: p.toolName, input: sanitize(p.input), questions: sanitize(p.questions),
        freeText: p.freeText, sensitive: p.sensitive, schema: sanitize(p.schema), options: sanitize(p.options?.filter(option => !option.response?.permissionUpdates)), createdAt: frame.receivedAt ?? iso() };
    });
  }
  async detail(id) {
    const record = this.registry.sessions[id];
    if (!record) {
      const desktop = this.getDesktop(id);
      if (!desktop) throw new BridgeError(404, 'not_found', 'Task not found.');
      const { workspacePath, ...session } = desktop;
      return { session, ...this.transcript(id), pendingInteractions: [], hostActivity: emptyHostActivity('desktopReadOnly') };
    }
    let activity;
    try { await this.ensureInitialized(id); activity = activityFromProjection(await this.hostActivity.ensure(id)); }
    catch (error) { activity = emptyHostActivity(error.code ?? 'projectionUnavailable'); }
    return { session: this.ownedDTO(record), ...this.transcript(id), pendingInteractions: this.pendingInteractions(id), hostActivity: activity };
  }
  transcript(id, options = {}) {
    const record = this.registry.sessions[id];
    if (!record && !this.getDesktop(id)) throw new BridgeError(404, 'not_found', 'Task not found.');
    const reader = record ? this.ownedHistory : this.history;
    const result = reader.transcript(id, options, record ? this.snapshots.get(id)?.messages ?? [] : []);
    return record ? { ...result, messages: withForkTargets(result.messages, this.hostActivity.projections.get(id)) } : result;
  }
  fork(id, body) { return forkSession(this, id, body); }
  async goalAction(id, action) {
    const record = this.requireOwned(id);
    if (!['pause', 'resume'].includes(action)) throw new BridgeError(422, 'goal_remove_unsupported', 'The verified desktop protocol has no goal removal command.');
    if (record.archived) throw new BridgeError(409, 'session_archived', 'Restore this task before changing its goal.');
    return this.mutate(id, async () => {
      await this.ensureInitialized(id);
      const before = await this.hostActivity.ensure(id), type = action === 'pause' ? 'pauseGoal' : 'resumeGoal';
      if (!before.goal || before.availability?.[type]?.allowed !== true) throw new BridgeError(409, 'goal_action_unavailable', 'The host has not enabled this goal action.', false, { reasonCode: before.availability?.[type]?.reasonCode });
      const acknowledgement = await this.command(id, type, {}, randomUUID(), { baseRevision: before.revision, baseLogEpoch: before.logEpoch });
      const after = await this.hostActivity.waitFor(id, projection => projection.goal?.targetId === before.goal.targetId && (action === 'pause' ? projection.goal?.status === 'paused' : ['active', 'verifying', 'notSatisfied'].includes(projection.goal?.status)));
      await this.refresh(id);
      return { accepted: true, sessionId: id, acknowledgement: acknowledgement.status, hostActivity: activityFromProjection(after) };
    });
  }
  async create({ project, title, mode = 'build', model, confirmFullAccess, clientDraftId }) {
    if (!SUPPORTED_MODES.includes(mode)) throw new BridgeError(422, 'invalid_request', 'Supported modes are build, plan, edit, and explicitly confirmed yolo.');
    if (mode === 'yolo' && confirmFullAccess !== true) throw new BridgeError(422, 'full_access_confirmation_required', 'Full access requires an explicit client confirmation.', false, { requiredField: 'confirmFullAccess' });
    if (clientDraftId === undefined) return this.createUnlocked({ project, title, mode, model });
    const key = hash(requireString(clientDraftId, 'clientDraftId', 128));
    // Hash the client's intent, so a later desktop default cannot change a retry.
    const contentHash = hash(JSON.stringify({ project, title: title ?? null, mode, model: model ? { providerId: model.providerId, modelId: model.modelId, thoughtLevel: model.thoughtLevel ?? null } : null }));
    return this.mutate(`create:${key}`, async () => {
      const previous = this.registry.drafts[key];
      if (previous) {
        if (previous.hash !== contentHash) throw new BridgeError(409, 'draft_conflict', 'This draft ID was already used with different task settings. Use a new draft ID for a different task.');
        const record = previous.sessionId && this.registry.sessions[previous.sessionId];
        if (previous.status === 'accepted' && record) return this.ownedDTO(record);
        throw new BridgeError(409, 'draft_uncertain', 'ZCode may have created this task before the result was recorded. Review the task list before creating another draft.', false, { ...(previous.sessionId ? { sessionId: previous.sessionId } : {}), reconcileTaskList: true });
      }
      return this.createUnlocked({ project, title, mode, model }, { key, hash: contentHash });
    });
  }
  async createUnlocked({ project, title, mode, model }, draft) {
    const workspace = this.projects().find(p => p.id === project);
    if (!workspace || !existsSync(workspace.path)) throw new BridgeError(404, 'not_found', 'Workspace not found.');
    const selection = model ? validateSelection(this.zcodeRoot, model) : this.projectSettings(project).model, runtimeModel = selectedRuntimeModel(this.zcodeRoot, selection);
    await this.protocol.start();
    if (draft) { this.registry.drafts[draft.key] = { hash: draft.hash, status: 'pending', at: iso() }; this.persist(); }
    try {
      const snapshot = await this.protocol.request('session/create', { workspace: { workspaceKey: workspace.path, workspacePath: workspace.path }, mode, persistence: 'deferred',
        model: runtimeModel.model, runtimeModel, thoughtLevel: selection.thoughtLevel, titleGenerationEnabled: false, mcpServers: [] }, 60000);
      const id = snapshot?.session?.sessionId;
      if (typeof id !== 'string' || !id) throw new BridgeError(502, 'invalid_runtime_response', 'ZCode did not return a task ID.');
      this.registry.sessions[id] = { id, path: workspace.path, title: title || 'New task', customTitle: !!title, mode,
        selection: { providerId: selection.providerId, modelId: selection.modelId, thoughtLevel: selection.thoughtLevel }, permissionMode: mode === 'plan' ? 'build' : mode,
        createdAt: iso(snapshot.session.createdAt), updatedAt: iso(), status: 'idle' };
      if (draft) Object.assign(this.registry.drafts[draft.key], { status: 'accepted', sessionId: id });
      this.snapshots.set(id, snapshot); this.persist();
      const session = this.ownedDTO(this.registry.sessions[id]); this.events.publish('session.created', { session }, id);
      await this.protocol.request('session/subscribe', { sessionId: id, deliveryKind: 'web-remote-replayable', includeSnapshot: false });
      this.initialized.add(id); return session;
    } catch (error) {
      if (draft && this.registry.drafts[draft.key].status !== 'accepted') { this.registry.drafts[draft.key].status = 'uncertain'; this.persist(); }
      throw error;
    }
  }
  async mutate(id, operation) {
    const previous = this.mutations.get(id) ?? Promise.resolve();
    const pending = previous.catch(() => {}).then(operation); this.mutations.set(id, pending);
    try { return await pending; } finally { if (this.mutations.get(id) === pending) this.mutations.delete(id); }
  }
  async command(id, type, payload = {}, commandId = randomUUID(), base = {}) {
    const result = await this.protocol.request('v4/command', { commandId, clientId: 'zcode-mobile-bridge', sessionId: id, type, payload, issuedAt: Date.now(), ...base }, 60000);
    if (!['accepted', 'duplicate', 'noop'].includes(result?.status)) throw new BridgeError(result?.status === 'stale' ? 409 : 422, 'command_rejected', result?.message || 'ZCode rejected this command.', false, { commandStatus: result?.status, reasonCode: result?.reasonCode });
    return result;
  }
  async runtimeAttachments(id, attachments, ids) {
    const refs = [];
    for (const [index, attachment] of attachments.entries()) {
      const bytes = Buffer.from(attachment.dataBase64, 'base64'), chunkSize = 512 * 1024;
      const key = { connectionId: this.events.epoch, uploadId: ids[index], sessionId: id };
      const begun = await this.protocol.request('v4/attachment/begin', { ...key, fileName: attachment.filename, mime: attachment.mimeType, totalBytes: bytes.length, totalChunks: Math.ceil(bytes.length / chunkSize), checksum: `sha256:${hash(bytes)}` });
      let ref = begun.ref;
      if (begun.state !== 'committed') {
        try {
          for (let chunkIndex = begun.nextChunkIndex ?? 0; chunkIndex < Math.ceil(bytes.length / chunkSize); chunkIndex++) await this.protocol.request('v4/attachment/chunk', { ...key, chunkIndex, dataBase64: bytes.subarray(chunkIndex * chunkSize, (chunkIndex + 1) * chunkSize).toString('base64') });
          ref = (await this.protocol.request('v4/attachment/commit', key)).ref;
        } catch (error) { await this.protocol.request('v4/attachment/abort', key).catch(() => {}); throw error; }
      }
      if (!ref) throw new BridgeError(502, 'attachment_upload_failed', 'ZCode did not return a reference for the attachment.');
      refs.push({ ref, fileName: attachment.filename, mime: attachment.mimeType, bytes: bytes.length });
    }
    return refs;
  }
  async metadata(id, body) {
    return this.mutate(id, async () => {
      const record = this.requireOwned(id), allowed = ['title', 'pinned', 'archived', 'unread', 'expectedUnreadAt'];
      if (!Object.keys(body).length || Object.keys(body).some(key => !allowed.includes(key))) throw new BridgeError(422, 'invalid_request', 'Use title, pinned, archived, or unread to update task metadata.');
      if (body.title !== undefined && (typeof body.title !== 'string' || !body.title.trim() || body.title.length > 200)) throw new BridgeError(422, 'invalid_request', 'title must contain 1 to 200 characters.');
      for (const key of ['pinned', 'archived', 'unread']) if (body[key] !== undefined && typeof body[key] !== 'boolean') throw new BridgeError(422, 'invalid_request', `${key} must be a boolean.`);
      if (body.unread === false && (!Number.isSafeInteger(body.expectedUnreadAt) || body.expectedUnreadAt < 0)
        || body.expectedUnreadAt !== undefined && body.unread !== false) throw new BridgeError(422, 'invalid_request', 'Clearing unread requires its exact expectedUnreadAt timestamp in milliseconds.');
      const unreadApplied = body.unread === undefined ? undefined : body.unread || record.unreadAt === body.expectedUnreadAt || record.unreadAt === undefined;
      if (unreadApplied === false && Object.keys(body).every(key => ['unread', 'expectedUnreadAt'].includes(key))) return { session: this.ownedDTO(record), metadataScope: 'bridge', unreadApplied: false };
      if (body.archived && ['running', 'waiting'].includes(record.status)) throw new BridgeError(409, 'session_busy', 'Stop the task before archiving it.');
      if (body.title !== undefined) {
        // Official CLI drafts are not stored until real input. Its immediate flag alone
        // does not persist them and breaks v4 admission; keep draft metadata separate.
        if (this.ownedHistory.hasSession?.(id) === false) record.pendingRuntimeTitle = body.title.trim();
        else {
          await this.ensureInitialized(id); await this.command(id, 'renameSession', { title: body.title.trim() });
          record.pendingRuntimeTitle = undefined; record.pendingRuntimeTitleError = undefined;
        }
        record.title = body.title.trim(); record.customTitle = true;
      }
      for (const key of ['pinned', 'archived']) if (body[key] !== undefined) record[key] = body[key];
      if (unreadApplied) record.unreadAt = body.unread ? Math.max(Date.now(), (record.unreadAt ?? 0) + 1) : undefined;
      record.updatedAt = iso(); this.persist(); const session = this.ownedDTO(record);
      this.events.publish('session.updated', { session }, id); return { session, metadataScope: 'bridge', ...(body.title !== undefined ? { runtimeTitleStatus: record.pendingRuntimeTitle ? 'pending-persistence' : 'applied' } : {}), ...(unreadApplied !== undefined ? { unreadApplied } : {}) };
    });
  }
  async syncPendingTitle(id) {
    const record = this.registry.sessions[id], title = record?.pendingRuntimeTitle;
    if (!title || this.ownedHistory.hasSession?.(id) === false) return;
    try {
      await this.command(id, 'renameSession', { title });
      const readback = await this.protocol.request('session/read', { sessionId: id, messageLimit: 1 });
      if (readback.session?.title !== title) throw new BridgeError(504, 'metadata_not_confirmed', 'The runtime title is not yet confirmed.', true);
      if (record.pendingRuntimeTitle === title) { record.pendingRuntimeTitle = undefined; record.pendingRuntimeTitleError = undefined; this.persist(); }
    } catch (error) { record.pendingRuntimeTitleError = error.code || 'metadata_sync_failed'; this.persist(); }
  }
  settings(id) {
    const record = this.requireOwned(id), model = modelCatalog(this.zcodeRoot).find(model => model.providerId === record.selection.providerId && model.modelId === record.selection.modelId);
    return { sessionId: id, model: record.selection, mode: record.mode, permissionMode: record.permissionMode ?? (record.mode === 'plan' ? 'build' : record.mode), thoughtLevels: model?.thoughtLevels ?? [], modes: SUPPORTED_MODES, mutable: this.protocol.ready && !record.archived };
  }
  async updateSettings(id, body) {
    return this.mutate(id, async () => {
      const record = this.requireOwned(id);
      if (record.archived) throw new BridgeError(409, 'session_archived', 'Unarchive this task before changing its settings.');
      if (['running', 'waiting'].includes(record.status)) throw new BridgeError(409, 'session_busy', 'Wait for the turn to finish before changing task settings.');
      if (!Object.keys(body).some(key => ['model', 'thoughtLevel', 'mode', 'permissionMode'].includes(key)) || Object.keys(body).some(key => !['model', 'thoughtLevel', 'mode', 'permissionMode', 'confirmFullAccess'].includes(key))) throw new BridgeError(422, 'invalid_request', 'Use model, thoughtLevel, mode, or permissionMode to update settings.');
      if (body.mode !== undefined && !SUPPORTED_MODES.includes(body.mode)) throw new BridgeError(422, 'invalid_request', 'Supported modes are build, plan, edit, and explicitly confirmed yolo.');
      if (body.permissionMode !== undefined && !['build', 'edit', 'yolo'].includes(body.permissionMode)) throw new BridgeError(422, 'invalid_request', 'permissionMode must be build, edit, or explicitly confirmed yolo.');
      if ((body.mode === 'yolo' || body.permissionMode === 'yolo') && body.confirmFullAccess !== true) throw new BridgeError(422, 'full_access_confirmation_required', 'Full access requires an explicit client confirmation.', false, { requiredField: 'confirmFullAccess' });
      if (body.mode && body.mode !== 'plan' && body.permissionMode && body.mode !== body.permissionMode) throw new BridgeError(422, 'invalid_request', 'Non-plan mode and permissionMode must agree when both are supplied.');
      const nextMode = body.mode ?? (record.mode === 'plan' ? 'plan' : body.permissionMode ?? record.mode);
      const nextPermissionMode = body.permissionMode ?? (body.mode && body.mode !== 'plan' ? body.mode : record.permissionMode ?? (record.mode === 'plan' ? 'build' : record.mode));
      if (body.model !== undefined && (!body.model || typeof body.model !== 'object' || Array.isArray(body.model))) throw new BridgeError(422, 'invalid_request', 'model must contain providerId and modelId.');
      const selection = validateSelection(this.zcodeRoot, { ...(body.model ?? record.selection), ...(body.thoughtLevel !== undefined ? { thoughtLevel: body.thoughtLevel } : {}) });
      await this.ensureInitialized(id);
      const runtimeModel = selectedRuntimeModel(this.zcodeRoot, selection);
      if (selection.providerId !== record.selection.providerId || selection.modelId !== record.selection.modelId) {
        const snapshot = await this.protocol.request('session/setModel', { sessionId: id, model: runtimeModel.model, runtimeModel, persistAsWorkspaceLastUsed: false });
        if (snapshot?.session) this.snapshots.set(id, snapshot);
      } else if (selection.thoughtLevel !== record.selection.thoughtLevel) {
        const snapshot = await this.protocol.request('session/setThoughtLevel', { sessionId: id, thoughtLevel: selection.thoughtLevel, runtimeModel, persistAsWorkspaceLastUsed: false });
        if (snapshot?.session) this.snapshots.set(id, snapshot);
      }
      record.selection = selection; this.persist();
      if (nextMode !== record.mode) {
        const snapshot = await this.protocol.request('session/setMode', { sessionId: id, mode: nextMode });
        if (snapshot?.session) this.snapshots.set(id, snapshot);
        record.mode = nextMode;
      }
      record.permissionMode = nextPermissionMode;
      record.updatedAt = iso(); this.persist(); this.events.publish('session.updated', { session: this.ownedDTO(record) }, id);
      return { ...this.settings(id), session: this.ownedDTO(record) };
    });
  }
  upload(id, body) { const record = this.requireOwned(id); if (record.archived) throw new BridgeError(409, 'session_archived', 'Unarchive this task before attaching files.'); return { attachment: this.attachments.create(id, body) }; }
  async ensureInitialized(id) {
    if (this.initialized.has(id)) return;
    if (this.initializing.has(id)) return this.initializing.get(id);
    const initialize = (async () => {
      const record = this.requireOwned(id); await this.protocol.start();
      const runtimeModel = selectedRuntimeModel(this.zcodeRoot, record.selection);
      let snapshot;
      try { snapshot = await this.protocol.request('session/resume', { sessionId: id, workspace: { workspaceKey: record.path, workspacePath: record.path }, runtimeModel, thoughtLevel: record.selection.thoughtLevel, mcpServers: [] }, 60000); }
      catch (error) {
        if (/^Session not found:/.test(error.message)) throw new BridgeError(409, 'session_draft_expired', 'This task was not saved by ZCode before the bridge restarted. Create a new task to continue.', false, { sessionId: id });
        throw error;
      }
      this.snapshots.set(id, snapshot);
      record.recoveryReason = undefined;
      if (['idle', 'running', 'waiting', 'completed', 'error'].includes(snapshot.session?.status)) record.status = snapshot.session.status;
      await this.protocol.request('session/subscribe', { sessionId: id, deliveryKind: 'web-remote-replayable', includeSnapshot: false });
      this.initialized.add(id);
    })();
    this.initializing.set(id, initialize);
    try { await initialize; } finally { this.initializing.delete(id); }
  }
  async send(id, text, inputId = randomUUID(), attachmentIds = []) { return this.mutate(id, () => this.sendUnlocked(id, text, inputId, attachmentIds)); }
  async sendUnlocked(id, text, inputId, attachmentIds) {
    const record = this.requireOwned(id), key = `${id}:${inputId}`, contentHash = hash(JSON.stringify({ text, attachmentIds }));
    if (record.archived) throw new BridgeError(409, 'session_archived', 'Unarchive this task before sending a message.');
    const previous = this.registry.inputs[key];
    if (previous) {
      if (previous.hash !== contentHash && !(attachmentIds.length === 0 && previous.hash === hash(text))) throw new BridgeError(409, 'input_conflict', 'Input ID was already used with different content.');
      if (previous.status === 'accepted') return { accepted: true, sessionId: id, inputId, duplicate: true };
      if (previous.status === 'pending' || previous.status === 'uncertain') throw new BridgeError(409, 'input_pending', 'This input may already be running. Refresh the task before sending again.', true);
    }
    if (['running', 'waiting'].includes(record.status)) throw new BridgeError(409, 'session_busy', 'This task is still running. Stop it or wait for completion before sending another message.');
    const model = modelCatalog(this.zcodeRoot).find(model => model.providerId === record.selection.providerId && model.modelId === record.selection.modelId);
    const attachments = this.attachments.resolve(id, attachmentIds, { supportsImages: model?.supportsImages ?? false, supportsPDF: model?.supportsPDF ?? false });
    await this.ensureInitialized(id);
    const refs = await this.runtimeAttachments(id, attachments, attachmentIds);
    this.registry.inputs[key] = { hash: contentHash, status: 'pending', at: iso() }; this.persist();
    try {
      record.stopRequestedAt = undefined;
      await this.command(id, 'sendText', { text, ...(refs.length ? { attachments: refs } : {}) }, inputId);
      this.registry.inputs[key].status = 'accepted'; record.status = 'running'; record.updatedAt = iso();
      if (!record.customTitle && record.title === 'New task') record.title = text.slice(0, 80);
      this.persist(); this.events.publish('session.updated', { session: this.ownedDTO(record) }, id);
      return { accepted: true, sessionId: id, inputId };
    } catch (error) {
      this.registry.inputs[key].status = error.code === 'runtime_timeout' || error.code === 'runtime_unavailable' ? 'uncertain' : 'failed'; this.persist(); throw error;
    }
  }
  async stop(id) {
    const record = this.requireOwned(id);
    if (!this.initialized.has(id) || !['running', 'waiting'].includes(record.status)) return { stopped: false, sessionId: id };
    const acknowledgement = await this.command(id, 'stop');
    record.stopRequestedAt = iso(); record.updatedAt = iso(); this.persist();
    for (const [key, frame] of this.protocol.interactions) if (frame.params.sessionId === id) this.protocol.interactions.delete(key);
    const deadline = Date.now() + 10000;
    do {
      await this.refresh(id);
      const snapshot = this.snapshots.get(id);
      if (!snapshot?.runtime?.activeTurnId && !['running', 'waiting'].includes(snapshot?.session?.status)) {
        record.status = 'idle'; this.persist(); this.events.publish('session.updated', { session: this.ownedDTO(record) }, id);
        return { stopped: true, sessionId: id, acknowledgement: acknowledgement.status, verified: true };
      }
      await new Promise(resolve => setTimeout(resolve, 100));
    } while (Date.now() < deadline);
    throw new BridgeError(504, 'stop_not_confirmed', 'The stop request was accepted, but the runtime has not confirmed the turn ended.', true, { sessionId: id, stopRequested: true });
  }
  respond(id, body) {
    const frame = this.protocol.interactions.get(id);
    if (!frame) throw new BridgeError(404, 'not_found', 'This request is no longer pending.');
    const record = this.requireOwned(frame.params.sessionId), sessionId = this.protocol.respond(id, body);
    record.status = 'running'; this.persist();
    this.events.publish('interaction.resolved', { interactionId: id }, sessionId);
    this.events.publish('session.updated', { session: this.ownedDTO(record) }, sessionId); return { accepted: true };
  }
  async changes(id) {
    const path = this.registry.sessions[id]?.path ?? this.getDesktop(id)?.workspacePath;
    if (!path) throw new BridgeError(404, 'not_found', 'Task not found.');
    return workspaceChanges(path);
  }
  onInteraction(id, frame) {
    const sessionId = frame.params.sessionId, record = this.registry.sessions[sessionId];
    if (!record) return;
    record.status = 'waiting'; this.persist();
    this.events.publish('interaction.requested', { interaction: this.pendingInteractions(sessionId).find(i => i.id === id) }, sessionId);
    this.events.publish('session.updated', { session: this.ownedDTO(record) }, sessionId);
  }
  onRuntimeEvent(event) {
    const id = event.sessionId, record = this.registry.sessions[id]; if (!record) return;
    if (event.type === 'turn.started') record.status = 'running';
    if (event.type === 'turn.completed') record.status = record.stopRequestedAt || event.payload?.resultType === 'cancelled' ? 'idle' : 'completed';
    if (event.type === 'turn.failed') record.status = record.stopRequestedAt ? 'idle' : 'error';
    record.updatedAt = iso();
    this.events.publish('runtime.event', { event }, id);
    if (!this.refreshTimers.has(id)) this.refreshTimers.set(id, setTimeout(() => { this.refreshTimers.delete(id); this.refresh(id).catch(() => {}); }, event.type.startsWith('turn.') ? 20 : 200));
  }
  async refresh(id) {
    if (!this.initialized.has(id)) return;
    if (this.refreshing.has(id)) return this.refreshing.get(id);
    const operation = (async () => {
      if (this.registry.sessions[id]?.pendingRuntimeTitle) await this.syncPendingTitle(id);
      const snapshot = await this.protocol.request('session/read', { sessionId: id, messageLimit: 500 });
      const before = normalizeMessages(this.snapshots.get(id)?.messages ?? []), after = withForkTargets(normalizeMessages(snapshot.messages ?? []), this.hostActivity.projections.get(id));
      this.snapshots.set(id, snapshot);
      const map = new Map(before.map(m => [m.id, JSON.stringify(m)]));
      for (const message of after) if (map.get(message.id) !== JSON.stringify(message)) this.events.publish('message.updated', { message }, id);
      const record = this.registry.sessions[id];
      if (record) {
        if (typeof snapshot.settings?.mode?.current === 'string') record.mode = snapshot.settings.mode.current;
        const state = snapshot.session?.status;
        if (['running', 'waiting', 'completed', 'error'].includes(state)) record.status = state;
        else if (state === 'idle' && ['running', 'waiting'].includes(record.status)) record.status = 'idle';
        record.updatedAt = iso(); this.persist(); this.events.publish('session.updated', { session: this.ownedDTO(record) }, id);
      }
    })();
    this.refreshing.set(id, operation);
    try { return await operation; } finally { this.refreshing.delete(id); }
  }
  async close() { for (const timer of this.refreshTimers.values()) clearTimeout(timer); this.hostActivity.close(); await this.protocol.close(); }
}
