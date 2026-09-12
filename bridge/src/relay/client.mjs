import { EventEmitter } from 'node:events';
import { randomUUID, createHmac } from 'node:crypto';
import { encodeIPC, decodeIPC, relayProof } from './codec.mjs';
import { RelayFrames } from './frames.mjs';
import { BridgeError } from '../util.mjs';

export function parseOfficialPairing(value) {
  let url; try { url = new URL(value); } catch { throw new Error('Scan a valid official ZCode Remote Control QR.'); }
  if (url.origin !== 'https://zcode.z.ai' || !/^\/remote\/v4\/?$/.test(url.pathname) || url.username || url.password || url.hash) throw new Error('Only the official HTTPS Remote Control v4 pairing URL is supported.');
  for (const key of ['sid', 'hash', 'mid']) if (url.searchParams.getAll(key).length > 1) throw new Error('Ambiguous pairing parameters');
  const deviceSid = url.searchParams.get('sid'), passHash = url.searchParams.get('hash');
  if (!deviceSid || !/^[A-Za-z0-9._~-]{1,256}$/.test(deviceSid) || !passHash || passHash.length < 32 || passHash.length > 512 || /\s/.test(passHash)) throw new Error('Pairing credentials are missing or invalid.');
  return { deviceSid, passHash, deviceMid: url.searchParams.get('mid') || undefined, deviceName: url.searchParams.get('name') || 'ZCode Desktop', appVersion: url.searchParams.get('app_version') || 'unknown', relayURL: 'wss://zcode.z.ai/ws' };
}
const READ_METHODS = {
  'zcode-task': new Set(['listTasks', 'listArchivedTasks', 'listPinnedTasks', 'listPinnedTaskIds']),
  'zcode-session': new Set(['readSession', 'readWorkspaceState']),
  'zcode-agent': new Set(['queryConversationCommandsV4', 'conversationRowsRangeV4', 'conversationPlansV4', 'conversationFileChangesV4', 'subscribeConversationV4', 'unsubscribeConversationV4', 'resyncConversationV4']),
};
const WRITE_METHODS = {
  'zcode-task': new Set(['renameTask', 'archiveTask', 'unarchiveTask', 'setTaskPinned']),
  'zcode-session': new Set(['createSession']),
  'zcode-agent': new Set(['sendConversationCommandV4', 'attachmentBeginV4', 'attachmentChunkV4', 'attachmentCommitV4', 'attachmentAbortV4']),
};
const COMMAND_TYPES = new Set(['sendText', 'stop', 'renameSession', 'resolveInteraction', 'switchModelConfig', 'switchCollaborationMode']);

// Experimental standalone transport: never starts on import, never reads persisted QR credentials,
// and never auto-reconnects or resends a command after an uncertain failure.
export class OfficialRelayClient extends EventEmitter {
  constructor({ WebSocketClass = globalThis.WebSocket, requestTimeout = 15000 } = {}) {
    super(); this.WebSocketClass = WebSocketClass; this.requestTimeout = requestTimeout; this.state = 'idle'; this.pendingApps = new Map(); this.pendingRPC = new Map(); this.listeners = new Map(); this.rpcSequence = 0; this.bridgeGeneration = 0; this.clientId = randomUUID();
  }
  setState(state) { this.state = state; this.emit('state', this.safeStatus()); }
  safeStatus() { return { state: this.state, deviceName: this.pairing?.deviceName, appVersion: this.pairing?.appVersion, workspaceKey: this.bridge?.workspaceKey, transport: 'official-relay-v4', liveVerified: false }; }
  async connect(pairingURL, { confirmedControllerReplacement = false } = {}) {
    if (!confirmedControllerReplacement) throw new BridgeError(409, 'controller_confirmation_required', 'Connecting may replace another mobile controller. Confirm the selected desktop before connecting.');
    if (this.socket) throw new Error('Disconnect before pairing another desktop.');
    this.pairing = parseOfficialPairing(pairingURL); const url = new URL(this.pairing.relayURL); if (this.pairing.deviceMid) url.searchParams.set('mid', this.pairing.deviceMid);
    this.setState('connecting');
    const paired = new Promise((resolve, reject) => { this.paired = { resolve, reject }; this.connectionTimer = setTimeout(() => this.fail('relay_pairing_timeout', 'The desktop did not pair before the deadline.'), this.requestTimeout); });
    const socket = this.socket = new this.WebSocketClass(url.toString());
    socket.addEventListener('open', () => { if (socket !== this.socket) return; this.setState('authenticating'); this.send({ type: 'auth_init', role: 'terminal', device_sid: this.pairing.deviceSid, meta: { platform: 'web', version: this.pairing.appVersion, name: 'zcode-native-ios' }, client_ts: Date.now() }); });
    socket.addEventListener('message', event => { if (socket !== this.socket) return; try { if (typeof event.data !== 'string' || Buffer.byteLength(event.data) > 1024 * 1024) throw new Error('Invalid relay envelope'); this.receive(JSON.parse(event.data)); } catch { this.fail('relay_protocol_error', 'The relay sent an invalid transport frame.'); } });
    socket.addEventListener('error', () => { if (socket === this.socket) this.fail('relay_unavailable', 'The encrypted relay connection failed.'); });
    socket.addEventListener('close', () => { if (socket === this.socket) this.fail('relay_disconnected', 'The relay connection closed. Reconnect explicitly to reconcile the desktop state.'); });
    await paired; return this.safeStatus();
  }
  send(value) { if (!this.socket || this.socket.readyState !== 1) throw new Error('Relay is not connected'); const text = JSON.stringify(value); if (Buffer.byteLength(text) > 1024 * 1024) throw new Error('Relay envelope exceeds 1 MB'); this.socket.send(text); }
  sendPayload(payload) { if (this.state !== 'paired') throw new Error('Desktop relay is not paired'); this.send({ type: 'data', payload, client_ts: Date.now() }); }
  receive(frame) {
    if (frame.type === 'auth_challenge') {
      if (typeof frame.nonce !== 'string' || frame.nonce.length > 4096) throw new Error('Invalid challenge');
      this.send({ type: 'auth_response', device_sid: this.pairing.deviceSid, proof: relayProof(this.pairing.passHash, frame.nonce, this.pairing.deviceSid, (key, text) => createHmac('sha256', Buffer.from(key, 'utf8')).update(text).digest('base64url')), client_ts: Date.now() }); return;
    }
    if (['auth_ack', 'pair_status_ack'].includes(frame.type)) {
      this.lastHeartbeat = Date.now();
      if (frame.pair_status === 'matched') {
        this.setState('paired'); clearTimeout(this.connectionTimer); this.paired?.resolve(); this.paired = undefined;
        if (!this.heartbeat) this.heartbeat = setInterval(() => { try { if (Date.now() - this.lastHeartbeat > 30000) return this.fail('relay_heartbeat_timeout', 'The desktop relay stopped responding.'); this.frames?.checkDeadline(); this.send({ type: 'pair_status_query', device_sid: this.pairing.deviceSid, client_ts: Date.now() }); } catch { this.fail('relay_transport_degraded', 'The relay transport needs reconnection.'); } }, 10000);
      } else if (frame.pair_status === 'waiting') this.setState('waiting'); return;
    }
    if (frame.type === 'error') return this.fail(frame.code === 'KICKED' ? 'controller_replaced' : 'relay_rejected', frame.code === 'KICKED' ? 'Another mobile controller replaced this connection.' : 'The relay rejected this pairing or the desktop is unavailable.');
    if (frame.type !== 'data' || !frame.payload || typeof frame.payload !== 'object') return;
    const payload = frame.payload;
    if (['rpc-frame', 'rpc-frame-ack'].includes(payload.zcode_type)) { this.frames?.accept(payload); return; }
    for (const [id, pending] of this.pendingApps) if (pending.matches(payload)) { clearTimeout(pending.timer); this.pendingApps.delete(id); if (payload.success === false || payload.zcode_type === 'workspace-bridge-error') pending.reject(new Error(payload.error || 'Desktop bridge rejected this request')); else pending.resolve(payload); return; }
    if (['bridge-degraded', 'workspace-bridge-error', 'app-error'].includes(payload.zcode_type)) return this.fail('desktop_bridge_degraded', 'The original desktop bridge is no longer available.');
    this.emit('payload', payload);
  }
  appRequest(payload, matches) {
    const requestId = payload.requestId ?? randomUUID();
    return new Promise((resolve, reject) => { const timer = setTimeout(() => { this.pendingApps.delete(requestId); reject(new BridgeError(504, 'relay_request_timeout', 'The desktop did not answer before the deadline.', true)); }, this.requestTimeout); this.pendingApps.set(requestId, { resolve, reject, timer, matches }); try { this.sendPayload({ ...payload, requestId }); } catch (error) { clearTimeout(timer); this.pendingApps.delete(requestId); reject(error); } });
  }
  async bootstrap() { const requestId = randomUUID(), response = await this.appRequest({ zcode_type: 'bootstrap-request', requestId }, payload => payload.zcode_type === 'bootstrap-response' && payload.requestId === requestId); return this.bootstrapInfo = response.result; }
  async workspaces() { const requestId = randomUUID(), response = await this.appRequest({ zcode_type: 'workspace-list-request', requestId }, payload => payload.zcode_type === 'workspace-list-response' && payload.requestId === requestId); return response.result; }
  async openWorkspace(workspaceKey, taskId) {
    if (typeof workspaceKey !== 'string' || !workspaceKey) throw new Error('Choose an opened desktop workspace.');
    if (this.pendingRPC.size) throw new Error('Wait for pending desktop operations before switching workspaces.');
    const bridgeSessionId = randomUUID(), response = await this.appRequest({ zcode_type: 'workspace-bridge-open', bridgeSessionId, bridgeGeneration: ++this.bridgeGeneration, workspaceKey, ...(taskId ? { taskId } : {}) }, payload => ['workspace-bridge-ready', 'workspace-bridge-error'].includes(payload.zcode_type) && payload.bridgeSessionId === bridgeSessionId);
    this.bridge = response.bridge; this.rpcReady = false; this.listeners.clear();
    this.frames = new RelayFrames(this.bridge, payload => this.sendPayload(payload)); this.frames.on('message', bytes => this.receiveIPC(bytes)); this.frames.on('degraded', () => this.fail('relay_transport_degraded', 'The replayable relay transport requires reconnection.'));
    return this.bridge;
  }
  receiveIPC(bytes) {
    const { header, body } = decodeIPC(bytes), [type, id] = header;
    if (type === 200) { this.rpcReady = true; this.emit('rpcReady'); return; }
    if (type === 204) { this.listeners.get(id)?.(body); return; }
    if (![201, 202, 203].includes(type)) return;
    const pending = this.pendingRPC.get(id); if (!pending) return;
    clearTimeout(pending.timer); this.pendingRPC.delete(id);
    if (type === 201) pending.resolve(body); else if ([202, 203].includes(type)) pending.reject(new BridgeError(502, 'desktop_rpc_error', body?.message || 'The desktop rejected the service call.', false, { code: body?.code }));
  }
  async waitRPC() {
    if (this.rpcReady) return;
    await new Promise((resolve, reject) => { const ready = () => { clearTimeout(timer); resolve(); }, timer = setTimeout(() => { this.off('rpcReady', ready); reject(new BridgeError(504, 'relay_rpc_not_ready', 'The desktop service did not initialize.', true)); }, this.requestTimeout); this.once('rpcReady', ready); });
  }
  scope(params = {}) { if (!this.bridge) throw new Error('Open a desktop workspace first'); return { ...params, workspacePath: this.bridge.workspacePath, ...(this.bridge.workspaceIdentity ? { workspaceIdentity: this.bridge.workspaceIdentity } : {}) }; }
  async rpc(channel, method, params = {}, { explicitUserAction = false, confirmFullAccess = false } = {}) {
    const read = READ_METHODS[channel]?.has(method), write = WRITE_METHODS[channel]?.has(method);
    if (!read && !write) throw new BridgeError(422, 'relay_method_unsupported', 'This desktop service capability is not exposed by the native adapter.');
    if (write && explicitUserAction !== true) throw new BridgeError(409, 'explicit_action_required', 'Desktop changes require an explicit user action.');
    if (method === 'sendConversationCommandV4') {
      if (!COMMAND_TYPES.has(params.envelope?.type)) throw new BridgeError(422, 'relay_command_unsupported', 'This desktop command is not exposed by the native adapter.');
      if (params.envelope.type === 'switchCollaborationMode' && params.envelope.payload?.mode === 'yolo' && confirmFullAccess !== true) throw new BridgeError(422, 'full_access_confirmation_required', 'Full access requires explicit confirmation.');
      if (params.envelope.type === 'resolveInteraction' && params.envelope.payload?.answer?.optionId === 'allow_project') throw new BridgeError(422, 'persistent_permissions_unsupported', 'The native adapter supports one-time permission decisions only.');
    }
    if (method === 'createSession' && params.mode === 'yolo' && confirmFullAccess !== true) throw new BridgeError(422, 'full_access_confirmation_required', 'Full access requires explicit confirmation.');
    await this.waitRPC(); const id = this.rpcSequence++, body = [this.scope(params)];
    return new Promise((resolve, reject) => { const timer = setTimeout(() => { this.pendingRPC.delete(id); reject(new BridgeError(504, 'relay_rpc_timeout', 'The desktop response is uncertain. Reconcile the original command ID before retrying.', true)); }, this.requestTimeout); this.pendingRPC.set(id, { resolve, reject, timer }); try { this.frames.send(encodeIPC([100, id, channel, method], body)); } catch (error) { clearTimeout(timer); this.pendingRPC.delete(id); reject(error); } });
  }
  async listenConversation(callback) { await this.waitRPC(); const id = this.rpcSequence++; this.listeners.set(id, callback); this.frames.send(encodeIPC([102, id, 'zcode-agent', 'onDynamicConversationFrame'], this.scope())); return () => { this.listeners.delete(id); if (this.rpcReady) this.frames.send(encodeIPC([103, id], undefined)); }; }
  fail(code, message) { const error = new BridgeError(503, code, message, true); this.dispose(error); this.setState(code === 'controller_replaced' ? 'replaced' : 'disconnected'); this.emit('failure', error); }
  dispose(error = new Error('Relay connection closed')) {
    clearTimeout(this.connectionTimer); clearInterval(this.heartbeat); this.heartbeat = undefined;
    const socket = this.socket; this.socket = undefined; try { socket?.close(); } catch {} this.paired?.reject(error); this.paired = undefined;
    for (const map of [this.pendingApps, this.pendingRPC]) { for (const pending of map.values()) { clearTimeout(pending.timer); pending.reject(error); } map.clear(); }
    this.listeners.clear(); this.rpcReady = false; this.frames = undefined; this.bridge = undefined; this.pairing = undefined;
  }
  disconnect() { this.dispose(); this.setState('idle'); }
}
