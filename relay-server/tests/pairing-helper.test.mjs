import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import { createPassHash } from '../src/auth.mjs';
import { normalizedOrigin } from '../src/server.mjs';

const script = fs.readFileSync(new URL('../web/pairing.js', import.meta.url), 'utf8');
const origin = 'https://relay.example.test:8443'; const hash = createPassHash('synthetic-only');
function run(href) {
  const nodes = Object.fromEntries(['status', 'payload', 'json', 'copy'].map((id) => [id, { style: {}, addEventListener() {} }]));
  const replaced = [];
  const context = vm.createContext({ URL, JSON, Error, atob, btoa,
    document: { body: { dataset: { origin, prefix: '/zcode' } }, getElementById: (id) => nodes[id] },
    location: { href }, history: { replaceState: (...args) => replaced.push(args) } });
  vm.runInContext(script, context, { timeout: 1000 });
  return { nodes, replaced };
}
function validURL() {
  const url = new URL('/zcode/remote/v4', origin);
  url.searchParams.set('sid', 'd_synthetic'); url.searchParams.set('hash', hash); url.searchParams.set('mid', 'synthetic-mid');
  return url;
}

test('pairing helper exports exactly typed same-origin JSON and removes browser URL credentials', () => {
  const url = validURL(); const result = run(url.href);
  assert.deepEqual(JSON.parse(result.nodes.json.value), { transport: 'zcode-relay', url: url.href, relayURL: 'wss://relay.example.test:8443/zcode/ws' });
  assert.deepEqual(result.replaced, [[null, '', '/zcode/remote/v4']]);
  assert.equal(result.nodes.payload.style.display, 'block');
  assert.equal(script.includes('fetch('), false); assert.equal(script.includes('localStorage.'), false);
});

test('official origin, alternate host/port, fragments, URL credentials and enrollment query fail closed', () => {
  const variants = [
    (url) => { url.hostname = 'zcode.z.ai'; }, (url) => { url.hostname = 'evil.test'; },
    (url) => { url.port = '8444'; }, (url) => { url.protocol = 'http:'; },
    (url) => { url.hash = 'secret'; }, (url) => { url.username = 'user'; },
    (url) => { url.searchParams.set('enroll', 'enrollment-is-not-a-phone-credential'); },
    (url) => { url.searchParams.append('sid', 'duplicate'); }
  ];
  for (const change of variants) {
    const url = validURL(); change(url); const result = run(url.href);
    assert.equal(result.nodes.json.value, undefined); assert.equal(result.replaced.length, 1);
  }
});

test('server origin normalization treats explicit default TLS port equally, rejecting unsafe or official origins', () => {
  assert.equal(normalizedOrigin('https://relay.test:443'), 'https://relay.test');
  for (const url of ['http://relay.test', 'https://relay.test/path', 'https://relay.test/?token=x',
    'https://user@relay.test', 'https://zcode.z.ai', 'https://zcode.chatglm.site']) assert.throws(() => normalizedOrigin(url));
});
