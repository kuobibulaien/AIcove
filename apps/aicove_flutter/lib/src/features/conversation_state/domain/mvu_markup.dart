/// 从原始回复中提取 MVU 更新命令（ADR0071）。
///
/// 口径对齐 MVU：思考区（含嵌套、未闭合到文末）里的内容不执行；JSON Patch 块按
/// JSON 字符串规则找结束标签；脚本式命令在思考区与补丁块之外的任意位置识别，
/// 括号配对时跳过字符串字面量；补丁与脚本命令按原文位置排序。
library;

import 'dart:convert';

import '../../content_tags/domain/content_tag_scanner.dart';
import 'mvu_literal.dart';
import 'state_path.dart';

/// 命令类型；`assign`/`unset`/`remove` 已归一为 insert/delete。
enum MvuCommandType { set, insert, delete, add, move }

class MvuCommand {
  const MvuCommand({
    required this.type,
    required this.path,
    required this.args,
    required this.offset,
    required this.fullMatch,
    this.reason = '',
    this.fromPatch = false,
  });

  final MvuCommandType type;
  final List<Object> path;

  /// 路径之后的原始参数文本，执行时再按 [parseMvuCommandValue] 解析。
  final List<String> args;

  /// 在原文中的起始偏移，用于排序。
  final int offset;
  final String fullMatch;
  final String reason;
  final bool fromPatch;
}

class MvuExtraction {
  const MvuExtraction({
    required this.commands,
    required this.brokenBlocks,
    required this.hasUpdateMarkup,
  });

  final List<MvuCommand> commands;

  /// 无法解析的补丁块说明；它们只贡献零条命令。
  final List<String> brokenBlocks;

  /// 原文里是否出现了更新标签或命令（区分 no_ops 与解析失败）。
  final bool hasUpdateMarkup;
}

/// 解析与隐藏共用的更新块标签名（小写）。`<update>` 太通用，不支持。
const Set<String> mvuUpdateTagNames = {'updatevariable', 'variableupdate'};
const Set<String> mvuPatchTagNames = {'jsonpatch', 'json_patch'};
const Set<String> mvuThinkTagNames = {
  'think',
  'thinking',
  'reasoning',
  'analysis',
  'analyze',
};

MvuExtraction extractMvuCommands(String text) {
  final view = _scan(text);
  final commands = <MvuCommand>[];
  final broken = <String>[];
  for (final block in view.patchBlocks) {
    if (!block.closed) continue;
    final payload = text.substring(block.contentStart, block.contentEnd);
    try {
      final parsed = parseMvuDataBlock(payload);
      if (parsed is! List ||
          parsed.any((op) => op is! Map || op['op'] is! String)) {
        throw const FormatException('不是 JSON Patch 数组');
      }
      for (final op in parsed.cast<Map>()) {
        final command = _fromPatchOp(op, block.start);
        if (command != null) commands.add(command);
      }
    } on FormatException catch (error) {
      broken.add('第 ${block.start} 字处的 JSON Patch 无法解析：${error.message}');
    }
  }

  final legacy = view.visible.split('');
  for (final block in view.patchBlocks) {
    for (var i = block.start; i < block.end; i++) {
      if (legacy[i] != '\n') legacy[i] = ' ';
    }
  }
  final legacyText = legacy.join();
  var cursor = 0;
  while (cursor < text.length) {
    final match = _legacyCommand.firstMatch(legacyText.substring(cursor));
    if (match == null) break;
    final start = cursor + match.start;
    final open = start + match[0]!.length;
    final close = _matchingParen(text, open);
    if (close < 0) {
      cursor = open;
      continue;
    }
    var end = close + 1;
    if (end >= text.length || text[end] != ';') {
      cursor = end;
      continue;
    }
    end++;
    final comment = _comment.matchAsPrefix(text, end);
    final reason = comment?.group(1)?.trim() ?? '';
    final params = _splitParameters(text.substring(open, close));
    cursor = comment?.end ?? end;
    if (params.isEmpty) continue;
    final name = match[1]!;
    commands.add(
      MvuCommand(
        type: switch (name) {
          'set' => MvuCommandType.set,
          'insert' || 'assign' => MvuCommandType.insert,
          'add' => MvuCommandType.add,
          _ => MvuCommandType.delete,
        },
        path: parseStatePath(params.first),
        args: params.sublist(1),
        offset: start,
        fullMatch: text.substring(start, end),
        reason: reason,
      ),
    );
  }
  commands.sort((a, b) => a.offset.compareTo(b.offset));
  return MvuExtraction(
    commands: List.unmodifiable(commands),
    brokenBlocks: List.unmodifiable(broken),
    hasUpdateMarkup:
        view.hasUpdateTag || view.patchBlocks.isNotEmpty || commands.isNotEmpty,
  );
}

MvuCommand? _fromPatchOp(Map op, int offset) {
  final name = op['op'] as String;
  final full = jsonEncode(op);
  final path = parseJsonPointer((op['path'] ?? op['to'] ?? '').toString());
  String encode(Object? value) => jsonEncode(value);
  switch (name) {
    case 'replace':
      return MvuCommand(
        type: MvuCommandType.set,
        path: path,
        args: [encode(op['value'])],
        offset: offset,
        fullMatch: full,
        fromPatch: true,
      );
    case 'delta':
      return MvuCommand(
        type: MvuCommandType.add,
        path: path,
        args: [encode(op['value'])],
        offset: offset,
        fullMatch: full,
        fromPatch: true,
      );
    case 'add':
    case 'insert':
      if (path.isEmpty) return null;
      final last = path.last;
      return MvuCommand(
        type: MvuCommandType.insert,
        path: path.sublist(0, path.length - 1),
        args: [last is int ? '$last' : encode(last), encode(op['value'])],
        offset: offset,
        fullMatch: full,
        fromPatch: true,
      );
    case 'remove':
      return MvuCommand(
        type: MvuCommandType.delete,
        path: path,
        args: const [],
        offset: offset,
        fullMatch: full,
        fromPatch: true,
      );
    case 'move':
      return MvuCommand(
        type: MvuCommandType.move,
        path: parseJsonPointer((op['from'] ?? '').toString()),
        args: [(op['path'] ?? '').toString()],
        offset: offset,
        fullMatch: full,
        fromPatch: true,
      );
  }
  return null;
}

class _PatchBlock {
  _PatchBlock(this.start, this.contentStart);
  final int start;
  final int contentStart;
  int contentEnd = -1;
  int end = -1;
  bool closed = false;
}

class _MarkupView {
  _MarkupView(this.visible, this.patchBlocks, this.hasUpdateTag);
  final String visible;
  final List<_PatchBlock> patchBlocks;
  final bool hasUpdateTag;
}

_MarkupView _scan(String text) {
  final visible = text.split('');
  final blocks = <_PatchBlock>[];
  final thinkStack = <String>[];
  var hasUpdateTag = false;
  _PatchBlock? patch;

  void hide(int start, int end) {
    for (var i = start; i < end && i < visible.length; i++) {
      if (text[i] != '\n' && text[i] != '\r') visible[i] = ' ';
    }
  }

  var i = 0;
  while (i < text.length) {
    final char = text[i];
    if (thinkStack.isNotEmpty) {
      final tag = char == '<' ? _tag.matchAsPrefix(text, i) : null;
      if (tag != null && mvuThinkTagNames.contains(tag[2]!.toLowerCase())) {
        final name = tag[2]!.toLowerCase();
        if (tag[1]!.isNotEmpty) {
          if (thinkStack.last == name) thinkStack.removeLast();
        } else {
          thinkStack.add(name);
        }
        hide(i, tag.end);
        i = tag.end;
        continue;
      }
      hide(i, i + 1);
      i++;
      continue;
    }
    if (patch != null) {
      final tag = char == '<' ? _tag.matchAsPrefix(text, i) : null;
      if (tag != null &&
          tag[1]!.isNotEmpty &&
          mvuPatchTagNames.contains(tag[2]!.toLowerCase()) &&
          !isInsideJsonString(text, patch.contentStart, i)) {
        patch
          ..contentEnd = i
          ..end = tag.end
          ..closed = true;
        blocks.add(patch);
        patch = null;
        i = tag.end;
        continue;
      }
      i++;
      continue;
    }
    final tag = char == '<' ? _tag.matchAsPrefix(text, i) : null;
    if (tag != null) {
      final name = tag[2]!.toLowerCase();
      final closing = tag[1]!.isNotEmpty;
      if (mvuThinkTagNames.contains(name)) {
        if (!closing) thinkStack.add(name);
        hide(i, tag.end);
        i = tag.end;
        continue;
      }
      if (mvuPatchTagNames.contains(name) && !closing) {
        patch = _PatchBlock(i, tag.end);
        i = tag.end;
        continue;
      }
      if (mvuUpdateTagNames.contains(name)) hasUpdateTag = true;
    }
    i++;
  }
  if (patch != null) {
    patch
      ..contentEnd = text.length
      ..end = text.length;
    blocks.add(patch);
  }
  return _MarkupView(visible.join(), blocks, hasUpdateTag);
}

int _matchingParen(String text, int open) {
  var depth = 1;
  String? quote;
  for (var i = open; i < text.length; i++) {
    final char = text[i];
    if (quote != null) {
      if (char == '\\') {
        i++;
      } else if (char == quote) {
        quote = null;
      }
      continue;
    }
    if (char == '"' || char == "'" || char == '`') {
      quote = char;
    } else if (char == '(') {
      depth++;
    } else if (char == ')') {
      depth--;
      if (depth == 0) return i;
    }
  }
  return -1;
}

/// 对齐 MVU `parseParameters`：只在引号外且各类括号都闭合时按逗号切分。
List<String> _splitParameters(String source) {
  final params = <String>[];
  final current = StringBuffer();
  String? quote;
  var paren = 0, bracket = 0, brace = 0;
  for (var i = 0; i < source.length; i++) {
    final char = source[i];
    if ((char == '"' || char == "'" || char == '`') &&
        (i == 0 || source[i - 1] != '\\')) {
      if (quote == null) {
        quote = char;
      } else if (char == quote) {
        quote = null;
      }
    }
    if (quote == null) {
      if (char == '(') paren++;
      if (char == ')') paren--;
      if (char == '[') bracket++;
      if (char == ']') bracket--;
      if (char == '{') brace++;
      if (char == '}') brace--;
      if (char == ',' && paren == 0 && bracket == 0 && brace == 0) {
        params.add(current.toString().trim());
        current.clear();
        continue;
      }
    }
    current.write(char);
  }
  if (current.toString().trim().isNotEmpty) {
    params.add(current.toString().trim());
  }
  return params;
}

final RegExp _tag = RegExp(r'<(/?)\s*([A-Za-z_]+)\b[^>]*>');
final RegExp _legacyCommand = RegExp(
  r'_\.(set|insert|assign|remove|unset|delete|add)\(',
);
final RegExp _comment = RegExp(r'[ \t]*//([^\n]*)');
