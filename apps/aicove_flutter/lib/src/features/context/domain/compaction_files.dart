import 'dart:convert';

import '../../../core/models/block_status.dart';
import '../../../core/models/message_block.dart';
import '../../chat/domain/message.dart';

/// 程序维护的文件清单，不交给总结模型改写。路径逐行 JSON 编码，保留换行、引号等字面量。
class CompactionFiles {
  CompactionFiles({
    this.text = '',
    Iterable<String> read = const [],
    Iterable<String> modified = const [],
    this.workspace,
    this.readOmitted = 0,
    this.modifiedOmitted = 0,
  }) : read = List.unmodifiable(read),
       modified = List.unmodifiable(modified);

  final String text;
  final List<String> read, modified;
  final String? workspace;
  final int readOmitted, modifiedOmitted;

  static final _blocks = RegExp(
    r'<(read-files|modified-files|file-workspace)>\r?\n([\s\S]*?)\r?\n</\1>',
  );

  static CompactionFiles strip(String summary) {
    final reads = <String>[], edits = <String>[];
    String? workspace;
    var readOmitted = 0, modifiedOmitted = 0;
    final text = summary.replaceAllMapped(_blocks, (match) {
      final tag = match[1];
      for (final line in match[2]!.split('\n')) {
        final omitted = RegExp(r'^\[omitted: (\d+)\]$').firstMatch(line);
        if (omitted != null) {
          if (tag == 'read-files') readOmitted += int.parse(omitted[1]!);
          if (tag == 'modified-files') {
            modifiedOmitted += int.parse(omitted[1]!);
          }
          continue;
        }
        final value = _decode(line);
        // 同时接受最简单的逐行路径块，输出统一使用 JSON 字符串。
        final path = value is String ? value : line.trim();
        if (path.isEmpty) continue;
        if (tag == 'file-workspace') {
          workspace = path;
        } else {
          (tag == 'read-files' ? reads : edits).add(path);
        }
      }
      return '';
    }).trim();
    return _Files(
      CompactionFiles(
        text: text,
        read: reads,
        modified: edits,
        workspace: workspace,
        readOmitted: readOmitted,
        modifiedOmitted: modifiedOmitted,
      ),
    ).finish(text: text);
  }

  String appendTo(String summary) {
    final blocks = <String>[strip(summary).text];
    void add(String tag, List<String> paths, int omitted) {
      if (paths.isEmpty && omitted == 0) return;
      blocks.add(
        '<$tag>\n${[if (omitted > 0) '[omitted: $omitted]', ...paths.map(jsonEncode)].join('\n')}\n</$tag>',
      );
    }

    if (workspace != null) {
      blocks.add(
        '<file-workspace>\n${jsonEncode(workspace)}\n</file-workspace>',
      );
    }
    add('read-files', read, readOmitted);
    add('modified-files', modified, modifiedOmitted);
    return blocks.where((s) => s.isNotEmpty).join('\n\n');
  }
}

/// 发送前压缩：只看真实工具块；codemode 的成功子调用即使外层脚本失败也已产生效果。
CompactionFiles collectMessageFiles(
  Iterable<Message> messages, {
  CompactionFiles? previous,
}) {
  final files = _Files(previous ?? CompactionFiles());
  for (final message in messages) {
    for (final block
        in message.blocks?.whereType<ToolBlock>() ?? <ToolBlock>[]) {
      files.call(
        block.toolName,
        block.arguments,
        block.result,
        failed: block.status == BlockStatus.error,
      );
      final nested = block.result?['codemodeCalls'];
      if (block.toolName != 'codemode' || nested is! List) continue;
      for (final call in nested.whereType<Map>()) {
        if (call['status'] == 'error') continue;
        // args 仅有前 200 字符，不能 jsonDecode 整段；只取完整 JSON 字符串字面量。
        // 截断到路径中间的项跳过；运行时消息不提取 codemode 嵌套调用。
        final args = <String, dynamic>{};
        for (final match in RegExp(
          r'"(path|from|to)"\s*:\s*("(?:\\.|[^"\\])*")',
        ).allMatches(call['args'] is String ? call['args'] as String : '')) {
          final path = _decode(match[2]);
          if (path is String) args[match[1]!] = path;
        }
        files.call(call['name']?.toString() ?? '', args, null);
      }
    }
  }
  return files.finish();
}

/// 运行时压缩：按调用 ID 配对结果，兼容 OpenAI、Claude 和 Gemini 的消息形状。
/// 此处不解析 codemodeCalls：运行时没有完整的持久化嵌套调用记录。
CompactionFiles collectRuntimeFiles(Iterable<Map<String, dynamic>> messages) {
  final files = _Files(CompactionFiles());
  final calls = <String, (String, Object?)>{};
  void result(String id, Object? value, {bool failed = false}) {
    final call = calls.remove(id);
    if (call != null) files.call(call.$1, call.$2, value, failed: failed);
  }

  for (final message in messages) {
    if (message['role'] == 'assistant' && message['content'] is String) {
      files.merge(CompactionFiles.strip(message['content'] as String));
    }
    for (final call
        in (message['tool_calls'] as List? ?? []).whereType<Map>()) {
      final fn = call['function'];
      if (fn is Map) {
        calls['${call['id']}'] = ('${fn['name']}', fn['arguments']);
      }
    }
    final fn = message['function_call'];
    if (fn is Map) calls['${fn['name']}'] = ('${fn['name']}', fn['arguments']);
    if (message['role'] == 'tool' || message['role'] == 'function') {
      result('${message['tool_call_id'] ?? message['name']}', message);
    }
    final content = message['content'];
    final parts =
        message['parts'] ?? (content is Map ? content['parts'] : content);
    if (parts is! List) continue;
    for (final part in parts.whereType<Map>()) {
      if (part['type'] == 'tool_use') {
        calls['${part['id']}'] = ('${part['name']}', part['input']);
      } else if (part['type'] == 'tool_result') {
        result('${part['tool_use_id']}', part);
      } else if (part['functionCall'] is Map) {
        final fn = part['functionCall'] as Map;
        calls['${fn['name']}'] = ('${fn['name']}', fn['args']);
      } else if (part['functionResponse'] is Map) {
        final response = part['functionResponse'] as Map;
        result('${response['name']}', response['response']);
      }
    }
  }
  return files.finish();
}

Object? _decode(Object? value) {
  if (value is! String) return value;
  try {
    return jsonDecode(value);
  } on FormatException {
    return null;
  }
}

bool _failed(Object? value) {
  if (value is Map) {
    if (value['is_error'] == true ||
        value['isError'] == true ||
        value['error'] != null ||
        value['status'] == 'error') {
      return true;
    }
    return [
      'content',
      'text',
      'result',
      'output',
      'structured',
      'response',
    ].any((key) => _failed(value[key]));
  }
  if (value is List) return value.any(_failed);
  if (value is! String) return false;
  final decoded = _decode(value);
  if (decoded is Map || decoded is List) return _failed(decoded);
  return RegExp(
        r'^(invalid_path|not_found|revision_mismatch|busy|limit|read_only|unauthorized|unavailable|filesystem_error|invalid_argument|cancelled|ambiguous|overlap):',
      ).hasMatch(value.trimLeft()) ||
      value.startsWith('这里是表情库的只读视图，不能修改。');
}

String? _workspace(Object? value) {
  final decoded = _decode(value);
  if (decoded is Map) {
    if (decoded['workspace'] is String) return decoded['workspace'] as String;
    for (final key in ['structured', 'result', 'output', 'text', 'content']) {
      final found = _workspace(decoded[key]);
      if (found != null) return found;
    }
  }
  if (decoded is List) {
    for (final part in decoded) {
      final found = _workspace(part);
      if (found != null) return found;
    }
  }
  return value is String
      ? RegExp(
          r'^workspace:\s*(.+)$',
          multiLine: true,
        ).firstMatch(value)?.group(1)?.trim()
      : null;
}

class _Files {
  _Files(CompactionFiles previous) {
    merge(previous);
  }
  final read = <String>{}, modified = <String>{};
  String? workspace;
  var readOmitted = 0, modifiedOmitted = 0;

  void merge(CompactionFiles previous) {
    workspace = previous.workspace ?? workspace;
    readOmitted += previous.readOmitted;
    modifiedOmitted += previous.modifiedOmitted;
    for (final path in previous.read) {
      _record(path, false);
    }
    for (final path in previous.modified) {
      _record(path, true);
    }
  }

  void _record(String path, bool changed) {
    if (changed || modified.contains(path)) {
      read.remove(path);
      modified
        ..remove(path)
        ..add(path);
    } else {
      read
        ..remove(path)
        ..add(path);
    }
  }

  void call(
    String name,
    Object? arguments,
    Object? result, {
    bool failed = false,
  }) {
    // 与 Pi 一致：明确错误才排除，无法识别的结果按成功记录。
    if (failed || _failed(result)) return;
    final args = _decode(arguments);
    if (name == 'workspace_create') {
      workspace = _workspace(result) ?? workspace;
      return;
    }
    if (args is! Map) return;
    if (name == 'workspace_open') {
      final target = args['path'] ?? args['id'];
      if (target is String && target.isNotEmpty) workspace = target;
      return;
    }
    final keys = switch (name) {
      'read' || 'write' || 'edit' || 'workspace_delete' => ['path'],
      'workspace_move' => ['from', 'to'],
      _ => <String>[],
    };
    for (final key in keys) {
      final path = args[key];
      if (path is! String || path.isEmpty) continue;
      final absolute =
          path.startsWith('/') ||
          path.startsWith('~') ||
          path.startsWith(r'\') ||
          RegExp(r'^[A-Za-z]:[/\\]').hasMatch(path);
      _record(
        workspace == null || absolute ? path : '[$workspace] $path',
        name != 'read',
      );
    }
  }

  CompactionFiles finish({String text = ''}) {
    final dropRead = read.length > 100 ? read.length - 100 : 0;
    final dropModified = modified.length > 100 ? modified.length - 100 : 0;
    return CompactionFiles(
      text: text,
      read: read.skip(dropRead),
      modified: modified.skip(dropModified),
      workspace: workspace,
      readOmitted: readOmitted + dropRead,
      modifiedOmitted: modifiedOmitted + dropModified,
    );
  }
}
