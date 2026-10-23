import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:aicove_agent_kernel/aicove_agent_kernel.dart' show ToolEffect;
import 'package:path/path.dart' as p;

import '../../../core/storage/app_data_directory.dart';
import '../domain/handlers/ai_tool.dart';

/// Immutable full tool output, isolated by task/conversation. References remain
/// valid across task runs and app restarts; no raw filesystem paths are exposed.
class ToolResultStore {
  ToolResultStore(this.directory);
  final Future<Directory> Function() directory;
  static final shared = ToolResultStore(
    () async => Directory(
      p.join((await appDataDirectory()).path, 'agent_tool_results'),
    ),
  );
  static const maxInlineChars = 8192;
  static const readToolName = 'read_tool_result';

  /// Tools that only return short control replies; a request whose tools
  /// are all of these has nothing to read back.
  static const shortReplyTools = {'delegate_task', 'steer_task'};

  /// Whether a request offering [toolNames] should also offer the reader.
  static bool wantsReader(Iterable<String> toolNames) => toolNames.any(
    (name) => name != readToolName && !shortReplyTools.contains(name),
  );

  Future<Directory> _owner(String owner) async => Directory(
    p.join(
      (await directory()).path,
      base64Url.encode(utf8.encode(owner)).replaceAll('=', ''),
    ),
  );

  Future<String> preserve(String owner, String text) async {
    if (text.length <= maxInlineChars) return text;
    final root = await _owner(owner);
    await root.create(recursive: true);
    final random = Random.secure();
    final ref = List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    await File(p.join(root.path, '$ref.txt')).writeAsString(text, flush: true);
    return '[完整工具结果 reference=$ref；共 ${text.length} 字符。'
        '用 $readToolName(reference, offset, limit) 分页回读，offset 从 0 起。]\n'
        '${text.substring(0, 4096)}\n[中间内容已保存]\n${text.substring(text.length - 1024)}';
  }

  Future<String> read(
    String owner,
    String reference, {
    int offset = 0,
    int limit = 4096,
  }) async {
    if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(reference))
      throw const FormatException('Invalid result reference');
    if (offset < 0 || limit < 1 || limit > 8192)
      throw const FormatException('Invalid result range');
    final String text;
    try {
      text = await File(
        p.join((await _owner(owner)).path, '$reference.txt'),
      ).readAsString();
    } on FileSystemException {
      throw const FormatException(
        'Result reference unavailable on this device',
      );
    }
    if (offset > text.length)
      throw const FormatException('Offset exceeds result length');
    var end = min(text.length, offset + limit);
    bool splitsCharacter(int at) =>
        at > 0 &&
        at < text.length &&
        text.codeUnitAt(at - 1) >= 0xd800 &&
        text.codeUnitAt(at - 1) <= 0xdbff &&
        text.codeUnitAt(at) >= 0xdc00 &&
        text.codeUnitAt(at) <= 0xdfff;
    if (splitsCharacter(offset))
      throw const FormatException('Invalid result range');
    String page() {
      if (splitsCharacter(end)) end--;
      if (end == offset && offset < text.length)
        throw const FormatException('Invalid result range');
      return jsonEncode({
        'reference': reference,
        'offset': offset,
        'next_offset': end,
        'total_chars': text.length,
        'eof': end == text.length,
        'text': text.substring(offset, end),
      });
    }

    var encoded = page();
    // Escaping can make a JSON page much larger than its source. Keep the
    // reader itself below the inline cap instead of creating references to
    // pages of another reference. next_offset remains the source offset.
    while (encoded.length > maxInlineChars) {
      end = offset + (end - offset) ~/ 2;
      encoded = page();
    }
    return encoded;
  }

  AITool reader(String owner) => AITool(
    name: readToolName,
    description:
        '按完整工具结果的 reference 分页回读。offset 是从 0 起的字符偏移；limit 最多 8192。只能读取当前任务或会话保存的结果。',
    parameters: const {},
    inputSchema: const {
      'type': 'object',
      'properties': {
        'reference': {'type': 'string'},
        'offset': {'type': 'integer', 'minimum': 0},
        'limit': {'type': 'integer', 'minimum': 1, 'maximum': 8192},
      },
      'required': ['reference'],
    },
    effect: ToolEffect.readPrivate,
    handler: (args) => read(
      owner,
      args['reference'] as String,
      offset: (args['offset'] as num?)?.toInt() ?? 0,
      limit: (args['limit'] as num?)?.toInt() ?? 4096,
    ),
  );
}
