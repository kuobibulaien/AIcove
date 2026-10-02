// Host-owned content transport protocol. No imported script or host I/O runs here.
globalThis.__transport = (() => {
  let name = '', anchor = '';
  const clone = value => JSON.parse(JSON.stringify(value));
  function contentStringStart(raw) {
    if (!/^\s*\{/.test(raw)) return -1;
    let depth = 0;
    for (let i = 0; i < raw.length; i++) {
      const ch = raw[i];
      if (ch === '{' || ch === '[') { depth++; continue; }
      if (ch === '}' || ch === ']') { depth--; continue; }
      if (ch !== '"') continue;
      const start = i++;
      for (; i < raw.length; i++) {
        if (raw[i] === '\\') { i++; continue; }
        if (raw[i] === '"') break;
      }
      if (i >= raw.length) return -1;
      if (depth !== 1) continue;
      let key;
      try { key = JSON.parse(raw.slice(start, i + 1)); } catch (_) { return -1; }
      if (key !== 'content') continue;
      const value = /^\s*:\s*"/.exec(raw.slice(i + 1));
      if (value) return i + 1 + value[0].length;
    }
    return -1;
  }
  const completeUnicode = value => value.replace(/[\uD800-\uDBFF]$/, '');
  function readContent(call) {
    if (typeof call.arguments?.content === 'string') return completeUnicode(call.arguments.content);
    const raw = call.rawArguments ?? call.arguments?._raw;
    if (typeof raw !== 'string') return '';
    try {
      const parsed = JSON.parse(raw);
      return typeof parsed?.content === 'string' ? completeUnicode(parsed.content) : '';
    } catch (_) {
      // Recover only the top-level content string, never another JSON field.
      const start = contentStringStart(raw);
      if (start < 0) return '';
      let result = '';
      const escapes = {'"':'"', '\\':'\\', '/':'/', b:'\b', f:'\f', n:'\n', r:'\r', t:'\t'};
      for (let i = start; i < raw.length; i++) {
        const ch = raw[i];
        if (ch === '"') break;
        if (ch !== '\\') { result += ch; continue; }
        if (++i >= raw.length) break;
        const escape = raw[i];
        if (escape === 'u') {
          const hex = raw.slice(i + 1, i + 5);
          if (!/^[0-9a-f]{4}$/i.test(hex)) break;
          result += String.fromCharCode(parseInt(hex, 16)); i += 4;
        } else if (Object.hasOwn(escapes, escape)) result += escapes[escape];
        else break;
      }
      // An incomplete surrogate must not become invalid UTF-8 at the bridge.
      return result.replace(/[\uD800-\uDBFF]$/, '');
    }
  }
  return {
    init(input) {
      name = ''; anchor = '';
      if (!input.config) return {tools:[], diagnostics:[]};
      const diagnostics = input.config.diagnostics || [];
      if (!input.config.enabled) return {tools:[], diagnostics:diagnostics.length ? diagnostics : ['transport_disabled']};
      if (!input.modelSupportsTools) return {tools:[], diagnostics:['transport_skipped_model_without_tools']};
      if (input.config.protocol !== 'content_tool_v1' || !/^[a-zA-Z0-9_-]{1,64}$/.test(input.name)) {
        throw Error('Invalid preset transport configuration');
      }
      name = input.name; anchor = String(input.config.anchor || '');
      return {tools:[{type:'function', function:{name,
        description:'Emit the complete final user-visible reply exactly once. Put the entire reply in content and write no reply text outside this call.',
        parameters:{type:'object', properties:{content:{type:'string', description:'The complete final reply shown to the user.'}}, required:['content']}
      }}], diagnostics:[...diagnostics, 'transport_enabled']};
    },
    prepare(messages) {
      const result = clone(messages);
      if (!name) return result;
      const content = 'Call the `' + name + '` function exactly once and put your complete final reply in its `content` argument. Do not write any of the final reply outside that call. Use any other available tools normally when they are needed.';
      const index = anchor ? result.findIndex(m => typeof m.content === 'string' && m.content.includes(anchor)) : -1;
      if (index >= 0) result.splice(index, 0, {role:'system', content});
      else result.push({role:result.at(-1)?.role === 'assistant' ? 'user' : 'system', content});
      return result;
    },
    response({text, calls}) {
      let best = String(text || '');
      const consumedIndexes = [];
      for (let i = 0; i < calls.length; i++) {
        // Exact request-owned identity: a prefix alone never authorizes consumption.
        if (!name || calls[i].name !== name) continue;
        consumedIndexes.push(i);
        const content = readContent(calls[i]);
        if (content.length >= best.length) best = content;
      }
      return {text:best, consumedIndexes};
    },
  };
})();
