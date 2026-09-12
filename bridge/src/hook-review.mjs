import { BridgeError, hash, iso, requireString, sanitize } from './util.mjs';

const LIMIT = 512 * 1024, MAX = Number.MAX_SAFE_INTEGER;
const targetKeys = ['sessionId', 'taskId', 'runId', 'workspaceIdentity', 'bundleDigest', 'reviewFlowId', 'generation', 'interactionId'];
const requestKeys = ['kind', ...targetKeys, 'workspaceLabel', 'createdAt', 'deadlineAt', 'sourceFiles', 'summary', 'items', 'warningCode'];
const pendingTrust = new Set(['pending_trust', 'revoked', 'stale_digest']);
const admitted = new Set(['accepted', 'duplicate', 'noop']);
const terminal = new Set(['rejected', 'stale', 'failed']);
const invalid = (message, code = 'hook_review_invalid', status = 422) => new BridgeError(status, code, message);
const text = value => typeof value === 'string' && value.trim().length > 0;
const integer = (value, minimum = 0) => Number.isSafeInteger(value) && value >= minimum;
const digest = value => typeof value === 'string' && /^[a-f0-9]{64}$/.test(value);
const finite = value => typeof value === 'number' && Number.isFinite(value) && Math.abs(value) <= MAX;
function shape(value, required, optional = []) {
  if (!value || typeof value !== 'object' || Array.isArray(value) || required.some(key => !Object.hasOwn(value, key)) || Object.keys(value).some(key => !required.includes(key) && !optional.includes(key))) throw invalid('The hook review has missing or unsupported fields.');
  return value;
}
// Swift String compares canonically equivalent strings by normalized UTF-8 order.
export const swiftStringCompare = (a, b) => Buffer.compare(Buffer.from(a.normalize('NFC')), Buffer.from(b.normalize('NFC')));
const uniqueStrings = values => Array.isArray(values) && values.length > 0 && values.length <= 1000 && values.every(text)
  && new Set(values.map(value => value.normalize('NFC'))).size === values.length;

/** Match RelayJSON.data(): Foundation JSONEncoder sortedKeys, withoutEscapingSlashes.
 * Hook wire keys are strict ASCII schemas. Unlike JSON.stringify, Foundation uses
 * scientific notation below 1e-4, pads short exponents, and preserves negative zero.
 * Cross-language vectors run the actual production Swift encoder and fingerprint.
 */
export function hookCanonicalJSON(value) {
  if (value === null) return 'null';
  if (typeof value === 'string' || typeof value === 'boolean') return JSON.stringify(value);
  if (typeof value === 'number') {
    if (!Number.isFinite(value)) throw invalid('Non-finite numbers are not hook JSON.');
    if (Object.is(value, -0)) return '-0';
    const magnitude = Math.abs(value);
    return magnitude && (magnitude < 1e-4 || magnitude >= 1e16)
      ? value.toExponential().replace(/e([+-])(\d+)$/, (_, sign, exponent) => 'e' + sign + exponent.padStart(2, '0')) : JSON.stringify(value);
  }
  if (Array.isArray(value)) return '[' + value.map(hookCanonicalJSON).join(',') + ']';
  if (value && typeof value === 'object') return '{' + Object.keys(value).sort(swiftStringCompare).map(key => JSON.stringify(key) + ':' + hookCanonicalJSON(value[key])).join(',') + '}';
  throw invalid('Unsupported hook JSON value.');
}

export function validateHookReview(value) {
  shape(value, requestKeys, ['remoteSessionId']);
  if (Buffer.byteLength(hookCanonicalJSON(value)) > LIMIT || value.kind !== 'workspaceHookReview' || value.warningCode !== 'workspace_hooks_execute_code') throw invalid('Malformed or oversized workspace hook review.');
  if (targetKeys.filter(key => key !== 'generation').some(key => !text(value[key])) || !digest(value.bundleDigest) || !integer(value.generation, 1)
    || !text(value.workspaceLabel) || Object.hasOwn(value, 'remoteSessionId') && !text(value.remoteSessionId)
    || !finite(value.createdAt) || !finite(value.deadlineAt) || value.deadlineAt < value.createdAt) throw invalid('Invalid hook review identity or deadline.');
  if (!Array.isArray(value.sourceFiles) || value.sourceFiles.length > 256 || !Array.isArray(value.items) || value.items.length > 1000) throw invalid('Too many hook review entries.');
  for (const file of value.sourceFiles) {
    shape(file, ['path', 'displayPath', 'editable']);
    if (!text(file.path) || !text(file.displayPath) || typeof file.editable !== 'boolean') throw invalid('Invalid hook source file.');
  }
  for (const item of value.items) {
    shape(item, ['reviewItemId', 'event', 'type', 'displayName', 'displayCommand', 'sourcePath', 'resolvedTimeoutMs', 'resolvedMaxOutputBytes', 'executionMode', 'configuredEnabled', 'editable', 'trustState'], ['matcher']);
    if (['reviewItemId', 'displayName', 'displayCommand', 'sourcePath'].some(key => !text(item[key]))
      || !['SessionStart', 'UserPromptSubmit', 'PreToolUse', 'PermissionRequest', 'PostToolUse', 'PostToolUseFailure', 'Stop'].includes(item.event)
      || !['command', 'process'].includes(item.type) || !['foreground', 'background'].includes(item.executionMode)
      || !['not_applicable', 'pending_trust', 'trusted_persistent', 'blocked_untrusted', 'blocked_policy', 'revoked', 'stale_digest'].includes(item.trustState)
      || !integer(item.resolvedTimeoutMs, 1) || !integer(item.resolvedMaxOutputBytes, 1) || typeof item.configuredEnabled !== 'boolean'
      || typeof item.editable !== 'boolean' || Object.hasOwn(item, 'matcher') && typeof item.matcher !== 'string') throw invalid('Invalid hook item.');
  }
  shape(value.summary, ['eventCount', 'hookCount', 'pendingCount']);
  if (Object.values(value.summary).some(number => !integer(number)) || value.summary.hookCount !== value.items.length
    || value.summary.eventCount !== new Set(value.items.map(item => item.event)).size
    || value.summary.pendingCount !== value.items.filter(item => pendingTrust.has(item.trustState)).length
    || new Set(value.items.map(item => item.reviewItemId.normalize('NFC'))).size !== value.items.length) throw invalid('Hook summary or unique item identities do not match.');
  return value;
}

export function hookOperation(action, body, request) {
  let operation, type;
  if (action === 'toggle') {
    if (!text(body.reviewItemId) || typeof body.enabled !== 'boolean') throw invalid('A hook toggle requires an exact item and explicit enabled value.');
    operation = { action: 'set_enabled', reviewItemIds: [body.reviewItemId], enabled: body.enabled }; type = 'toggleWorkspaceHookReviewItem';
  } else {
    if (!['respond', 'revoke'].includes(action) || !uniqueStrings(body.reviewItemIds)) throw invalid('Choose unique hook item IDs.', 'hook_review_selection_invalid');
    operation = { action: action === 'respond' ? 'trust_selected' : 'revoke_selected', reviewItemIds: [...body.reviewItemIds].sort(swiftStringCompare) };
    type = action === 'respond' ? 'respondWorkspaceHookReview' : 'revokeWorkspaceHookTrust';
  }
  const items = operation.reviewItemIds.map(id => request.items.find(item => item.reviewItemId === id));
  if (items.some(item => !item) || action === 'respond' && items.some(item => !pendingTrust.has(item.trustState))) throw invalid('The selected items do not await trust in this review.', 'hook_review_selection_invalid');
  if (action === 'toggle' && !items[0].editable) throw invalid('This hook configuration is not editable.', 'hook_review_item_read_only');
  const target = Object.fromEntries([...targetKeys, ...(request.remoteSessionId === undefined ? [] : ['remoteSessionId'])].map(key => [key, request[key]]));
  const payload = { ...target, ...(action === 'respond' ? { decision: { action: 'trust_selected', reviewItemIds: operation.reviewItemIds } }
    : action === 'revoke' ? { reviewItemIds: operation.reviewItemIds } : { reviewItemId: body.reviewItemId, enabled: body.enabled }) };
  return { operation, type, payload };
}
export const hookOperationFingerprint = (request, operation) => hash(hookCanonicalJSON({ request, operation }));

function currentReview(projection, sessionId) {
  if (!projection || projection.sessionId !== sessionId) throw invalid('Refresh this task before reviewing its hooks.', 'workspace_hooks_review_superseded', 409);
  const candidates = (projection.pendingInteractions ?? []).filter(item => item.kind === 'workspaceHookReview');
  if (candidates.length !== 1) throw invalid('The hook review is no longer current.', 'workspace_hooks_review_superseded', 409);
  const pending = candidates[0], request = validateHookReview(pending.payload);
  if (Object.hasOwn(pending, 'autoResolution') || pending.interactionId !== request.interactionId || request.sessionId !== sessionId) throw invalid('The host review identity does not match its task.', 'workspace_hooks_snapshot_mismatch', 409);
  return request;
}

function requireDisplayableReview(request) {
  // HTTP and SSE both sanitize their payloads. A changed display cannot carry
  // valid consent to the original command; keep it on the desktop instead.
  if (hookCanonicalJSON(sanitize(request)) !== hookCanonicalJSON(request)) throw invalid('This hook review contains sensitive content that cannot be displayed completely. Review it on the computer.', 'hook_review_redacted');
  return request;
}

export function hookInteractions(projection, sessionId) {
  const items = (projection?.pendingInteractions ?? []).filter(item => item.kind === 'workspaceHookReview');
  if (!items.length) return [];
  try {
    const review = requireDisplayableReview(currentReview(projection, sessionId));
    return [{ id: review.interactionId, sessionId, kind: 'workspaceHookReview', title: '审查工作区钩子', reason: '所选钩子的信任会持久保存。', hookReview: review }];
  } catch (error) {
    // Retain an honest return-to-computer card; never expose an actionable invalid payload.
    const redacted = error.code === 'hook_review_redacted';
    return items.filter(item => text(item.interactionId)).map(item => ({ id: item.interactionId, sessionId, kind: 'workspaceHookReview',
      title: redacted ? '钩子命令含有敏感内容' : '工作区钩子请求无法验证',
      reason: redacted ? '请回到电脑审查完整命令。' : '请回到电脑检查当前审查。', unsupportedReason: redacted ? 'hook_review_redacted' : 'hook_review_invalid' }));
  }
}

function parseAction(id, action, body) {
  const common = ['clientCommandId', 'request', 'confirmation'];
  if (action === 'request') {
    shape(body, ['clientCommandId', 'workspaceIdentity', 'bundleDigest'], ['remoteSessionId']);
    if (!text(body.workspaceIdentity) || !digest(body.bundleDigest) || Object.hasOwn(body, 'remoteSessionId') && !text(body.remoteSessionId)) throw invalid('Invalid workspace hook admission identity.');
    const payload = { sessionId: id, workspaceIdentity: body.workspaceIdentity, bundleDigest: body.bundleDigest, ...(body.remoteSessionId === undefined ? {} : { remoteSessionId: body.remoteSessionId }) };
    return { type: 'requestWorkspaceHookReview', payload, intent: { type: 'requestWorkspaceHookReview', payload } };
  }
  if (!['respond', 'toggle', 'revoke'].includes(action)) throw invalid('Unknown hook review action.');
  shape(body, [...common, ...(action === 'toggle' ? ['reviewItemId', 'enabled'] : ['reviewItemIds'])]);
  const request = validateHookReview(body.request);
  if (request.sessionId !== id) throw invalid('This review belongs to another task.', 'workspace_hooks_snapshot_mismatch', 409);
  const { type, payload, operation } = hookOperation(action, body, request);
  shape(body.confirmation, ['action', 'fingerprint', 'confirmedAt']);
  const confirmation = body.confirmation;
  if (confirmation.action !== operation.action || !digest(confirmation.fingerprint) || confirmation.fingerprint !== hookOperationFingerprint(request, operation)
    || !finite(confirmation.confirmedAt) || confirmation.confirmedAt >= request.deadlineAt) throw invalid('The explicit confirmation does not match this whole review and operation.', 'hook_review_confirmation_required');
  return { request, operation, type, payload, confirmation, intent: { request, operation } };
}

function checkCurrent(projection, id, parsed, now) {
  if (parsed.request) {
    const actual = requireDisplayableReview(currentReview(projection, id));
    if (actual.deadlineAt <= now || parsed.request.deadlineAt <= now) throw invalid('This workspace hook review expired.', 'hook_review_expired', 409);
    if (actual.reviewFlowId !== parsed.request.reviewFlowId || actual.generation !== parsed.request.generation || actual.interactionId !== parsed.request.interactionId) throw invalid('This workspace hook review has been replaced.', 'workspace_hooks_review_superseded', 409);
    if (hookCanonicalJSON(actual) !== hookCanonicalJSON(parsed.request)) throw invalid('The displayed hook review changed. Refresh before confirming.', 'workspace_hooks_snapshot_mismatch', 409);
    if (projection.workspaceHookAdmission?.workspaceIdentity && projection.workspaceHookAdmission.workspaceIdentity !== actual.workspaceIdentity
      || projection.workspaceHookAdmission?.bundleDigest && projection.workspaceHookAdmission.bundleDigest !== actual.bundleDigest) throw invalid('The workspace hook bundle changed.', 'workspace_hooks_bundle_changed', 409);
  } else {
    const admission = projection?.workspaceHookAdmission;
    let review; try { review = currentReview(projection, id); } catch {}
    if (projection?.sessionId !== id || (!admission && !review) || (admission?.workspaceIdentity ?? review?.workspaceIdentity) !== parsed.payload.workspaceIdentity
      || (admission?.bundleDigest ?? review?.bundleDigest) !== parsed.payload.bundleDigest
      || parsed.payload.remoteSessionId !== review?.remoteSessionId) throw invalid('Refresh the current workspace hook admission before requesting review.', 'workspace_hooks_snapshot_mismatch', 409);
  }
}

function validateAck(value, envelope) {
  if (!value || value.commandId !== envelope.commandId || !admitted.has(value.status) && !terminal.has(value.status)) throw new BridgeError(504, 'hook_review_uncertain', 'The host did not return the original hook command outcome.', true);
  return sanitize(value);
}
function ackResult(id, ack) {
  if (admitted.has(ack.status)) return { accepted: true, sessionId: id, acknowledgement: ack };
  throw new BridgeError(ack.status === 'failed' ? 422 : 409, ack.reasonCode || 'hook_review_rejected', ack.message || 'The host rejected this hook review operation.', false, { commandStatus: ack.status, commandId: ack.commandId });
}

export class HookReviewManager {
  constructor(service, { now = Date.now } = {}) { this.service = service; this.now = now; }
  pending(id) { return this.service.hostActivity.stale.has(id) ? [] : hookInteractions(this.service.hostActivity.projections.get(id), id); }
  finishAcknowledgement(id, acknowledgement) {
    const result = ackResult(id, acknowledgement);
    // Fresh, queried and cached ACKs all need the same read-only reconciliation.
    // Never resume a session solely to recover an already acknowledged result.
    const subscription = [...this.service.hostActivity.subscriptions].find(([, sessionId]) => sessionId === id)?.[0];
    if (subscription) this.service.hostActivity.recover(subscription, 'hookReviewAcknowledged');
    return result;
  }
  observe(id, after, before) {
    const previous = hookInteractions(before, id), next = hookInteractions(after, id);
    const changed = JSON.stringify(previous) !== JSON.stringify(next), admissionChanged = JSON.stringify(before?.workspaceHookAdmission ?? null) !== JSON.stringify(after.workspaceHookAdmission ?? null);
    if (!changed && !admissionChanged) return;
    for (const item of previous) if (!next.some(current => current.id === item.id)) this.service.events.publish('interaction.resolved', { interactionId: item.id }, id);
    for (const item of next) if (!previous.some(prior => JSON.stringify(prior) === JSON.stringify(item))) this.service.events.publish('interaction.requested', { interaction: item }, id);
    const record = this.service.registry.sessions[id];
    if (record) {
      if (next.length) record.status = 'waiting';
      record.updatedAt = iso(); this.service.persist(); this.service.events.publish('session.updated', { session: this.service.ownedDTO(record) }, id);
      if (previous.length && !next.length) this.service.refresh(id).catch(() => {});
    }
  }
  async perform(id, action, body) {
    const service = this.service;
    service.requireOwned(id);
    const parsed = parseAction(id, action, body), clientID = requireString(body.clientCommandId, 'clientCommandId', 128);
    const clientKey = hash(hookCanonicalJSON({ sessionId: id, clientCommandId: clientID })), intentHash = hash(hookCanonicalJSON(parsed.intent));
    return service.mutate('hook:' + id, async () => {
      const owner = service.requireOwned(id);
      let record = Object.values(service.registry.hookCommands).find(item => item.clientKeys.includes(clientKey));
      if (record && (record.intentHash !== intentHash || record.envelope.sessionId !== id)) throw invalid('This command ID was used for another hook operation.', 'hook_review_conflict', 409);
      if (!record) record = Object.values(service.registry.hookCommands).filter(item => item.envelope.sessionId === id && item.intentHash === intentHash
        // Opening a review has no immutable generation in its body. After a
        // definite ACK, a new explicit UUID must be able to open it again.
        && (!item.acknowledgement || action !== 'request' && admitted.has(item.acknowledgement.status))).sort((a, b) => Number(!!a.acknowledgement) - Number(!!b.acknowledgement) || a.envelope.issuedAt - b.envelope.issuedAt)[0];
      if (record && !record.clientKeys.includes(clientKey)) { record.clientKeys.push(clientKey); service.persist(); }
      if (record?.acknowledgement) return this.finishAcknowledgement(id, record.acknowledgement);
      if (record?.attempted) {
        // Query before any session resume. A restart may have replaced the old run.
        await service.protocol.start();
        const key = { sessionId: id, commandId: record.envelope.commandId };
        const query = await service.protocol.request('v4/commands/query', { commands: [key] });
        const result = query?.results?.find(item => item.key?.sessionId === id && item.key?.commandId === key.commandId)?.result;
        if (result && result !== 'unknown') {
          record.acknowledgement = validateAck(result, record.envelope); service.persist(); return this.finishAcknowledgement(id, record.acknowledgement);
        }
        if (result !== 'unknown' || !service.initialized.has(id)) throw new BridgeError(504, 'hook_review_uncertain', 'The original hook outcome is unknown. Reconcile this task before retrying the same command.', true);
      }
      if (owner.archived) throw invalid('Restore this task before changing its hooks.', 'session_archived', 409);
      await service.ensureInitialized(id);
      const projection = await service.hostActivity.ensure(id);
      // Metadata uses another lock; ownership or archive state may have changed
      // during either await. Recheck immediately before journal or stdio writes.
      if (service.requireOwned(id).archived) throw invalid('Restore this task before changing its hooks.', 'session_archived', 409);
      checkCurrent(projection, id, parsed, this.now());
      if (!record) {
        record = { clientKeys: [clientKey], intentHash, intent: structuredClone(parsed.intent), ...(parsed.confirmation ? { confirmation: structuredClone(parsed.confirmation) } : {}),
          envelope: { commandId: 'hook-' + clientKey, clientId: 'zcode-mobile-bridge', sessionId: id, type: parsed.type, payload: structuredClone(parsed.payload), issuedAt: this.now() }, attempted: false, createdAt: iso() };
        service.registry.hookCommands[record.envelope.commandId] = record; service.persist();
      }
      record.attempted = true; service.persist();
      let acknowledgement;
      try { acknowledgement = await service.protocol.request('v4/command', record.envelope, 60000); }
      catch { throw new BridgeError(504, 'hook_review_uncertain', 'The hook command was sent but its outcome is unconfirmed. Retry the same action to reconcile it.', true); }
      record.acknowledgement = validateAck(acknowledgement, record.envelope); service.persist();
      return this.finishAcknowledgement(id, record.acknowledgement);
    });
  }
}
