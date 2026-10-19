import 'dart:convert';

import 'package:aicove_agent_kernel/aicove_agent_kernel.dart' show ToolEffect;

import '../../plugins/domain/handlers/ai_tool.dart';
import '../data/workspace_store.dart';
import '../domain/workspace_errors.dart';
import '../domain/workspace_models.dart';
import '../domain/workspace_path_rules.dart';

/// Workspace tools of one agent run (ADR0087 §1–2). [workspaceIds] is the
/// run's effective grant; anything else fails as unauthorized. Writes are
/// recorded under [runId] so the run can be undone as a whole.
///
/// Not exposed to the chat model: W1 registers these only in tests, the
/// errand agent (ADR0088, batch W2) takes them over.
class WorkspaceToolset {
  WorkspaceToolset({
    required this.store,
    required Set<String> workspaceIds,
    required this.runId,
    this.onCreated,
    this.isCancelled,
  }) : _granted = {...workspaceIds};

  final WorkspaceStore store;
  final String runId;

  /// Adds a workspace the agent created to its role's grants.
  final Future<void> Function(WorkspaceInfo workspace)? onCreated;

  /// Checked right before every commit; a cancelled run writes nothing more.
  final bool Function()? isCancelled;

  final Set<String> _granted;

  /// Files this run created or changed, as (workspace, path), in order.
  final List<(String, String)> changed = [];

  void _beforeCommit() {
    if (isCancelled?.call() ?? false) {
      throw const WorkspaceException('cancelled', '任务已取消，不再写入');
    }
  }

  void _record(String workspaceId, String path) {
    changed.remove((workspaceId, path));
    changed.add((workspaceId, path));
  }

  Set<String> get workspaceIds => Set.unmodifiable(_granted);

  /// System prompt section: only names and descriptions; contents load on
  /// `workspace_open`, like package skills.
  Future<String?> prompt() async {
    final lines = [
      for (final info in await store.list())
        if (_granted.contains(info.id))
          '- ${info.name}（ID: ${info.id}）'
              '${info.description.isEmpty ? '' : '：${info.description}'}',
    ];
    if (lines.isEmpty) return null;
    return '你可以使用下面这些工作区。先用 workspace_open 打开，'
        '再用文件工具读写；修改已有文件要带上读取时得到的 revision。\n'
        '${lines.join('\n')}';
  }

  List<AITool> tools() => [
    _tool(
      'workspace_open',
      '打开工作区：返回它的 AGENTS.md 说明和顶层目录。',
      {'workspace': _workspaceParam},
      ['workspace'],
      ToolEffect.readDiagnostic,
      _open,
    ),
    _tool(
      'workspace_create',
      '新建一个工作区，新工作区自动授权给你。',
      {
        'name': {'type': 'string', 'description': '名称，最多 50 个字符'},
        'description': {'type': 'string', 'description': '一句话说明用途'},
      },
      ['name'],
      ToolEffect.write,
      _create,
    ),
    _tool(
      'workspace_read',
      '读取文本文件，返回内容和 revision。内容超过 64 KiB 时分页，'
          '用返回的 next_offset 继续读。',
      {
        'workspace': _workspaceParam,
        'path': _pathParam,
        'offset': {'type': 'integer', 'description': '从第几个字符开始，默认 0'},
      },
      ['workspace', 'path'],
      ToolEffect.readDiagnostic,
      _read,
    ),
    _tool(
      'workspace_write',
      '写入文本文件（整文件覆盖）。新建时不带 expected_revision；'
          '覆盖已有文件必须带读取时得到的 revision。',
      {
        'workspace': _workspaceParam,
        'path': _pathParam,
        'content': {'type': 'string', 'description': '文件全部内容，最多 1 MiB'},
        'expected_revision': _revisionParam,
      },
      ['workspace', 'path', 'content'],
      ToolEffect.write,
      _write,
    ),
    _tool(
      'workspace_edit',
      '把文件里的一段文字替换成新文字。old_text 必须在文件里只出现一次，'
          '除非 replace_all 为 true。',
      {
        'workspace': _workspaceParam,
        'path': _pathParam,
        'old_text': {'type': 'string', 'description': '要替换的原文'},
        'new_text': {'type': 'string', 'description': '替换后的文字'},
        'expected_revision': _revisionParam,
        'replace_all': {'type': 'boolean', 'description': '替换所有出现处'},
      },
      ['workspace', 'path', 'old_text', 'new_text', 'expected_revision'],
      ToolEffect.write,
      _edit,
    ),
    _tool(
      'workspace_list',
      '列出目录下的文件和子目录。',
      {
        'workspace': _workspaceParam,
        'path': {'type': 'string', 'description': '目录的相对路径，默认根目录'},
        'cursor': _cursorParam,
      },
      ['workspace'],
      ToolEffect.readDiagnostic,
      _list,
    ),
    _tool(
      'workspace_glob',
      '按通配符找文件，例如 **/*.md、notes/*.txt。',
      {
        'workspace': _workspaceParam,
        'pattern': {'type': 'string', 'description': '通配符，* 不跨目录，** 跨目录'},
        'cursor': _cursorParam,
      },
      ['workspace', 'pattern'],
      ToolEffect.readDiagnostic,
      _glob,
    ),
    _tool(
      'workspace_grep',
      '按正则表达式搜索文本文件的内容，返回「路径:行号: 内容」。',
      {
        'workspace': _workspaceParam,
        'pattern': {'type': 'string', 'description': '正则表达式'},
        'glob': {'type': 'string', 'description': '只搜匹配这个通配符的文件'},
        'cursor': _cursorParam,
      },
      ['workspace', 'pattern'],
      ToolEffect.readDiagnostic,
      _grep,
    ),
    _tool(
      'workspace_move',
      '移动或重命名文件；目标不能已存在。',
      {
        'workspace': _workspaceParam,
        'from': _pathParam,
        'to': _pathParam,
        'expected_revision': _revisionParam,
      },
      ['workspace', 'from', 'to', 'expected_revision'],
      ToolEffect.write,
      _move,
    ),
    _tool(
      'workspace_delete',
      '删除文件（可以撤销）。',
      {
        'workspace': _workspaceParam,
        'path': _pathParam,
        'expected_revision': _revisionParam,
      },
      ['workspace', 'path', 'expected_revision'],
      ToolEffect.write,
      _delete,
    ),
  ];

  static const _workspaceParam = {'type': 'string', 'description': '工作区 ID'};
  static const _pathParam = {
    'type': 'string',
    'description': '相对工作区根目录的路径，用 / 分隔',
  };
  static const _revisionParam = {
    'type': 'string',
    'description': '读取时得到的 revision',
  };
  static const _cursorParam = {
    'type': 'integer',
    'description': '上次结果给出的 next_cursor',
  };

  AITool _tool(
    String name,
    String description,
    Map<String, Object> properties,
    List<String> required,
    ToolEffect effect,
    Future<Map<String, Object?>> Function(Map<String, dynamic> args) run,
  ) => AITool(
    name: name,
    description: description,
    parameters: const {},
    inputSchema: {
      'type': 'object',
      'properties': properties,
      'required': required,
    },
    effect: effect,
    handler: (args) async {
      try {
        return jsonEncode(await run(args));
      } on WorkspaceException catch (error) {
        return jsonEncode({'error': error.code, 'message': error.message});
      } on FormatException catch (error) {
        return jsonEncode({
          'error': 'invalid_argument',
          'message': error.message,
        });
      }
    },
  );

  String _workspace(Map<String, dynamic> args) {
    final id = _string(args, 'workspace');
    if (!_granted.contains(id)) {
      throw WorkspaceException.unauthorized('没有使用工作区 $id 的授权');
    }
    return id;
  }

  static String _string(Map<String, dynamic> args, String key) {
    final value = args[key];
    if (value is! String) throw FormatException('缺少参数 $key');
    return value;
  }

  static String? _optionalString(Map<String, dynamic> args, String key) {
    final value = args[key];
    return value is String && value.isNotEmpty ? value : null;
  }

  static int _int(Map<String, dynamic> args, String key) {
    final value = args[key];
    return switch (value) {
      final int number when number >= 0 => number,
      final num number when number >= 0 => number.toInt(),
      _ => 0,
    };
  }

  // ---------------------------------------------------------------------

  Future<Map<String, Object?>> _open(Map<String, dynamic> args) async {
    final ws = _workspace(args);
    final info = (await store.get(ws))!;
    String? guide;
    if (await store.stat(ws, 'AGENTS.md') != null) {
      final text = _decode((await store.read(ws, 'AGENTS.md')).$1);
      guide = text == null ? null : _page(text, 0).$1;
    }
    final entries = await store.listDirectory(ws, '');
    return {
      'name': info.name,
      'description': info.description,
      'agents_md': guide,
      'entries': _entryNames(entries).take(WorkspaceLimits.maxResults).toList(),
    };
  }

  Future<Map<String, Object?>> _create(Map<String, dynamic> args) async {
    _beforeCommit();
    final info = await store.create(
      name: _string(args, 'name'),
      description: _optionalString(args, 'description') ?? '',
    );
    _granted.add(info.id);
    await onCreated?.call(info);
    return {'workspace': info.id, 'name': info.name};
  }

  Future<Map<String, Object?>> _read(Map<String, dynamic> args) async {
    final ws = _workspace(args);
    final (bytes, revision) = await store.read(ws, _string(args, 'path'));
    final text = _decode(bytes);
    if (text == null) {
      return {'revision': revision, 'binary': true, 'size': bytes.length};
    }
    final offset = _int(args, 'offset').clamp(0, text.length);
    final (content, next) = _page(text, offset);
    return {
      'revision': revision,
      'content': content,
      if (next != null) 'next_offset': next,
    };
  }

  Future<Map<String, Object?>> _write(Map<String, dynamic> args) async {
    final ws = _workspace(args);
    final bytes = utf8.encode(_string(args, 'content'));
    if (bytes.length > WorkspaceLimits.maxWriteBytes) {
      throw const WorkspaceException.limit('单次写入不能超过 1 MiB');
    }
    _beforeCommit();
    final file = await store.write(
      ws,
      _string(args, 'path'),
      bytes,
      expectedRevision: _optionalString(args, 'expected_revision'),
      runId: runId,
    );
    _record(ws, file.path);
    return {'path': file.path, 'revision': file.revision};
  }

  Future<Map<String, Object?>> _edit(Map<String, dynamic> args) async {
    final ws = _workspace(args);
    final path = _string(args, 'path');
    final oldText = _string(args, 'old_text');
    final newText = _string(args, 'new_text');
    if (oldText.isEmpty) throw const FormatException('old_text 不能为空');
    final expected = _string(args, 'expected_revision');
    final (bytes, revision) = await store.read(ws, path);
    if (revision != expected) {
      throw WorkspaceException.revisionMismatch('$path 在读取之后被改过，请重新读取后再改');
    }
    final text = _decode(bytes);
    if (text == null) {
      throw const WorkspaceException.invalidPath('二进制文件不能按文字编辑');
    }
    final count = oldText.allMatches(text).length;
    if (count == 0) {
      throw const WorkspaceException.notFound('文件里没有找到 old_text');
    }
    final replaceAll = args['replace_all'] == true;
    if (count > 1 && !replaceAll) {
      throw WorkspaceException(
        'ambiguous',
        'old_text 在文件里出现了 $count 次，请多带些上下文，或设 replace_all',
      );
    }
    final updated = utf8.encode(
      replaceAll
          ? text.replaceAll(oldText, newText)
          : text.replaceFirst(oldText, newText),
    );
    if (updated.length > WorkspaceLimits.maxWriteBytes) {
      throw const WorkspaceException.limit('编辑后的文件超过 1 MiB');
    }
    _beforeCommit();
    final file = await store.write(
      ws,
      path,
      updated,
      expectedRevision: expected,
      runId: runId,
    );
    _record(ws, file.path);
    return {'path': file.path, 'revision': file.revision, 'replaced': count};
  }

  Future<Map<String, Object?>> _list(Map<String, dynamic> args) async {
    final ws = _workspace(args);
    final entries = await store.listDirectory(
      ws,
      _optionalString(args, 'path') ?? '',
    );
    return _paged(_entryNames(entries).toList(), _int(args, 'cursor'));
  }

  Future<Map<String, Object?>> _glob(Map<String, dynamic> args) async {
    final ws = _workspace(args);
    final pattern = globToRegExp(_string(args, 'pattern'));
    final paths = [
      for (final file in await store.files(ws))
        if (pattern.hasMatch(file.path)) file.path,
    ];
    return _paged(paths, _int(args, 'cursor'));
  }

  Future<Map<String, Object?>> _grep(Map<String, dynamic> args) async {
    final ws = _workspace(args);
    final RegExp pattern;
    try {
      pattern = RegExp(_string(args, 'pattern'));
    } on FormatException {
      throw const FormatException('正则表达式写法不对');
    }
    final glob = _optionalString(args, 'glob');
    final filter = glob == null ? null : globToRegExp(glob);
    final cursor = _int(args, 'cursor');
    final hits = <String>[];
    var bytes = 0;
    var seen = 0;
    for (final file in await store.files(ws)) {
      if (filter != null && !filter.hasMatch(file.path)) continue;
      if (file.size > WorkspaceLimits.maxWriteBytes) continue;
      final text = _decode((await store.read(ws, file.path)).$1);
      if (text == null) continue;
      final lines = const LineSplitter().convert(text);
      for (final (index, line) in lines.indexed) {
        if (!pattern.hasMatch(line)) continue;
        if (seen++ < cursor) continue;
        final shown = line.length > 200 ? '${line.substring(0, 200)}…' : line;
        final hit = '${file.path}:${index + 1}: $shown';
        bytes += utf8.encode(hit).length + 1;
        if (hits.length >= WorkspaceLimits.maxResults ||
            bytes > WorkspaceLimits.maxResultBytes) {
          return {'matches': hits, 'truncated': true, 'next_cursor': seen - 1};
        }
        hits.add(hit);
      }
    }
    return {'matches': hits};
  }

  Future<Map<String, Object?>> _move(Map<String, dynamic> args) async {
    final ws = _workspace(args);
    final to = _string(args, 'to');
    _beforeCommit();
    await store.move(
      ws,
      _string(args, 'from'),
      to,
      expectedRevision: _string(args, 'expected_revision'),
      runId: runId,
    );
    final target = WorkspacePathRules.normalize(to);
    _record(ws, target);
    return {'path': target};
  }

  Future<Map<String, Object?>> _delete(Map<String, dynamic> args) async {
    final ws = _workspace(args);
    _beforeCommit();
    await store.delete(
      ws,
      _string(args, 'path'),
      expectedRevision: _string(args, 'expected_revision'),
      runId: runId,
    );
    return {'deleted': true};
  }

  // ---------------------------------------------------------------------

  static Iterable<String> _entryNames(List<WorkspaceEntry> entries) =>
      entries.map((e) => e.isDirectory ? '${e.name}/' : e.name);

  static String? _decode(List<int> bytes) {
    try {
      return utf8.decode(bytes);
    } on FormatException {
      return null;
    }
  }

  /// Up to 64 KiB of UTF-8 from [offset]; the next offset when more is left.
  static (String, int?) _page(String text, int offset) {
    var end = offset;
    var size = 0;
    while (end < text.length) {
      final unit = text.codeUnitAt(end);
      final pair = unit >= 0xD800 && unit <= 0xDBFF && end + 1 < text.length
          ? 2
          : 1;
      final bytes = pair == 2
          ? 4
          : unit < 0x80
          ? 1
          : unit < 0x800
          ? 2
          : 3;
      if (size + bytes > WorkspaceLimits.maxReadBytes) break;
      size += bytes;
      end += pair;
    }
    return (text.substring(offset, end), end < text.length ? end : null);
  }

  static Map<String, Object?> _paged(List<String> items, int cursor) {
    final page = <String>[];
    var bytes = 0;
    for (var i = cursor; i < items.length; i++) {
      bytes += utf8.encode(items[i]).length + 1;
      if (page.length >= WorkspaceLimits.maxResults ||
          bytes > WorkspaceLimits.maxResultBytes) {
        return {'items': page, 'truncated': true, 'next_cursor': i};
      }
      page.add(items[i]);
    }
    return {'items': page};
  }
}

/// `*` stays inside one directory, `**` crosses directories, `?` is one
/// character.
RegExp globToRegExp(String glob) {
  final out = StringBuffer('^');
  for (var i = 0; i < glob.length; i++) {
    final char = glob[i];
    if (char == '*') {
      if (i + 1 < glob.length && glob[i + 1] == '*') {
        final slash = i + 2 < glob.length && glob[i + 2] == '/';
        out.write(slash ? '(?:.*/)?' : '.*');
        i += slash ? 2 : 1;
      } else {
        out.write('[^/]*');
      }
    } else if (char == '?') {
      out.write('[^/]');
    } else {
      out.write(RegExp.escape(char));
    }
  }
  out.write(r'$');
  return RegExp(out.toString());
}
