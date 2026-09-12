import { DatabaseSync } from 'node:sqlite';
import { existsSync } from 'node:fs';
import { basename, join } from 'node:path';
import { hash, iso, projectId, readJSON } from './util.mjs';
import { TranscriptPages, MAX_TRANSCRIPT_ROWS, MAX_TRANSCRIPT_BYTES, historyLimit } from './transcript-pages.mjs';

function dbRead(path, callback, fallback) {
  if (!existsSync(path)) return fallback;
  const db = new DatabaseSync(path, { readOnly: true });
  try { return callback(db); } finally { db.close(); }
}
const parse = text => { try { return JSON.parse(text); } catch { return {}; } };

// Provider role alone does not describe transcript visibility. The host records
// goal pause/resume reminders as role=user while explicitly hiding them from UI.
// Do not infer visibility from text, synthetic origin, or executionKind: genuine
// /goal input is a visible real-user message in a controlOnly turn.
function visibleInTranscript(value) {
  const semantics = value?.semantics ?? value?.metadata?.semantics;
  return semantics?.uiVisibility !== 'hidden' && semantics?.transcriptVisibility !== 'hidden'
    && value?.visibility !== 'model-only' && value?.metadata?.visibility !== 'model-only';
}

export function normalizeMessages(rows) {
  return rows.map((row, index) => {
    const info = row.info ?? row;
    if (!visibleInTranscript(info) || !visibleInTranscript(row)) return undefined;
    const parts = (row.parts ?? []).filter(visibleInTranscript);
    const text = parts.filter(p => p.type === 'text').map(p => p.text ?? '').join('\n');
    const tools = parts.filter(p => p.type === 'tool').map(p => ({
      id: p.callID ?? p.callId ?? p.id, name: p.tool ?? p.name ?? 'Tool',
      status: p.state?.status ?? p.status ?? 'completed', input: p.state?.input ?? p.input,
      output: typeof p.state?.output === 'string' ? p.state.output : typeof p.state?.error === 'string' ? p.state.error : typeof p.output === 'string' ? p.output : undefined,
    }));
    const reasoning = parts.filter(p => p.type === 'reasoning').map(p => p.text ?? '').join('\n');
    const attachments = parts.filter(p => p.type === 'file').map(p => ({ id: p.partId ?? p.id, fileName: p.filename ?? 'Attachment', mimeType: p.mime, ...(p.url?.startsWith('data:image/') ? { previewURL: p.url } : {}) }));
    // session/read uses messageId; the persisted message store and session/messages use id.
    const id = info.messageId ?? info.id ?? `fallback_${hash(JSON.stringify([info.role, info.time?.created ?? info.time_created, index])).slice(0, 24)}`;
    return { id: String(id), role: ['user', 'assistant', 'system', 'tool'].includes(info.role) ? info.role : 'system',
      text, createdAt: iso(info.time?.created ?? info.time_created),
      isStreaming: info.role === 'assistant' && !info.time?.completed && !info.finish,
      ...(tools.length ? { toolCalls: tools } : {}), ...(reasoning ? { reasoning } : {}), ...(attachments.length ? { attachments } : {}) };
  }).filter(row => row && (row.text || row.toolCalls?.length || row.reasoning || row.attachments?.length));
}

export class HistoryReader {
  constructor(zcodeRoot) {
    this.zcodeRoot = zcodeRoot;
    this.sessionDb = join(zcodeRoot, 'cli/db/db.sqlite');
    this.taskDb = join(zcodeRoot, 'v2/tasks-index.sqlite');
    this.transcripts = new TranscriptPages();
  }
  sessions(limit = 200, onlyID) {
    const metadata = dbRead(this.taskDb, db => new Map(db.prepare('SELECT task_id,title,task_status,model,mode,archived,deleted,unread_at FROM tasks').all().map(r => [r.task_id, r])), new Map());
    return dbRead(this.sessionDb, db => db.prepare("SELECT id,title,path,directory,time_created,time_updated,summary_additions,summary_deletions FROM session WHERE parent_id IS NULL AND time_archived IS NULL AND task_type = 'interactive'" + (onlyID ? ' AND id = ?' : '') + ' ORDER BY time_updated DESC,id DESC LIMIT ?').all(...(onlyID ? [onlyID, limit] : [limit])).flatMap(row => {
      const meta = metadata.get(row.id);
      if (meta?.archived || meta?.deleted) return [];
      const path = row.path || row.directory;
      return [{ id: row.id, title: meta?.title || row.title || 'Untitled task', projectId: projectId(path), projectName: basename(path),
        status: ['running', 'waiting', 'completed', 'error'].includes(meta?.task_status) ? meta.task_status : 'idle',
        statusSource: 'persisted', createdAt: iso(row.time_created), updatedAt: iso(row.time_updated), source: 'desktop',
        mode: meta?.mode ?? 'build', ...(meta?.model ? { model: meta.model } : {}), workspacePath: path,
        unread: typeof meta?.unread_at === 'number', unreadAt: meta?.unread_at ?? null, unreadScope: 'desktop',
        capabilities: { read: true, send: false, stop: false, approve: false, changes: true, markUnread: false } }];
    }), []);
  }
  session(id) { return this.sessions(1, id)[0]; }
  sessionIndex(limit = 5000) {
    const rawCount = dbRead(this.sessionDb, db => db.prepare("SELECT COUNT(*) AS count FROM session WHERE parent_id IS NULL AND time_archived IS NULL AND task_type = 'interactive'").get().count, 0);
    const sessions = this.sessions(limit + 1);
    return { sessions: sessions.slice(0, limit), truncated: rawCount > limit || sessions.length > limit };
  }
  messages(id, limit = 500) {
    return dbRead(this.sessionDb, db => {
      const rows = db.prepare('SELECT id,data,time_created FROM message WHERE session_id = ? ORDER BY sequence ASC,time_created ASC LIMIT ?').all(id, limit);
      const partQuery = db.prepare('SELECT id,data FROM part WHERE message_id = ? ORDER BY sequence ASC,time_created ASC');
      return normalizeMessages(rows.map(row => ({ info: { ...parse(row.data), id: row.id, time_created: row.time_created }, parts: partQuery.all(row.id).map(p => ({ ...parse(p.data), id: p.id })) }))).map(m => ({ ...m, isStreaming: false }));
    }, []);
  }
  transcript(id, options = {}, liveRows = []) {
    const live = new Map(liveRows.map(row => {
      const info = row.info ?? row;
      return [info.messageId ?? info.id, row];
    }).filter(([key]) => typeof key === 'string' && key));
    const read = db => {
      // One read transaction keeps the index, messages and parts consistent while
      // the host continues to append. This connection is opened read-only.
      db?.exec('BEGIN');
      try {
        const count = db?.prepare('SELECT COUNT(*) AS count FROM message WHERE session_id = ?').get(id).count ?? 0;
        if (count > MAX_TRANSCRIPT_ROWS) throw historyLimit('The conversation exceeds the safely indexed history limit.', { maxRows: MAX_TRANSCRIPT_ROWS, totalRowCount: count });
        const stored = db?.prepare('SELECT id FROM message WHERE session_id = ? ORDER BY sequence ASC,time_created ASC,id ASC').all(id).map(row => row.id) ?? [];
        const known = new Set(stored), ids = [...stored, ...[...live.keys()].filter(key => !known.has(key))];
        const infoQuery = db?.prepare('SELECT id,data,time_created FROM message WHERE session_id = ? AND id = ?');
        const partQuery = db?.prepare('SELECT id,data FROM part WHERE session_id = ? AND message_id = ? ORDER BY sequence ASC,time_created ASC,id ASC');
        const sizeQuery = db?.prepare('SELECT COALESCE((SELECT length(CAST(data AS BLOB)) FROM message WHERE session_id = ? AND id = ?),0) + COALESCE((SELECT SUM(length(CAST(data AS BLOB))) FROM part WHERE session_id = ? AND message_id = ?),0) AS bytes');
        return this.transcripts.page(id, ids, selected => {
          let bytes = 0;
          return selected.flatMap(key => {
            const current = live.get(key);
            bytes += current ? Buffer.byteLength(JSON.stringify(current)) : sizeQuery.get(id, key, id, key).bytes;
            if (bytes > MAX_TRANSCRIPT_BYTES) throw historyLimit('The loaded history exceeds the safe response byte limit.', { maxBytes: MAX_TRANSCRIPT_BYTES, totalRowCount: ids.length });
            if (current) return normalizeMessages([current]);
            const row = infoQuery.get(id, key);
            const raw = { info: { ...parse(row.data), id: row.id, time_created: row.time_created }, parts: partQuery.all(id, key).map(part => ({ ...parse(part.data), id: part.id })) };
            return normalizeMessages([raw]).map(message => ({ ...message, isStreaming: false }));
          });
        }, options);
      } finally { db?.exec('ROLLBACK'); }
    };
    if (!existsSync(this.sessionDb)) return read();
    return dbRead(this.sessionDb, read);
  }
  latestModel(path) {
    return dbRead(this.sessionDb, db => {
      const row = db.prepare("SELECT e.data FROM session_entry e JOIN session s ON s.id=e.session_id WHERE e.type='runtime/model_selection' ORDER BY CASE WHEN s.path = ? OR s.directory = ? THEN 0 ELSE 1 END,e.time_updated DESC LIMIT 1").get(path, path);
      return row ? parse(row.data) : undefined;
    }, undefined);
  }
  projects() {
    const projects = new Map();
    for (const session of this.sessions(1000)) {
      const path = session.workspacePath, id = projectId(path);
      const existing = projects.get(id);
      projects.set(id, { id, name: basename(path), path, sessionCount: (existing?.sessionCount ?? 0) + 1 });
    }
    const recent = readJSON(join(this.zcodeRoot, 'v2/setting.json')).recentProjects ?? [];
    for (const entry of recent) {
      const path = typeof entry === 'string' ? entry : entry.path ?? entry.workspacePath;
      if (!path || !existsSync(path)) continue;
      const id = projectId(path);
      if (!projects.has(id)) projects.set(id, { id, name: basename(path), path, sessionCount: 0 });
    }
    return [...projects.values()];
  }
}
