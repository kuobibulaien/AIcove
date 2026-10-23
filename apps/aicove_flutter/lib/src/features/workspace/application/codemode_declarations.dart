import 'dart:convert';
import '../../plugins/domain/handlers/ai_tool.dart';

// Ported from pi-mono packages/codemode/src/declarations.ts (MIT, 476a303).
String toCodemodeIdentifier(String name) {
  final value = name.replaceAll(RegExp(r'[^A-Za-z0-9_$]'), '_');
  return value.isEmpty || RegExp(r'^\d').hasMatch(value) ? '_$value' : value;
}

String docComment(String text) =>
    '/** ${text.trim().replaceAll('*/', r'*\/')} */';

String schemaToType(Object? schema, {int? maxChars}) {
  var expansions = 0;
  final resolving = <String>{};
  String union(Iterable<String> types) {
    final values = types.toSet();
    return values.contains('unknown')
        ? 'unknown'
        : values.isEmpty
        ? 'never'
        : values.join(' | ');
  }

  late String Function(Object?, bool) render;
  render = (value, tags) {
    if (value == false) return 'never';
    if (value is! Map) return 'unknown';
    final ref = value[r'$ref'];
    if (ref is String) {
      if ((!ref.startsWith('#/') && ref != '#') ||
          resolving.contains(ref) ||
          expansions++ >= 32)
        return 'unknown';
      Object? target = schema;
      for (final part
          in (ref == '#' ? <String>[] : ref.substring(2).split('/'))) {
        if (target is! Map) return 'unknown';
        target =
            target[Uri.decodeComponent(
              part,
            ).replaceAll('~1', '/').replaceAll('~0', '~')];
      }
      resolving.add(ref);
      final type = render(target, tags);
      resolving.remove(ref);
      return type;
    }
    if (value.containsKey('const')) return jsonEncode(value['const']);
    if (value['enum'] is List)
      return union((value['enum'] as List).map(jsonEncode));
    for (final key in ['anyOf', 'oneOf']) {
      if (value[key] is List)
        return union((value[key] as List).map((v) => render(v, tags)));
    }
    if (value['allOf'] is List) {
      final parts = (value['allOf'] as List)
          .map((v) => render(v, tags))
          .where((v) => v != 'unknown');
      return parts.isEmpty
          ? 'unknown'
          : parts.map((v) => v.contains(' | ') ? '($v)' : v).join(' & ');
    }
    final type = value['type'];
    if (type is List)
      return union(type.map((v) => render({...value, 'type': v}, tags)));
    if (['string', 'boolean', 'null'].contains(type)) return '$type';
    if (type == 'integer' || type == 'number') return 'number';
    if (type == 'array' ||
        value.containsKey('items') ||
        value.containsKey('prefixItems')) {
      final items = value['items'];
      if (items != null && items is! List)
        return 'Array<${render(items, tags)}>';
      final tuple = value['prefixItems'] ?? items;
      return tuple is List && tuple.isNotEmpty
          ? '[${tuple.map((v) => render(v, tags)).join(', ')}]'
          : 'unknown[]';
    }
    if (type == 'object' ||
        value.containsKey('properties') ||
        value.containsKey('additionalProperties') ||
        value.containsKey('required')) {
      final properties = value['properties'] is Map
          ? value['properties'] as Map
          : const {};
      final required = value['required'] is List
          ? value['required'] as List
          : const [];
      final names = properties.keys.cast<String>().toList()..sort();
      final members = <String>[];
      var comments = false;
      for (final name in names) {
        final property = properties[name];
        final annotations = <String>[];
        if (property is Map) {
          if (property['description'] is String)
            annotations.addAll(
              (property['description'] as String)
                  .split(RegExp(r'[\r\n\u2028\u2029]'))
                  .where((v) => v.trim().isNotEmpty),
            );
          if (tags) annotations.addAll(_constraintTags(property));
        }
        final comment = annotations.isEmpty
            ? ''
            : '// ${annotations.join(' ')}\n';
        comments |= annotations.isNotEmpty;
        final key = RegExp(r'^[A-Za-z_$][A-Za-z0-9_$]*$').hasMatch(name)
            ? name
            : jsonEncode(name);
        members.add(
          '$comment$key${required.contains(name) ? '' : '?'}: ${render(property, tags)};',
        );
      }
      final additional = value['additionalProperties'];
      if (additional != null && additional != false)
        members.add('[key: string]: ${render(additional, tags)};');
      else if (additional == null && names.isEmpty)
        members.add('[key: string]: unknown;');
      if (members.isEmpty) return '{}';
      return comments
          ? '{\n${members.map((v) => v.split('\n').map((l) => '  $l').join('\n')).join('\n')}\n}'
          : '{ ${members.join(' ')} }';
    }
    return 'unknown';
  };
  var type = render(schema, true);
  if (maxChars != null && type.length > maxChars) {
    expansions = 0;
    resolving.clear();
    type = render(schema, false);
    if (type.length > maxChars) return 'unknown';
  }
  return type;
}

List<String> _constraintTags(Map property) {
  final variants = property['anyOf'] ?? property['oneOf'];
  final nonNull = variants is List
      ? variants.whereType<Map>().where((v) => v['type'] != 'null').toList()
      : <Map>[];
  final schemas = [property, if (nonNull.length == 1) nonNull.single].map((
    raw,
  ) {
    final value = Map<Object?, Object?>.from(raw);
    for (final bound in ['Minimum', 'Maximum']) {
      if (value['exclusive$bound'] == true) {
        value['exclusive$bound'] = value[bound.toLowerCase()];
        value.remove(bound.toLowerCase());
      }
    }
    return value;
  }).toList();
  final tags = <String>[];
  if (schemas.any(
    (s) =>
        s['type'] == 'integer' ||
        (s['type'] is List && (s['type'] as List).contains('integer')),
  ))
    tags.add('@integer');
  const lower = {'minimum', 'exclusiveMinimum', 'minLength', 'minItems'};
  const upper = {'maximum', 'exclusiveMaximum', 'maxLength', 'maxItems'};
  for (final key in [
    'minimum',
    'exclusiveMinimum',
    'maximum',
    'exclusiveMaximum',
    'multipleOf',
    'minLength',
    'maxLength',
    'pattern',
    'format',
    'minItems',
    'maxItems',
  ]) {
    final values = schemas.map((s) => s[key]).toSet();
    if (lower.contains(key) || upper.contains(key)) {
      final numbers = values.whereType<num>();
      if (numbers.isNotEmpty) {
        final bound = numbers.reduce(
          (a, b) => lower.contains(key) ? (a > b ? a : b) : (a < b ? a : b),
        );
        tags.add('@$key $bound');
      }
    } else {
      for (final value in values)
        if (value is String || value is num) tags.add('@$key $value');
    }
  }
  if (schemas.any((s) => s['uniqueItems'] == true)) tags.add('@uniqueItems');
  if (property['default'] != null)
    tags.add('@default ${jsonEncode(property['default'])}');
  if (property['deprecated'] == true) tags.add('@deprecated');
  return tags
      .where((t) => t.length <= 80)
      .map(
        (tag) => tag.replaceAllMapped(
          RegExp(r'[\r\n\u2028\u2029]'),
          (m) => '\\u${m[0]!.codeUnitAt(0).toRadixString(16).padLeft(4, '0')}',
        ),
      )
      .toList();
}

String renderToolSignature(AITool tool) =>
    '${toCodemodeIdentifier(tool.name)}(args: ${schemaToType(tool.parameterSchema, maxChars: 16000)}): Promise<${tool.outputSchema == null ? 'string' : schemaToType(tool.outputSchema)}>;';
String toolNamespace(AITool tool) =>
    tool.namespace ??
    (tool.name.startsWith('mcp__')
        ? tool.name.split('__')[1]
        : tool.name.startsWith('aicove_')
        ? 'aicove'
        : tool.name.startsWith('workspace_') ||
              ['read', 'write', 'edit', 'bash'].contains(tool.name)
        ? 'workspace'
        : 'tools');
Map<String, dynamic> describeCodemodeTool(AITool tool) => {
  'name': tool.name,
  'namespace': toolNamespace(tool),
  'description':
      '${tool.description}\n\ncodemode tool declaration:\n```ts\ndeclare const tools: { ${renderToolSignature(tool)} };\n```',
};
List<Map<String, dynamic>> directToolSchemas(Iterable<AITool> tools) => [
  for (final tool in tools)
    if (tool.exposure == ToolExposure.direct) tool.toOpenAISchema(),
];

const codemodeGuidance =
    '独立的多个工具调用（Promise.allSettled）、要串起来的调用、要过滤的大结果，用 codemode 一次做完，不要一个个分开调。';

const codemodeIntro =
    '''Run JavaScript that calls other tools. Supply code as raw JavaScript in the code field, not a code fence. QuickJS async function body: top-level await and return work. No Node, file system, or timers. fetch and ws byte helpers are available.
- await tools.<name>({...args}) resolves to a string, or structured output when declared; failures, blocked calls and invalid arguments reject Error with the tool error text. Effects already performed are not rolled back. Pending calls are cancelled when the script ends.
- Optional first line: // @options: {"max_output_tokens": 10000, "timeout_ms": 60000}. No timeout unless specified; user cancellation stops the script.
Globals:
- text(value), image(dataUrlOrImageBlock), console.log/info/warn/error/debug, return: add output. exit() ends the script. Multiple text items have ==> text N/M <== headers; console lines follow in <console_output>. Images are saved under .aicove/outputs/.
- store(key,value), load(key): session JSON state; only successful script writes persist.
- ALL_TOOLS, await searchTools(query,{limit?,namespace?}), await describeTool(name), await describeNamespace(name): discover unlisted tools, including MCP.
- fetch(url,options) returns status, ok, headers.get/has, text(), json(), arrayBuffer(). Check status/ok before interpreting an error response. ws.readBytes(path,{offset,length}) returns base64; ws.writeBytes(path,base64OrUint8Array,{offset,truncate}) writes bytes. Paths are relative to the current workspace.

Nested tools:''';

String createCodemodeDescription(
  Iterable<AITool> tools, {
  int inlineBudget = 3000,
}) {
  final groups = <String, List<(String, String)>>{};
  for (final tool in tools) {
    if (tool.name == 'codemode' || tool.exposure != ToolExposure.codemode)
      continue;
    final section =
        '### `${toCodemodeIdentifier(tool.name)}`\n${docComment(tool.description)}\n${renderToolSignature(tool)}';
    groups.putIfAbsent(toolNamespace(tool), () => []).add((tool.name, section));
  }
  final keys = groups.keys.toList()..sort();
  final selected = <String>{};
  // Reserve all headings and the omission marker before namespace round-robin.
  var remaining =
      inlineBudget * 4 -
      codemodeIntro.length -
      keys.fold<int>(0, (n, k) => n + k.length + 34);
  for (var index = 0; ; index++) {
    var any = false;
    for (final key in keys) {
      final group = groups[key]!;
      if (index >= group.length) continue;
      any = true;
      final item = group[index];
      if (item.$2.length + 2 <= remaining) {
        selected.add(item.$1);
        remaining -= item.$2.length + 2;
      }
    }
    if (!any) break;
  }
  return [
    codemodeIntro,
    for (final key in keys) ...[
      '## $key${groups[key]!.every((e) => selected.contains(e.$1)) ? '' : ' (some tools not listed)'}',
      for (final item in groups[key]!)
        if (selected.contains(item.$1)) item.$2,
    ],
  ].join('\n\n');
}

/// Only tool-mode runs opt into the compact loadout; ordinary chat is unchanged.
List<AITool> assembleCodemodeTools(Iterable<AITool> tools) {
  const direct = {'read', 'write', 'edit', 'bash', 'codemode'};
  final loadout = [
    for (final tool in tools)
      tool.copyWith(
        exposure: direct.contains(tool.name)
            ? ToolExposure.direct
            : tool.name.startsWith('mcp__')
            ? ToolExposure.deferred
            : ToolExposure.codemode,
      ),
  ];
  return [
    for (final tool in loadout)
      if (tool.name == 'codemode')
        tool.copyWith(description: createCodemodeDescription(loadout))
      else if (tool.exposure == ToolExposure.direct)
        tool.copyWith(
          description:
              '${tool.description}\n\nCodemode: `tools.${toCodemodeIdentifier(tool.name)}(args)` resolves to ${tool.outputSchema == null ? 'a string' : '`${schemaToType(tool.outputSchema)}`'}.',
        )
      else
        tool,
  ];
}
