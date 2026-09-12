import { BridgeError, hash, iso, requireString } from './util.mjs';

export function rowTarget(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value) || Object.keys(value).length !== 2 || !Number.isSafeInteger(value.rowId) || value.rowId < 0
    || typeof value.entityId !== 'string' || !value.entityId.trim() || Buffer.byteLength(value.entityId) > 4096) throw new BridgeError(422, 'invalid_request', 'target requires the exact host rowId and entityId.');
  return { rowId: value.rowId, entityId: value.entityId };
}
export function forkRows(projection) {
  if (projection?.availability?.fork?.allowed !== true) return [];
  return (projection.rows?.window ?? []).filter(row => row.kind === 'assistantText' && row.state === 'complete' && row.actions?.canFork === true
    && Number.isSafeInteger(row.rowId) && row.rowId >= 0 && typeof row.entityId === 'string' && !!row.entityId.trim()).sort((a, b) => a.rowId - b.rowId);
}
export function withForkTargets(messages, projection) {
  const targets = new Map(forkRows(projection).filter(row => typeof row.assistantResponseId === 'string').map(row => [row.assistantResponseId, rowTarget({ rowId: row.rowId, entityId: row.entityId })]));
  return messages.map(message => message.role === 'assistant' && targets.has(message.id) ? { ...message, forkTarget: targets.get(message.id) } : message);
}
function admitted(ack) {
  if (!['accepted', 'duplicate'].includes(ack?.status)) throw new BridgeError(409, 'fork_rejected', ack?.message || 'The host rejected this fork.', false, { reasonCode: ack?.reasonCode, commandStatus: ack?.status });
  if (ack.result?.type !== 'forkAssistant' || typeof ack.result.sessionId !== 'string' || !ack.result.sessionId) throw new BridgeError(504, 'fork_uncertain', 'The host did not confirm the forked task ID. Retry the original request.', true);
  return ack.result.sessionId;
}

/** Native host fork, with a durable original command. Never copies or edits transcript storage. */
export async function forkSession(service, id, body) {
  const parent = service.requireOwned(id);
  if (!body || typeof body !== 'object' || Array.isArray(body) || Object.keys(body).some(key => !['clientForkId', 'target'].includes(key))) throw new BridgeError(422, 'invalid_request', 'Use clientForkId and optional target.');
  const key = hash(requireString(body.clientForkId, 'clientForkId', 128)), target = body.target === undefined ? undefined : rowTarget(body.target);
  const intentHash = hash(JSON.stringify({ parentSessionId: id, target: target ?? null }));
  return service.mutate(id, () => service.mutate('fork:' + key, async () => {
    let record = service.registry.forks[key];
    if (record && record.intentHash !== intentHash) throw new BridgeError(409, 'fork_conflict', 'This fork ID was used with a different source or target.');
    if (!record) {
      if (parent.archived) throw new BridgeError(409, 'session_archived', 'Restore the task before branching it.');
      await service.ensureInitialized(id);
      const projection = await service.hostActivity.ensure(id), rows = forkRows(projection);
      const chosen = target ? rows.find(row => row.rowId === target.rowId && row.entityId === target.entityId) : rows.at(-1);
      if (!chosen) throw new BridgeError(409, target ? 'fork_target_stale' : 'fork_unavailable', 'The host has no matching completed assistant boundary available to branch.');
      record = { intentHash, envelope: { commandId: 'fork-' + key, clientId: 'zcode-mobile-bridge', sessionId: id, type: 'forkAssistant', payload: { target: rowTarget({ rowId: chosen.rowId, entityId: chosen.entityId }) },
        baseRevision: projection.revision, baseLogEpoch: projection.logEpoch, issuedAt: Date.now() }, attempted: false, createdAt: iso() };
      service.registry.forks[key] = record; service.persist();
    }
    if (!record.acknowledgement) {
      await service.ensureInitialized(id);
      if (record.attempted) {
        const queryKey = { sessionId: id, commandId: record.envelope.commandId };
        const query = await service.protocol.request('v4/commands/query', { commands: [queryKey] });
        const result = query?.results?.find(item => item.key?.sessionId === id && item.key?.commandId === queryKey.commandId)?.result;
        if (result && typeof result === 'object' && result.commandId === queryKey.commandId) { record.acknowledgement = result; service.persist(); }
        else if (result !== 'unknown') throw new BridgeError(504, 'fork_uncertain', 'The host omitted the original fork outcome. Retry the same request.', true);
      }
      if (!record.acknowledgement) {
        record.attempted = true; service.persist();
        const ack = await service.protocol.request('v4/command', record.envelope, 60000);
        if (ack?.commandId !== record.envelope.commandId) throw new BridgeError(504, 'fork_uncertain', 'The host acknowledged another command.', true);
        record.acknowledgement = ack; service.persist();
      }
    }
    const child = admitted(record.acknowledgement);
    if (child === id) throw new BridgeError(502, 'invalid_runtime_response', 'The host did not return a distinct child task.');
    if (!service.registry.sessions[child]) {
      const snapshot = await service.protocol.request('session/read', { sessionId: child, messageLimit: 500 });
      const model = snapshot.settings?.model?.current, thought = snapshot.settings?.thoughtLevel?.current, mode = snapshot.settings?.mode?.current;
      if (snapshot.session?.sessionId !== child || typeof model?.providerId !== 'string' || typeof model?.modelId !== 'string' || typeof thought !== 'string' || typeof mode !== 'string') throw new BridgeError(504, 'fork_uncertain', 'The fork exists, but its inherited configuration has not been confirmed. Retry the original request.', true);
      service.registry.sessions[child] = { id: child, parentSessionId: id, path: parent.path, title: snapshot.session.title || parent.title, mode, permissionMode: mode === 'plan' ? 'build' : mode,
        selection: { providerId: model.providerId, modelId: model.modelId, thoughtLevel: thought }, createdAt: iso(snapshot.session.createdAt), updatedAt: iso(), status: snapshot.session.status ?? 'idle' };
      service.snapshots.set(child, snapshot); service.persist();
    }
    if (!service.initialized.has(child)) {
      // A recovered ACK can point to a child from a previous bridge process.
      // Only this verified bridge-owned child may be resumed in the isolated runtime.
      await service.ensureInitialized(child);
    }
    const session = service.ownedDTO(service.registry.sessions[child]); service.events.publish('session.created', { session }, child);
    return { session, parentSessionId: id, forkedSessionId: child };
  }));
}
