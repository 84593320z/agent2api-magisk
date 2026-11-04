#!/usr/bin/env node
/** Execute the actual snapshot component/API with controlled React/HTTP scheduling.
 * No npm packages, generated bundle, network access or APK build are required.
 * Node >=22.13 (node:module stripTypeScriptTypes) is required.
 */
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { stripTypeScriptTypes } from 'node:module';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const componentPath = path.join(root, 'apk-mod/src/components/GatewaySwitches.tsx');
const apiPath = path.join(root, 'apk-mod/src/api/switches.ts');
const component = fs.readFileSync(componentPath, 'utf8');
const api = fs.readFileSync(apiPath, 'utf8');
const startMarker = 'export function GatewaySwitches() {';
const start = component.indexOf(startMarker);
const end = component.indexOf('  const groups:', start);
assert.ok(start >= 0 && end > start, 'component extraction must match the real source');
const componentJs = stripTypeScriptTypes(
  'function factory(){' + component.slice(start + startMarker.length, end) +
  '\nreturn {load,toggle,chain,pending,epoch};}', { mode: 'strip' });
const disabledExpression = component.match(/const disabled = (.+)/)?.[1];
assert.ok(disabledExpression && component.includes('disabled={disabled}'), 'actual Switch must consume disabled');
const apiJs = stripTypeScriptTypes(api.replace(/^import .* from '\.\/client'\r?\n/m, '').replace(/^export /gm, ''), { mode: 'strip' });
const results = [];
async function test(name, fn) {
  let timer;
  try {
    await Promise.race([fn(), new Promise((_, reject) => { timer = setTimeout(() => reject(new Error('case exceeded 2000ms')), 2000); })]);
    results.push({ name, pass: true }); console.log('ok   ' + name);
  } catch (error) { results.push({ name, pass: false, error: error.stack }); console.error('FAIL ' + name + '\n' + error.stack); }
  finally { clearTimeout(timer); }
}
const flush = async () => { for (let i = 0; i < 20; ++i) await Promise.resolve(); };
function defer() { let resolve, reject; const p = new Promise((a, b) => { resolve = a; reject = b; }); return { p, resolve, reject }; }
function apiHarness(call) {
  const ctx = vm.createContext({ apiCall: call });
  vm.runInContext(apiJs + '\nthis.definitions=SWITCH_DEFS;', ctx);
  return ctx;
}
function harness(initial = {}, { deferred = false, realApi = false } = {}) {
  const slots = [], reads = [], writes = [], effects = [], updates = [];
  let index = 0, instance;
  const apiContext = realApi ? apiHarness((_path, options) => {
    assert.equal(options.method, 'PUT');
    const d = defer(); writes.push({ ...d, body: options.body }); return d.p;
  }) : null;
  const set = (i, value) => {
    const apply = () => { slots[i] = typeof value === 'function' ? value(slots[i]) : value; };
    if (deferred) updates.push(apply); else apply();
  };
  const ctx = vm.createContext({
    useState(value) { const i = index++; if (!(i in slots)) slots[i] = i === 0 ? { ...initial } : i === 1 && Object.keys(initial).length > 0 ? true : typeof value === 'function' ? value() : value; return [slots[i], next => set(i, next)]; },
    useRef(value) { const i = index++; if (!(i in slots)) slots[i] = { current: value }; return slots[i]; },
    useCallback(fn) { index++; return fn; },
    useEffect(fn) { index++; effects.push(fn); },
    fetchSwitches() { const d = defer(); reads.push(d); return d.p; },
    saveSwitch(id, next) { if (apiContext) return apiContext.saveSwitch(id, next); const d = defer(); writes.push({ ...d, id, next }); return d.p; },
    t: value => value,
    window: { setInterval() { return 1; }, clearInterval() {} },
    document: { visibilityState: 'visible', addEventListener() {}, removeEventListener() {} },
  });
  vm.runInContext(componentJs, ctx);
  const render = () => { index = 0; instance = ctx.factory(); };
  render();
  return {
    get x() { return instance; }, slots, reads, writes, render,
    commit() { while (updates.length) updates.shift()(); },
    setDeferred(value) { deferred = value; },
    mount() { return effects[0](); },
    disabled(id) { ctx.ready = slots[1]; ctx.value = slots[0][id]; ctx.busy = slots[3]; return vm.runInContext(disabledExpression, ctx); },
  };
}

for (const deferred of [false, true]) {
  const suffix = deferred ? ' [deferred React updater]' : ' [immediate updater]';
  await test('RR08 replaces missing keys and disables unknown' + suffix, async () => {
    const h = harness({}, { deferred });
    assert.equal(h.disabled('debug'), true);
    let p = h.x.load(); h.reads[0].resolve({ debug: true }); await p; h.commit();
    assert.equal(h.slots[0].debug, true); assert.equal(h.disabled('debug'), false);
    p = h.x.load(); h.reads[1].resolve({}); await p; h.commit();
    assert.equal(h.slots[0].debug, undefined); assert.equal(h.slots[1], true); assert.equal(h.disabled('debug'), true);
  });
  for (const readDuringWrite of [false, true]) {
    await test('reject GET ' + (readDuringWrite ? 'issued during PUT' : 'issued before PUT') + ' after completed PUT' + suffix, async () => {
      const h = harness({ debug: false }, { deferred });
      let p;
      if (!readDuringWrite) p = h.x.load();
      h.x.toggle('debug', true); h.commit(); await flush();
      if (readDuringWrite) p = h.x.load();
      assert.equal(h.disabled('debug'), true);
      h.writes[0].resolve({ debug: true }); await h.x.chain.current; h.commit();
      assert.equal(h.x.pending.current.size, 0); assert.equal(h.slots[0].debug, true);
      h.reads[0].resolve({ debug: false }); await p; h.commit();
      assert.equal(h.slots[0].debug, true); assert.equal(h.disabled('debug'), false);
      const fresh = h.x.load(); h.reads[1].resolve({ debug: false }); await fresh; h.commit();
      assert.equal(h.slots[0].debug, false, 'fresh post-write GET must still update');
    });
  }
  await test('late GET cannot restore value after failed PUT' + suffix, async () => {
    const h = harness({ debug: false }, { deferred });
    h.x.toggle('debug', true); await flush(); const p = h.x.load();
    h.writes[0].reject(new Error('network')); await h.x.chain.current; h.commit();
    h.reads[0].resolve({ debug: false }); await p; h.commit();
    assert.equal(h.slots[0].debug, undefined); assert.equal(h.disabled('debug'), true); assert.ok(h.slots[2]);
  });
  await test('GET responses are ordered by latest request' + suffix, async () => {
    const h = harness({}, { deferred }); const a = h.x.load(), b = h.x.load();
    h.reads[1].resolve({ debug: true }); await b; h.reads[0].resolve({ debug: false }); await a; h.commit();
    assert.equal(h.slots[0].debug, true);
  });
  await test('different-key PUTs are globally serial and preserve pending intent' + suffix, async () => {
    const h = harness({ sink: false, breaker: false }, { deferred });
    h.x.toggle('sink', true); h.x.toggle('breaker', true); h.commit(); await flush();
    assert.equal(h.writes.length, 1); assert.equal(h.writes[0].id, 'sink');
    assert.equal(h.disabled('sink'), true); assert.equal(h.disabled('breaker'), true);
    h.writes[0].resolve({ sink: true, breaker: false }); await flush();
    assert.equal(h.writes.length, 2); assert.equal(h.writes[1].id, 'breaker');
    h.commit(); assert.equal(h.slots[0].breaker, true);
    h.writes[1].resolve({ sink: true, breaker: true }); await h.x.chain.current; h.commit();
    assert.equal(h.slots[0].sink, true); assert.equal(h.slots[0].breaker, true); assert.equal(h.slots[3].size, 0);
  });
  await test('failed write does not stop serial queue' + suffix, async () => {
    const h = harness({ debug: false, cors: false }, { deferred });
    h.x.toggle('debug', true); h.x.toggle('cors', true); await flush();
    h.writes[0].reject(new Error('network')); await flush();
    assert.equal(h.writes.length, 2); h.writes[1].resolve({ cors: true }); await h.x.chain.current; h.commit();
    assert.equal(h.slots[0].debug, undefined); assert.equal(h.slots[0].cors, true); assert.equal(h.slots[3].size, 0);
  });
  await test('pending intent survives missing read endpoint' + suffix, async () => {
    const h = harness({ debug: false }, { deferred }); h.x.toggle('debug', true); await flush();
    const p = h.x.load(); h.reads[0].resolve({}); await p; h.commit();
    assert.equal(h.slots[0].debug, true); assert.equal(h.disabled('debug'), true);
    h.writes[0].resolve({ debug: true }); await h.x.chain.current; h.commit(); assert.equal(h.slots[0].debug, true);
  });
  await test('duplicate same-key event is ignored without losing pending ownership' + suffix, async () => {
    const h = harness({ debug: false }, { deferred }); h.x.toggle('debug', true); h.x.toggle('debug', false); await flush();
    assert.equal(h.x.pending.current.get('debug'), true); assert.equal(h.writes.length, 1);
    h.writes[0].resolve({ debug: true }); await flush();
    assert.equal(h.writes.length, 1, 'same-key duplicate must not start a second PUT');
    await h.x.chain.current; h.commit();
    assert.equal(h.slots[0].debug, true); assert.equal(h.x.pending.current.size, 0);
  });
  for (const response of [{}, { debugMode: false }, { debugMode: 'true' }]) {
    await test('actual API invalid echo becomes unknown in component ' + JSON.stringify(response) + suffix, async () => {
      const h = harness({ debug: false }, { deferred, realApi: true }); h.x.toggle('debug', true); await flush();
      h.writes[0].resolve(response); await h.x.chain.current; h.commit();
      assert.equal(h.slots[0].debug, undefined); assert.equal(h.disabled('debug'), true); assert.ok(h.slots[2]); assert.equal(h.slots[3].size, 0);
    });
  }
  await test('actual API valid echo confirms component target' + suffix, async () => {
    const h = harness({ debug: false }, { deferred, realApi: true }); h.x.toggle('debug', true); await flush();
    h.writes[0].resolve({ debugMode: true }); await h.x.chain.current; h.commit();
    assert.equal(h.slots[0].debug, true); assert.equal(h.disabled('debug'), false); assert.equal(h.slots[2], '');
  });
}
await test('already queued GET updater rechecks write-intent barrier on commit', async () => {
  const h = harness({ debug: false }); const p = h.x.load(); h.setDeferred(true);
  h.reads[0].resolve({ debug: false, cors: true }); await p;
  h.x.toggle('debug', true); h.commit();
  assert.equal(h.slots[0].debug, true); assert.equal(h.slots[0].cors, undefined, 'whole obsolete snapshot must be rejected');
  await flush(); h.writes[0].resolve({ debug: true }); await h.x.chain.current; h.commit();
});
await test('GET updater queued during PUT rechecks write-settlement barrier', async () => {
  const h = harness({ debug: false }); h.x.toggle('debug', true); await flush();
  const p = h.x.load(); h.setDeferred(true); h.reads[0].resolve({ debug: false, cors: true }); await p;
  h.writes[0].resolve({ debug: true }); await h.x.chain.current; h.commit();
  assert.equal(h.slots[0].debug, true); assert.equal(h.slots[0].cors, undefined);
});
await test('queued older GET updater loses to a later GET before commit', async () => {
  const h = harness({}, { deferred: true }); const a = h.x.load(); h.reads[0].resolve({ debug: false, cors: true }); await a;
  const b = h.x.load(); h.reads[1].resolve({ debug: true }); await b; h.commit();
  assert.equal(h.slots[0].debug, true); assert.equal(h.slots[0].cors, undefined);
});
await test('deferred earlier PUT cannot overwrite a later failed pending key', async () => {
  const h = harness({ sink: false, breaker: false }, { deferred: true });
  h.x.toggle('sink', true); h.x.toggle('breaker', true); await flush();
  h.writes[0].resolve({ sink: true, breaker: false }); await flush();
  h.writes[1].reject(new Error('network')); await h.x.chain.current; h.commit();
  assert.equal(h.slots[0].sink, true); assert.equal(h.slots[0].breaker, undefined); assert.ok(h.slots[2]);
});
await test('later confirmed endpoint response may resolve another failed key', async () => {
  const h = harness({ sink: false, breaker: false }, { deferred: true });
  h.x.toggle('sink', true); h.x.toggle('breaker', true); await flush();
  h.writes[0].reject(new Error('network')); await flush();
  h.writes[1].resolve({ sink: false, breaker: true }); await h.x.chain.current; h.commit();
  // The second confirmed endpoint response is newer evidence for sink, so false is allowed.
  assert.equal(h.slots[0].breaker, true); assert.equal(h.slots[0].sink, false);
});
await test('unmounted component ignores late GET and PUT state updates', async () => {
  const h = harness({ debug: false }); const cleanup = h.mount(); h.x.toggle('debug', true); await flush(); cleanup();
  h.reads[0].resolve({ debug: false }); h.writes[0].resolve({ debug: false }); await h.x.chain.current; await flush();
  assert.equal(h.slots[0].debug, true); assert.equal(h.x.pending.current.size, 0);
});

const definitions = apiHarness(async () => ({})).definitions;
for (const def of definitions) {
  for (const next of [false, true]) {
    await test('API strict confirmation ' + def.id + '=' + next, async () => {
      let seen;
      const ctx = apiHarness(async (url, options) => { seen = { url, options }; return { [def.field]: next }; });
      const result = await ctx.saveSwitch(def.id, next);
      assert.equal(result[def.id], next); assert.equal(seen.url, def.path); assert.equal(seen.options.method, 'PUT');
      assert.equal(seen.options.body[def.field], next);
    });
    for (const response of [{}, { [def.field]: !next }, { [def.field]: Number(next) }, { [def.field]: String(next) }, { [def.field]: null }, null, []]) {
      await test('API rejects ' + def.id + '=' + next + ' echo ' + JSON.stringify(response), async () => {
        const ctx = apiHarness(async () => response); await assert.rejects(() => ctx.saveSwitch(def.id, next));
      });
    }
  }
}
for (const localPanel of [false, true]) {
  for (const next of [false, true]) {
    await test('captcha current-side boolean echo ' + JSON.stringify({ localPanel, next }), async () => {
      const response = { localPanel, captchaWeb: localPanel ? !next : next, captchaDesktop: localPanel ? next : !next };
      const ctx = apiHarness(async () => response); assert.equal((await ctx.saveSwitch('captcha', next)).captcha, next);
      const wrong = apiHarness(async () => ({ ...response, [localPanel ? 'captchaDesktop' : 'captchaWeb']: !next }));
      await assert.rejects(() => wrong.saveSwitch('captcha', next));
    });
  }
}
await test('fetchSwitches deduplicates routing and preserves partial unknown', async () => {
  const calls = [];
  const ctx = apiHarness(async (url) => { calls.push(url); if (url === '/api/debug') return { debugMode: true }; if (url === '/api/routing') return { routingSink: false, routingBreakerEnabled: 'true' }; throw new Error('endpoint down'); });
  const result = await ctx.fetchSwitches();
  assert.equal(calls.length, 7); assert.equal(calls.filter(url => url === '/api/routing').length, 1);
  assert.equal(result.debug, true); assert.equal(result.sink, false); assert.equal(result.breaker, undefined); assert.equal(result.cors, undefined);
});
await test('unknown switch and invalid requested type reject before HTTP', async () => {
  let calls = 0; const ctx = apiHarness(async () => { calls++; return {}; });
  await assert.rejects(() => ctx.saveSwitch('unknown', true)); await assert.rejects(() => ctx.saveSwitch('debug', 'true')); assert.equal(calls, 0);
});

const failed = results.filter(item => !item.pass).length;
const report = {
  node: process.version, root,
  inputs: [componentPath, apiPath].map(input => ({ path: input, sha256: crypto.createHash('sha256').update(fs.readFileSync(input)).digest('hex') })),
  total: results.length, passed: results.length - failed, failed, results,
};
const reportOption = process.argv.indexOf('--report');
if (reportOption >= 0) { assert.ok(process.argv[reportOption + 1], '--report requires output path'); fs.writeFileSync(process.argv[reportOption + 1], JSON.stringify(report, null, 2) + '\n'); }
console.log(`\n=== ${report.total} checked / ${report.passed} passed / ${failed} failed ===`);
process.exitCode = failed ? 1 : 0;
