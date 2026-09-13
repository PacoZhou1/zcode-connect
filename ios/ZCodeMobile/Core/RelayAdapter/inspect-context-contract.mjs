import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';

const hash = data => createHash('sha256').update(data).digest('hex');
const cli = fs.readFileSync('/Applications/ZCode.app/Contents/Resources/glm/zcode.cjs', 'utf8');
const asar = fs.readFileSync('/Applications/ZCode.app/Contents/Resources/app.asar');
assert.equal(hash(cli), 'e9f1868c0fdb863537ed910ee3828b9be96b8c2fd805473f63b439e1113266b8');
assert.equal(hash(asar), '0317216fc08f374162e5cc1b779bae5f94ef70c5eaa585cb71b8ffedc537b668');
const header = JSON.parse(asar.subarray(16, 16 + asar.readUInt32LE(12)));
function source(path) {
  let entry = header;
  for (const part of path.split('/')) entry = entry.files[part];
  const offset = 8 + asar.readUInt32LE(4) + Number(entry.offset);
  return asar.subarray(offset, offset + entry.size).toString();
}
const rendererPath = 'out/renderer/assets/styles-DyAcaLKy.js', renderer = source(rendererPath);
const anchors = [];
function extract(label, text, first, end) {
  const offset = text.indexOf(first), finish = text.indexOf(end, offset + first.length);
  assert.ok(offset >= 0 && finish > offset, label);
  const snippet = text.slice(offset, finish);
  anchors.push({ label, source: text === cli ? 'installed CLI' : rendererPath, offset, sha256: hash(snippet), snippet });
  return snippet;
}
extract('character breakdown schema and legacy runtime counters', cli, 'Rbn=f.enum(', 'tCt=f.object(');
extract('projection context window is separate from cumulative tokens', cli, 'ije=f.object(', ',twn=');
extract('compact marker schema', cli, 'Hbn=f.union(', ',f.object({type:f.literal("forkNotice")');
extract('model-complete current context versus cumulative totals', cli, 'onModelComplete(t)', 'onCompactLifecycle(t)');
const status = extract('official compact status mapping', cli, 'function I0n(', 'function e1t(');
const lifecycle = extract('official compact projection deltas', cli, 'onCompactLifecycle(t)', 'onTargetChanged(t)');
const order = extract('desktop breakdown order', renderer, 'HGe={', ';function UGe(');
const shares = extract('desktop percentages are character shares', renderer, 'function UGe(', 'function WGe(');
const context = vm.createContext({});
vm.runInContext(`var ${order};${shares};${status};this.shares=UGe;this.Projector=class{${lifecycle}};`, context, { timeout: 500 });
const breakdown = [
  { source: 'messages', chars: 4000 }, { source: 'messages', chars: 1000 },
  { source: 'system_prompt', chars: 2000 }, { source: 'meta_user_context', chars: 1000 },
  { source: 'skills', chars: 500 }, { source: 'tool_prompt', chars: 500 },
  { source: 'system_tool_schemas', chars: 700 }, { source: 'mcp_tool_schemas', chars: 300 },
];
const desktopShares = JSON.parse(JSON.stringify(context.shares(breakdown)));
assert.equal(desktopShares[0].chars, 5000); assert.equal(desktopShares[0].percent, 0.5);
assert.equal(desktopShares.length, 7);
const initial = {
  protocolVersion: 1, sessionId: 'session-test', logEpoch: 'epoch-one', seq: 10, revision: 1,
  meta: { title: 'Synthetic context fixture' }, config: { provider: 'host-provider', model: 'host-model', thought: 'max', mode: 'build' },
  control: { phase: 'running', canStop: false, stopState: 'idle', stopTargetKind: 'unknown', activeWorks: [] },
  pendingInteractions: [], subagents: { revision: 0, childSessionIds: [], running: [], endedTotal: 0 }, goal: null,
  rows: { window: [{ rowId: 1, kind: 'assistantText', text: 'Synthetic unchanged answer' }], firstRowId: 1, totalCount: 1 },
  usage: { contextWindow: { usedTokens: 150000, maxTokens: 200000, autoCompactThresholdTokens: 160000, breakdown },
    cumulative: { inputTokens: 1500000, outputTokens: 500000, cacheReadTokens: 900000, cacheWriteTokens: 100000 } },
};
const projector = new context.Projector();
Object.assign(projector, {
  snapshot: structuredClone(initial), compactMarkerRowIdByOperationId: new Map(), entityIdByRowId: new Map(), editTargetByEntityId: new Map(),
  contextWindowState: { usedTokens: 150000, maxTokens: 200000 }, nextRowID: 2,
  findRow(id) { return this.snapshot.rows.window.find(row => row.rowId === id); },
  rowIdForMessageId() { return null; }, turnIdOf() { return 'synthetic-turn'; }, ms() { return 1700000000000; },
  rowBase(_, turnId, entityId) { return { rowId: this.nextRowID++, turnId, entityId, createdAt: 1700000000000, createdAtSeq: 11 }; },
  controlPatch(patch) { return { control: { ...this.snapshot.control, ...patch } }; },
});
function apply(deltas) {
  for (const delta of deltas) {
    if (delta.op === 'row.appended') { projector.snapshot.rows.window.push(delta.row); projector.snapshot.rows.totalCount++; }
    else if (delta.op === 'row.upserted') {
      const index = projector.snapshot.rows.window.findIndex(row => row.rowId === delta.row.rowId); assert.ok(index >= 0); projector.snapshot.rows.window[index] = delta.row;
    } else if (delta.op === 'state.updated') Object.assign(projector.snapshot, delta.patch);
    else assert.fail('Unexpected original compact delta');
  }
}
function event(status, extra = {}) {
  return { payload: { operationId: 'synthetic-auto-compact', trigger: 'auto', status, preCompactTokenCount: 150000, ...extra } };
}
const startDeltas = JSON.parse(JSON.stringify(projector.onCompactLifecycle(event('started')))); apply(startDeltas);
assert.equal(projector.snapshot.control.activeWorks[0].kind, 'compact');
assert.equal(projector.snapshot.rows.window.at(-1).marker.status, 'running');
const completedDeltas = JSON.parse(JSON.stringify(projector.onCompactLifecycle(event('completed', { postCompactTokenCount: 45000, truePostCompactTokenCount: 40000 })))); apply(completedDeltas);
assert.equal(projector.snapshot.control.activeWorks.length, 0);
assert.equal(projector.snapshot.rows.window.at(-1).marker.status, 'success');
assert.equal(projector.snapshot.usage.contextWindow.usedTokens, 40000);
assert.equal(projector.snapshot.usage.contextWindow.breakdown, undefined);
assert.equal(projector.snapshot.usage.cumulative.inputTokens, 1500000);
const statusVectors = ['started', 'retrying', 'completed', 'skipped', 'interrupted', 'failed'].map(input => ({ input, status: context.I0n(input) }));
const logical = (deltas, from, to) => ({ topic: 'conversation/session-test', subscriptionId: 'subscription-one', fromSeq: from, toSeq: to, sentAt: 1700000000000, payload: { kind: 'deltas', deltas } });
const output = {
  verifiedAt: new Date().toISOString(), passed: true, sources: { cliSHA256: hash(cli), asarSHA256: hash(asar), rendererPath, rendererSHA256: hash(renderer) }, anchors,
  desktopShares, statusVectors, fixture: { initialProjection: initial, start: logical(startDeltas, 10, 11), completed: logical(completedDeltas, 11, 12) },
  boundary: 'Only the extracted desktop share calculator and CLI compact projection method ran against memory fixtures. No compact operation, CLI process, credential, task, model, permission, hook, network or database action.',
};
assert.ok(process.argv[2], 'Pass an evidence JSON destination');
fs.writeFileSync(process.argv[2], JSON.stringify(output, null, 2) + '\n');
console.log(JSON.stringify({ passed: true, anchors: anchors.length, desktopCategories: desktopShares.length, lifecycleFrames: 2, statusVectors: statusVectors.length }));
