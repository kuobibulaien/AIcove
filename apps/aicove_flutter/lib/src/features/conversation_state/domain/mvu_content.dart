/// MVU 相关内容的识别与过滤（ADR0071）：世界书条目归属、历史更新块清理、
/// 显示隐藏与宏输出。标签边界统一经 [ContentTagScanner]，不另写正则。
library;

import 'dart:convert';

import '../../../core/models/message_block.dart';
import '../../agent_context/domain/silly_tavern_world_book.dart';
import '../../chat/domain/message.dart';
import '../../content_tags/domain/content_tag_registry.dart';
import '../../content_tags/domain/content_tag_scanner.dart';
import '../../content_tags/domain/content_tag_spec.dart';
import 'state_path.dart';

const String mvuTagOwnerId = 'mvu';

/// 历史消息与显示用：更新块与补丁块整块去掉。思考区不在此处理。
const ContentTagProvider mvuUpdateTagProvider = StaticContentTagProvider(
  providerId: mvuTagOwnerId,
  tagSpecs: [
    ContentTagSpec(
      name: 'updatevariable',
      aliases: {'variableupdate'},
      ownerId: mvuTagOwnerId,
      requestWhenActive: ContentTagRequestAction.strip,
      requestWhenInactive: ContentTagRequestAction.strip,
      display: ContentTagDisplay.hidden,
    ),
    ContentTagSpec(
      name: 'jsonpatch',
      aliases: {'json_patch'},
      ownerId: mvuTagOwnerId,
      requestWhenActive: ContentTagRequestAction.strip,
      requestWhenInactive: ContentTagRequestAction.strip,
      display: ContentTagDisplay.hidden,
      jsonPayload: true,
    ),
  ],
);

final ContentTagScanner _updateScanner = ContentTagScanner(
  ContentTagRegistry(const [mvuUpdateTagProvider]),
);

final RegExp _updateHint = RegExp(
  r'<\s*/?\s*(?:updatevariable|variableupdate|json_?patch)\b',
  caseSensitive: false,
);
final RegExp _extraBlankLines = RegExp(r'\n{3,}');

bool mayContainMvuUpdate(String text) => _updateHint.hasMatch(text);

/// 去掉全部更新块（含流式未闭合的）与孤立闭标签；无更新块时原样返回。
String stripMvuUpdateBlocks(String text) {
  if (!mayContainMvuUpdate(text)) return text;
  final output = StringBuffer();
  for (final segment in _updateScanner.scan(text)) {
    if (segment is ContentTagText) output.write(segment.text);
  }
  return output.toString().replaceAll(_extraBlankLines, '\n\n').trim();
}

/// 聊天列表显示用的消息副本：去掉 MVU 更新块；没有时原样返回同一实例。
Message stripMvuUpdatesForDisplay(Message message) {
  if (message.role != 'assistant') return message;
  final blocks = message.blocks;
  if (blocks == null || blocks.isEmpty) {
    if (!mayContainMvuUpdate(message.content)) return message;
    return message.copyWith(content: stripMvuUpdateBlocks(message.content));
  }
  if (!blocks.any(_hasUpdateText)) return message;
  return message.copyWith(
    blocks: [
      for (final block in blocks)
        _hasUpdateText(block)
            ? (block as TextBlock).copyWith(
                content: stripMvuUpdateBlocks(block.content),
              )
            : block,
    ],
  );
}

bool _hasUpdateText(MessageBlock block) =>
    block is TextBlock && mayContainMvuUpdate(block.content);

/// 请求副本：只清理历史消息（user/assistant）里的更新块，不动预设与世界书。
List<Map<String, dynamic>> stripMvuUpdatesFromHistory(
  List<Map<String, dynamic>> messages,
) {
  return [
    for (final message in messages)
      if (message['role'] != 'user' && message['role'] != 'assistant')
        message
      else
        _stripMessage(message),
  ];
}

Map<String, dynamic> _stripMessage(Map<String, dynamic> message) {
  final content = message['content'];
  if (content is String) {
    if (!mayContainMvuUpdate(content)) return message;
    return {...message, 'content': stripMvuUpdateBlocks(content)};
  }
  if (content is List) {
    var changed = false;
    final parts = [
      for (final part in content)
        if (part is Map &&
            part['type'] == 'text' &&
            part['text'] is String &&
            mayContainMvuUpdate(part['text'] as String))
          () {
            changed = true;
            return {
              ...part,
              'text': stripMvuUpdateBlocks(part['text'] as String),
            };
          }()
        else
          part,
    ];
    return changed ? {...message, 'content': parts} : message;
  }
  return message;
}

bool isMvuInitVarEntry(TavernWorldEntry entry) =>
    entry.name.toLowerCase().contains('[initvar]');

bool containsEjs(String text) => text.contains('<%') && text.contains('%>');

final RegExp _mvuSpecific = RegExp(
  r'(?:get|format)_message_variable|<\s*/?\s*(?:updatevariable|variableupdate|json_?patch)\b',
  caseSensitive: false,
);

/// 读取 MVU 状态或要求模型输出更新块的内容属于 MVU 专属。
bool isMvuSpecificContent(String text) => _mvuSpecific.hasMatch(text);

/// 本轮世界书扫描要跳过的条目：`书id/条目id` → 提示。
/// `[InitVar]` 永不注入；EJS 条目整条跳过；MVU 未生效时跳过 MVU 专属条目。
Map<String, String> mvuWorldEntrySkips(
  List<TavernWorldBook> books, {
  required bool mvuActive,
}) {
  final skips = <String, String>{};
  for (final book in books) {
    for (final entry in book.entries) {
      final id = '${book.id}/${entry.id}';
      if (isMvuInitVarEntry(entry)) {
        skips[id] = '';
      } else if (containsEjs(entry.content)) {
        skips[id] = '${entry.name} 含 EJS 模板（<% %>），本期不支持，已跳过该条目';
      } else if (!mvuActive && isMvuSpecificContent(entry.content)) {
        skips[id] = '${entry.name} 是 MVU 变量专用内容，本会话未启用 MVU 变量，已跳过';
      }
    }
  }
  return skips;
}

/// `[InitVar]` 来源条目（不论开关），按书与条目原顺序。
List<TavernWorldEntry> mvuInitVarEntries(List<TavernWorldBook> books) => [
  for (final book in books)
    if (book.enabled)
      for (final entry in book.entries)
        if (isMvuInitVarEntry(entry)) entry,
];

/// 宏 `{{get_message_variable::路径}}` 的取值：去掉 `$` 开头的键；字符串原样，其余 JSON。
/// 路径不存在返回 null。
String? readMessageVariableMacro(
  Map<String, Object?> variables,
  String rawPath, {
  required bool yaml,
}) {
  final path = parseStatePath(rawPath);
  if (!stateHas(variables, path)) return null;
  final value = _withoutDollarKeys(stateGet(variables, path));
  if (value is String) return value;
  return yaml ? toYaml(value) : jsonEncode(value);
}

Object? _withoutDollarKeys(Object? value) {
  if (value is Map) {
    return {
      for (final entry in value.entries)
        if (!entry.key.toString().startsWith(r'$'))
          entry.key.toString(): _withoutDollarKeys(entry.value),
    };
  }
  if (value is List) {
    return [for (final item in value) _withoutDollarKeys(item)];
  }
  return value;
}

/// 块风格 YAML，字符串一律双引号（对齐上游 `QUOTE_DOUBLE`）。
String toYaml(Object? value) {
  final buffer = StringBuffer();
  _writeYaml(buffer, value, 0, inline: true);
  return buffer.toString().trimRight();
}

void _writeYaml(
  StringBuffer out,
  Object? value,
  int indent, {
  required bool inline,
}) {
  final pad = '  ' * indent;
  if (value is Map) {
    if (value.isEmpty) {
      out.writeln(inline ? '{}' : '$pad{}');
      return;
    }
    if (inline && indent > 0) out.writeln();
    for (final entry in value.entries) {
      out.write('$pad${_yamlKey(entry.key.toString())}:');
      final child = entry.value;
      if (child is Map && child.isNotEmpty ||
          child is List && child.isNotEmpty) {
        out.writeln();
        _writeYaml(out, child, indent + 1, inline: false);
      } else {
        out.write(' ');
        _writeYaml(out, child, indent + 1, inline: true);
      }
    }
    return;
  }
  if (value is List) {
    if (value.isEmpty) {
      out.writeln(inline ? '[]' : '$pad[]');
      return;
    }
    if (inline && indent > 0) out.writeln();
    for (final item in value) {
      out.write('$pad-');
      if (item is Map && item.isNotEmpty || item is List && item.isNotEmpty) {
        out.writeln();
        _writeYaml(out, item, indent + 1, inline: false);
      } else {
        out.write(' ');
        _writeYaml(out, item, indent + 1, inline: true);
      }
    }
    return;
  }
  out.writeln(_yamlScalar(value));
}

String _yamlScalar(Object? value) {
  if (value == null) return 'null';
  if (value is String) return jsonEncode(value);
  return value.toString();
}

String _yamlKey(String key) =>
    RegExp(
          r'^[^\s:#\[\]{},&*!|>"%@`'
          "'"
          r'-][^:#]*$',
        ).hasMatch(key) &&
        key.trim() == key
    ? key
    : jsonEncode(key);
