import { mkdirSync, readFileSync, unlinkSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';

// One owner per isolated store, even when two listeners choose different ports.
export function acquireRuntimeLock(runtimeDir) {
  mkdirSync(runtimeDir, { recursive: true, mode: 0o700 });
  const path = join(runtimeDir, 'runtime.lock'), id = randomUUID();
  for (let attempt = 0; attempt < 3; attempt++) {
    try {
      writeFileSync(path, JSON.stringify({ pid: process.pid, id, createdAt: new Date().toISOString() }) + '\n', { mode: 0o600, flag: 'wx' });
      return () => { try { if (JSON.parse(readFileSync(path, 'utf8')).id === id) unlinkSync(path); } catch {} };
    } catch (error) {
      if (error.code !== 'EEXIST') throw error;
      let current, raw;
      try { raw = readFileSync(path, 'utf8'); current = JSON.parse(raw); } catch { throw new Error('The runtime lock cannot be read. Check that no other bridge owns this runtime directory.'); }
      if (!Number.isSafeInteger(current.pid) || current.pid < 1) throw new Error('The runtime lock has no valid owner. Check the runtime directory before starting.');
      let alive = true;
      try { process.kill(current.pid, 0); } catch (probe) { if (probe.code === 'ESRCH') alive = false; }
      if (alive) throw new Error(`A bridge already owns this runtime directory (PID ${current.pid}).`);
      try { if (readFileSync(path, 'utf8') === raw) unlinkSync(path); } catch (unlink) { if (unlink.code !== 'ENOENT') throw unlink; }
    }
  }
  throw new Error('Another bridge acquired the runtime directory while starting.');
}
