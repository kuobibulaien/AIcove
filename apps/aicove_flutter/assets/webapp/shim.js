/* AIcove localStorage bridge. ES2017, synchronous installation before page scripts. */
(function () {
  'use strict';
  var boot = window.__AICOVE_BOOT__;
  delete window.__AICOVE_BOOT__;
  if (!boot) return;

  var FORMAT = 'aicove.webapp.save.v1';
  var MAX_BYTES = 16 * 1024 * 1024;
  var page = boot.page;

  // Model calls through AIcove; the channel key never reaches the page (ADR0109).
  var aicove = window.aicove && typeof window.aicove === 'object' ? window.aicove : {};
  aicove.chat = async function (messages, options) {
    if (typeof messages === 'string') messages = [{role: 'user', content: messages}];
    var body = Object.assign({}, options || {}, {messages: messages});
    var response, result;
    try {
      response = await fetch('/__aicove/ai/chat?page=' + encodeURIComponent(page), {
        method: 'POST', cache: 'no-store', credentials: 'same-origin',
        headers: {'Content-Type': 'application/json'}, body: JSON.stringify(body)
      });
    } catch (_) {
      result = {error: 'disconnected', message: '连不上 AIcove，请确认 AIcove 正在运行'};
    }
    if (response) {
      try { result = await response.json(); }
      catch (_) { result = {error: 'http_' + response.status, message: 'AIcove 拒绝了这次请求'}; }
    }
    if (response && response.status === 200 && typeof result.text === 'string') return result.text;
    var error = new Error((result && result.message) || 'AI 请求失败');
    error.code = (result && result.error) || 'model_failed';
    throw error;
  };
  window.aicove = aicove;

  var snapshotKey = '__aicove_pending__:' + page;
  var nativeStorage;
  try { nativeStorage = window.localStorage; } catch (_) { nativeStorage = null; }
  var snapshotEnabled = !!nativeStorage;
  var snapshotWarned = false;
  var snapshotTimer = null;
  var owner = false;
  var ready = false;
  var phase = 'normal';
  var revision = boot.revision;
  var external = null;
  var seq = 0;
  var savedSeq = 0;
  var epoch = 0;
  var runId = null;
  var pendingSave = null;
  var inflight = null;
  var debounce = null;
  var maximum = null;
  var retry = null;
  var failures = 0;
  var writeDue = false;
  var reloadPending = false;
  var unloading = false;
  var changedBeforeLock = false;
  var notices = Object.create(null);
  var ui = null;
  var data = new Map();
  var used = 0;

  var COPY = {
    disconnected: '连不上 AIcove，进度暂时没保存。请回到 AIcove，在空间里再点一次「运行」。',
    broken: '存档文件格式有误，本页进度暂不保存。存档修好后会自动恢复。',
    unmanaged: '没能接管这个网页的存档，本次进度不会保存到 AIcove。',
    duplicate: '这个游戏已在另一个标签页打开，本页进度不会保存。',
    snapshot: '浏览器存储不可用：关闭页面后，还没保存的进度无法找回。',
    conflict: '存档在别处被改过了（比如 AIcove酱 刚改了它），本页还有没保存的进度。',
    discard: '放弃本页进度，载入新存档',
    overwrite: '保留本页进度并覆盖'
  };

  function utf8Len(text) {
    var size = 0;
    for (var i = 0; i < text.length; i++) {
      var c = text.charCodeAt(i);
      if (c < 128) size++;
      else if (c < 2048) size += 2;
      else if (c >= 0xd800 && c <= 0xdbff && i + 1 < text.length &&
               text.charCodeAt(i + 1) >= 0xdc00 && text.charCodeAt(i + 1) <= 0xdfff) {
        size += 4; i++;
      } else size += 3;
    }
    return size;
  }

  function decodeSave(text) {
    if (text === null) return new Map();
    var save = JSON.parse(text);
    if (!save || save.format !== FORMAT || !save.localStorage ||
        Object.getPrototypeOf(save.localStorage) !== Object.prototype ||
        Array.isArray(save.localStorage)) throw new Error('bad_save');
    var result = new Map();
    Object.keys(save.localStorage).forEach(function (key) {
      var value = save.localStorage[key];
      result.set(key, typeof value === 'string' ? value : JSON.stringify(value));
    });
    return result;
  }

  function saveObject(map) {
    var values = Object.create(null);
    map.forEach(function (value, key) {
      var parsed;
      try { parsed = JSON.parse(value); } catch (_) { /* Preserve literal text. */ }
      values[key] = parsed !== null && typeof parsed === 'object' &&
        JSON.stringify(parsed) === value ? parsed : value;
    });
    return {format: FORMAT, localStorage: values};
  }

  function encodeSave(map, compact) {
    var save = saveObject(map);
    var text = JSON.stringify(save, null, compact ? 0 : 2);
    return !compact && utf8Len(text) > MAX_BYTES ? JSON.stringify(save) : text;
  }

  function equalMaps(a, b) {
    if (a.size !== b.size) return false;
    var equal = true;
    a.forEach(function (v, k) { if (!b.has(k) || b.get(k) !== v) equal = false; });
    return equal;
  }

  function setData(map) {
    data = map;
    used = 0;
    data.forEach(function (v, k) { used += utf8Len(JSON.stringify(k)) + utf8Len(JSON.stringify(v)); });
  }

  var disk;
  var diskValid = true;
  try { disk = decodeSave(boot.text); } catch (_) { diskValid = false; disk = new Map(); phase = 'broken'; }
  setData(disk);
  var initialSnapshot = null;
  var removeInitialSnapshot = false;
  if (nativeStorage) {
    try {
      var raw = nativeStorage.getItem(snapshotKey);
      if (raw !== null) {
        var pending = JSON.parse(raw);
        if (pending && typeof pending.base === 'string' && Number.isSafeInteger(pending.seq) &&
            pending.seq >= 0 && typeof pending.text === 'string') {
          var recovered = decodeSave(pending.text);
          if (diskValid && equalMaps(recovered, disk)) {
            removeInitialSnapshot = true;
          } else {
            initialSnapshot = pending;
            setData(recovered);
            seq = Math.max(1, pending.seq);
            if (!diskValid) phase = 'broken';
            else if (pending.base !== revision) {
              phase = 'conflict';
              external = {revision: revision, text: boot.text};
            }
            revision = pending.base;
          }
        }
      }
    } catch (_) { disableSnapshots(); }
  }

  function dirty() { return seq !== savedSeq; }
  function show(name, value) {
    if (value) notices[name] = value;
    else delete notices[name];
    render();
  }

  function render() {
    if (!document.documentElement) return;
    if (!ui) {
      var host = document.createElement('div');
      host.setAttribute('data-aicove-webapp', '');
      // Inline important rules prevent ordinary game styles hiding the bridge.
      host.style.cssText = 'all:initial!important;position:fixed!important;inset:0!important;z-index:2147483647!important;pointer-events:none!important;';
      var shadow = host.attachShadow({mode: 'closed'});
      ui = {host: host, shadow: shadow};
      document.documentElement.appendChild(host);
    }
    var root = ui.shadow;
    while (root.firstChild) root.removeChild(root.firstChild);
    var style = document.createElement('style');
    style.textContent = ':host{color-scheme:light dark} .box{font:16px/1.5 system-ui,sans-serif;color:#fff;background:#242424;padding:12px 16px;border-radius:10px;margin:12px;pointer-events:auto;max-width:560px;box-shadow:0 2px 16px #0006} button{font:inherit;margin:8px 8px 0 0;padding:8px;cursor:pointer}';
    root.appendChild(style);
    Object.keys(notices).forEach(function (key) {
      if (key === 'disconnected' && document.visibilityState === 'hidden') return;
      var line = document.createElement('div');
      line.className = 'box';
      line.setAttribute('role', 'status');
      line.textContent = notices[key];
      root.appendChild(line);
    });
    if (owner && phase === 'conflict') {
      var box = document.createElement('div');
      box.className = 'box';
      box.setAttribute('role', 'alertdialog');
      box.setAttribute('aria-label', COPY.conflict);
      var label = document.createElement('div');
      label.textContent = COPY.conflict;
      box.appendChild(label);
      [[COPY.discard, discard], [COPY.overwrite, overwrite]].forEach(function (item) {
        var button = document.createElement('button');
        button.type = 'button';
        button.textContent = item[0];
        button.addEventListener('click', item[1]);
        box.appendChild(button);
      });
      root.appendChild(box);
    }
  }

  document.addEventListener('DOMContentLoaded', render);

  function disableSnapshots() {
    snapshotEnabled = false;
    if (owner && !snapshotWarned) { snapshotWarned = true; show('snapshot', COPY.snapshot); }
  }
  function removeSnapshot() {
    clearTimeout(snapshotTimer); snapshotTimer = null;
    if (!owner || !snapshotEnabled) return;
    try { nativeStorage.removeItem(snapshotKey); } catch (_) { disableSnapshots(); }
  }
  function writeSnapshot() {
    clearTimeout(snapshotTimer); snapshotTimer = null;
    if (!owner || !snapshotEnabled) return;
    try {
      nativeStorage.setItem(snapshotKey, JSON.stringify({
        base: revision, seq: seq, text: encodeSave(data, true)
      }));
    } catch (_) { disableSnapshots(); }
  }
  // Encoding the whole save on every setItem would stall games that save often;
  // coalesce bursts and write at once when the page is hidden or closed.
  function writeSnapshotSoon() {
    if (!owner || !snapshotEnabled || snapshotTimer !== null) return;
    snapshotTimer = setTimeout(writeSnapshot, 300);
  }
  function writePendingSnapshot() {
    if (snapshotTimer !== null) writeSnapshot();
  }
  function acknowledgeSnapshot(sentSeq) {
    if (!snapshotEnabled) return;
    if (seq === sentSeq) removeSnapshot();
    else writeSnapshot(); // Newer in-memory changes, with the acknowledged base.
  }

  function clearWriteTimers() {
    clearTimeout(debounce); clearTimeout(maximum); clearTimeout(retry);
    debounce = null; maximum = null; retry = null;
  }
  function schedule() {
    if (!ready || !owner || phase !== 'normal' || !dirty() || reloadPending) return;
    clearTimeout(debounce);
    debounce = setTimeout(function () { debounce = null; flush(); }, 2000);
    if (maximum === null) maximum = setTimeout(function () { maximum = null; flush(); }, 10000);
  }
  function changed() {
    seq++;
    if (!ready) changedBeforeLock = true;
    writeSnapshotSoon();
    schedule();
  }

  function requireArgs(args, count) {
    if (args.length < count) throw new TypeError('Not enough arguments');
  }
  function getItem(key) {
    requireArgs(arguments, 1);
    key = String(key);
    return data.has(key) ? data.get(key) : null;
  }
  function setItem(key, value) {
    requireArgs(arguments, 2);
    key = String(key); value = String(value);
    var old = data.get(key);
    if (data.has(key) && old === value) return;
    var next = used + (data.has(key) ? -utf8Len(JSON.stringify(old)) : utf8Len(JSON.stringify(key))) + utf8Len(JSON.stringify(value));
    if (next > boot.quota) throw new DOMException('Storage quota exceeded', 'QuotaExceededError');
    data.set(key, value); used = next; changed();
  }
  function removeItem(key) {
    requireArgs(arguments, 1); key = String(key);
    if (!data.has(key)) return;
    used -= utf8Len(JSON.stringify(key)) + utf8Len(JSON.stringify(data.get(key)));
    data.delete(key); changed();
  }
  function clear() {
    if (!data.size) return;
    data.clear(); used = 0; changed();
  }
  function key(index) {
    requireArgs(arguments, 1); index = Number(index) >>> 0;
    if (index >= data.size) return null;
    return Array.from(data.keys())[index];
  }

  var target = Object.create(Storage.prototype);
  Object.defineProperties(target, {
    getItem: {value: getItem, configurable: true},
    setItem: {value: setItem, configurable: true},
    removeItem: {value: removeItem, configurable: true},
    clear: {value: clear, configurable: true},
    key: {value: key, configurable: true},
    length: {get: function () { return data.size; }, configurable: true}
  });
  function named(name) { return typeof name === 'string' && data.has(name) && !(name in target); }
  var storage = new Proxy(target, {
    get: function (t, name, receiver) { return named(name) ? data.get(name) : Reflect.get(t, name, receiver); },
    has: function (t, name) { return named(name) || Reflect.has(t, name); },
    getOwnPropertyDescriptor: function (t, name) {
      return named(name) ? {value: data.get(name), writable: true, enumerable: true, configurable: true} : Reflect.getOwnPropertyDescriptor(t, name);
    },
    set: function (t, name, value) {
      if (typeof name === 'string') { setItem(name, value); return true; }
      return Reflect.set(t, name, value, t);
    },
    defineProperty: function (t, name, descriptor) {
      if (typeof name === 'string') {
        // Accessor descriptors are not supported by Web IDL named setters.
        if (descriptor.get || descriptor.set) return false;
        setItem(name, descriptor.value); return true;
      }
      return Reflect.defineProperty(t, name, descriptor);
    },
    deleteProperty: function (t, name) {
      if (named(name)) { removeItem(name); return true; }
      return Reflect.deleteProperty(t, name);
    },
    ownKeys: function (t) {
      var keys = Array.from(data.keys());
      Reflect.ownKeys(t).forEach(function (name) { if (keys.indexOf(name) < 0) keys.push(name); });
      return keys;
    }
  });

  try {
    Object.defineProperty(window, 'localStorage', {
      value: storage, configurable: true, enumerable: true, writable: false
    });
    if (window.localStorage !== storage) throw new Error('not_installed');
  } catch (_) {
    phase = 'unmanaged';
    show('unmanaged', COPY.unmanaged);
    return;
  }

  function endpoint(route, params) {
    var url = '/__aicove/' + route + '?page=' + encodeURIComponent(page);
    if (params) url += params;
    return url;
  }
  async function request(route, options, params) {
    var controller = new AbortController();
    var timeout = setTimeout(function () { controller.abort(); }, 15000);
    try {
      var response = await fetch(endpoint(route, params), Object.assign({
        cache: 'no-store', credentials: 'same-origin', signal: controller.signal
      }, options));
      var body = await response.json();
      return {status: response.status, body: body};
    } finally { clearTimeout(timeout); }
  }
  function success() { failures = 0; show('disconnected', null); }
  function failed() {
    failures++;
    if (failures >= 3) show('disconnected', COPY.disconnected);
  }
  function tryLater() {
    clearWriteTimers();
    retry = setTimeout(function () { retry = null; flush(); }, 3000);
  }
  function setBroken() {
    phase = 'broken'; clearWriteTimers(); show('broken', COPY.broken);
  }
  function externalChange(state) {
    runId = null; pendingSave = null;
    clearWriteTimers();
    external = state;
    try { decodeSave(state.text); } catch (_) { setBroken(); return; }
    show('broken', null);
    if (!dirty()) {
      removeSnapshot(); reloadPending = true; window.location.reload();
    } else {
      phase = 'conflict'; render();
    }
  }
  function discard() {
    if (!owner || phase !== 'conflict') return;
    clearWriteTimers(); removeSnapshot(); reloadPending = true; window.location.reload();
  }
  function overwrite() {
    if (!owner || phase !== 'conflict' || !external) return;
    revision = external.revision; epoch++; runId = null; pendingSave = null;
    phase = 'normal'; external = null;
    // Even an unchanged local map must overwrite the newer disk version.
    if (!dirty()) seq++;
    writeSnapshot(); render(); flush();
  }

  async function flush() {
    if (!ready || !owner || phase !== 'normal' || !dirty() || reloadPending) return;
    if (inflight) { writeDue = true; return; }
    writeDue = false;
    clearWriteTimers();
    var ticket = {};
    inflight = ticket;
    var sentSeq = pendingSave ? pendingSave.seq : seq, sentEpoch = epoch;
    var text = pendingSave ? pendingSave.text : encodeSave(data, false);
    var retryNeeded = false;
    try {
      if (!runId) {
        var opened = await request('run', {method: 'POST'});
        if (sentEpoch !== epoch) return;
        if (opened.status !== 200) {
          if (opened.status === 503) { failed(); retryNeeded = true; return; }
          setBroken(); return;
        }
        success(); runId = opened.body.runId;
      }
      // Until acknowledged, retry the exact body/base even if gameplay has
      // advanced. Newer edits remain in the per-page snapshot for the next save.
      if (!pendingSave) pendingSave = {seq: sentSeq, text: text, base: revision, runId: runId};
      var options = {
        method: 'POST', headers: {
          'Content-Type': 'application/json', 'X-AIcove-Base': pendingSave.base, 'X-AIcove-Run': pendingSave.runId
        }, body: text
      };
      // pagehide may fire while still visible; only keepalive survives unload.
      if ((document.visibilityState === 'hidden' || unloading) && utf8Len(text) <= 60 * 1024) options.keepalive = true;
      var result = await request('save', options);
      if (sentEpoch !== epoch) return;
      if (result.status === 200) {
        success(); pendingSave = null; revision = result.body.revision; epoch++; savedSeq = sentSeq;
        acknowledgeSnapshot(sentSeq);
      } else if (result.status === 409) {
        success(); pendingSave = null;
        if (result.body.error === 'run_closed') {
          runId = null;
          var state = await request('state');
          if (sentEpoch !== epoch) return;
          if (state.status !== 200) { failed(); retryNeeded = true; return; }
          externalChange(state.body);
        } else externalChange(result.body);
      } else if (result.status === 400 || result.status === 413) {
        success(); pendingSave = null; setBroken();
      } else {
        failed(); retryNeeded = true;
      }
    } catch (_) {
      if (sentEpoch === epoch) { failed(); retryNeeded = true; }
    } finally {
      if (inflight === ticket) inflight = null;
      if (retryNeeded && phase === 'normal') tryLater();
      else if (writeDue && phase === 'normal') flush();
      else schedule();
    }
  }

  // A save during unload can send one keepalive request, not run + save, so
  // hold a run before the first change needs it.
  async function prefetchRun() {
    if (runId || inflight || phase !== 'normal' || reloadPending) return;
    var ticket = {};
    inflight = ticket;
    var sentEpoch = epoch;
    try {
      var opened = await request('run', {method: 'POST'});
      if (sentEpoch === epoch && opened.status === 200 && !runId) runId = opened.body.runId;
    } catch (_) { /* The next save opens a run itself. */ }
    finally {
      if (inflight === ticket) inflight = null;
      if (writeDue && phase === 'normal') flush();
    }
  }

  async function poll() {
    // Let an idempotent retry acknowledge a possibly committed save first.
    // A poll during this gap could mistake a lost response for an external edit.
    if (!ready || !owner || inflight || reloadPending ||
        (phase === 'normal' && retry !== null && dirty()) ||
        document.visibilityState === 'hidden') return;
    var ticket = {};
    inflight = ticket;
    var sentEpoch = epoch;
    try {
      var result = await request('state', {}, '&known=' + encodeURIComponent(revision));
      if (sentEpoch !== epoch) return;
      if (result.status !== 200) { failed(); return; }
      success();
      if (result.body.revision !== revision) externalChange(result.body);
      // A rejected write may leave an unchanged but valid disk save. Keep broken
      // until an external revision change supplies a repaired save.
    } catch (_) { if (sentEpoch === epoch) failed(); }
    finally {
      if (inflight === ticket) inflight = null;
      if (writeDue && phase === 'normal') flush();
      else if (phase === 'normal' && dirty() && debounce === null && retry === null) schedule();
    }
  }

  function acquired(lock) {
    if (!lock) {
      phase = 'unmanaged'; ready = true;
      show('duplicate', COPY.duplicate);
      return;
    }
    owner = true; ready = true;
    if (!snapshotEnabled) disableSnapshots();
    if (phase === 'broken') show('broken', COPY.broken);
    if (removeInitialSnapshot) removeSnapshot();
    if (changedBeforeLock) writeSnapshot();
    render();
    setInterval(poll, 2000);
    if (phase === 'normal' && (initialSnapshot || dirty())) flush();
    else prefetchRun();
    // Pending promises do not keep a page alive. The browser releases this lock
    // when the document is destroyed; never release it on visibility changes.
    return new Promise(function () {});
  }
  if (navigator.locks && typeof navigator.locks.request === 'function') {
    navigator.locks.request('aicove:' + page, {ifAvailable: true}, acquired).catch(function () {
      phase = 'unmanaged'; ready = true; owner = false;
      show('unmanaged', COPY.unmanaged);
    });
  } else acquired(true);

  document.addEventListener('visibilitychange', function () {
    render();
    if (document.visibilityState === 'hidden') { writePendingSnapshot(); flush(); }
  });
  window.addEventListener('pagehide', function () { unloading = true; writePendingSnapshot(); flush(); });
  window.addEventListener('pageshow', function () { unloading = false; });
}());
