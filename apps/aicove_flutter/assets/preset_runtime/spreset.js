// Headless SPreset host. Author callbacks are evaluated unchanged by QuickJS.
// No DOM, remote loader, native modules or credentials are exposed.
globalThis.console = Object.freeze({log(){}, info(){}, warn(){}, error(){}, debug(){}});
globalThis.__spreset = (() => {
  let config = {}, macros = {}, definitions = new Map();
  let processor = null, output = '', raw = '', hold = '', state = {};
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
  async function postScript(target, arrayMode) {
    const setting = config.ChatSquash || {};
    if (!setting.squashed_post_script_enable) return target;
    const changed = await functionValue(setting.squashed_post_script)(target);
    if (arrayMode) return validateMessages(changed === undefined ? target : changed);
    if (typeof changed !== 'string') throw Error('Merged post script must return text');
    return changed;
  }
  async function squash(messages) {
    const s = config.ChatSquash || {};
    if (!s.enabled) return postScript(messages, true);
    if (s.parse_clewd || s.re_split || s.separate_chat_history) {
      throw Error('SPreset parse_clewd/re_split/separate_chat_history not supported');
    }
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
    if (s.enable_stop_string) throw Error('SPreset merged stop strings not supported');
    const affix = {
      user: [substitute(s.user_prefix), substitute(s.user_suffix)],
      assistant: [substitute(s.char_prefix), substitute(s.char_suffix)],
      system: [substitute(s.prefix_system), substitute(s.suffix_system)],
    };
    const result = []; let buffer = '', previous = '';
    let role = s.role === 'follow' ? (messages[0]?.role || 'user') : (s.role || 'assistant');
    const flush = async () => {
      if (!buffer) return;
      if (previous) buffer += affix[previous][1];
      result.push({role, content: await postScript(buffer, false)});
      buffer = ''; previous = '';
    };
    const separator = s.enable_squashed_separator && s.squashed_separator_string
      ? (s.squashed_separator_regex ? new RegExp(s.squashed_separator_string) : s.squashed_separator_string) : null;
    for (const source of messages) {
      const m = clone(source);
      const native = !affix[m.role] || Object.keys(m).some(k => !['role','content'].includes(k) && m[k] != null)
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
      buffer += m.content; previous = m.role;
    }
    await flush(); return result;
  }
  function forced(messages) {
    const p = config.ForcedPostProcessing || {};
    if (!p.enabled || !p.mode) return messages;
    if (p.mode !== 'merge_tools') throw Error('Unsupported forced post-processing: '+p.mode);
    const result = [];
    for (const source of messages) {
      const m = clone(source); m.content ??= '';
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
      } else result.push(m);
    }
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
      if (config.MacroNest) throw Error('SPreset MacroNest not supported');
      const enabled = new Set(input.activeIds || []);
      for (const [id,b] of Object.entries(config.MessageInjections || {})) {
        if (enabled.has(id) && b.enabled) throw Error('Active SPreset MessageInjections require node-level host support');
      }
      for (const [id,b] of Object.entries(config.ToolBindings || {})) {
        if (!enabled.has(id) || !b.enabled || b.valid === false) continue;
        const d = await Function(String(b.code || ''))();
        if (!d || !/^[a-zA-Z0-9_-]{1,64}$/.test(d.name) || typeof d.action !== 'function' || d.parameters?.type !== 'object') throw Error('Invalid tool factory');
        if (definitions.has(d.name)) throw Error('Duplicate preset tool: '+d.name);
        definitions.set(d.name,d);
      }
      return {tools:[...definitions.values()].map(d=>({type:'function',function:{name:d.name,description:String(d.description||''),parameters:d.parameters}}))};
    },
    async prepare(messages) { return validateMessages(forced(await squash(clone(messages)))); },
    async action({name,args}) {
      const d = definitions.get(name); if (!d) throw Error('Unknown preset tool');
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
