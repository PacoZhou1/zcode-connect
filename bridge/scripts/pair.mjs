import { readFileSync } from 'node:fs';
import { dirname, resolve, join } from 'node:path';
import { fileURLToPath } from 'node:url';
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const path = join(process.env.ZCODE_MOBILE_RUNTIME_DIR || join(root, '.runtime'), 'pairing-token');
if (!process.stdout.isTTY && !process.argv.includes('--allow-pipe')) {
  console.error('Pairing token is only displayed in an interactive terminal. Use --allow-pipe for an explicit local handoff.'); process.exitCode = 1;
} else {
  console.log('Server: http://127.0.0.1:18789'); console.log('Pairing token: ' + readFileSync(path, 'utf8').trim());
}
