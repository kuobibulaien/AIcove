// Request-owned headless SillyTavern host and single-flight fetch bridge.
// Headless browser and Tavern APIs for preset-owned scripts.
const __presetHost = (() => {
  let currentScript = '', listeners = new Map(), writes = [], captured = null, flight = null;
  let timerId = 0, timers = new Map(), storage = {}, session = {}, context = {};
  let timerGeneration = 0, timerRunning = false, timerActive = false, timerLoop = null, ignoredTools = false, manager;
  let timerCallbacks = new Map(), acceptInitialTimers = true, timerExpired = false;
  let roundListeners = null;
  let chat = [], chatSources = new Map(), activeTools = new Map();
  let responseCache = new Map(), actionCache = new Map(), scriptInfo = new Map(), modules = new Map();
  let hostInput = {}, preset = {}, presetName = '', streamingProcessor = {isFinished:true,isStopped:false,abortController:{signal:{aborted:false}}}, executedScripts = false;
  const copy = value => value === undefined ? undefined : JSON.parse(JSON.stringify(value));
  const call = (method, args) => __aq_host(method, args);
  async function owned(owner, fn, ...args) {
    const previous = currentScript; currentScript = owner;
    try { return await fn(...args); } finally { currentScript = previous; }
  }
  function ownedSync(owner, fn, ...args) {
    const previous = currentScript; currentScript = owner;
    try { return fn(...args); } finally { currentScript = previous; }
  }
  // Rewrite only executable import tokens, not comments or quoted source text.
  function scriptSource(source) {
    return String(source).replace(/(\/\*[\s\S]*?\*\/|\/\/[^\r\n]*|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`)|\bimport\s*\(/g,
      (token, literal) => literal ? token : '__presetImport(');
  }
  function evaluate(source) { return (0,eval)(scriptSource(source)); }
  async function importScript(url) {
    url = String(url);
    if (!/^https?:\/\//i.test(url)) throw new TypeError('Unsupported module URL');
    if (!modules.has(url)) {
      const owner = currentScript;
      modules.set(url, owned(owner, async () => {
        const response = await globalThis.fetch(url);
        if (!response.ok) throw new TypeError('Script fetch failed: ' + url);
        let code = await response.text();
        const exports = [];
        // CDN modules without static imports can execute in the same headless host.
        code = code.replace(/\bexport\s+default\s+/g, '__exports.default = ')
          .replace(/\bexport\s+((?:async\s+)?(?:function|class|const|let|var))\s+([a-zA-Z_$][\w$]*)/g, (_, kind, name) => { exports.push([name,name]); return kind+' '+name; })
          .replace(/\bexport\s*\{([^}]+)\}\s*;?/g, (_, names) => {
            for (const part of names.split(',')) { const [local, alias] = part.trim().split(/\s+as\s+/); if (local) exports.push([local, alias || local]); }
            return '';
          });
        const original = code;
        return await evaluate('(async()=>{const __exports={};\n' + original + '\n' + exports.map(([local, alias]) => '__exports[' + JSON.stringify(alias) + ']=' + local + ';').join('') + '\nreturn __exports;})()');
      }));
    }
    return modules.get(url);
  }
  const flush = async () => { while (writes.length) { const pending = writes; writes = []; await Promise.all(pending); } };
  const b64chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  function btoa(s) {
    let out = ''; s = String(s);
    for (let i = 0; i < s.length; i += 3) {
      const a = s.charCodeAt(i), b = s.charCodeAt(i+1), c = s.charCodeAt(i+2);
      if (a > 255 || b > 255 || c > 255) throw Error('Invalid character');
      const n = (a << 16) | ((b || 0) << 8) | (c || 0);
      out += b64chars[(n >> 18)&63] + b64chars[(n >> 12)&63] + (isNaN(b) ? '=' : b64chars[(n >> 6)&63]) + (isNaN(c) ? '=' : b64chars[n&63]);
    }
    return out;
  }
  function atob(s) {
    s = String(s).replace(/\s/g, '').replace(/=+$/, ''); let out = '', bits = 0, n = 0;
    for (const ch of s) { const v = b64chars.indexOf(ch); if (v < 0) throw Error('Invalid base64'); n = (n << 6) | v; bits += 6; if (bits >= 8) { bits -= 8; out += String.fromCharCode((n >> bits)&255); } }
    return out;
  }
  class TextEncoder { encode(s = '') { return Uint8Array.from(unescape(encodeURIComponent(String(s))), c => c.charCodeAt(0)); } }
  class TextDecoder {
    constructor() { this.pending = []; }
    decode(bytes = [], options = {}) {
      const input = bytes instanceof ArrayBuffer ? new Uint8Array(bytes) : ArrayBuffer.isView(bytes) ? new Uint8Array(bytes.buffer, bytes.byteOffset, bytes.byteLength) : bytes;
      const data = [...this.pending, ...input]; this.pending = []; let out = '';
      for (let i = 0; i < data.length;) {
        const a = data[i]; let size = a < 0x80 ? 1 : a >= 0xc2 && a <= 0xdf ? 2 : a >= 0xe0 && a <= 0xef ? 3 : a >= 0xf0 && a <= 0xf4 ? 4 : 0;
        if (!size) { out += '\ufffd'; i++; continue; }
        if (i + size > data.length) {
          const tail = data.slice(i + 1);
          if (tail.every((v,j)=>v >= 0x80 && v <= 0xbf && (j || a !== 0xe0 || v >= 0xa0) && (j || a !== 0xed || v < 0xa0) && (j || a !== 0xf0 || v >= 0x90) && (j || a !== 0xf4 || v < 0x90))) {
            if (options.stream) this.pending = data.slice(i); else out += '\ufffd'; break;
          }
        }
        let cp = size === 1 ? a : a & (0x7f >> size), valid = true;
        for (let j = 1; j < size; j++) { const v = data[i+j]; if (!(v >= 0x80 && v <= 0xbf) || j === 1 && (a === 0xe0 && v < 0xa0 || a === 0xed && v >= 0xa0 || a === 0xf0 && v < 0x90 || a === 0xf4 && v >= 0x90)) { valid = false; break; } cp = (cp << 6) | (v & 63); }
        if (!valid) { out += '\ufffd'; i++; } else { out += String.fromCodePoint(cp); i += size; }
      }
      return out;
    }
  }
  class URLSearchParams {
    constructor(init = '') { this.items = []; if (typeof init === 'string') { for (const pair of init.replace(/^\?/, '').split('&')) { if (!pair) continue; const [k,...v] = pair.split('='); this.append(decodeURIComponent(k.replace(/\+/g,' ')), decodeURIComponent(v.join('=').replace(/\+/g,' '))); } } else if (Array.isArray(init)) { for (const [k,v] of init) this.append(k,v); } else { for (const [k,v] of Object.entries(init || {})) this.append(k,v); } }
    append(k,v) { this.items.push([String(k),String(v)]); }
    set(k,v) { this.delete(k); this.append(k,v); }
    get(k) { return this.items.find(x=>x[0]===String(k))?.[1] ?? null; }
    getAll(k) { return this.items.filter(x=>x[0]===String(k)).map(x=>x[1]); }
    has(k) { return this.items.some(x=>x[0]===String(k)); }
    delete(k) { this.items=this.items.filter(x=>x[0]!==String(k)); }
    toString() { return this.items.map(([k,v])=>encodeURIComponent(k)+'='+encodeURIComponent(v)).join('&'); }
    [Symbol.iterator]() { return this.items[Symbol.iterator](); }
  }
  class URL {
    constructor(value, base) {
      let url = String(value);
      if (!/^[a-z][a-z0-9+.-]*:\/\//i.test(url) && base) { const root = String(base).match(/^[a-z][a-z0-9+.-]*:\/\/[^/]+/i)?.[0] || ''; url = root + (url.startsWith('/') ? url : '/' + url); }
      const m = url.match(/^([a-z][a-z0-9+.-]*:)\/\/([^/?#]+)([^?#]*)(\?[^#]*)?(#.*)?$/i);
      if (!m) throw new TypeError('Invalid URL');
      this.protocol=m[1]; this.host=m[2]; this.hostname=m[2].replace(/:\d+$/, ''); this.port=m[2].match(/:(\d+)$/)?.[1] || ''; this.pathname=m[3] || '/'; this.search=m[4] || ''; this.hash=m[5] || ''; this.origin=this.protocol+'//'+this.host; this.searchParams=new URLSearchParams(this.search);
    }
    get href() { const query=this.searchParams.toString(); return this.origin+this.pathname+(query?'?'+query:'')+this.hash; }
    toString() { return this.href; }
  }
  class Headers {
    constructor(init = {}) { this.data = {}; if (init instanceof Headers) init = init.data; if (Array.isArray(init)) for (const [k,v] of init) this.set(k,v); else for (const [k,v] of Object.entries(init || {})) this.set(k,v); }
    set(k,v) { this.data[String(k).toLowerCase()] = String(v); }
    get(k) { return this.data[String(k).toLowerCase()] ?? null; }
    has(k) { return this.get(k) !== null; }
    append(k,v) { this.set(k, this.has(k) ? this.get(k) + ', ' + v : v); }
    delete(k) { delete this.data[String(k).toLowerCase()]; }
    entries() { return Object.entries(this.data)[Symbol.iterator](); }
    [Symbol.iterator]() { return this.entries(); }
    forEach(fn) { for (const [k,v] of this) fn(v,k,this); }
  }
  class ReadableStream {
    constructor(source = {}) {
      this.source = source; this.queue = []; this.waiters = []; this.closed = false; this.disturbed = false; this.errorValue = null; this.locked = false; this.pulling = false; this.pullAgain = false; this.started = false;
      this.controller = {
        enqueue:v => { if (this.closed) return; const w = this.waiters.shift(); if (w) {w.resolve({value:v,done:false}); if (this.waiters.length) this._pull();} else this.queue.push(v); },
        close:() => { if (this.closed) return; this.closed = true; for (const w of this.waiters.splice(0)) w.resolve({done:true}); },
        error:e => { this.errorValue = e || new Error('Stream failed'); this.queue = []; this.closed = true; for (const w of this.waiters.splice(0)) w.reject(this.errorValue); },
        get desiredSize() { return 1; }
      };
      Promise.resolve().then(()=>source.start?.(this.controller)).then(()=>{this.started = true; this._pull();},e=>this.controller.error(e));
    }
    _pull() {
      if (!this.started || this.closed || !this.waiters.length || !this.source.pull) return;
      if (this.pulling) {this.pullAgain = true; return;}
      this.pulling = true; this.pullAgain = false;
      Promise.resolve().then(()=>this.source.pull(this.controller)).then(()=>{this.pulling = false; if (this.pullAgain) this._pull();},e=>{this.pulling = false; this.controller.error(e);});
    }
    _read() {
      this.disturbed = true;
      if (this.errorValue) return Promise.reject(this.errorValue);
      if (this.queue.length) return Promise.resolve({value:this.queue.shift(),done:false});
      if (this.closed) return Promise.resolve({done:true});
      return new Promise((resolve,reject)=>{this.waiters.push({resolve,reject}); this._pull();});
    }
    getReader() {
      if (this.locked) throw new TypeError('Stream is locked'); this.locked = true; let released = false;
      return {read:()=>released ? Promise.reject(new TypeError('Reader released')) : this._read(), cancel:reason=>this._cancel(reason), releaseLock:()=>{released = true; this.locked = false;}};
    }
    async _cancel(reason) { this.disturbed = true; this.queue = []; this.controller.close(); await this.source.cancel?.(reason); }
    cancel(reason) { if (this.locked) return Promise.reject(new TypeError('Stream is locked')); return this._cancel(reason); }
    async pipeTo(writable) {
      const reader = this.getReader(), writer = writable.getWriter();
      try { while (true) { const r = await reader.read(); if (r.done) break; await writer.write(r.value); } await writer.close(); }
      catch (error) { await writer.abort?.(error); await reader.cancel(error); throw error; }
      finally { reader.releaseLock(); writer.releaseLock?.(); }
    }
    pipeThrough(transform) { this.pipeTo(transform.writable).catch(e=>transform.readable.controller.error(e)); return transform.readable; }
    tee() {
      const reader = this.getReader(); let cancelled = [false,false], reasons = [];
      const branches = [0,1].map(i=>new ReadableStream({cancel:reason=>{cancelled[i] = true; reasons[i] = reason; if (cancelled.every(Boolean)) return reader.cancel(reasons);}}));
      (async()=>{try {while (true) {const r = await reader.read(); for (let i=0;i<2;i++) if (!cancelled[i]) {if (r.done) branches[i].controller.close(); else branches[i].controller.enqueue(r.value instanceof Uint8Array ? r.value.slice() : r.value);} if (r.done) break;}} catch(e) {for (const b of branches) b.controller.error(e);} finally {reader.releaseLock();}})();
      return branches;
    }
  }
  class TransformStream {
    constructor(transformer = {}) {
      this.readable = new ReadableStream(); const c = this.readable.controller;
      const controller = {...c,terminate:()=>c.close()};
      this.writable = {getWriter:()=>({write:async v=>{if (!this.readable.closed) return transformer.transform ? transformer.transform(v,controller) : c.enqueue(v);},close:async()=>{if (!this.readable.closed) {await transformer.flush?.(controller); c.close();}},abort:async e=>c.error(e),releaseLock(){}})};
      transformer.start?.(controller);
    }
  }
  const bodyStream = body => body instanceof ReadableStream ? body : new ReadableStream({start(c) {if (body != null) c.enqueue(typeof body === 'string' ? new TextEncoder().encode(body) : body instanceof ArrayBuffer ? new Uint8Array(body) : body); c.close();}});
  class Response {
    constructor(body = '', options = {}) { this.status = options.status ?? 200; this.statusText = options.statusText || ''; this.headers = new Headers(options.headers); this.url = options.url || ''; this.ok = this.status >= 200 && this.status < 300; this.body = bodyStream(body); this._bodyUsed = false; }
    get bodyUsed() { return this._bodyUsed || this.body.disturbed; }
    async arrayBuffer() { if (this.bodyUsed) throw new TypeError('Body consumed'); this._bodyUsed = true; const reader = this.body.getReader(), chunks = []; let size = 0; try {while (true) {const r = await reader.read(); if (r.done) break; const bytes = typeof r.value === 'string' ? new TextEncoder().encode(r.value) : new Uint8Array(r.value); chunks.push(bytes); size += bytes.length;}} finally {reader.releaseLock();} const bytes = new Uint8Array(size); let offset = 0; for (const chunk of chunks) {bytes.set(chunk,offset); offset += chunk.length;} return bytes.buffer; }
    async text() { return new TextDecoder().decode(await this.arrayBuffer()); }
    async json() { return JSON.parse(await this.text()); }
    async blob() { const bytes = await this.arrayBuffer(); return {size:bytes.byteLength,type:this.headers.get('content-type') || '',arrayBuffer:async()=>bytes,text:async()=>new TextDecoder().decode(bytes)}; }
    clone() { if (this.bodyUsed || this.body.locked) throw new TypeError('Body consumed'); const [a,b] = this.body.tee(); this.body = a; return new Response(b,{status:this.status,statusText:this.statusText,headers:this.headers,url:this.url}); }
  }
  class Request {
    constructor(input, options = {}) { this.url = typeof input === 'string' ? input : input.url || input.href; this.method = options.method || input.method || 'GET'; this.headers = new Headers(options.headers || input.headers); this.body = options.body ?? input.body; }
    async text() { return this.body instanceof ReadableStream ? new Response(this.body).text() : String(this.body || ''); }
    async json() { return JSON.parse(await this.text()); }
    clone() { if (this.body instanceof ReadableStream) { const [a,b] = this.body.tee(); this.body = a; return new Request(this,{body:b}); } return new Request(this); }
  }
  function makeStorage(data, persistent) { const api = {
    get length() { return Object.keys(data).length; }, key(i) { return Object.keys(data)[i] ?? null; },
    getItem(k) { return Object.hasOwn(data, String(k)) ? data[String(k)] : null; },
    setItem(k,v) { k=String(k); v=String(v); data[k]=v; if (persistent) writes.push(call('storageSet',[k,v])); },
    removeItem(k) { k=String(k); delete data[k]; if (persistent) writes.push(call('storageRemove',[k])); },
    clear() { for (const k of Object.keys(data)) delete data[k]; if (persistent) writes.push(call('storageClear',[])); }
  }; return new Proxy(api, {get(target,key) { return key in target || typeof key !== 'string' ? target[key] : target.getItem(key) ?? undefined; }, set(target,key,value) { target.setItem(key,value); return true; }, deleteProperty(target,key) { target.removeItem(key); return true; }}); }
  async function baseFetch(input, options = {}) {
    const req = new Request(input, options);
    if (/^\/api\/settings\/get\b/.test(req.url)) return new Response(JSON.stringify({openai_setting_names:[presetName],openai_settings:[preset]}), {headers:{'content-type':'application/json'}});
    if (/^\/api\/backends\/[^/]+\/generate\b/.test(req.url)) {
      const current = flight;
      if (!current || current.captured) throw new Error('No pending generation');
      captured = JSON.parse(await req.text()); current.captured = captured;
      if (!hostInput.modelSupportsTools && captured.tools?.length) {
        ignoredTools = true; current.ignored = true;
        captured = {...copy(current.eventData),tools:[]}; delete captured.tool_choice;
      }
      current.ready(captured);
      return new Promise((resolve,reject)=>{current.wake = resolve; current.reject = reject;});
    }
    if (!/^https?:\/\//i.test(req.url)) throw new TypeError('Failed to fetch: unsupported URL');
    try { const r = await call('fetch', [{url:req.url, method:req.method, headers:req.headers.data, body:req.body == null ? null : String(req.body)}]); const bytes = Uint8Array.from(atob(r.base64), c=>c.charCodeAt(0)); return new Response(bytes, {url:r.url,status:r.status,headers:r.headers}); }
    catch (e) { throw new TypeError('Failed to fetch: ' + e); }
  }
  function beginEvaluation(active = false) { if (timerExpired) throw new Error("Preset timer evaluation expired"); timers.clear(); timerGeneration++; timerRunning = false; timerActive = active; }
  async function stopTimers() {
    acceptInitialTimers = false;
    const generation = timerGeneration, deadline = Date.now() + 2000;
    while (timerCallbacks.size && Date.now() < deadline) {
      await call('sleep', [Math.min(25, Math.max(0, deadline - Date.now()))]);
    }
    if (timerCallbacks.size) {
      for (const owner of new Set(timerCallbacks.values())) context.failed(owner);
      // A timed-out JavaScript continuation cannot be safely cancelled.
      // Retire this host rather than let it modify a later evaluation.
      timerExpired = true;
    }
    timers.clear(); timerGeneration++; timerActive = false;
    const active = timerLoop; timerLoop = null; timerRunning = false;
    if (active) { try { await active; } catch (_) {} }
    if (generation + 1 === timerGeneration) await flush();
  }
  function timer(fn, ms, repeat, args) {
    const id = ++timerId, delay = Math.max(0, Math.min(30000, Number(ms) || 0));
    if (!timerActive && !acceptInitialTimers) return id;
    timers.set(id, {fn, args, delay, owner:currentScript, due:Date.now()+delay, remaining:repeat ? 4 : 1});
    if (!timerActive || timerRunning) return id;
    const generation = timerGeneration;
    async function run() {
      if (timerRunning) return;
      timerRunning = true;
      try {
        while (generation === timerGeneration && timers.size) {
          const next = Math.min(...Array.from(timers.values(), t=>t.due));
          await call('sleep',[Math.max(0,Math.min(25,next-Date.now()))]);
          if (generation !== timerGeneration) return;
          const now = Date.now();
          for (const [key, entry] of [...timers]) {
            if (entry.due > now || !timers.has(key)) continue;
            if (--entry.remaining === 0) timers.delete(key);
            else entry.due = now + Math.max(1,entry.delay);
            try {
              const result = ownedSync(entry.owner, entry.fn, ...entry.args);
              if (result && typeof result.then === 'function') {
                const task = Promise.resolve(result);
                timerCallbacks.set(task, entry.owner);
                task.then(() => timerCallbacks.delete(task), () => {
                  timerCallbacks.delete(task);
                  if (generation === timerGeneration) context.failed(entry.owner);
                });
              }
            } catch (_) { context.failed(entry.owner); }
          }
        }
      } finally { if (generation === timerGeneration) { timerRunning = false; timerLoop = null; } }
    }
    timerLoop = run(); timerLoop.catch(()=>{}); return id;
  }
  async function refreshStorage() {
    const values = await call('storageSnapshot',[]);
    for (const key of Object.keys(storage)) delete storage[key];
    Object.assign(storage, values);
  }
  function on(event, fn, once = false, first = false) {
    if (typeof fn !== 'function') return;
    const list = listeners.get(event) || [], entry = {fn, once, owner:currentScript};
    if (first) list.unshift(entry); else list.push(entry);
    listeners.set(event,list); return fn;
  }
  async function emit(event, ...args) {
    for (const entry of [...(listeners.get(event) || [])]) {
      if (entry.once) off(event, entry.fn);
      try { await owned(entry.owner, entry.fn, ...args); } catch (_) { context.failed(entry.owner); }
    }
  }
  function off(event, fn) { listeners.set(event,(listeners.get(event)||[]).filter(x=>x.fn !== fn)); }
  function eventTarget(target) {
    const events = new Map();
    Object.assign(target, {
      addEventListener(type, fn, options = {}) {
        const list = events.get(type) || [];
        list.push({fn, owner:currentScript, once:!!options.once}); events.set(type, list);
      },
      removeEventListener(type, fn) { events.set(type,(events.get(type) || []).filter(e=>e.fn !== fn)); },
      dispatchEvent(event) {
        event.target = event.target || this; event.currentTarget = this;
        for (const entry of [...(events.get(event.type) || [])]) {
          if (entry.once) this.removeEventListener(event.type, entry.fn);
          try {
            const result = ownedSync(entry.owner, () => typeof entry.fn === 'function' ? entry.fn.call(this,event) : entry.fn.handleEvent(event));
            if (result?.then) writes.push(result.catch(()=>context.failed(entry.owner)));
          } catch (_) { context.failed(entry.owner); }
        }
        return !event.defaultPrevented;
      }
    });
    return target;
  }
  function insertedScript(child) {
    if (child.tagName !== 'SCRIPT') return;
    const owner = currentScript;
    const loaded = async () => {
      await child.onload?.(); child.dispatchEvent({type:'load'});
    };
    if (child.src) {
      const work = owned(owner, async () => {
        try {
          const response = await globalThis.fetch(child.src);
          if (!response.ok) throw new TypeError('Script fetch failed: ' + child.src);
          await evaluate(await response.text()); await loaded();
        } catch (error) {
          // A loader may deliberately install an onerror fallback.
          if (typeof child.onerror === 'function') await child.onerror(error);
          else context.failed(owner);
          child.dispatchEvent({type:'error', error});
        }
      });
      writes.push(work); return;
    }
    try {
      const result = ownedSync(owner, () => evaluate(child.text || child.textContent || child.innerHTML || ''));
      writes.push(Promise.resolve(result).then(()=>owned(owner,loaded)).catch(async error => {
        if (typeof child.onerror === 'function') await owned(owner,child.onerror,error); else context.failed(owner);
      }));
    } catch (error) {
      if (typeof child.onerror === 'function') child.onerror(error); else context.failed(owner);
    }
  }
  function element(tag = '') {
    const attributes = {}, classes = new Set(); let markup='';
    const node = eventTarget({tagName:String(tag).toUpperCase(), nodeType:1, style:{setProperty(k,v){this[k]=String(v);},getPropertyValue(k){return this[k] || '';},removeProperty(k){const v=this[k];delete this[k];return v;}}, dataset:{}, children:[], parentNode:null, textContent:'',
      get innerHTML() { return markup; },
      set innerHTML(value) {
        markup=String(value); for (const child of this.children) child.parentNode=null; this.children=[];
        const stack=[this], voidTags=new Set(['AREA','BASE','BR','COL','EMBED','HR','IMG','INPUT','LINK','META','PARAM','SOURCE','TRACK','WBR']);
        for (const token of markup.match(/<!--[\s\S]*?-->|<[^>]+>|[^<]+/g) || []) {
          if (token.startsWith('<!--')) continue;
          if (/^<\//.test(token)) { if (stack.length>1) stack.pop(); continue; }
          const match=token.match(/^<([\w-]+)/);
          if (!match) { stack.at(-1).textContent+=token; continue; }
          const child=element(match[1]), parent=stack.at(-1);
          for (const [,key,double,single,bare] of token.slice(match[0].length).matchAll(/([^\s=/>]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+)))?/g)) child.setAttribute(key,double ?? single ?? bare ?? '');
          parent.children.push(child); child.parentNode=parent;
          if (!voidTags.has(child.tagName) && !/\/\s*>$/.test(token)) stack.push(child);
        }
      },
      get parentElement() { return this.parentNode?.nodeType === 1 ? this.parentNode : null; },
      get childNodes() { return this.children; }, get firstChild() { return this.children[0] || null; }, get lastChild() { return this.children.at(-1) || null; },
      get nextSibling() { const list=this.parentNode?.children || []; return list[list.indexOf(this)+1] || null; },
      get previousSibling() { const list=this.parentNode?.children || []; return list[list.indexOf(this)-1] || null; },
      get className() { return [...classes].join(' '); }, set className(value) { classes.clear(); for (const c of String(value).split(/\s+/)) if (c) classes.add(c); },
      setAttribute(k,v) { v=String(v); attributes[k]=v; if (k === 'class') this.className=v; else this[k]=v; if (k.startsWith('data-')) this.dataset[k.slice(5).replace(/-([a-z])/g,(_,c)=>c.toUpperCase())]=v; },
      getAttribute(k) { if (k === 'class') return this.className || (Object.hasOwn(attributes,k) ? '' : null); return attributes[k] ?? (typeof this[k] === 'string' ? this[k] : null); },
      removeAttribute(k) { delete attributes[k]; if (k === 'class') this.className=''; else delete this[k]; },
      matches(selector) {
        return String(selector).split(',').some(part => {
          part=part.trim(); if (!part) return false;
          const attrs=[...part.matchAll(/\[([^=\]]+)(?:=["']?([^"'\]]*)["']?)?\]/g)];
          if (attrs.some(([,key,value])=>this.getAttribute(key) === null || value !== undefined && this.getAttribute(key) !== value)) return false;
          part=part.replace(/\[[^\]]*\]/g,'');
          const id=part.match(/#([\w-]+)/)?.[1]; if (id && this.id !== id) return false;
          if ([...part.matchAll(/\.([\w-]+)/g)].some(([,c])=>!classes.has(c))) return false;
          const name=part.match(/^[\w-]+/)?.[0]; return !name || this.tagName === name.toUpperCase();
        });
      },
      closest(selector) { for (let n=this;n;n=n.parentElement) if (n.matches(selector)) return n; return null; },
      contains(other) { for (let n=other;n;n=n.parentNode) if (n === this) return true; return false; },
      querySelectorAll(selector) {
        const parts=String(selector).trim().split(/\s+/), result=[];
        const walk=n=>{ for (const child of n.children || []) { if (child.matches?.(parts.at(-1))) { let ancestor=child.parentElement, i=parts.length-2; while (i>=0 && ancestor) { if (ancestor.matches(parts[i])) i--; ancestor=ancestor.parentElement; } if (i<0) result.push(child); } walk(child); } };
        walk(this); return result;
      },
      querySelector(selector) { return this.querySelectorAll(selector)[0] || null; },
      appendChild(child) { return this.insertBefore(child,null); },
      insertBefore(child, reference) {
        if (typeof child === 'string') child=document.createTextNode(child);
        if (reference !== null && !this.children.includes(reference)) throw new Error('Reference node is not a child');
        if (child === reference) return child;
        child.remove?.();
        const index=reference === null ? this.children.length : this.children.indexOf(reference);
        this.children.splice(index,0,child); child.parentNode=this; insertedScript(child); return child;
      },
      append(...children) { for (const child of children) this.appendChild(child); },
      prepend(...children) { const reference=this.firstChild; for (const child of children) this.insertBefore(child,reference); },
      removeChild(child) { const index=this.children.indexOf(child); if (index<0) throw new Error('Node is not a child'); this.children.splice(index,1); child.parentNode=null; return child; },
      replaceChild(child, old) { this.insertBefore(child,old); this.removeChild(old); return old; },
      remove() { this.parentNode?.removeChild(this); },
      before(...nodes) { for (const child of nodes) this.parentNode?.insertBefore(child,this); },
      after(...nodes) { const parent=this.parentNode, next=this.nextSibling; for (const child of nodes) parent?.insertBefore(child,next); },
      replaceWith(...nodes) { this.before(...nodes); this.remove(); },
      cloneNode(deep=false) { const result=element(this.tagName); for (const [k,v] of Object.entries(attributes)) result.setAttribute(k,v); result.className=this.className; for (const key of ['id','textContent','value','src','text','width','height']) if (this[key] !== undefined) result[key]=this[key]; Object.assign(result.style,this.style); Object.assign(result.dataset,this.dataset); if (deep) for (const child of this.children) { const cloned=child.cloneNode ? child.cloneNode(true) : {...child,parentNode:null}; result.children.push(cloned); cloned.parentNode=result; } return result; },
      getClientRects() { return []; },
      getBoundingClientRect() { return {x:0,y:0,top:0,left:0,right:0,bottom:0,width:0,height:0,toJSON(){return {x:0,y:0,width:0,height:0};}}; },
      click() { this.dispatchEvent({type:'click'}); }, focus(){}, blur(){},
    });
    node.classList={add(...values){for(const c of values) classes.add(c);},remove(...values){for(const c of values) classes.delete(c);},contains:c=>classes.has(c),toggle(c,force){const add=force ?? !classes.has(c); if(add) classes.add(c); else classes.delete(c); return add;}};
    if (node.tagName === 'CANVAS') {
      node.width=300; node.height=150;
      const ctx=new Proxy({canvas:node,measureText:text=>({width:String(text).length*8}),getImageData:(x,y,w,h)=>({data:new Uint8ClampedArray(w*h*4),width:w,height:h}),createImageData:(w,h)=>({data:new Uint8ClampedArray(w*h*4),width:w,height:h}),getLineDash:()=>[],createLinearGradient:()=>({addColorStop(){}}),createRadialGradient:()=>({addColorStop(){}})}, {get:(target,key)=>key in target ? target[key] : ()=>{}});
      node.getContext=type=>type === '2d' ? ctx : null; node.toDataURL=()=> 'data:image/png;base64,';
    }
    return node;
  }
  const body = element('body'), head = element('head'), root = element('html');
  root.append(head,body);
  const document = eventTarget({body,head,documentElement:root,readyState:'complete',createElement:element,createElementNS:(namespace,tag)=>element(tag),
    createTextNode(text) { return {nodeType:3,textContent:String(text),parentNode:null,remove(){this.parentNode?.removeChild(this);},cloneNode(){return document.createTextNode(this.textContent);}}; },
    querySelector:selector=>root.matches(selector) ? root : root.querySelector(selector),querySelectorAll:selector=>root.matches(selector) ? [root,...root.querySelectorAll(selector)] : root.querySelectorAll(selector),getElementById:id=>root.querySelector('#'+id)});
  document.defaultView = globalThis;
  function jquery(value) { if (typeof value === 'function') { value(); return jquery(); } const api = {length:0, on(){return this;}, off(){return this;}, ready(fn){fn();return this;}, append(){return this;}, prepend(){return this;}, remove(){return this;}, find(){return this;}, each(){return this;}, css(){return this;}, attr(){return this;}, text(){return this;}, html(){return this;}, val(){return this;}, hide(){return this;}, show(){return this;}, addClass(){return this;}, removeClass(){return this;}}; return api; }
  jquery.extend = Object.assign;
  function messageText(message) {
    if (typeof message.content === 'string') return message.content;
    return (Array.isArray(message.content) ? message.content : []).filter(p=>p?.type === 'text').map(p=>p.text || '').join('\n');
  }
  const floorRole = floor => floor.is_system ? 'system' : floor.is_user ? 'user' : 'assistant';
  function floorFrom(message) {
    const role=message.role || (message.is_user ? 'user' : message.is_system ? 'system' : 'assistant');
    const mes=message.message ?? message.mes ?? messageText(message);
    return {name:message.name || (role === 'user' ? hostInput.macros?.user : hostInput.macros?.char) || '',is_user:role === 'user',is_system:role === 'system',mes:String(mes),extra:copy(message.extra || {}),data:copy(message.data || {}),swipe_id:message.swipe_id || 0,swipes:copy(message.swipes || [String(mes)])};
  }
  function buildChat(messages) {
    chat.splice(0); chatSources.clear();
    const marked=messages.some(m=>Object.hasOwn(m,'__isHistory'));
    for (const message of messages) {
      if (marked ? message.__isHistory !== true : !['user','assistant'].includes(message.role)) continue;
      if (message.role === 'tool' || message.tool_calls?.length) continue;
      const floor=floorFrom(message); chat.push(floor);
      chatSources.set(floor,{message,mes:floor.mes,role:floorRole(floor)});
    }
  }
  function syncFloorMessage(floor) {
    const source=chatSources.get(floor); if (!source) return;
    const role=floorRole(floor);
    if (floor.mes !== source.mes || role !== source.role) { source.message.content=floor.mes; source.message.role=role; }
    for (const key of ['extra','data']) {
      if (JSON.stringify(floor[key]) !== JSON.stringify(source.message[key] || {})) source.message[key]=copy(floor[key]);
    }
  }
  function writeChat(messages) {
    const originals=new Set([...chatSources.values()].map(x=>x.message));
    const alive=new Set(chat.map(f=>chatSources.get(f)?.message).filter(Boolean));
    const floorMessage=floor=>{
      const source=chatSources.get(floor), role=floorRole(floor);
      if (!source) return {role,content:floor.mes,extra:copy(floor.extra),data:copy(floor.data)};
      syncFloorMessage(floor);
      return source.message;
    };
    const result=[]; let cursor=0, lastFloor=-1;
    // Use the original floor slots so prompt/tool records keep their positions.
    for (const message of messages) {
      if (!originals.has(message)) { result.push(message); continue; }
      if (!alive.has(message)) continue;
      while (cursor<chat.length && !chatSources.has(chat[cursor])) result.push(floorMessage(chat[cursor++]));
      if (cursor<chat.length) result.push(floorMessage(chat[cursor++]));
      lastFloor=result.length;
    }
    if (cursor<chat.length) result.splice(lastFloor<0 ? result.length : lastFloor,0,...chat.slice(cursor).map(floorMessage));
    messages.splice(0,messages.length,...result);
  }
  function floorIndex(value, fallback=chat.length-1) {
    if (value === undefined || value === null || value === 'latest') return fallback;
    const n=Number(value); return Number.isInteger(n) ? (n<0 ? chat.length+n : n) : -1;
  }
  function getChatMessages(range='0-{{lastMessageId}}', options={}) {
    let start=0, end=chat.length-1;
    if (typeof range === 'number' || /^-?\d+$/.test(String(range))) start=end=floorIndex(range);
    else if (Array.isArray(range)) { start=floorIndex(range[0],0); end=floorIndex(range[1]); }
    else {
      const value=String(range).replace(/\{\{(?:lastMessageId|currentMessageId)\}\}/g,String(chat.length-1));
      const match=value.match(/^(-?\d+)\s*-\s*(-?\d+)$/);
      if (match) { start=floorIndex(match[1],0); end=floorIndex(match[2]); }
    }
    const result=[];
    for (let i=Math.max(0,start);i<=Math.min(chat.length-1,end);i++) {
      const floor=chat[i], role=floorRole(floor);
      if (options.role && options.role !== 'all' && options.role !== role) continue;
      if (options.hide_state === 'hidden' && !floor.is_hidden || options.hide_state === 'unhidden' && floor.is_hidden) continue;
      result.push({message_id:i,name:floor.name,role,message:floor.mes,is_hidden:!!floor.is_hidden,extra:copy(floor.extra || {}),data:copy(floor.data || {}),swipe_id:floor.swipe_id || 0,swipes:copy(floor.swipes || [floor.mes])});
    }
    return result;
  }
  function setChatMessages(messages) {
    for (const update of messages || []) {
      const floor=chat[floorIndex(update.message_id ?? update.id)]; if (!floor) continue;
      if (update.message !== undefined || update.mes !== undefined) floor.mes=String(update.message ?? update.mes);
      if (update.role) { floor.is_user=update.role === 'user'; floor.is_system=update.role === 'system'; }
      if (update.name !== undefined) floor.name=update.name;
      for (const key of ['extra','data']) {
        if (update[key] === undefined) continue;
        floor[key]=copy(update[key]);
        const source=chatSources.get(floor); if (source) source.message[key]=copy(floor[key]);
      }
      if (update.is_hidden !== undefined) floor.is_hidden=!!update.is_hidden;
      if (update.swipes) floor.swipes=copy(update.swipes);
      if (update.swipe_id !== undefined) { floor.swipe_id=update.swipe_id; if (update.message === undefined && floor.swipes?.[floor.swipe_id] !== undefined) floor.mes=floor.swipes[floor.swipe_id]; }
      syncFloorMessage(floor);
    }
  }
  function createChatMessages(messages, options={}) {
    let index=options.insert_before === undefined || options.insert_before === 'end' ? chat.length : Math.max(0,floorIndex(options.insert_before));
    chat.splice(index,0,...(messages || []).map(floorFrom));
  }
  function deleteChatMessages(ids) { for (const index of [...new Set((ids || []).map(id=>floorIndex(id)))].sort((a,b)=>b-a)) if (index>=0 && index<chat.length) chat.splice(index,1); }
  function rotateChatMessages(begin, middle, end) {
    if (typeof begin === 'object') ({begin,middle,end}=begin);
    begin=floorIndex(begin,0); middle=floorIndex(middle); end=end === chat.length ? end : floorIndex(end);
    if (begin>=0 && begin<=middle && middle<=end && end<=chat.length) chat.splice(begin,end-begin,...chat.slice(middle,end),...chat.slice(begin,middle));
  }
  async function runInitialTimers() {
    const pending=[...timers.values()]; beginEvaluation(true);
    try {
    for (const entry of pending) {
      try { await owned(entry.owner,entry.fn,...entry.args); } catch (_) { context.failed(entry.owner); }
    }
    await flush();
    } finally { await stopTimers(); }
  }
  function registered() { return manager?.tools || []; }
  async function collectTools(candidates, existingTools, enabled) {
    activeTools.clear();
    const tools=[], businessTools=[], existingNames=new Set((existingTools || []).map(t=>t?.function?.name)), names=new Set();
    const entries=registered(), byName=new Map(entries.map(entry=>[entry.definition.name,entry]));
    for (const candidate of [...(candidates || []),...entries.map(entry=>entry.definition)]) {
      const d=candidate?.function || candidate, entry=byName.get(d?.name) || {definition:d,owner:currentScript};
      if (!d || existingNames.has(d.name) || names.has(d.name) || !/^[a-zA-Z0-9_-]{1,64}$/.test(d.name || '') || d.parameters?.type !== 'object') continue;
      names.add(d.name);
      try { if (typeof entry.definition.shouldRegister === 'function' && (await owned(entry.owner,()=>entry.definition.shouldRegister())) === false) continue; }
      catch (_) { context.failed(entry.owner); continue; }
      if (!enabled) { ignoredTools=true; continue; }
      if (entry.definition.stealth !== true && hostInput.toolsAllowed === false) continue;
      const schema={type:'function',function:{name:d.name,description:String(d.description || ''),parameters:copy(d.parameters)}};
      activeTools.set(d.name,entry);
      if (!existingNames.has(d.name)) (entry.definition.stealth === true ? tools : businessTools).push(schema);
    }
    await flush(); return {tools,businessTools};
  }
  function hasAction(name) { return typeof activeTools.get(name)?.definition.action === 'function'; }
  async function invokeAction(name, args) {
    const entry=activeTools.get(name);
    if (!entry || typeof entry.definition.action !== 'function') throw new Error('Unknown preset tool action: '+name);
    try { return await owned(entry.owner,()=>entry.definition.action(args || {})); }
    finally { await flush(); }
  }
  async function action(name, args) {
    beginEvaluation(true);
    try {
      const result=await invokeAction(name,args);
      return typeof result === 'string' ? result : JSON.stringify(result ?? '');
    } finally { await stopTimers(); }
  }
  const eventNames = ['GENERATION_AFTER_COMMANDS','GENERATION_STARTED','CHAT_COMPLETION_SETTINGS_READY','GENERATE_AFTER_DATA','CHAT_COMPLETION_PROMPT_READY','MESSAGE_RECEIVED','CHARACTER_MESSAGE_RENDERED','GENERATION_ENDED'];
  function install(input, failed) {
    storage = {...input.storage}; session = {}; listeners = new Map(); writes = []; context = {failed}; beginEvaluation();
    hostInput={...input,regexes:copy(input.regexes || input.extensions?.regex_scripts || [])}; chat=[]; chatSources.clear(); activeTools.clear(); responseCache.clear(); actionCache.clear(); scriptInfo.clear(); modules.clear();
    preset={...copy(input.preset || {}),prompts:copy(input.prompts || input.preset?.prompts || []),extensions:copy(input.extensions || input.preset?.extensions || {})};
    presetName=input.presetName || input.name || ''; streamingProcessor={isFinished:true,isStopped:false,abortController:{signal:{aborted:false}}}; executedScripts=false;
    const eventTypes = new Proxy(Object.fromEntries(eventNames.map(x=>[x,x])), {get:(target,key)=>target[key] ?? key});
    const random = input.random?.length ? input.random : [73,129,37,251]; let randomOffset = 0;
    context.randomOffset = value => value === undefined ? randomOffset : (randomOffset = value);
    manager = {tools:[], registerFunctionTool(tool) {
      const definition=tool?.function || tool;
      if (!input.modelSupportsTools) ignoredTools = true;
      this.unregisterFunctionTool(definition.name);
      this.tools.push({...definition,definition,owner:currentScript,toFunctionOpenAI:()=>({type:'function',function:definition})});
    }, unregisterFunctionTool(name) { this.tools=this.tools.filter(t=>t.definition.name!==name); }, isToolCallingSupported:()=>!!input.modelSupportsTools};
    ignoredTools = false;
    const randomValues = array => { const bytes = new Uint8Array(array.buffer, array.byteOffset, array.byteLength); for (let i=0;i<bytes.length;i++) bytes[i] = random[(randomOffset++) % random.length]; return array; };
    Math.random = () => {const bytes = randomValues(new Uint8Array(4)); return ((bytes[0]*16777216 + bytes[1]*65536 + bytes[2]*256 + bytes[3]) >>> 0) / 4294967296;};
    const registerFunctionTool = tool => manager.registerFunctionTool(tool);
    const unregisterFunctionTool = name => manager.unregisterFunctionTool(name);
    const variableStores=new Map(), macros=new Map(), injections=new Map(), buttons=new Map(), worlds=new Map();
    const variableKey=options=>{ const type=typeof options === 'string' ? options : options?.type; return type === 'script' ? 'script:'+(options?.script_id || currentScript) : type === 'extension' ? 'extension:'+(options?.extension_id || '') : type === 'message' ? 'message:'+(options?.message_id ?? '') : ['preset','global','chat','character'].includes(type) ? type : 'chat'; };
    const isScope=value=>typeof value === 'string' && ['preset','global','chat','script','character','extension','message'].includes(value) || !!value && typeof value === 'object' && !Array.isArray(value) && typeof value.type === 'string' && Object.keys(value).every(k=>['type','script_id','extension_id','message_id'].includes(k));
    const helperMetadata=Array.isArray(preset.extensions?.tavern_helper) ? Object.fromEntries(preset.extensions.tavern_helper) : preset.extensions?.tavern_helper;
    const presetVars=helperMetadata?.variables || {};
    variableStores.set('preset',copy(Array.isArray(presetVars) ? Object.fromEntries(presetVars) : presetVars));
    context.variableStores=variableStores;
    variableStores.set('chat',copy(input.variables || {}));
    const vars=options=>{ const key=variableKey(options); if (!variableStores.has(key)) variableStores.set(key,{}); return variableStores.get(key); };
    const replaceObject=(target,value)=>{ for(const k of Object.keys(target)) delete target[k]; Object.assign(target,value || {}); return target; };
    const substitute=value=>{
      let text=String(value ?? '').replace(/{{(lastMessageId|currentMessageId)}}/g,(_,key)=>String(key === 'currentMessageId' ? Math.max(0,chat.length-1) : chat.length-1));
      text=text.replace(/{{([^{}]+)}}/g,(full,key)=>{
        if (macros.has(key)) { const entry=macros.get(key); return ownedSync(entry.owner,entry.fn); }
        return input.macros?.[key.toLowerCase()] ?? vars()[key] ?? full;
      }); return text;
    };
    const info=()=>scriptInfo.get(currentScript) || {id:currentScript,name:currentScript};
    const worldName=name=>typeof name === 'string' ? name : name?.name || '';
    const promptId = prompt => typeof prompt === 'string' ? prompt : prompt?.id ?? prompt?.identifier ?? '';
    const normalizedPromptId = prompt => String(promptId(prompt)).replace(/_/g,'').toLowerCase();
    const placeholderIds = new Set(['worldinfobefore','worldinfoafter','chardescription','charpersonality','scenario','personadescription','dialogueexamples','chathistory']);
    const systemIds = new Set(['main','nsfw','jailbreak','enhancedefinitions']);
    const isPresetPlaceholderPrompt = prompt => !!(prompt?.marker || placeholderIds.has(normalizedPromptId(prompt)));
    const isPresetSystemPrompt = prompt => !isPresetPlaceholderPrompt(prompt) && !!(prompt?.system_prompt || systemIds.has(normalizedPromptId(prompt)));
    const helper={
      isPresetPlaceholderPrompt,isPresetSystemPrompt,isPresetNormalPrompt:prompt=>!isPresetPlaceholderPrompt(prompt) && !isPresetSystemPrompt(prompt),
      errorCatched:fn=>{ const owner=currentScript; return function(...args) { try { const result=ownedSync(owner,()=>fn.apply(this,args)); return result?.then ? Promise.resolve(result).catch(()=>undefined) : result; } catch (_) { return undefined; } }; },
      getPreset:()=>copy(preset),getLoadedPresetName:()=>presetName,getPresetNames:()=>[presetName],
      replacePreset:(name,value)=>{ preset=copy(value === undefined ? name : value); },setPreset:name=>{ presetName=String(name); },
      updatePresetWith:async (name,updater)=>{ updater=updater || name; const draft=copy(preset); preset=copy(await updater(draft) ?? draft); return copy(preset); },
      getVariables:options=>copy(vars(options)),getAllVariables:()=>Object.fromEntries([...variableStores].map(([key,value])=>[key,copy(value)])),
      replaceVariables:(value,options)=>{ if (isScope(value) && !isScope(options)) [value,options]=[options,value]; return replaceObject(vars(options),copy(value)); },
      insertOrAssignVariables:(value,options)=>Object.assign(vars(options),copy(value)),
      insertVariables:(value,options)=>{ const target=vars(options); for(const [k,v] of Object.entries(value || {})) if(!Object.hasOwn(target,k)) target[k]=copy(v); return copy(target); },
      updateVariablesWith:async (updater,options)=>{ if (typeof updater !== 'function') [updater,options]=[options,updater]; const target=vars(options), draft=copy(target), value=await updater(draft); replaceObject(target,value ?? draft); return copy(target); },
      deleteVariable:(key,options)=>delete vars(options)[key],
      injectPrompts:prompts=>{ for(const prompt of prompts || []) injections.set(prompt.id || prompt.identifier,{...copy(prompt),owner:currentScript}); return {uninject(){for(const p of prompts || []) injections.delete(p.id || p.identifier);}}; },
      uninjectPrompts:ids=>{ for(const id of ids || []) injections.delete(id); },
      registerMacroLike:(name,fn)=>macros.set(name,{fn,owner:currentScript}),unregisterMacroLike:name=>macros.delete(name),
      substitudeMacros:substitute,substituteMacros:substitute,substituteParams:substitute,substituteParamsExtended:substitute,
      triggerSlash:async()=>'',triggerSlashWithResult:async()=>({pipe:'',isError:false}),
      generate:async()=>'',generateRaw:async()=>'',stopGenerationById:()=>{streamingProcessor.isFinished=true;streamingProcessor.isStopped=true;streamingProcessor.abortController.signal.aborted=true;},stopAllGeneration:()=>{streamingProcessor.isFinished=true;streamingProcessor.isStopped=true;streamingProcessor.abortController.signal.aborted=true;},
      getTavernHelperVersion:()=> '4.11.3',getTavernVersion:()=> '1.19.0',
      getScriptButtons:()=>copy(buttons.get(currentScript) || []),replaceScriptButtons:value=>buttons.set(currentScript,copy(value)),
      appendInexistentScriptButtons:value=>{ const list=buttons.get(currentScript) || []; for(const button of value || []) if(!list.some(b=>b.name === button.name)) list.push(copy(button)); buttons.set(currentScript,list); },
      updateScriptButtonsWith:async updater=>{ const owner=currentScript, draft=copy(buttons.get(owner) || []); const value=await updater(draft); buttons.set(owner,copy(value ?? draft)); },
      getButtonEvent:name=>'button_'+name,getScriptId:()=>currentScript,getScriptName:()=>info().name || currentScript,getScriptInfo:()=>copy(info()),replaceScriptInfo:value=>scriptInfo.set(currentScript,copy(value)),
      eventMakeFirst:(e,f)=>{off(e,f);return on(e,f,false,true);},eventEmitAndWait:emit,eventOnButton:(name,fn)=>on('button_'+name,fn),eventClearEvent:e=>listeners.delete(e),eventClearListener:fn=>{for(const event of listeners.keys()) off(event,fn);},
      getWorldbookNames:()=>[...worlds.keys()],getGlobalWorldbookNames:()=>copy(input.globalWorldbooks || []),getCharWorldbookNames:()=>copy(input.charWorldbooks || {primary:null,additional:[]}),getChatWorldbookName:()=>input.chatWorldbookName || null,
      getWorldbook:name=>copy(worlds.get(worldName(name)) || []),replaceWorldbook:(name,value)=>worlds.set(worldName(name),copy(value)),
      updateWorldbookWith:async (name,updater)=>{ const key=worldName(name), draft=copy(worlds.get(key) || []), value=await updater(draft); worlds.set(key,copy(value ?? draft)); return copy(worlds.get(key) || []); },
      getLorebooks:()=>[...worlds.keys()],getLorebookEntries:name=>copy(worlds.get(worldName(name)) || []),setLorebookEntries:(name,value)=>worlds.set(worldName(name),copy(value)),
      getTavernRegexes:()=>copy(hostInput.regexes || []),replaceTavernRegexes:value=>{hostInput.regexes=copy(value);},
      updateTavernRegexesWith:async updater=>{const draft=copy(hostInput.regexes || []); hostInput.regexes=copy(await updater(draft) ?? draft);},
      formatAsTavernRegexedString:(value,placement,options={})=>{
        let text=String(value);
        for (const regex of hostInput.regexes || []) {
          if (regex.disabled || regex.enabled === false) continue;
          if (Array.isArray(regex.placement) && typeof placement === 'number' && !regex.placement.includes(placement)) continue;
          if (regex.markdownOnly && !options.is_display || regex.promptOnly && options.is_display) continue;
          const pattern=regex.findRegex || regex.find_regex; if (!pattern) continue;
          try { const literal=String(pattern).match(/^\/(.*)\/([a-z]*)$/s); text=text.replace(literal ? new RegExp(literal[1],literal[2]) : new RegExp(pattern,'g'),regex.replaceString ?? regex.replace_string ?? ''); } catch (_) {}
        }
        return text;
      },isCharacterTavernRegexesEnabled:()=>input.characterRegexesEnabled !== false,
      registerFunctionTool,unregisterFunctionTool,getChatMessages,setChatMessages,createChatMessages,deleteChatMessages,rotateChatMessages,
      getLastMessageId:()=>chat.length-1,getCurrentMessageId:()=>Math.max(0,chat.length-1),
      builtin:{addOneMessage(){},retrieveRawLastMessage:()=>chat.at(-1)?.mes || '',promptQuietForLoud:async()=>''},
    };
    for (const [name,entries] of Object.entries(input.worldbooks || {})) worlds.set(name,copy(entries));
    const tavernContext={canPerformToolCalls:type=>!!input.modelSupportsTools && preset.function_calling !== false && (!type || ['normal','continue','regenerate','impersonate','swipe'].includes(String(type))),mainApi:'openai',getRequestHeaders:()=>({'Content-Type':'application/json'}),
      getPresetManager:()=>({getSelectedPresetName:()=>presetName,getSelectedPreset:()=>presetName,getCompletionPresetByName:()=>copy(preset),getPresetList:()=>({preset_names:[presetName],presets:[copy(preset)]}),savePreset:async(n,c)=>{if(n)presetName=String(n);if(c&&typeof c==='object')preset=copy(c);}}),
      getChatCompletionPromptManager:()=>({setChatCompletionSettings(p){if(p&&typeof p==='object')preset=copy(p);},render(){}}),name1:input.macros?.user || '',name2:input.macros?.char || '',chat,
      chatId:input.chatId || ('chat_'+(input.presetName || 'default')),streamingProcessor,
      characterId:0,characters:[{name:input.macros?.char || 'Assistant',avatar:'default.png'}],groupId:null,
      getCurrentChatId:()=>input.chatId || ('chat_'+(input.presetName || 'default')),
      get chatCompletionSettings(){return {...preset,prompts:preset.prompts || [],extensions:preset.extensions || {},chat_completion_source:'openai'};},
      eventSource:{on,once:(e,f)=>on(e,f,true),emit,removeListener:off},eventTypes,ToolManager:manager,registerFunctionTool,unregisterFunctionTool,
      saveChat:async()=>{},saveChatConditional:async()=>{},saveSettingsDebounced(){},substituteParams:substitute,substituteParamsExtended:substitute,
    };
    Object.assign(globalThis, {window:globalThis,self:globalThis,parent:globalThis,top:globalThis,document,frameElement:{parentElement:body},location:new URL('http://localhost/'),performance:{now:()=>Date.now()},navigator:{userAgent:'AIcove'},URL,URLSearchParams,localStorage:makeStorage(storage,true),sessionStorage:makeStorage(session,false),fetch:baseFetch,Headers,Request,Response,ReadableStream,TransformStream,TextEncoder,TextDecoder,atob,btoa,structuredClone:copy,
      setTimeout:(fn,ms,...args)=>timer(fn,ms,false,args),clearTimeout:id=>timers.delete(id),requestAnimationFrame:fn=>timer(()=>fn(Date.now()),16,false,[]),cancelAnimationFrame:id=>timers.delete(id),setInterval:(fn,ms,...args)=>timer(fn,ms,true,args),clearInterval:id=>timers.delete(id),
      eventOn:(e,f)=>on(e,f),eventOnce:(e,f)=>on(e,f,true),eventMakeLast:(e,f)=>{off(e,f);return on(e,f);},eventRemoveListener:off,eventOff:off,eventEmit:emit,eventClearAll:e=>e ? listeners.delete(e) : listeners.clear(),
      tavern_events:eventTypes,event_types:eventTypes, $:jquery,jQuery:jquery, MutationObserver:class {observe(){} disconnect(){} takeRecords(){return [];}}, Event:class {constructor(type){this.type=type;}}, CustomEvent:class {constructor(type,options={}){this.type=type;this.detail=options.detail;}}, toastr:{info(){},success(){},warning(){},error(){}},
      crypto:{getRandomValues:randomValues,randomUUID(){const bytes=randomValues(new Uint8Array(16)); bytes[6]=(bytes[6]&15)|64; bytes[8]=(bytes[8]&63)|128; const h=Array.from(bytes,b=>b.toString(16).padStart(2,'0')).join(''); return h.slice(0,8)+'-'+h.slice(8,12)+'-'+h.slice(12,16)+'-'+h.slice(16,20)+'-'+h.slice(20);}},
      SillyTavern:{...tavernContext,getContext:()=>tavernContext,extensionSettings:preset.extensions || {},ToolManager:manager,registerFunctionTool,unregisterFunctionTool},
      ToolManager:manager,registerFunctionTool,unregisterFunctionTool,
      ...helper,TavernHelper:helper,getContext:()=>tavernContext,__presetImport:importScript,
    });
    eventTarget(globalThis);
    if (Array.isArray(input.chat)) chat.push(...copy(input.chat));
    context.injections=injections;

  }
  async function runScripts(scripts) {
    for (let i=0;i<(scripts || []).length;i++) {
      const script=scripts[i]; if (script.enabled === false) continue;
      const owner=String(script.id || script.name || i+1);
      if (String(script.content || '').trim()) executedScripts=true;
      scriptInfo.set(owner,{...copy(script),id:owner,name:script.name || owner});
      if (script.data && typeof script.data === 'object') context.variableStores.set('script:'+owner,copy(script.data));
      try { await owned(owner,()=>evaluate(String(script.content || ''))); await flush(); }
      catch (_) { context.failed(script.name || owner); }
    }
  }
  function beginRound(messages) {
    buildChat(messages); streamingProcessor.isFinished=false; streamingProcessor.isStopped=false; streamingProcessor.abortController.signal.aborted=false;
    responseCache.clear(); actionCache.clear(); activeTools.clear();
  }
  async function cancelFlight() {
    if (!flight) return;
    const old = flight; flight = null; old.cancelled = true;
    old.upstream?.controller.close(); old.reject?.(new Error('Generation replaced'));
    if (old.reader) await old.reader.cancel('Generation replaced');
    await old.pump?.catch(()=>{});
  }
  async function prepareCustom(messages, existingTools, replay = false) {
    await cancelFlight(); await refreshStorage(); beginRound(messages);
    // Floor extraction needs the private provenance marker; scripts and wire do not.
    for (const message of messages) delete message.__isHistory;
    await runInitialTimers();
    if (replay && roundListeners) listeners = new Map([...roundListeners].map(([event,entries])=>[event,[...entries]]));
    else roundListeners = new Map([...listeners].map(([event,entries])=>[event,[...entries]]));
    beginEvaluation(true);
    try {
      await emit('GENERATION_STARTED','normal',{automatic_trigger:false},false);
      await emit('GENERATION_AFTER_COMMANDS','normal',{},false);
      const collected = await collectTools([],existingTools,!!hostInput.modelSupportsTools && preset.function_calling !== false);
      const data = {messages,type:'normal',stream:true,chat_completion_source:'openai',custom_prompt_post_processing:preset.custom_prompt_post_processing || ''};
      const allTools = [...existingTools,...collected.tools,...collected.businessTools];
      if (allTools.length) {data.tools = allTools; data.tool_choice = hostInput.callerToolChoice || 'auto';}
      if (hostInput.callerToolChoice != null) data.tool_choice = hostInput.callerToolChoice;
      await emit('GENERATE_AFTER_DATA',data,false);
      const prompt = {chat:data.messages,dryRun:false}; await emit('CHAT_COMPLETION_PROMPT_READY',prompt);
      if (Array.isArray(prompt.chat)) data.messages = prompt.chat;
      writeChat(data.messages);
      for (const prompt of context.injections.values()) {
        if (prompt.enabled === false || prompt.position === 'none' || prompt.position?.type === 'none') continue;
        const depth = Number(prompt.depth ?? prompt.position?.depth), index = Number.isFinite(depth) ? Math.max(0,data.messages.length-depth) : data.messages.length;
        data.messages.splice(index,0,{role:prompt.role || 'system',content:globalThis.substitudeMacros(prompt.content || '')});
      }
      const current = {eventData:copy(data),text:'',calls:[],sentText:'',sentCalls:new Map(),cancelled:false,started:false};
      const ready = new Promise((resolve,reject)=>{current.ready = resolve; current.fail = reject;}); flight = current;
      await emit('CHAT_COMPLETION_SETTINGS_READY',data);
      current.eventData = copy(data);
      // No mutation is permitted between SETTINGS_READY and serialization.
      current.fetchPromise = Promise.resolve(globalThis.fetch('/api/backends/chat-completions/generate',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(data)}));
      current.fetchPromise.catch(error=>{if (!current.cancelled) {current.error = error; current.fail(error);}});
      const request = await ready; await flush(); return request;
    } finally { await stopTimers(); }
  }
  function parseResponseObject(current, object) {
    for (const choice of object.choices || []) {
      if ((choice.index || 0) !== 0) continue;
      const delta = choice.delta || choice.message || {};
      if (typeof delta.content === 'string') current.text += delta.content;
      for (let i=0;i<(delta.tool_calls || []).length;i++) {
        const call = delta.tool_calls[i], index = call.index ?? i;
        const target = current.calls[index] || (current.calls[index] = {id:'',name:'',rawArguments:''});
        if (call.id) target.id += call.id;
        if (call.function?.name) target.name += call.function.name;
        if (call.function?.arguments) target.rawArguments += call.function.arguments;
      }
    }
  }
  async function readResponse(current) {
    const response = await current.fetchPromise;
    const decoder = new TextDecoder(); let buffer = '';
    const sse = /text\/event-stream/i.test(response.headers.get('content-type') || '');
    const consume = final => {
      if (!sse) {if (final && buffer.trim()) parseResponseObject(current,JSON.parse(buffer)); return;}
      buffer = buffer.replace(/\r\n/g,'\n');
      let index;
      while ((index = buffer.indexOf('\n\n')) >= 0) {
        const event = buffer.slice(0,index); buffer = buffer.slice(index+2);
        const payload = event.split('\n').filter(line=>line.startsWith('data:')).map(line=>line.slice(5).trimStart()).join('\n');
        if (payload && payload.trim() !== '[DONE]') parseResponseObject(current,JSON.parse(payload));
      }
      if (final && buffer.trim()) {buffer += '\n\n'; consume(false);}
    };
    current.reader = response.body.getReader();
    try {while (true) {const r = await current.reader.read(); if (r.done) break; buffer += typeof r.value === 'string' ? r.value : decoder.decode(r.value,{stream:true}); consume(false);} buffer += decoder.decode(); consume(true);}
    finally {current.reader.releaseLock(); current.reader = null;}
  }
  function startResponse(current) {
    if (current.started) return;
    current.started = true; current.upstream = new ReadableStream();
    current.wake(new Response(current.upstream,{status:200,headers:{'content-type':'text/event-stream'}}));
    current.pump = readResponse(current); current.pump.catch(error=>{current.error = error;});
  }
  function enqueue(current, payload) { current.upstream.controller.enqueue(new TextEncoder().encode('data: '+(typeof payload === 'string' ? payload : JSON.stringify(payload))+'\n\n')); }
  async function feedResponse(text, calls, final = false) {
    const current = flight;
    if (!current) return {text:String(text || ''),calls};
    if (current.captured?.stream === false) {
      if (!final) return {text:'',calls:[]};
      current.started = true;
      current.wake(new Response(JSON.stringify({choices:[{index:0,message:{role:'assistant',content:String(text || ''),tool_calls:calls.map(c=>({id:c.id,type:'function',function:{name:c.name,arguments:c.rawArguments ?? JSON.stringify(c.arguments || {})}}))},finish_reason:calls.length ? 'tool_calls' : 'stop'}]}),{headers:{'content-type':'application/json'}}));
      current.pump = readResponse(current); await current.pump;
      return {text:current.text,calls:current.calls.filter(Boolean)};
    }
    startResponse(current);
    text = String(text || ''); const delta = {};
    if (text.length > current.sentText.length) delta.content = text.slice(current.sentText.length);
    current.sentText = text;
    const changed = [];
    const occurrences = new Map();
    for (let i=0;i<calls.length;i++) {
      const call = calls[i], identity = call.id || call.name || String(i);
      const occurrence = occurrences.get(identity) || 0; occurrences.set(identity,occurrence+1);
      const key = identity+':'+occurrence;
      const previous = current.sentCalls.get(key) || {index:current.sentCalls.size,id:'',name:'',raw:''};
      let raw = call.rawArguments ?? call.arguments?._raw ?? JSON.stringify(call.arguments || {});
      if (!final && call.rawArguments == null && !call.arguments?._raw) {
        // Object-valued provider snapshots close their JSON on every update.
        // Only a leading string has a stable cumulative prefix. Hold later
        // fields (and objects beginning with other value types) until final.
        const firstValue = /^\s*\{\s*"(?:\\.|[^"\\])*"\s*:\s*("(?:\\.|[^"\\])*")/.exec(raw);
        raw = firstValue ? raw.slice(0,firstValue[0].length-1) : '';
      }
      const next = {index:previous.index,type:'function',function:{}};
      if (call.id && call.id !== previous.id) next.id = String(call.id).slice(previous.id.length);
      if (call.name && call.name !== previous.name) next.function.name = call.name.slice(previous.name.length);
      if (!raw.startsWith(previous.raw)) throw new Error('Tool arguments must extend the previous streamed JSON prefix');
      if (raw.length > previous.raw.length) next.function.arguments = raw.slice(previous.raw.length);
      if (next.id || Object.keys(next.function).length) changed.push(next);
      current.sentCalls.set(key,{index:previous.index,id:call.id || '',name:call.name || '',raw});
    }
    if (changed.length) delta.tool_calls = changed;
    if (Object.keys(delta).length) enqueue(current,{choices:[{index:0,delta,finish_reason:null}]});
    if (final) {
      enqueue(current,{choices:[{index:0,delta:{},finish_reason:calls.length ? 'tool_calls' : 'stop'}]}); enqueue(current,'[DONE]'); current.upstream.controller.close();
      await current.pump;
    } else {
      // Settle the in-memory fetch/transform/read chain without closing its stream.
      for (let i=0;i<128;i++) await Promise.resolve();
    }
    if (current.error) throw current.error;
    return {text:current.text,calls:current.calls.filter(Boolean)};
  }
  async function completeResponse(text, calls, selected) {
    const key=JSON.stringify({text,calls});
    if (responseCache.has(key)) return responseCache.get(key);
    const work=(async()=>{
      beginEvaluation(true);
      try {
      let result=selected;

      const consumed=new Set(result.consumedIndexes);
      const before=chat.length, previousMessages=new Map(chat.map(f=>[f,f.mes]));
      let output=String(result.text || '');
      for (let i=0;i<calls.length;i++) {
        const entry=activeTools.get(calls[i].name);
        if (!entry || entry.definition.stealth !== true) continue;
        consumed.add(i);
        if (!hasAction(calls[i].name)) continue;
        const callKey=JSON.stringify([calls[i].id ?? i,calls[i].name,calls[i].arguments ?? calls[i].rawArguments]);
        if (!actionCache.has(callKey)) {
          actionCache.set(callKey,(async()=>{
            let args=calls[i].arguments;
            if (!args || typeof args !== 'object' || Object.hasOwn(args,'_raw')) {
              try { args=JSON.parse(calls[i].rawArguments ?? args?._raw ?? '{}'); } catch (_) { args={}; }
            }
            return invokeAction(calls[i].name,args);
          })());
        }
        try {
          const value=await actionCache.get(callKey);
          if (typeof value === 'string' && value) output=value;
        } catch (_) { context.failed(entry.owner); }
      }
      const created=chat.slice(before).filter(f=>floorRole(f) === 'assistant');
      let floor=created.at(-1);
      if (floor) output=floor.mes;
      else {
        // Actions may edit an existing assistant floor instead of appending one.
        floor=chat.findLast(f=>floorRole(f) === 'assistant' && previousMessages.has(f) && f.mes !== previousMessages.get(f));
        if (floor) output=floor.mes;
        else { floor=floorFrom({role:'assistant',content:output}); chat.push(floor); }
      }
      floor.mes=output;
      streamingProcessor.isFinished=true;
      const id=chat.indexOf(floor);
      await emit('MESSAGE_RECEIVED',id,'normal');
      await emit('CHARACTER_MESSAGE_RENDERED',id,'normal');
      await emit('GENERATION_ENDED',id);
      await flush();
      output=chat.findLast(f=>floorRole(f) === 'assistant')?.mes || '';
      return {text:output,consumedIndexes:[...consumed].sort((a,b)=>a-b)};
      } finally { await stopTimers(); }
    })();
    responseCache.set(key,work); return work;
  }
  return {install,runScripts,prepareCustom,collectTools,hasAction,action,completeResponse,feedResponse,cancelFlight,
    randomOffset:value=>context.randomOffset(value),hasFetchOverride:()=>globalThis.fetch !== baseFetch,
    hasScripts:()=>executedScripts,flush,hasIgnoredTools:()=>ignoredTools,registered,
    timerExpired:()=>timerExpired};
})();

// The bridge classifies the final captured wire request, never preset identities.
globalThis.__transport = (() => {
  let input = {}, tools = [], businessTools = [], diagnostics = [], baseDiagnostics = [], toolChoice = null;
  let savedMessages = null, savedClientTools = [], savedRoundTools = [], savedOffset = 0, consumed = false, finalCache = new Map(), roundState = null;
  const clone = value => JSON.parse(JSON.stringify(value));
  const nameOf = tool => tool?.function?.name;
  const failed = owner => {const value = 'custom_script_failed:'+(owner || 'unknown'); if (!baseDiagnostics.includes(value)) baseDiagnostics.push(value); if (!diagnostics.includes(value)) diagnostics.push(value);};
  function readString(call, schema) {
    const fields = schema?.function?.parameters?.properties || {};
    const keys = ['content','text','manuscript','buffer_content','payload','output','response','answer',...(schema?.function?.parameters?.required || []),...Object.keys(fields)];
    const key = keys.find(k=>fields[k]?.type === 'string') || keys.find(k=>typeof call.arguments?.[k] === 'string');
    if (!key) return '';
    if (typeof call.arguments?.[key] === 'string') return call.arguments[key];
    const raw = call.rawArguments ?? call.arguments?._raw;
    if (typeof raw !== 'string') return '';
    try {const value = JSON.parse(raw); return typeof value[key] === 'string' ? value[key] : '';} catch (_) {}
    // Recover a partial JSON string while holding incomplete escapes/surrogates.
    const pattern = new RegExp('"'+key.replace(/[.*+?^${}()|[\]\\]/g,'\\$&')+'"\\s*:\\s*"','g');
    const match = pattern.exec(raw); if (!match) return '';
    let out = '', cursor = match.index+match[0].length;
    for (;cursor<raw.length;cursor++) {
      const ch = raw[cursor]; if (ch === '"') break;
      if (ch !== '\\') {out += ch; continue;}
      if (++cursor>=raw.length) break;
      if (raw[cursor] === 'u') {const hex = raw.slice(cursor+1,cursor+5); if (!/^[0-9a-f]{4}$/i.test(hex)) break; out += String.fromCharCode(parseInt(hex,16)); cursor += 4;}
      else {const escapes = {'"':'"','\\':'\\','/':'/',n:'\n',r:'\r',t:'\t',b:'\b',f:'\f'}; if (!Object.hasOwn(escapes,raw[cursor])) break; out += escapes[raw[cursor]];}
    }
    return out.replace(/[\uD800-\uDBFF]$/,'');
  }
  function previewFallback(text, calls) {
    if (text) return text;
    const previewTools = [...tools,...savedRoundTools];
    return calls.map(call=>{const schema = previewTools.find(t=>nameOf(t) === call.name); return schema ? readString(call,schema) : '';}).filter(Boolean).join('\n');
  }
  async function prepare(messages, clientTools = [], roundTools = [], replay = false) {
    if (!replay) {
      savedMessages = clone(messages); savedClientTools = clone(clientTools); savedRoundTools = clone(roundTools);
      savedOffset = __presetHost.randomOffset();
    } else __presetHost.randomOffset(savedOffset);
    consumed = false; finalCache.clear(); diagnostics = [...baseDiagnostics]; tools = []; businessTools = [];
    const modelCapable = !!input.modelSupportsTools;
    const businessCapable = modelCapable && input.toolsAllowed !== false;
    const allowedRoundTools = businessCapable && input.preset?.function_calling !== false ? roundTools : [];
    const clients = businessCapable ? clientTools : [];
    const request = await __presetHost.prepareCustom(clone(messages),[...clients,...allowedRoundTools],replay);
    const clientNames = new Set(clientTools.map(nameOf));
    const roundNames = new Set(allowedRoundTools.map(nameOf));
    const active = new Map(__presetHost.registered().map(entry=>[entry.definition.name,entry.definition]));
    const unique = new Set();
    for (const tool of request.tools || []) {
      const name = nameOf(tool); if (!name || clientNames.has(name) || unique.has(name) || !modelCapable) continue;
      unique.add(name); const entry = active.get(name);
      if (roundNames.has(name) || entry && entry.stealth !== true && typeof entry.action === 'function' && input.toolsAllowed !== false && __presetHost.hasAction(name)) businessTools.push(tool);
      else tools.push(tool);
    }
    toolChoice = typeof request.tool_choice === 'string' ? request.tool_choice : tools.length ? 'auto' : null;
    if (__presetHost.hasIgnoredTools()) diagnostics.push('custom_script_tools_ignored');
    if (!modelCapable) diagnostics.push('transport_skipped_model_without_tools');
    if (replay && roundState) {
      // Recovery still sends the original prepared model request. Keep its
      // classifications authoritative even if a script has one-shot state.
      const originalBusiness = new Set(roundState.businessTools.map(nameOf));
      const wire = new Map([...roundState.tools,...tools].filter(t=>!originalBusiness.has(nameOf(t))).map(t=>[nameOf(t),t]));
      tools = [...wire.values()]; businessTools = clone(roundState.businessTools); toolChoice = roundState.toolChoice;
    } else roundState = {tools:clone(tools),businessTools:clone(businessTools),toolChoice};
    if (tools.length) diagnostics.push('transport_enabled');
    return request.messages || messages;
  }
  return {
    async init(value) {input = value; tools = []; businessTools = []; diagnostics = []; baseDiagnostics = [];
      __presetHost.install(value,failed); await __presetHost.runScripts(value.scripts || []); return this.state();},
    state() {return {tools,businessTools,toolChoice,diagnostics,timerExpired:__presetHost.timerExpired()};},
    prepare(messages, clientTools, roundTools) {return prepare(messages,clientTools,roundTools);},
    async reset() {if (consumed && savedMessages) await prepare(savedMessages,savedClientTools,savedRoundTools,true); return true;},
    async preview({text,calls = []}) {consumed = true; const result = await __presetHost.feedResponse(text,calls); return {text:result.text || (!__presetHost.hasFetchOverride() ? previewFallback('',calls) : '')};},
    hasAction(name) {return businessTools.some(t=>nameOf(t) === name) && __presetHost.hasAction(name);},
    action({name,args}) {return __presetHost.action(name,args);},
    async response({text,calls = []}) {
      const key = JSON.stringify({text,calls});
      if (finalCache.has(key)) return finalCache.get(key);
      const work = this.finishResponse(text,calls); finalCache.set(key,work); return work;
    },
    async finishResponse(text,calls) {
      consumed = true; const result = await __presetHost.feedResponse(text,calls,true);
      const wireNames = new Set(tools.map(nameOf)), remaining = new Map();
      for (const call of result.calls) remaining.set(call.id,(remaining.get(call.id) || 0)+1);
      const consumedIndexes = [];
      calls.forEach((call,index)=>{const count = remaining.get(call.id) || 0; if (wireNames.has(call.name) || !count) consumedIndexes.push(index); else remaining.set(call.id,count-1);});
      const output = result.text || previewFallback('',calls.filter(c=>wireNames.has(c.name)));
      return __presetHost.completeResponse(text,calls,{text:output,consumedIndexes});
    },
  };
})();
