import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { lstat } from 'node:fs/promises';
import { join } from 'node:path';
import { readWorkspaceFile, restrictedPath, workspacePath } from './files.mjs';

const exec = promisify(execFile);
async function git(cwd, args) {
  return (await exec('/usr/bin/git', ['-c', 'core.fsmonitor=false', ...args], { cwd, encoding: 'utf8', timeout: 8000, maxBuffer: 2 * 1024 * 1024, env: { ...process.env, GIT_OPTIONAL_LOCKS: '0', GIT_PAGER: 'cat' } })).stdout;
}
export async function workspaceChanges(cwd) {
  try { await git(cwd, ['rev-parse', '--show-toplevel']); }
  catch { return { files: [], totals: { additions: 0, deletions: 0 }, source: 'workspace', truncated: false, unavailableReason: 'This workspace is not a Git repository.' }; }
  let base = [];
  try { await git(cwd, ['rev-parse', '--verify', 'HEAD']); base = ['HEAD']; } catch {}
  const diffArgs = ['diff', '--relative', '--no-renames', '--no-ext-diff', '--no-textconv'];
  const numstat = await git(cwd, [...diffArgs, '--numstat', '-z', ...base, '--', '.']);
  const entries = numstat.split('\0').filter(Boolean).map(line => {
    const match = line.match(/^([^\t]+)\t([^\t]+)\t([\s\S]+)$/);
    if (!match) return null;
    return { path: match[3], status: 'modified', additions: Number(match[1]) || 0, deletions: Number(match[2]) || 0, binary: match[1] === '-' };
  }).filter(Boolean);
  const untracked = (await git(cwd, ['ls-files', '--others', '--exclude-standard', '-z', '--', '.'])).split('\0').filter(Boolean);
  const visible = [...entries, ...untracked.map(path => ({ path, status: 'added', additions: 0, deletions: 0 }))].filter(entry => !restrictedPath(entry.path));
  const files = [];
  for (const entry of visible.slice(0, 100)) {
    const stat = await lstat(join(cwd, entry.path)).catch(() => null);
    if (stat?.isSymbolicLink()) continue;
    if (stat) { try { await workspacePath(cwd, entry.path); } catch { continue; } }
    if (entry.status !== 'added') entry.status = stat ? 'modified' : 'deleted';
    let diff = '', truncated = false;
    if (entry.status === 'added') {
      try {
        if (!stat?.isFile() || stat.size > 128 * 1024) throw new Error();
        const { content } = await readWorkspaceFile(cwd, entry.path), lines = content.split('\n');
        if (lines.at(-1) === '') lines.pop(); entry.additions = lines.length;
        diff = `diff --git a/${entry.path} b/${entry.path}\nnew file mode 100644\n--- /dev/null\n+++ b/${entry.path}\n@@ -0,0 +1,${lines.length} @@\n` + lines.map(line => '+' + line).join('\n');
      } catch { truncated = true; diff = 'Preview unavailable for this file.'; }
    } else diff = await git(cwd, [...diffArgs, ...base, '--', entry.path]);
    if (diff.length > 128000) { diff = diff.slice(0, 128000); truncated = true; }
    files.push({ ...entry, diff, truncated });
  }
  return { files, totals: files.reduce((sum, file) => ({ additions: sum.additions + file.additions, deletions: sum.deletions + file.deletions }), { additions: 0, deletions: 0 }), source: 'workspace', truncated: visible.length > 100 || files.some(file => file.truncated) };
}
