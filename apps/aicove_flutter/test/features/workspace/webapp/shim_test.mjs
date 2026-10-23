import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';

const source = readFileSync(new URL('../../../../assets/webapp/shim.js', import.meta.url), 'utf8');
const FORMAT = 'aicove.webapp.save.v1';
const save = values => JSON.stringify({format: FORMAT, localStorage: values});
const delay = () => Promise.resolve();
async function settle() { for (let i = 0; i < 40; i++) await delay(); }
function deferred() {
  let resolve, reject;
  const promise = new Promise((a, b) => { resolve = a; reject = b; });
  return {promise, resolve, reject};
}
class Element {
  constructor(tag) { this.tag = tag; this.children = []; this.style = {}; this.events = {}; this.textContent = ''; }
  get firstChild() { return this.children[0]; }
  appendChild(child) { this.children.push(child); return child; }
  removeChild(child) { this.children.splice(this.children.indexOf(child), 1); }
  setAttribute(name, value) { this[name] = value; }
  addEventListener(name, fn) { this.events[name] = fn; }
  attachShadow() { this.shadow = new Element('shadow'); return this.shadow; }
}
function nativeStorage(map = new Map(), {failWrite = false} = {}) {
  return {
    map,
    getItem: k => map.has(String(k)) ? map.get(String(k)) : null,
    setItem: (k, v) => { if (failWrite) throw new DOMException('full', 'QuotaExceededError'); map.set(String(k), String(v)); },
    removeItem: k => map.delete(String(k)),
  };
}
function locks() {
  const held = new Set();
  return {held, request: async (name, options, fn) => {
    await delay();
    assert.equal(options.ifAvailable, true);
    if (held.has(name)) return fn(null);
    held.add(name); return fn({name});
  }};
}

function environment(options = {}) {
  const timers = new Map(), documentEvents = {}, windowEvents = {};
  let time = 0, timerId = 0, serverRevision = options.revision ?? '', diskText = options.text ?? null, nextRun = 0;
  const calls = [];
  const native = options.native ?? nativeStorage();
  const document = {
    visibilityState: 'visible', documentElement: new Element('html'),
    createElement: tag => new Element(tag),
    addEventListener: (name, fn) => { documentEvents[name] = fn; },
  };
  const env = {
    calls, document, native, reloads: 0,
    handler: options.handler ?? null,
    maxConcurrent: 0, concurrent: 0,
    get now() { return time; },
    get revision() { return serverRevision; },
    get text() { return diskText; },
    external(text, revision) { diskText = text; serverRevision = revision; },
    async tick(ms) {
      const until = time + ms;
      await settle();
      let iterations = 0;
      while (true) {
        assert(++iterations < 100000, 'timer runaway');
        let chosen = null;
        for (const [id, timer] of timers) {
          if (timer.at <= until && (!chosen || timer.at < chosen[1].at || (timer.at === chosen[1].at && id < chosen[0]))) chosen = [id, timer];
        }
        if (!chosen) break;
        const [id, timer] = chosen;
        time = timer.at;
        if (timer.interval) timer.at += timer.interval;
        else timers.delete(id);
        timer.fn(); await settle();
      }
      time = until; await settle();
    },
    async visibility(value) {
      document.visibilityState = value; documentEvents.visibilitychange?.(); await settle();
    },
    async pagehide() { windowEvents.pagehide?.(); await settle(); },
    texts() {
      const all = [];
      function visit(e) { if (e.textContent) all.push(e.textContent); e.children.forEach(visit); if (e.shadow) visit(e.shadow); }
      visit(document.documentElement); return all;
    },
    async click(label) {
      let found;
      function visit(e) {
        if (e.tag === 'button' && e.textContent.includes(label)) found = e;
        e.children.forEach(visit); if (e.shadow) visit(e.shadow);
      }
      visit(document.documentElement); assert(found, `button missing: ${label}`);
      found.events.click(); await settle();
    },
  };
  function schedule(fn, ms, interval) {
    const id = ++timerId; timers.set(id, {fn, at: time + ms, interval}); return id;
  }
  async function fetch(url, init = {}) {
    const route = new URL(url, 'http://ws.localhost').pathname.split('/').pop();
    const call = {route, url, init, at: time}; calls.push(call);
    env.concurrent++; env.maxConcurrent = Math.max(env.maxConcurrent, env.concurrent);
    const aborted = deferred();
    const abort = () => aborted.reject(new DOMException('aborted', 'AbortError'));
    init.signal?.addEventListener('abort', abort, {once: true});
    try {
      const response = await Promise.race([(async () => {
        const custom = env.handler && await env.handler(call, env);
        if (custom) return custom;
        if (route === 'run') return {status: 200, body: {runId: `webapp-${++nextRun}`}};
        if (route === 'state') {
          const known = new URL(url, 'http://ws.localhost').searchParams.get('known');
          return {status: 200, body: {revision: serverRevision, ...(known !== serverRevision ? {text: diskText} : {})}};
        }
        assert.equal(route, 'save');
        assert.equal(init.method, 'POST');
        assert.equal(init.headers['Content-Type'], 'application/json');
        if (init.body === diskText) return {status: 200, body: {revision: serverRevision}};
        if (init.headers['X-AIcove-Base'] !== serverRevision) return {status: 409, body: {error: 'conflict', revision: serverRevision, text: diskText}};
        diskText = init.body; serverRevision = `rev-${calls.filter(c => c.route === 'save').length}`;
        return {status: 200, body: {revision: serverRevision}};
      })(), aborted.promise]);
      return {status: response.status, json: async () => response.body};
    } finally {
      init.signal?.removeEventListener('abort', abort); env.concurrent--;
    }
  }
  const context = {
    console, document, navigator: options.noLocks ? {} : {locks: options.locks ?? locks()},
    DOMException, AbortController, fetch,
    setTimeout: (fn, ms) => schedule(fn, ms, 0), clearTimeout: id => timers.delete(id),
    setInterval: (fn, ms) => schedule(fn, ms, ms), clearInterval: id => timers.delete(id),
    addEventListener: (name, fn) => { windowEvents[name] = fn; },
    location: {reload: () => env.reloads++},
    __AICOVE_BOOT__: {page: options.page ?? 'game.html', savePath: 'game.save.json',
      revision: serverRevision, text: diskText, quota: options.quota ?? 5 * 1024 * 1024},
  };
  context.window = context;
  context.Storage = class Storage {};
  for (const key of ['getItem', 'setItem', 'removeItem', 'key', 'clear']) {
    Object.defineProperty(context.Storage.prototype, key, {value() { throw new Error('native Storage method called'); }, configurable: true});
  }
  if (options.nativeUnavailable) Object.defineProperty(context, 'localStorage', {get() { throw new Error('blocked'); }, configurable: true});
  else Object.defineProperty(context, 'localStorage', {value: native, configurable: !options.unmanaged, writable: true});
  vm.createContext(context);
  vm.runInContext(source, context, {filename: 'shim.js'});
  env.context = context;
  env.storage = context.localStorage;
  env.eval = code => vm.runInContext(code, context);
  env.pending = () => JSON.parse(native.getItem(`__aicove_pending__:${options.page ?? 'game.html'}`) ?? 'null');
  return env;
}

const tests = [];
function test(name, fn) { tests.push([name, fn]); }
const writes = e => e.calls.filter(c => c.route === 'save');
const runs = e => e.calls.filter(c => c.route === 'run');
const hasText = (e, part) => e.texts().some(t => t.includes(part));

test('round trip all ADR values, three lossy JSON counterexamples and object fields', async () => {
  const e = environment(); await settle();
  assert.equal(e.context.__AICOVE_BOOT__, undefined);
  const values = {
    string: 'hello', number: '42', float: '{"n":1.0}', order: '{"2":2,"1":1}',
    large: '{"n":9007199254740993}', object: '{"n":1}', array: '[1,"中",true]',
    spaced: '{ "n": 1 }', chinese: '中文和\u{1f600}', empty: '', bool: 'true', nil: 'null',
    __protoValue: 'literal', slashes: 'a\\b\n\t',
  };
  for (const [k, v] of Object.entries(values)) e.storage.setItem(k, v);
  e.storage.setItem('__proto__', '{"x":1}');
  await e.tick(2000);
  assert.equal(writes(e).length, 1);
  const encoded = JSON.parse(e.text);
  assert.deepEqual(encoded.localStorage.object, {n: 1});
  assert.deepEqual(encoded.localStorage.array, [1, '中', true]);
  for (const key of ['float', 'order', 'large', 'spaced', 'number', 'bool', 'nil']) assert.equal(encoded.localStorage[key], values[key]);
  const restored = environment({text: e.text, revision: e.revision}); await settle();
  for (const [key, value] of Object.entries(values)) assert.equal(restored.storage.getItem(key), value);
  assert.equal(restored.storage.getItem('__proto__'), '{"x":1}');
  assert.equal(writes(restored).length, 0);
});

test('pretty save exceeding 16 MiB falls back to compact JSON', async () => {
  const e = environment(); await settle();
  let value = Array(300000).fill(0);
  for (let i = 0; i < 30; i++) value = [value];
  const literal = JSON.stringify(value);
  e.storage.setItem('nested', literal);
  await e.tick(2000);
  assert.equal(writes(e).length, 1);
  assert(Buffer.byteLength(e.text) < 16 * 1024 * 1024);
  assert(!e.text.includes('\n'));
  assert.equal(JSON.stringify(JSON.parse(e.text).localStorage.nested), literal);
});

test('handwritten number, boolean and null become strings; invalid shape is broken', async () => {
  const e = environment({text: save({number: 12, bool: false, nil: null, nested: {x: 1}}), revision: 'r'});
  assert.equal(e.storage.number, '12'); assert.equal(e.storage.bool, 'false'); assert.equal(e.storage.nil, 'null');
  assert.equal(e.storage.nested, '{"x":1}');
  for (const text of ['{', 'null', '[]', '{"format":"wrong","localStorage":{}}', '{"format":"aicove.webapp.save.v1","localStorage":[]}']) {
    const broken = environment({text, revision: 'bad'}); await settle();
    broken.storage.setItem('x', 'y'); await broken.tick(20000);
    assert.equal(writes(broken).length, 0); assert(hasText(broken, '存档文件格式有误'));
  }
});

test('Storage proxy: attributes, collisions, own keys, symbol, IDL conversion and required arguments', async () => {
  const e = environment(); const s = e.storage;
  s.foo = 12; assert.equal(s.foo, '12'); assert.equal(s['foo'], '12'); assert.equal(s.getItem('missing'), null);
  assert('foo' in s); assert(!('missing' in s)); assert.equal(s.length, 1);
  assert.deepEqual(Array.from(Object.keys(s)), ['foo']);
  assert.deepEqual({...Object.getOwnPropertyDescriptor(s, 'foo')}, {value: '12', writable: true, configurable: true, enumerable: true});
  s.setItem('getItem', 'hidden'); assert.equal(typeof s.getItem, 'function'); assert.equal(s.getItem('getItem'), 'hidden');
  s.setItem = 'shadow'; assert.equal(typeof s.setItem, 'function'); assert.equal(s.getItem('setItem'), 'shadow');
  s.length = 99; assert.equal(s.length, 4); assert.equal(s.getItem('length'), '99');
  s.toString = 'hidden prototype'; assert.equal(typeof s.toString, 'function');
  assert.deepEqual(Array.from(Object.keys(s)), ['foo']);
  Object.defineProperty(s, 'defined', {value: true}); assert.equal(s.defined, 'true');
  assert.equal(s.key(0), 'foo'); assert.equal(s.key(2 ** 32), 'foo');
  assert.equal(s.key(NaN), 'foo'); assert.equal(s.key(Infinity), 'foo'); assert.equal(s.key(-1), null);
  assert.equal(s.key(0.9), 'foo'); assert.equal(s.key('0'), 'foo');
  for (const expression of ['localStorage.getItem()', 'localStorage.setItem()', 'localStorage.setItem("x")', 'localStorage.removeItem()', 'localStorage.key()']) {
    assert.throws(() => e.eval(expression), error => error.name === 'TypeError');
  }
  const sym = Symbol('extra'); s[sym] = 7; assert.equal(s[sym], 7); assert(Reflect.ownKeys(s).includes(sym));
  assert(s instanceof e.context.Storage);
  delete s.foo; assert.equal(s.getItem('foo'), null);
  s.removeItem('defined'); assert.equal(s.defined, undefined);
  s.clear(); assert.equal(s.length, 0); assert.equal(s.key(0), null);
});

test('quota uses JSON-escaped UTF-8 bytes and rolls back without dirty changes', async () => {
  const e = environment({quota: 12}); await settle();
  e.storage.setItem('中', '文'); // 5 + 5 = 10 bytes.
  assert.throws(() => e.storage.setItem('x', 'y'), error => error.name === 'QuotaExceededError');
  assert.equal(e.storage.length, 1); assert.equal(e.storage.getItem('x'), null);
  e.storage.setItem('中', 'x');
  assert.throws(() => e.storage.setItem('中', '\u{1f600}\u{1f600}'), error => error.name === 'QuotaExceededError');
  assert.equal(e.storage.getItem('中'), 'x');
  await e.tick(2000); assert.equal(writes(e).length, 1);
  const seq = e.pending(); assert.equal(seq, null);
  e.storage.setItem('中', 'x'); e.storage.removeItem('missing'); await e.tick(2000);
  assert.equal(writes(e).length, 1);
});

test('2-second debounce, 10-second ceiling, and one run per play session', async () => {
  const e = environment(); await settle();
  e.storage.x = '1'; await e.tick(1500); e.storage.x = '2'; await e.tick(1999);
  assert.equal(writes(e).length, 0); await e.tick(1); assert.equal(writes(e).length, 1);
  assert.equal(e.pending(), null);
  for (let i = 0; i < 10; i++) { e.storage.x = String(i); await e.tick(1000); }
  assert.equal(writes(e).length, 2); assert.equal(runs(e).length, 1);
  assert.equal(e.reloads, 0);
  await e.tick(10000); assert.equal(e.reloads, 0); assert.equal(writes(e).length, 2);
});

test('hidden/pagehide save immediately, keepalive only for <=60 KiB', async () => {
  const e = environment(); await settle();
  e.storage.x = 'value'; await e.visibility('hidden');
  assert.equal(writes(e).length, 1); assert.equal(writes(e)[0].init.keepalive, true);
  e.storage.x = 'a'.repeat(65 * 1024); await e.pagehide();
  assert.equal(writes(e).length, 2); assert.equal(writes(e)[1].init.keepalive, undefined);
  assert.equal(e.maxConcurrent, 1);
});

test('pagehide while still visible sends with keepalive', async () => {
  const e = environment(); await settle();
  assert.equal(runs(e).length, 1); // Held before the first change.
  e.storage.x = 'leaving'; await e.pagehide();
  assert.equal(runs(e).length, 1);
  assert.equal(writes(e).length, 1); assert.equal(writes(e)[0].init.keepalive, true);
});

test('one inflight request; changed during save advances only snapshot base', async () => {
  const pending = deferred();
  const e = environment({handler: call => call.route === 'save' ? pending.promise : null}); await settle();
  e.storage.x = 'first'; await e.tick(2000);
  assert.equal(writes(e).length, 1);
  e.storage.x = 'second'; await e.tick(300); const seq = e.pending().seq;
  await e.tick(700); assert.equal(e.calls.filter(c => c.route === 'state').length, 1);
  pending.resolve({status: 200, body: {revision: 'acked'}}); await settle();
  assert.equal(e.pending().base, 'acked'); assert.equal(e.pending().seq, seq);
  assert.equal(JSON.parse(e.pending().text).localStorage.x, 'second');
  assert.equal(e.maxConcurrent, 1);
});

test('a due write blocked by polling is sent immediately after it finishes', async () => {
  const pending = deferred(); let hold = true;
  const e = environment({handler: call => call.route === 'state' && hold ? pending.promise : null}); await settle();
  await e.tick(2000); // Idle poll begins.
  e.storage.x = 'local'; await e.tick(2000); assert.equal(writes(e).length, 0);
  hold = false; pending.resolve({status: 200, body: {revision: ''}}); await settle();
  assert.equal(writes(e).length, 1); assert.equal(e.maxConcurrent, 1);
});

test('409 conflict retains edits, overwrite uses latest base and a new run', async () => {
  let firstPoll = true;
  const e = environment({text: save({x: 'initial'}), revision: 'initial', handler: call => {
    if (call.route === 'state' && firstPoll) { firstPoll = false; return {status: 200, body: {revision: 'initial'}}; }
    return null;
  }}); await settle();
  e.storage.x = 'local'; e.external(save({x: 'remote'}), 'remote');
  await e.tick(2000); assert.equal(writes(e).length, 1); assert(hasText(e, '存档在别处被改过了'));
  e.storage.x = 'keep this'; await e.tick(10000); assert.equal(writes(e).length, 1);
  assert.equal(JSON.parse(e.pending().text).localStorage.x, 'keep this');
  await e.click('保留本页进度');
  assert.equal(writes(e).length, 2); assert.equal(writes(e)[1].init.headers['X-AIcove-Base'], 'remote');
  assert.equal(JSON.parse(e.text).localStorage.x, 'keep this'); assert.equal(runs(e).length, 2);
  assert.equal(e.reloads, 0);
});

test('external revision reloads a clean page and discarding conflict deletes pending', async () => {
  const clean = environment({text: save({x: 'old'}), revision: 'old'}); await settle();
  clean.external(save({x: 'new'}), 'new'); await clean.tick(2000);
  assert.equal(clean.reloads, 1); assert.equal(clean.pending(), null);
  const e = environment(); await settle();
  e.storage.x = 'dirty'; e.external(save({x: 'external'}), 'remote');
  await e.tick(2000); await e.click('放弃本页进度');
  assert.equal(e.reloads, 1); assert.equal(e.pending(), null);
});

test('run_closed fetches state, conflicts with pending progress, overwrite opens a new run', async () => {
  let closed = true;
  const e = environment({handler: call => call.route === 'save' && closed ? {status: 409, body: {error: 'run_closed'}} : null}); await settle();
  e.storage.x = 'progress'; await e.tick(2000);
  assert(hasText(e, '存档在别处被改过了')); assert.equal(e.reloads, 0);
  closed = false; await e.click('保留本页进度');
  assert.equal(runs(e).length, 2); assert.equal(JSON.parse(e.text).localStorage.x, 'progress');
});

test('400 and 413 become broken and do not retry edits', async () => {
  for (const status of [400, 413]) {
    const e = environment({handler: call => call.route === 'save' ? {status, body: {error: 'bad_save'}} : null}); await settle();
    e.storage.x = 'local'; await e.tick(2000); assert(hasText(e, '存档文件格式有误'));
    e.storage.x = 'more'; await e.tick(20000); assert.equal(writes(e).length, 1);
  }
});

test('broken archive repaired: clean reloads; dirty conflicts and never silently writes', async () => {
  for (const dirty of [false, true]) {
    const e = environment({text: '{', revision: 'broken'}); await settle();
    if (dirty) e.storage.x = 'local';
    await e.tick(4000); assert.equal(writes(e).length, 0);
    e.external(save({x: 'fixed'}), 'fixed'); await e.tick(2000);
    assert.equal(e.reloads, dirty ? 0 : 1);
    if (dirty) { assert(hasText(e, '存档在别处被改过了')); e.storage.x = 'more'; await e.tick(10000); }
    assert.equal(writes(e).length, 0);
  }
});

test('503/network failure retries after 3 seconds and recovers the disconnected notice', async () => {
  let fail = true;
  const e = environment({handler: call => {
    if (!fail) return null;
    if (call.route === 'save') return {status: 503, body: {error: 'busy'}};
    if (call.route === 'state') throw new Error('offline');
    return null;
  }}); await settle();
  e.storage.x = 'local'; await e.tick(2000);
  await e.tick(2999); assert.equal(writes(e).length, 1);
  await e.tick(1); assert.equal(writes(e).length, 2);
  await e.tick(3000); assert(hasText(e, '连不上 AIcove'));
  fail = false; await e.tick(3000);
  assert.equal(e.pending(), null); assert(!hasText(e, '连不上 AIcove'));
});

test('lost save response is retried idempotently before polling can report a false conflict', async () => {
  let first = true;
  const e = environment({handler: (call, env) => {
    if (call.route === 'save' && first) {
      first = false; env.external(call.init.body, 'committed');
      throw new Error('response lost after commit');
    }
    return null;
  }}); await settle();
  e.storage.x = 'progress'; await e.tick(2000);
  assert.equal(writes(e).length, 1); assert(e.pending());
  await e.tick(3000);
  assert.equal(writes(e).length, 2); assert.equal(e.pending(), null);
  assert.equal(e.reloads, 0); assert(!hasText(e, '存档在别处被改过了'));
  await e.tick(4000); assert.equal(e.reloads, 0);
});

test('lost response with newer local changes retries the original body before sending the new snapshot', async () => {
  const lost = deferred(); let first = true;
  const e = environment({handler: (call, env) => {
    if (call.route === 'save' && first) {
      first = false; env.external(call.init.body, 'committed'); return lost.promise;
    }
    return null;
  }}); await settle();
  e.storage.x = 'first'; await e.tick(2000);
  e.storage.x = 'newer'; lost.reject(new Error('lost response')); await settle();
  await e.tick(3000);
  assert.equal(writes(e).length, 2);
  assert.equal(writes(e)[1].init.body, writes(e)[0].init.body);
  assert.equal(e.pending().base, 'committed');
  assert.equal(JSON.parse(e.pending().text).localStorage.x, 'newer');
  await e.tick(2000);
  assert.equal(JSON.parse(e.text).localStorage.x, 'newer');
  assert.equal(e.pending(), null); assert(!hasText(e, '存档在别处被改过了'));
});

test('request timeout aborts at 15 seconds and retries without concurrent fetches', async () => {
  let fail = true;
  const e = environment({handler: call => call.route === 'save' && fail ? new Promise(() => {}) : null}); await settle();
  e.storage.x = 'local'; await e.tick(2000); assert.equal(writes(e).length, 1);
  await e.tick(14999); assert.equal(writes(e).length, 1);
  await e.tick(1); assert.equal(e.concurrent, 0);
  fail = false; await e.tick(2999); assert.equal(writes(e).length, 1);
  await e.tick(1); assert.equal(writes(e).length, 2); assert.equal(e.pending(), null);
  assert.equal(e.maxConcurrent, 1);
});

test('epoch ignores a late poll after conflict overwrite changes the local base', async () => {
  const slow = deferred(); let hold = false;
  const e = environment(); await settle();
  e.storage.x = 'local'; e.external(save({x: 'remote'}), 'remote'); await e.tick(2000);
  assert(hasText(e, '存档在别处被改过了'));
  e.handler = call => call.route === 'state' && hold ? slow.promise : null;
  hold = true; await e.tick(2000); // Poll in conflict.
  await e.click('保留本页进度');
  hold = false; slow.resolve({status: 200, body: {revision: 'stale', text: save({x: 'stale'})}}); await settle();
  assert.equal(e.reloads, 0); assert.equal(JSON.parse(e.text).localStorage.x, 'local');
  assert(!hasText(e, '存档在别处被改过了')); assert.equal(e.maxConcurrent, 1);
});

test('per-page snapshots never overwrite each other and duplicate tabs cannot write/remove them', async () => {
  const native = nativeStorage(), manager = locks();
  const a = environment({native, locks: manager, page: 'a.html'}); await settle(); a.storage.x = 'a'; await a.tick(300);
  const aSnapshot = native.getItem('__aicove_pending__:a.html');
  const b = environment({native, locks: manager, page: 'b.html'}); await settle(); b.storage.x = 'b'; await b.tick(300);
  assert.equal(native.getItem('__aicove_pending__:a.html'), aSnapshot);
  assert.equal(JSON.parse(b.pending().text).localStorage.x, 'b');
  const duplicate = environment({native, locks: manager, page: 'a.html'}); await settle();
  assert.equal(duplicate.storage.x, 'a');
  duplicate.storage.x = 'should not save'; await duplicate.tick(20000); await duplicate.pagehide();
  assert.equal(duplicate.calls.length, 0); assert(hasText(duplicate, '另一个标签页'));
  assert.equal(native.getItem('__aicove_pending__:a.html'), aSnapshot);
});

test('startup snapshots: absent, identical, matching base, conflicting base use the correct initial map', async () => {
  const none = environment({text: save({x: 'disk'}), revision: 'r'});
  assert.equal(none.storage.x, 'disk'); await settle(); assert.equal(writes(none).length, 0);
  const native = nativeStorage();
  native.setItem('__aicove_pending__:game.html', JSON.stringify({base: 'outdated', seq: 5, text: save({x: 'disk'})}));
  const identical = environment({native, text: save({x: 'disk'}), revision: 'r'});
  assert.equal(identical.storage.x, 'disk'); await settle();
  assert.equal(identical.pending(), null); assert.equal(writes(identical).length, 0);
  native.setItem('__aicove_pending__:game.html', JSON.stringify({base: 'r', seq: 7, text: save({x: 'pending'})}));
  const matching = environment({native, text: save({x: 'disk'}), revision: 'r'});
  assert.equal(matching.storage.x, 'pending'); await settle();
  assert.equal(writes(matching).length, 1); assert.equal(matching.pending(), null);
  native.setItem('__aicove_pending__:game.html', JSON.stringify({base: 'old', seq: 9, text: save({x: 'recover me'})}));
  const conflict = environment({native, text: save({x: 'external'}), revision: 'new'});
  assert.equal(conflict.storage.x, 'recover me'); await settle();
  assert(hasText(conflict, '存档在别处被改过了')); assert.equal(writes(conflict).length, 0);
  conflict.storage.x = 'still pending';
  assert.equal(conflict.pending().base, 'old');
  await conflict.click('保留本页进度');
  assert.equal(writes(conflict)[0].init.headers['X-AIcove-Base'], 'new');
  assert.equal(JSON.parse(conflict.text).localStorage.x, 'still pending');
});

test('snapshot writes coalesce bursts and are written at once when hidden', async () => {
  const native = nativeStorage(); let snapshotWrites = 0;
  const setItem = native.setItem; native.setItem = (k, v) => { snapshotWrites++; setItem(k, v); };
  const e = environment({native, handler: call => call.route === 'save' ? new Promise(() => {}) : null}); await settle();
  for (let i = 0; i < 100; i++) e.storage.setItem('x', String(i));
  assert.equal(snapshotWrites, 0);
  await e.tick(300); assert.equal(snapshotWrites, 1);
  assert.equal(JSON.parse(e.pending().text).localStorage.x, '99');
  e.storage.x = 'last'; await e.visibility('hidden');
  assert.equal(snapshotWrites, 2); assert.equal(JSON.parse(e.pending().text).localStorage.x, 'last');
});

test('pre-lock synchronous changes are preserved and equivalent snapshots do not delete newer ones', async () => {
  const native = nativeStorage();
  native.setItem('__aicove_pending__:game.html', JSON.stringify({base: '', seq: 3, text: save({})}));
  const e = environment({native});
  e.storage.x = 'before callback'; await settle();
  assert.equal(JSON.parse(e.text).localStorage.x, 'before callback');
  assert.equal(e.pending(), null);
});

test('native storage unavailable/quota failure warns once but normal saves still work', async () => {
  for (const options of [{nativeUnavailable: true}, {native: nativeStorage(new Map(), {failWrite: true})}]) {
    const e = environment(options); await settle();
    e.storage.x = 'one'; e.storage.y = 'two'; await e.tick(2000);
    assert(hasText(e, '无法找回')); assert.equal(writes(e).length, 1);
  }
  const unmanaged = environment({unmanaged: true}); await settle();
  await unmanaged.tick(10000); assert.equal(unmanaged.calls.length, 0);
  assert(hasText(unmanaged, '没能接管'));
});

test('Web Locks absent uses single-document fallback', async () => {
  const e = environment({noLocks: true}); e.storage.x = 'saved'; await e.tick(2000);
  assert.equal(writes(e).length, 1);
});

test('aicove.chat posts messages and surfaces error codes', async () => {
  let reply = {status: 200, body: {text: '你好呀'}};
  const e = environment({handler: async call => {
    if (call.route !== 'chat') return null;
    if (reply instanceof Error) throw reply;
    return reply;
  }});
  assert.equal(await e.eval(`aicove.chat('hi', {temperature: 0.2})`), '你好呀');
  const call = e.calls.find(c => c.route === 'chat');
  assert.equal(call.url, '/__aicove/ai/chat?page=game.html');
  assert.equal(call.init.method, 'POST');
  assert.deepEqual(JSON.parse(call.init.body), {temperature: 0.2, messages: [{role: 'user', content: 'hi'}]});
  const messages = [{role: 'system', content: 'NPC'}, {role: 'user', content: 'yo'}];
  await e.eval(`aicove.chat(${JSON.stringify(messages)})`);
  assert.deepEqual(JSON.parse(e.calls.filter(c => c.route === 'chat')[1].init.body).messages, messages);
  reply = {status: 429, body: {error: 'busy', message: '同时最多 2 个'}};
  await assert.rejects(e.eval(`aicove.chat('x')`), error => error.code === 'busy' && error.message === '同时最多 2 个');
  reply = new TypeError('Failed to fetch');
  await assert.rejects(e.eval(`aicove.chat('x')`), error => error.code === 'disconnected');
});

test('aicove.chat exists even when localStorage cannot be managed', async () => {
  const e = environment({unmanaged: true});
  assert.equal(typeof e.eval('aicove.chat'), 'function');
});

let failures = 0;
for (const [name, fn] of tests) {
  try { await fn(); console.log(`ok - ${name}`); }
  catch (error) { failures++; console.error(`not ok - ${name}\n${error.stack}`); }
}
console.log(`${tests.length - failures}/${tests.length} shim tests passed`);
if (failures) process.exitCode = 1;
