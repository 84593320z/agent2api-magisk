#!/usr/bin/env node
/** Execute the real discover.ts with controlled HTTP responses.
 * No npm packages, generated bundle, network access or APK build are required.
 * Node >=22.13 (node:module stripTypeScriptTypes) is required.
 */
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import assert from 'node:assert/strict';
import { fileURLToPath } from 'node:url';
import { stripTypeScriptTypes } from 'node:module';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const sourcePath = path.join(root, 'apk-mod/src/lib/discover.ts');
const source = fs.readFileSync(sourcePath, 'utf8');
const withoutImport = source.replace(/^import \{ normalizeBase \} from '\.\/servers'\r?\n/m, '');
assert.notEqual(withoutImport, source, 'the real servers import must be isolated');
const discoverJs = stripTypeScriptTypes(withoutImport.replace(/^export /gm, ''), { mode: 'strip' });

function harness(services = {}) {
  const calls = [];
  const context = vm.createContext({
    AbortController,
    setTimeout,
    clearTimeout,
    // Discovery supplies only host:port candidates; server normalization is outside this unit.
    normalizeBase: value => `http://${value}`,
    fetch: async (url, options) => {
      calls.push({ url, options });
      const parsed = new URL(url);
      const service = services[Number(parsed.port)] || {};
      if (parsed.pathname === '/health') {
        if (service.healthError) throw new Error(service.healthError);
        return { ok: true, json: async () => service.health ?? { status: 'ok' } };
      }
      if (parsed.pathname === '/api/panel/status') {
        if (service.panelError) throw new Error(service.panelError);
        return { ok: true, json: async () => service.panel ?? { success: true, data: {} } };
      }
      throw new Error('unexpected request path: ' + parsed.pathname);
    },
  });
  vm.runInContext(discoverJs + '\nthis.discoverLocalGateways = discoverLocalGateways;', context);
  return { discover: context.discoverLocalGateways, calls };
}

const ports = found => Array.from(found, item => Number(new URL(item.base).port));
const pathsFor = (calls, port) => calls
  .filter(call => Number(new URL(call.url).port) === port)
  .map(call => new URL(call.url).pathname);

const results = [];
async function test(name, fn) {
  let timer;
  try {
    await Promise.race([
      fn(),
      new Promise((_, reject) => { timer = setTimeout(() => reject(new Error('case exceeded 2000ms')), 2000); }),
    ]);
    results.push({ name, pass: true });
    console.log('ok   ' + name);
  } catch (error) {
    results.push({ name, pass: false, error: error.stack });
    console.error('FAIL ' + name + '\n' + error.stack);
  } finally {
    clearTimeout(timer);
  }
}

await test('multiple gateways keep default port 3065 first', async () => {
  const h = harness({
    3060: { health: { status: 'ok', transport: 'http', version: '3.5.0-beta.1' } },
    3065: { health: { status: 'ok', authRequired: false, version: '3.5.0-beta.1' } },
    3070: { health: { status: 'ok', defaultModel: 'model-a' } },
  });
  const found = await h.discover(50);
  assert.deepEqual(ports(found), [3065, 3060, 3070]);
});

await test('all non-default gateways remain in numeric port order', async () => {
  const h = harness({
    3061: { health: { status: 'ok', transport: 'http' } },
    3060: { health: { status: 'ok', transport: 'http' } },
    3079: { health: { status: 'ok', transport: 'http' } },
    3064: { health: { status: 'ok', transport: 'http' } },
    3072: { health: { status: 'ok', transport: 'http' } },
  });
  const found = await h.discover(50);
  assert.deepEqual(ports(found), [3060, 3061, 3064, 3072, 3079]);
});

await test('lookalike health and non-boolean panel payloads are rejected', async () => {
  const h = harness({
    3060: {
      health: { status: 'ok', version: '3.5.0-beta.1', name: 'agent2api' },
      panel: { success: true, data: { registered: 'false' } },
    },
    3061: {
      health: { status: 'ok', healthy: true },
      panel: { success: true, data: { registered: 1 } },
    },
    3065: {
      health: { status: 'ok', message: 'welcome' },
      panel: { success: true, data: { registered: null } },
    },
  });
  const found = await h.discover(50);
  assert.deepEqual(ports(found), []);
  for (const port of [3060, 3061, 3065]) {
    assert.deepEqual(pathsFor(h.calls, port), ['/health', '/api/panel/status']);
  }
});

await test('panel marker still discovers a gateway after health request failure', async () => {
  const h = harness({
    3065: {
      healthError: 'simulated connection reset',
      panel: { success: true, data: { registered: false } },
    },
  });
  const found = await h.discover(50);
  assert.deepEqual(ports(found), [3065]);
  assert.deepEqual(pathsFor(h.calls, 3065), ['/health', '/api/panel/status']);
});

const failed = results.filter(item => !item.pass).length;
console.log(`\n=== ${results.length} checked / ${results.length - failed} passed / ${failed} failed ===`);
process.exitCode = failed ? 1 : 0;
