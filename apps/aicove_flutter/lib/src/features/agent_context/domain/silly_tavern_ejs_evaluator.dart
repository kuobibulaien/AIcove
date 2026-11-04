import 'dart:convert';

import 'package:aicove_quickjs/aicove_quickjs.dart';

class SillyTavernEjsEvaluator {
  const SillyTavernEjsEvaluator();

  String render(
    String template, {
    required Map<String, String> variables,
    required Map<String, Object?>? messageVariables,
    required String char,
    required String user,
    required String description,
    required String scenario,
    required String lastUserMessage,
    required List<String> warnings,
  }) {
    if ((!template.contains('<%') && !template.contains('<_%')) ||
        !template.contains('%>')) {
      return template;
    }
    final tags = RegExp(r'<(_?)%([_=-]?)([\s\S]*?)([-_]?%>)');
    final code = StringBuffer();
    var offset = 0;
    var stripNext = false;
    for (final match in tags.allMatches(template)) {
      var literal = template.substring(offset, match.start);
      if (stripNext) literal = literal.replaceFirst(RegExp(r'^\s+'), '');
      if (match.group(1) == '_' || match.group(2) == '_') {
        literal = literal.replaceFirst(RegExp(r'\s+$'), '');
      }
      code.writeln('__out += ${jsonEncode(literal)};');
      final body = match.group(3)!;
      if (match.group(2) == '=' || match.group(2) == '-') {
        code.writeln('__out += String(($body) ?? "");');
      } else {
        code.writeln(body);
      }
      stripNext = match.group(4)!.startsWith('_');
      offset = match.end;
    }
    var tail = template.substring(offset);
    if (stripNext) tail = tail.replaceFirst(RegExp(r'^\s+'), '');
    code.writeln('__out += ${jsonEncode(tail)};');
    try {
      final source =
          '''
(() => {
const variables = ${jsonEncode(variables)};
const messageVariables = ${jsonEncode(messageVariables ?? {})};
const stat_data = messageVariables.stat_data ?? {};
const char = ${jsonEncode(char)}, user = ${jsonEncode(user)}, description = ${jsonEncode(description)}, scenario = ${jsonEncode(scenario)}, lastUserMessage = ${jsonEncode(lastUserMessage)};
Object.assign(globalThis, {variables, messageVariables, stat_data, char, user, description, scenario, lastUserMessage});
const parts = p => Array.isArray(p) ? p : String(p).split('.');
const get = (obj, path, fallback) => { let v = obj; for (const k of parts(path)) { if (v == null || !Object.prototype.hasOwnProperty.call(Object(v), k)) return fallback; v = v[k]; } return v === undefined ? fallback : v; };
const set = (obj, path, value) => { const keys = parts(path); let v = obj; for (let i=0; i<keys.length-1; i++) { const k=keys[i]; if (!v[k] || typeof v[k] !== 'object') v[k]={}; v=v[k]; } v[keys[keys.length-1]]=value; return obj; };
const _ = {get, set, has: (o,p) => get(o,p,undefined) !== undefined, isEmpty: v => v == null || (typeof v === 'string' || Array.isArray(v) ? v.length === 0 : typeof v === 'object' ? Object.keys(v).length === 0 : true), cloneDeep: v => v === undefined ? v : JSON.parse(JSON.stringify(v))};
const getvar = (path, defaults) => { let v = Object.prototype.hasOwnProperty.call(variables,path) ? variables[path] : get(messageVariables,path,undefined); if (v === undefined) v=get(stat_data,path,undefined); if (v == null) return defaults ?? 0; if (typeof v === 'string' && v.trim() !== '' && !Number.isNaN(Number(v))) return Number(v); return v; };
const setvar = (key,val) => (variables[key]=val);
const addvar = (key,inc) => setvar(key, Number(getvar(key,0)) + Number(inc));
const getMessageVar = (key,options) => messageVariables[key] ?? options?.defaults ?? {};
Object.assign(globalThis, {_, getvar, setvar, addvar, getMessageVar});
let __out = '';
$code
return JSON.stringify({text: __out, variables});
})()
''';
      final result = jsonDecode(QuickJsSync.evaluate(source)) as Map;
      final updated = result['variables'] as Map;
      variables
        ..clear()
        ..addAll(
          updated.map(
            (key, value) => MapEntry(key.toString(), value.toString()),
          ),
        );
      return result['text'] as String;
    } catch (error) {
      warnings.add('EJS 执行失败：$error');
      return template.replaceAll(tags, '');
    }
  }
}
