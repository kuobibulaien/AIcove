// Headless SPreset host. Author callbacks are evaluated unchanged by QuickJS.
// No DOM, remote loader, native modules or credentials are exposed.
globalThis.console = Object.freeze({log(){}, info(){}, warn(){}, error(){}, debug(){}});
globalThis.__spreset = (() => {
  let config = {}, macros = {}, definitions = new Map(), activeIds = [], stopStrings = [];
  let processor = null, output = '', raw = '', hold = '', state = {};
  let initialTools = [], currentTools = [], dynamicToolNames = new Set();
  const clone = value => JSON.parse(JSON.stringify(value));
  const functionValue = source => {
    const value = (0, eval)(String(source));
    if (typeof value !== 'function') throw Error('Expected a JavaScript function');
    return value;
  };
  const substitute = text => String(text || '').replace(/{{(char|user|description|scenario)}}/gi,
    (match, key) => macros[key.toLowerCase()] ?? match);
  function validateMessages(messages) {
    if (!Array.isArray(messages) || messages.length > 4000) throw Error('Invalid message array');
    for (const m of messages) {
      if (!m || !['system','user','assistant','tool'].includes(m.role) ||
          !(typeof m.content === 'string' || Array.isArray(m.content) || m.content == null)) {
        throw Error('Invalid message from preset');
      }
    }
    return messages;
  }
  function normalizeTool(tool) {
    const d = tool?.type === 'function' && tool.function ? tool.function : tool;
    if (!d || typeof d.name !== 'string' || !/^[a-zA-Z0-9_-]{1,64}$/.test(d.name) || d.parameters?.type !== 'object') {
      throw Error('Invalid tool from preset');
    }
    return {type:'function',function:{name:d.name,description:String(d.description||''),parameters:d.parameters}};
  }
  // Runs last, after squash and forced processing, and owns this round's tools.
  async function finalRequest(prepared) {
    currentTools = clone(initialTools); dynamicToolNames.clear();
    const f = config.FinalRequestProcessing || {};
    if (!f.enabled || !String(f.script || '').trim()) return prepared;
    const request = {messages: prepared, tools: clone(initialTools)};
    const changed = await functionValue(f.script)({request});
    const result = changed && typeof changed === 'object' ? changed : request;
    const messages = validateMessages(result.messages);
    if (Array.isArray(result.tools)) {
      const tools = result.tools.map(normalizeTool);
      const names = new Set();
      for (const t of tools) {
        if (names.has(t.function.name)) throw Error('Duplicate preset tool: '+t.function.name);
        names.add(t.function.name);
      }
      currentTools = clone(tools);
      for (const name of names) if (!definitions.has(name)) dynamicToolNames.add(name);
    }
    return messages;
  }
  async function postScript(target, arrayMode) {
    const setting = config.ChatSquash || {};
    if (!setting.squashed_post_script_enable) return target;
    const changed = await functionValue(setting.squashed_post_script)(target);
    if (arrayMode) return validateMessages(changed === undefined ? target : changed);
    if (typeof changed !== 'string') throw Error('Merged post script must return text');
    return changed;
  }
  function hyperProcess(content) {
    for (const order of [1,2,3]) {
      const pattern = new RegExp('<regex(?: +order *= *' + order + ')' + (order === 2 ? '?' : '') + '> *"(/?)(.*?)\\1(.*?)" *: *"(.*?)" *</regex>', 'gm');
      for (const match of [...content.matchAll(pattern)]) {
        try { content = content.replace(new RegExp(match[2],match[3]), JSON.parse('"'+match[4].replace(/\\?"/g,'\\"')+'"')); } catch (_) {}
      }
    }
    return content.replace(/<regex(?: +order *= *\d)?>.*?<\/regex>/gm,'').replace(/\r\n|\r/g,'\n')
      .replace(/\s*<\|curtail\|>\s*/g,'\n').replace(/\s*<\|join\|>\s*/g,'').replace(/\s*<\|space\|>\s*/g,' ')
      .replace(/<\|(\\.*?)\|>/g,(m,p)=>{ try { return JSON.parse('"'+p+'"'); } catch (_) { return m; } });
  }
  function inject(messages) {
    return messages.flatMap((m,i) => {
      const id = m.identifier ?? m.__spresetIdentifier ?? (messages.length === activeIds.length ? activeIds[i] : null);
      delete m.__spresetIdentifier;
      const b = config.MessageInjections?.[id];
      if (!b?.enabled) return [m];
      if (b.reasoning != null && b.reasoning !== '') { m.reasoning = b.reasoning; m.reasoning_content = b.reasoning; }
      if (b.reasoning_content != null) m.reasoning_content = b.reasoning_content;
      if (b.signature) m.signature = b.signature;
      const calls = b.tool_calls || b.toolCalls;
      if (Array.isArray(calls) && calls.length) m.tool_calls = calls.map(c => c.function ? c : {id:c.id,type:'function',function:{name:c.name,arguments:typeof c.arguments === 'string' ? c.arguments : JSON.stringify(c.arguments || {})},...(c.signature ? {signature:c.signature} : {})});
      if (m.reasoning || m.reasoning_content || m.signature || m.tool_calls) m.role = 'assistant';
      return [m,...(b.toolResults || []).map(r=>({role:'tool',tool_call_id:r.toolCallId || r.tool_call_id,content:typeof r.content === 'string' ? r.content : JSON.stringify(r.content ?? '')}))];
    });
  }
  async function squash(messages) {
    const s = config.ChatSquash || {};
    if (!s.enabled) return postScript(messages, true);
    if (s.conditional_enabled) {
      const tag = String(s.conditional_tag || ''); let matched = false;
      const remove = value => {
        if (typeof value === 'string') { if (tag && value.includes(tag)) matched = true; return tag ? value.split(tag).join('') : value; }
        if (Array.isArray(value)) return value.map(remove);
        if (value && typeof value === 'object') for (const k of Object.keys(value)) value[k] = remove(value[k]);
        return value;
      };
      for (const m of messages) m.content = remove(m.content);
      if (!matched) return messages;
    }
    stopStrings = [];
    if (s.enable_stop_string && s.stop_string) {
      try { const value = JSON.parse(s.stop_string); stopStrings = Array.isArray(value) ? value : [String(value)]; }
      catch (_) { stopStrings = [String(s.stop_string)]; }
    }
    const affix = {
      user: [substitute(s.user_prefix), substitute(s.user_suffix)],
      assistant: [substitute(s.char_prefix), substitute(s.char_suffix)],
      system: [substitute(s.prefix_system), substitute(s.suffix_system)],
    };
    const result = []; let buffer = '', previous = '', bufferHistory = false;
    let role = s.role === 'follow' ? (messages[0]?.role || 'user') : (s.role || 'assistant');
    const flush = async () => {
      if (!buffer) return;
      if (previous) buffer += affix[previous][1];
      if (s.parse_clewd) buffer = hyperProcess(buffer);
      buffer = await postScript(buffer, false);
      if (s.re_split) {
        let remaining = buffer, split = [];
        while (remaining) {
          const key = ['user','assistant','system'].find(k => affix[k][0] && remaining.startsWith(affix[k][0]));
          if (!key) break;
          remaining = remaining.slice(affix[key][0].length);
          let end = remaining.length;
          for (const [prefix] of Object.values(affix)) if (prefix) { const i = remaining.indexOf(prefix); if (i >= 0) end = Math.min(end,i); }
          let part = remaining.slice(0,end);
          if (affix[key][1] && part.endsWith(affix[key][1])) part = part.slice(0,-affix[key][1].length);
          if (part.trim()) split.push({role:key,content:part.trim(),__isHistory:bufferHistory});
          remaining = remaining.slice(end);
        }
        if (split.length && !remaining) result.push(...split); else result.push({role,content:buffer,__isHistory:bufferHistory});
      } else result.push({role, content:buffer, __isHistory:bufferHistory});
      buffer = ''; previous = ''; bufferHistory = false;
    };
    const separator = s.enable_squashed_separator && s.squashed_separator_string
      ? (s.squashed_separator_regex ? new RegExp(s.squashed_separator_string) : s.squashed_separator_string) : null;
    const marked = messages.some(m => Object.hasOwn(m,'__isHistory'));
    const firstChat = messages.findIndex(m => m.role !== 'system');
    let lastChat = messages.length - 1;
    while (lastChat >= 0 && messages[lastChat].role === 'system') lastChat--;
    for (let index = 0; index < messages.length; index++) {
      const m = clone(messages[index]);
      const history = marked ? m.__isHistory === true : index >= firstChat && index <= lastChat;
      // Retain provenance until the transport host extracts chat floors.
      if (s.separate_chat_history && !history) { await flush(); result.push(m); continue; }
      if (s.parse_clewd && typeof m.content === 'string' && m.content.includes('<|no-trans|>')) {
        await flush(); m.content = m.content.replace(/<\|no-trans\|>/g,''); result.push(m); continue;
      }
      const native = !affix[m.role] || Object.keys(m).some(k => !['role','content','__isHistory'].includes(k) && m[k] != null)
        || (Array.isArray(m.content) && m.content.some(p => typeof p !== 'string' &&
          (!p || p.type !== 'text' || typeof p.text !== 'string' || Object.keys(p).some(k => !['type','text'].includes(k)))));
      if (native) {
        await flush();
        const clean = text => separator ? text.replace(separator, '') : text;
        if (typeof m.content === 'string') m.content = clean(m.content);
        else if (Array.isArray(m.content)) m.content = m.content.map(p =>
          typeof p === 'string' ? clean(p) : p?.type === 'text' && typeof p.text === 'string' &&
          Object.keys(p).every(k=>['type','text'].includes(k)) ? {...p,text:clean(p.text)} : p);
        result.push(m); if (s.role === 'follow') role = m.role;
        continue;
      }
      if (Array.isArray(m.content)) m.content = m.content.map(p => typeof p === 'string' ? p : p.text).join('');
      if (!m.content) continue;
      if (s.user_role_system && m.role === 'system') m.role = 'user';
      const separate = separator && (typeof separator === 'string' ? m.content.includes(separator) : separator.test(m.content));
      if (separate) {
        await flush(); m.content = m.content.replace(separator, ''); result.push(m);
        if (s.role === 'follow') role = m.role;
        continue;
      }
      if (previous !== m.role) {
        if (previous) buffer += affix[previous][1];
        buffer += affix[m.role][0];
      } else buffer += '\n';
      buffer += m.content; previous = m.role; bufferHistory ||= history;
    }
    await flush(); return result;
  }
  function forced(messages) {
    const p = config.ForcedPostProcessing || {};
    if (!p.enabled || !p.mode) return messages;
    if (p.mode === 'none') return messages;
    const mode = p.mode === 'claude' ? 'merge' : p.mode;
    if (!['merge','merge_tools','semi','semi_tools','strict','strict_tools','single'].includes(mode)) throw Error('Unsupported forced post-processing: '+p.mode);
    const preserveTools = mode.endsWith('_tools');
    const result = [];
    for (const source of messages) {
      const m = clone(source); m.content ??= '';
      if (!preserveTools && (m.role === 'tool' || m.tool_calls)) {
        const pieces = [typeof m.content === 'string' ? m.content : JSON.stringify(m.content)];
        if (m.tool_calls) pieces.push(JSON.stringify(m.tool_calls));
        m.content = pieces.filter(Boolean).join('\n');
        if (m.role === 'tool') m.role = 'user';
        delete m.tool_calls; delete m.tool_call_id;
      }
      if ((mode.startsWith('semi') || mode.startsWith('strict')) && result.length && m.role === 'system') m.role = 'user';
      if (mode.startsWith('strict') && m.role === 'assistant' && !result.some(x => x.role !== 'system')) result.push({role:'user',content:"Let's get started."});
      if (mode === 'single') { m.role = 'user'; if (typeof m.content !== 'string') m.content = JSON.stringify(m.content); for (const key of Object.keys(m)) if (!['role','content','__isHistory'].includes(key)) delete m[key]; }
      if (m.name && typeof m.content === 'string') {
        const name = m.role === 'system'
          ? (m.name === 'example_user' ? macros.user : m.name === 'example_assistant' ? macros.char : '') : m.name;
        if (name && !m.content.startsWith(name+': ')) m.content = name+': '+m.content;
      }
      delete m.name;
      const last = result[result.length-1];
      const structured = x => x.tool_calls || x.tool_call_id || x.signature || x.reasoning_content;
      if (last && last.role === m.role && m.role !== 'tool' && m.content &&
          typeof m.content === 'string' && typeof last.content === 'string' && !structured(last) && !structured(m)) {
        last.content += '\n\n'+m.content;
        if (Object.hasOwn(last,'__isHistory') || Object.hasOwn(m,'__isHistory')) last.__isHistory = last.__isHistory === true || m.__isHistory === true;
      } else result.push(m);
    }
    if (mode === 'single') return [{role:'user',content:result.map(m => m.content).filter(Boolean).join('\n\n'),...(result.some(m=>Object.hasOwn(m,'__isHistory')) ? {__isHistory:result.some(m=>m.__isHistory === true)} : {})}];
    return result.length ? result : [{role:'user',content:"Let's get started."}];
  }
  function resetOutput(stream) {
    const o = config.OutputPreprocessing || {};
    processor = o.enabled && String(o.script || '').trim() ? functionValue(o.script) : null;
    output = ''; raw = ''; hold = ''; state = {};
    return {stream: !!stream};
  }
  let streaming = false;
  async function push(chunk, final) {
    chunk = String(chunk ?? ''); raw += chunk;
    const value = processor ? await processor({buffer:hold+chunk,chunk,hold,output,raw,final:!!final,stream:streaming,state,channel:'main'})
      : {output: hold+chunk,hold:''};
    const normalized = typeof value === 'string' ? {output:value,hold:''} : value;
    if (!normalized || !['output','emit','text','content'].some(k=>Object.hasOwn(normalized,k))) throw Error('Invalid output processor result');
    const key = ['output','emit','text','content'].find(k=>Object.hasOwn(normalized,k));
    let emitted = String(normalized[key] ?? ''); hold = String(normalized.hold ?? '');
    if (normalized.state !== undefined) state = normalized.state;
    if (final && hold) { emitted += hold; hold = ''; }
    output += emitted; return {output,emitted,hold};
  }
  return {
    async init(input) {
      config = input.config || {}; macros = input.macros || {}; definitions = new Map();
      dynamicToolNames = new Set();
      const enabled = new Set(input.activeIds || []);
      activeIds = input.activeIds || [];
      for (const [id,b] of Object.entries(config.ToolBindings || {})) {
        if (!enabled.has(id) || !b.enabled || b.valid === false) continue;
        const d = await Function(String(b.code || ''))();
        if (!d || !/^[a-zA-Z0-9_-]{1,64}$/.test(d.name) || typeof d.action !== 'function' || d.parameters?.type !== 'object') throw Error('Invalid tool factory');
        if (definitions.has(d.name)) throw Error('Duplicate preset tool: '+d.name);
        definitions.set(d.name,d);
      }
      initialTools = clone([...definitions.values()].map(normalizeTool));
      currentTools = clone(initialTools);
      return {tools:currentTools};
    },
    async prepare(messages) { return finalRequest(validateMessages(forced(await squash(inject(clone(messages)))))); },
    stopStrings() { return stopStrings; },
    tools() { return currentTools; },
    async action({name,args}) {
      const d = definitions.get(name);
      // Tools a script injected have no action of their own, e.g. context sync.
      if (!d && dynamicToolNames.has(name)) return JSON.stringify({ok:true});
      if (!d) throw Error('Unknown preset tool');
      const result = await d.action(args); return typeof result === 'string' ? result : JSON.stringify(result);
    },
    reset(stream) { streaming=!!stream; resetOutput(stream); return true; },
    async update({text,final}) {
      text = String(text ?? '');
      if (!text.startsWith(raw)) resetOutput(streaming);
      const delta = text.slice(raw.length);
      if (!delta && !final) return {output,emitted:'',hold};
      return push(delta, final);
    },
    async response({text,calls}) {
      const o = config.OutputPreprocessing || {};
      // Only calls registered by this preset are output transports.
      const consumed = o.enabled && o.consumeToolCalls ? calls.filter(c=>definitions.has(c.name)) : [];
      if (consumed.length) {
        const formatter = o.toolCallFormatter;
        let body;
        if (formatter?.enabled) body = await functionValue(formatter.script)({calls:consumed});
        else body = consumed.map(c=> {
          const keys=Object.keys(c.arguments); const v=c.arguments[keys[0]];
          return keys.length===1 && (typeof v==='string' || ['content','text','output','answer','message','response'].includes(keys[0]))
            ? (typeof v==='string'?v:JSON.stringify(v)) : JSON.stringify(c.arguments);
        }).join('\n');
        if (typeof body !== 'string') throw Error('Tool formatter must return text');
        text += (text && !text.endsWith('\n') ? '\n' : '') + body;
      }
      const result = await this.update({text,final:true});
      return {...result,consumedIds:consumed.map(c=>c.id),
        consumedIndexes:calls.flatMap((c,i)=>consumed.includes(c)?[i]:[])};
    },
  };
})();
