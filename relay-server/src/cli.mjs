import fs from 'node:fs';
import path from 'node:path';
import { parseArgs } from 'node:util';
import { RelayRegistry } from './registry.mjs';
import { createRelayServer, normalizedOrigin } from './server.mjs';

let registry; let server;
try {
  const { values, positionals } = parseArgs({ allowPositionals: true, options: {
    'state-dir': { type: 'string' }, port: { type: 'string', default: '18795' },
    origin: { type: 'string' }, prefix: { type: 'string', default: '/zcode' },
    mid: { type: 'string' }, out: { type: 'string' }, 'ttl-seconds': { type: 'string', default: '600' },
    'rotate-existing-pairing': { type: 'boolean', default: false }
  } });
  if (!['start', 'enroll'].includes(positionals[0]) || !values['state-dir'] || !values.origin) {
    throw new Error('Usage: node src/cli.mjs start|enroll --state-dir PRIVATE_DIR --origin https://host[:port] [--port 18795] [--mid DEVICE_MID --out PRIVATE_FILE]');
  }
  const origin = normalizedOrigin(values.origin);
  if (!/^\/[a-zA-Z0-9_-]+(?:\/[a-zA-Z0-9_-]+)*$/.test(values.prefix)) throw new Error('INVALID_PREFIX');
  registry = new RelayRegistry({ directory: values['state-dir'] });
  if (positionals[0] === 'enroll') {
    if (!values.mid || !values.out) throw new Error('ENROLL_REQUIRES_MID_AND_PRIVATE_OUTPUT_FILE');
    const output = path.resolve(values.out);
    const parent = fs.lstatSync(path.dirname(output));
    if (!parent.isDirectory() || parent.isSymbolicLink() || (parent.mode & 0o077) !== 0) throw new Error('OUTPUT_DIRECTORY_MUST_BE_PRIVATE');
    // Reserve the output first. Never grant a permit if its delivery target is invalid or existing.
    const fd = fs.openSync(output, 'wx', 0o600);
    try {
      const permit = registry.issueEnrollment(values.mid, Number(values['ttl-seconds']) * 1000,
        { rotate: values['rotate-existing-pairing'] });
      const wsURL = new URL(`${values.prefix}/ws`, origin); wsURL.protocol = 'wss:';
      wsURL.searchParams.set('enroll', permit.enrollmentToken);
      const config = { version: 1, ...permit,
        desktopEnvironment: { ZCODE_WEB_REMOTE_CONTROL_RELAY_WS_URL: wsURL.href,
          ZCODE_WEB_REMOTE_CONTROL_URL: new URL(`${values.prefix}/remote/v4`, origin).href } };
      fs.writeFileSync(fd, `${JSON.stringify(config, null, 2)}\n`); fs.fsyncSync(fd);
    } finally { fs.closeSync(fd); }
    registry.close(); registry = undefined;
    console.log(JSON.stringify({ enrollmentConfigWritten: output, secretPrinted: false }));
  } else {
    server = createRelayServer({ registry, publicOrigin: origin, prefix: values.prefix });
    const bound = await server.listen({ port: Number(values.port) });
    console.log(JSON.stringify({ pid: process.pid, ...bound, wsPath: server.wsPath,
      pairingPath: server.pairingPath, publicOrigin: origin, enrollment: 'closed_without_private_permit' }));
    let closing = false;
    const close = async () => {
      if (closing) return; closing = true;
      await server.close(); registry.close();
    };
    process.once('SIGINT', close); process.once('SIGTERM', close);
  }
} catch (error) {
  if (server) await server.close();
  registry?.close();
  // Error codes only: never dump request bodies, URLs, environment or native credential material.
  console.error(error?.code || (String(error?.message).startsWith('Usage:') ? error.message : 'RELAY_START_FAILED'));
  process.exitCode = 1;
}
