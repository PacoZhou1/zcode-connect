import fs from 'node:fs';
import crypto from 'node:crypto';
import vm from 'node:vm';
import assert from 'node:assert/strict';

// Installed source only. No package import, database handle, app-server or network.
const cliPath = '/Applications/ZCode.app/Contents/Resources/glm/zcode.cjs';
const asarPath = '/Applications/ZCode.app/Contents/Resources/app.asar';
const cli = fs.readFileSync(cliPath, 'utf8'), archive = fs.readFileSync(asarPath);
const hash = data => crypto.createHash('sha256').update(data).digest('hex');
assert.equal(hash(cli), 'e9f1868c0fdb863537ed910ee3828b9be96b8c2fd805473f63b439e1113266b8');
assert.equal(hash(archive), '0317216fc08f374162e5cc1b779bae5f94ef70c5eaa585cb71b8ffedc537b668');
const header = JSON.parse(archive.subarray(16, 16 + archive.readUInt32LE(12)));
const entry = header.files.out.files.host.files['index.js'];
const offset = 8 + archive.readUInt32LE(4) + Number(entry.offset);
const host = archive.subarray(offset, offset + entry.size).toString('utf8');
assert.equal(hash(host), '30911a90dadc5c384959d00d95ccc70c8cf38c74a9cb99c3168b0897d046d215');
const anchors = [];
function anchor(label, source, start, end, required) {
  const index = source.indexOf(start); assert.ok(index >= 0, label + ' start');
  const finish = source.indexOf(end, index + start.length); assert.ok(finish > index, label + ' end');
  const body = source.slice(index, finish);
  for (const value of required) assert.ok(body.includes(value), label + ': ' + value);
  anchors.push({ label, source: source === cli ? 'installed CLI' : 'installed host', offset: index, length: body.length, sha256: hash(body), matches: required.map(literal => ({ literal, offset: index + body.indexOf(literal) })) });
  return body;
}
const rootSQL = anchor('ordinary sessions exclude children', cli, 'function q6t(', 'function V6t(', ['t.roots&&r.push("parent_id is null")']);
anchor('session list forces roots', cli, 'async function qpn(', 'async function c3e(', ['roots:!0']);
anchor('parent-scoped persisted child directory', cli, 'async function c3e(', 'async function Dwt(', ['getSession(n.sessionId)', 'xpn(s,u,l)', 'v.taskType!=="subagent_child"', 'ended:{total:h.ended.length,items:_.items']);
anchor('original child title and outcome projection', cli, 'function bpn(', 'function tLi(', ['title:n.title', 'summary:n.summary??u.summary', 'endedAt:']);
anchor('scoped directory service forwarding', host, 'async listSessionSubagents(m)', 'async getAppUsageStats(m)', ['sessionId:m.sessionId', 'endedCursor:m.endedCursor', 'endedLimit:m.endedLimit??20']);
const resume = anchor('real runtime resume restores persisted child type before hooks', cli, 'async function y7r(', 'async function wdi(', ['this.config.taskType=n.taskType', 'this.config.mode=k', 'this.createEvent(V.SessionResumed', 'this.runSessionStartHooks("resume"']);
assert.ok(resume.indexOf('this.config.taskType=n.taskType') < resume.indexOf('this.runSessionStartHooks("resume"'));
anchor('original snapshot retains child ancestry and workspace', cli, 'function fse(', 'function qMe(', ['parentSessionId:e.session?.parentID', 'sessionKind:e.session?.taskType', 'workspace:e.workspace']);
anchor('goal command schema', cli, 'sendGoalCommand:f.object({text:f.string()', 'stop:f.object(', ['displayText:f.string().optional()', 'heldQueueDisposition']);
anchor('goal execution sets or replaces target then continues', cli, 'async function Bse(', 'function efn(', ['t.app.readTarget()', 't.app.setTarget(', 'status:"active"', 'reason:n?"goal_replaced":"goal_set"']);

// Only the original SQL builder runs, with a fake prepare/all implementation.
// The VM has no require, filesystem, network, or real database object.
let query;
const context = vm.createContext({ C4n: () => [], tUe: value => value, capture: (sql, args) => { query = { sql, args: Array.from(args) }; } });
vm.runInContext(rootSQL + '; q6t({prepare(sql){return {all(...args){capture(sql,args);return [];}}}}, {directory:"/synthetic-workspace",roots:true,includeArchived:true,limit:10000});', context, { timeout: 500 });
assert.match(query.sql, /parent_id is null/);
assert.deepEqual(query.args, ['/synthetic-workspace', 10000]);
const evidence = { verifiedAt: new Date().toISOString(), passed: true, sourcePaths: { cliPath, asarPath, hostEntry: 'out/host/index.js' }, sourceHashes: { cli: hash(cli), asar: hash(archive), host: hash(host) }, anchors, pureRootListProbe: query, boundary: 'Source inspection and one extracted pure SQL builder with a fake database. No database was opened, no cold runtime restored, no hook executed, no command submitted, no network or credential access.' };
fs.writeFileSync(process.argv[2], JSON.stringify(evidence, null, 2) + '\n');
console.log(JSON.stringify({ passed: true, anchors: anchors.length, originalPureFunctionProbes: 1, output: process.argv[2] }));
