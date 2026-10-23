import '../data/workspace_read_only_mount.dart' show stickerViewReadOnly;
import 'package:mime/mime.dart';
import 'dart:convert';
import 'dart:async';
import 'workspace_image.dart';
import 'workspace_script.dart';
import 'codemode_script.dart';
import 'codemode_declarations.dart' show codemodeGuidance;
import 'workspace_shell.dart';
import 'dart:io';

import 'package:aicove_agent_kernel/aicove_agent_kernel.dart' show ToolEffect;

import '../../plugins/domain/handlers/ai_tool.dart';
import '../data/workspace_store.dart';
import '../domain/workspace_errors.dart';
import '../domain/workspace_models.dart';
import '../domain/workspace_path_rules.dart';
import '../webapp/webapp_server.dart' show WebAppServer;

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
    this.enableScripts = false,
    this.enableShell = false,
    this.platform,
    this.runWebApp,
    this.shellEnvironment,
    String? currentWorkspaceId,
  }) : _granted = {...workspaceIds},
       _currentWorkspaceId =
           currentWorkspaceId ??
           (workspaceIds.contains('aicove')
               ? 'aicove'
               : workspaceIds.firstOrNull);

  final WorkspaceStore store;
  final String runId;

  /// Adds a workspace the agent created to its role's grants.
  final Future<void> Function(WorkspaceInfo workspace)? onCreated;

  /// Checked right before every commit; a cancelled run writes nothing more.
  final bool Function()? isCancelled;
  final bool enableScripts;
  final bool enableShell;
  final String? platform;

  /// Serves a workspace page on AIcove's loopback host and opens it in the
  /// default browser (ADR0105); returns the page URL. Null hides `workspace_run`.
  final Future<Uri> Function(String workspaceId, String path)? runWebApp;

  /// Channel keys for `bash`, read at every command (ADR0109 补充二).
  final Map<String, String> Function()? shellEnvironment;
  String? _currentWorkspaceId;
  String? get currentWorkspaceId => _currentWorkspaceId;

  final Set<String> _granted;

  /// Files this run created or changed, as (workspace, path), in order.
  final List<(String, String)> changed = [];

  void _beforeCommit() {
    if ((isCancelled?.call() ?? false) ||
        (ToolCallContext.current?.cancellation?.isCancelled ?? false)) {
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

    return '$codemodeGuidance\n当前工作区：${_currentWorkspaceId ?? '未选择'}。可用工作区：\n'
        '${lines.join('\n')}\n路径都相对当前工作区。用 workspace_open({id}) 切换；workspace_create 新建后自动切换。'
        '${runWebApp == null ? '' : '\n$_webAppHint'}';
  }

  List<AITool> tools() => [
    if (enableShell &&
        [
          'macos',
          'windows',
          'linux',
        ].contains(platform ?? Platform.operatingSystem))
      AITool(
        name: 'bash',
        description:
            '在工作区目录执行命令，权限与当前登录用户相同（macOS 应用不在沙盒里），可以读写整台电脑上该用户能访问的文件，并使用系统已安装的命令行工具（git、python3 等需要已安装）。命令直接执行，不经确认；用户开启「修改前每次问我」后逐条确认。macOS/Linux 使用 /bin/sh -c，Windows 使用 powershell -NoProfile -Command。命令改动无法撤销；同一任务的多条命令可以同时运行；运行期间锁住工作区其他写入，最后一条结束后统一还原 .aicove/ 并扫描登记变化。默认不限时，timeout 可指定秒数，取消／超时停止整个进程树。输出最后 2000 行或 50 KiB，截断产物在 .aicove/outputs/，最多保留最后 8 MiB。'
            '${shellEnvironment == null ? '' : _keyHint}',
        parameters: const {},
        inputSchema: {
          'type': 'object',
          'properties': {
            'command': {'type': 'string'},
            'timeout': {
              'type': 'integer',
              'minimum': 1,
              'description': 'Seconds; omitted means no timeout',
            },
          },
          'required': ['command'],
        },
        effect: ToolEffect.external,
        concurrent: true,
        managesDeadline: true,
        outputSchema: WorkspaceShell.outputSchema,
        handler: (args) async => (await _runShell(args)).persistentText,
        richHandler: _runShell,
      ),
    if (enableScripts)
      AITool(
        name: 'codemode',
        description:
            'Run JavaScript that calls tools; top-level await and return work.',
        parameters: const {},
        inputSchema: const {
          'type': 'object',
          'properties': {
            'code': {'type': 'string', 'description': 'Raw JavaScript source.'},
          },
          'required': ['code'],
          'additionalProperties': false,
        },
        effect: ToolEffect.external,
        managesDeadline: true,
        handler: (args) async => (await _runScript(args)).persistentText,
        richHandler: _runScript,
      ),
    _tool(
      'workspace_open',
      '打开工作区：返回它的 AGENTS.md 说明和顶层目录。',
      {'id': _workspaceParam},
      ['id'],
      ToolEffect.readDiagnostic,
      _open,
    ),
    if (runWebApp != null)
      _tool(
        'workspace_run',
        '用 AIcove 自带的本机服务运行当前工作区里的 .html／.htm 网页，并在用户的默认浏览器里打开。'
            '返回网页地址和给网页用的 AI 接口地址。',
        {'path': _pathParam},
        ['path'],
        ToolEffect.external,
        _run,
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
      'read',
      '按行读取文本或查看图片；offset 从 1 开始，最多 2000 行或 50 KiB，返回续读行号与 revision。',
      {
        'path': _pathParam,
        'offset': {'type': 'integer', 'description': '起始行，从 1 开始'},
        'limit': {'type': 'integer', 'description': '行数，默认 2000'},
      },
      ['path'],
      ToolEffect.readDiagnostic,
      _read,
    ),
    _tool(
      'write',
      '写入文本文件，整文件覆盖并自动建目录；expected_revision 可选，冲突时重新读取。',
      {
        'path': _pathParam,
        'content': {'type': 'string', 'description': '文件全部内容，最多 1 MiB'},
        'expected_revision': _revisionParam,
      },
      ['path', 'content'],
      ToolEffect.write,
      _write,
    ),
    _tool(
      'edit',
      '一次编辑多处文本，各 oldText 必须在原文件唯一且互不重叠；保留 BOM 和换行，返回 diff。兼容 old_text/new_text。',
      {
        'path': _pathParam,
        'old_text': {'type': 'string', 'description': '要替换的原文'},
        'new_text': {'type': 'string', 'description': '替换后的文字'},
        'expected_revision': _revisionParam,
        'edits': {
          'type': 'array',
          'items': {
            'type': 'object',
            'properties': {
              'oldText': {'type': 'string'},
              'newText': {'type': 'string'},
            },
            'required': ['oldText', 'newText'],
          },
        },
      },
      ['path'],
      ToolEffect.write,
      _edit,
    ),
    _tool(
      'workspace_list',
      '列出目录下的文件和子目录。',
      {
        'path': {'type': 'string', 'description': '目录的相对路径，默认根目录'},
        'cursor': _cursorParam,
      },
      [],
      ToolEffect.readDiagnostic,
      _list,
    ),
    _tool(
      'workspace_glob',
      '按通配符找文件，例如 **/*.md、notes/*.txt。',
      {
        'pattern': {'type': 'string', 'description': '通配符，* 不跨目录，** 跨目录'},
        'cursor': _cursorParam,
      },
      ['pattern'],
      ToolEffect.readDiagnostic,
      _glob,
    ),
    _tool(
      'workspace_grep',
      '按正则表达式搜索文本文件的内容，返回「路径:行号: 内容」。',
      {
        'pattern': {'type': 'string', 'description': '正则表达式'},
        'glob': {'type': 'string', 'description': '只搜匹配这个通配符的文件'},
        'cursor': _cursorParam,
      },
      ['pattern'],
      ToolEffect.readDiagnostic,
      _grep,
    ),
    _tool(
      'workspace_move',
      '移动或重命名文件；目标不能已存在。',
      {
        'from': _pathParam,
        'to': _pathParam,
        'expected_revision': _revisionParam,
      },
      ['from', 'to'],
      ToolEffect.write,
      _move,
    ),
    _tool(
      'workspace_delete',
      '删除文件（可以撤销）。',
      {'path': _pathParam, 'expected_revision': _revisionParam},
      ['path'],
      ToolEffect.write,
      _delete,
    ),
  ];

  Future<ToolOutput> _runScript(Map<String, dynamic> args) async {
    final context = ToolCallContext.current;
    return CodemodeScript(
      store: store,
      workspace: () => _currentWorkspaceId,
      runId: runId,
      owner: context?.stateOwner ?? context?.sessionId ?? runId,
      callId: context?.toolCallId ?? 'codemode',
      tools: context?.scriptTools,
      isCancelled: () =>
          (isCancelled?.call() ?? false) ||
          (context?.isCancelled?.call() ?? false) ||
          (context?.cancellation?.isCancelled ?? false),
    ).run(_string(args, 'code'));
  }

  Future<ToolOutput> _runShell(Map<String, dynamic> args) async {
    try {
      final context = ToolCallContext.current;
      return await WorkspaceShell(
        store: store,
        workspace: _workspace(args),
        runId: runId,
        isCancelled: () =>
            (isCancelled?.call() ?? false) ||
            (context?.isCancelled?.call() ?? false),
        environment: shellEnvironment,
      ).run(
        _string(args, 'command'),
        timeout: WorkspaceShell.deadline(args['timeout']),
      );
    } on Object catch (error) {
      return ToolOutput(
        text: WorkspaceScriptOutput.modelTail('$error').trimRight(),
        isError: true,
      );
    }
  }

  static const _keyHint =
      ' 用户在 AIcove 配好的渠道 Key 在环境变量里：AICOVE_KEYS 列出「ID:渠道名」，'
      '每个渠道有 AICOVE_KEY_<ID>（Key）和 AICOVE_URL_<ID>（接口地址），比如 NovelAI 渠道是 AICOVE_KEY_NOVELAI。'
      '要把 Key 填进网页设置或配置文件时，在命令或脚本里直接读环境变量写进去（如 python3 的 os.environ），'
      '不要 echo 或打印 Key，输出里的 Key 会被打码；也不要让用户把 Key 发到聊天里。';

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
    Future<Object> Function(Map<String, dynamic> args) run,
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
    handler: (args) async => (await _invoke(run, args)).persistentText,
    richHandler: (args) => _invoke(run, args),
    controlledHandler: (args, control) async {
      control.progress('Starting $name');
      final result = await _invoke(run, args);
      control.progress('Finished $name');
      return result;
    },
  );

  Future<ToolOutput> _invoke(
    Future<Object> Function(Map<String, dynamic>) run,
    Map<String, dynamic> args,
  ) async {
    try {
      final result = await run(args);
      return result is ToolOutput
          ? result
          : ToolOutput(text: _format(result), structured: result);
    } on WorkspaceException catch (error) {
      return ToolOutput(
        text: error.message == stickerViewReadOnly
            ? stickerViewReadOnly
            : '${error.code}: ${error.message}',
        isError: true,
      );
    } on FormatException catch (error) {
      return ToolOutput(
        text: 'invalid_argument: ${error.message}',
        isError: true,
      );
    }
  }

  static String _format(Object? value) {
    if (value is Map) {
      return value.entries
          .map((e) => '${e.key}: ${_format(e.value)}')
          .join('\n');
    }
    if (value is List) return value.map(_format).join('\n');
    return value?.toString() ?? '';
  }

  String _workspace(Map<String, dynamic> args) {
    final id = _currentWorkspaceId;
    if (id == null || !_granted.contains(id)) {
      throw const WorkspaceException.unauthorized('没有可用的当前工作区');
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
    final ws = _string(args, 'id');
    if (!_granted.contains(ws))
      throw WorkspaceException.unauthorized('没有使用工作区 $ws 的授权');
    final info = (await store.get(ws))!;
    _currentWorkspaceId = ws;
    String? guide;
    if (await store.stat(ws, 'AGENTS.md') != null) {
      final text = _decode((await store.read(ws, 'AGENTS.md')).$1);
      guide = text == null ? null : _page(text, 1).$1;
    }
    final entries = await store.listDirectory(ws, '');
    return {
      'name': info.name,
      'description': info.description,
      'agents_md': guide,
      'webapp_guide':
          '.html／.htm 用 workspace_run 运行（或由用户在空间页点「运行」），在默认浏览器里打开。'
          '页面只能加载本空间里的文件，依赖 CDN 的要先下载到空间里；只支持 UTF-8 等 ASCII 兼容编码。'
          '存档在同目录 <文件名去扩展名>.save.json，格式 '
          '{"format":"aicove.webapp.save.v1","localStorage":{...}}：'
          '值是对象／数组时可以直接改字段，其余是原样字符串。改完后游戏页面几秒内自动重载。'
          '网页代码用了 indexedDB 的，那部分进度存在浏览器里，你看不到也改不了，要提醒用户。'
          'RPG Maker MV 等引擎的存档是压缩过的字符串，要先解码再改，改完按原方式编码回去。'
          '网页要调用 AI 时用 await window.aicove.chat(messages, {temperature, max_tokens})，'
          'messages 是 [{role:"system|user|assistant",content:"…"}] 或一个字符串，返回模型回复文字；'
          '失败时抛出 Error，error.code 为 bad_request／busy／no_model／model_failed／disconnected。'
          '它走用户在 AIcove 里配好的默认聊天模型，只在 AIcove 运行且用户点过「运行」时可用，费用记在用户的额度上，同一空间同时最多 2 个请求。'
          '页面可以连外网和本机其他端口（如 http://127.0.0.1:8188 的 ComfyUI）。'
          '聊天类 AI 优先走上面的本机服务；生图等本机服务不代调的功能，网页自己连外部服务，'
          '需要 Key 时用 bash 环境变量里的渠道 Key 写进 .save.json（见 bash 说明），不要让用户手填。'
          '自带 API 设置的第三方网页（OpenAI 兼容）不用改代码：把它的 API 地址设成 workspace_run 返回的 ai_base_url，'
          'Key 随便填或留空，模型填 ${WebAppServer.openAiModel}；支持 /models 和 /chat/completions（含 stream，整段一次返回）。'
          '这类设置通常存在 localStorage，可以先读网页代码找到键名，再改 .save.json 写进去，省得用户手填。',
      'entries': _entryNames(entries).take(WorkspaceLimits.maxResults).toList(),
    };
  }

  static const _webAppHint =
      '网页、网页游戏要运行时用 workspace_run，不要自己起服务器（bash 结束后进程会被回收）。'
      '网页可以通过 AIcove 本机服务调用用户在 AIcove 里配好的默认模型；'
      '网页也能连外网，生图等功能要 Key 时用 bash 环境变量里的渠道 Key 写进设置；'
      '具体写法和改存档的方法见 workspace_open 返回的 webapp_guide。';

  Future<Map<String, Object?>> _run(Map<String, dynamic> args) async {
    final ws = _workspace(args);
    final uri = await runWebApp!(ws, _string(args, 'path'));
    return {
      'url': '$uri',
      'ai_base_url': '${uri.origin}/__aicove/v1',
      'note': '页面里也可以直接用 window.aicove.chat；网页依赖 CDN 的要先下载到空间里。',
    };
  }

  Future<Map<String, Object?>> _create(Map<String, dynamic> args) async {
    _beforeCommit();
    final info = await store.create(
      name: _string(args, 'name'),
      description: _optionalString(args, 'description') ?? '',
    );
    _beforeCommit();
    _granted.add(info.id);
    _currentWorkspaceId = info.id;
    await onCreated?.call(info);
    return {'workspace': info.id, 'name': info.name};
  }

  Future<ToolOutput> _read(Map<String, dynamic> args) async {
    final ws = _workspace(args);
    final path = _string(args, 'path');
    final (bytes, revision) = await store.read(ws, path);
    final image = await prepareWorkspaceImage(bytes, '$ws/$path');
    if (image != null) {
      return ToolOutput(text: 'revision: $revision', images: [image]);
    }
    final text = _decode(bytes);
    if (text == null || text.contains('\u0000')) {
      return ToolOutput(
        text:
            '二进制文件（${lookupMimeType(path, headerBytes: bytes.take(32).toList()) ?? 'application/octet-stream'}），${bytes.length} 字节。${enableScripts ? '可用 codemode 的 ws.readBytes 分段处理。' : ''}\nrevision: $revision',
      );
    }
    final offset = args.containsKey('offset') ? _int(args, 'offset') : 1;
    if (offset < 1) throw const FormatException('offset 从 1 开始');
    final limit = args.containsKey('limit') ? _int(args, 'limit') : 2000;
    if (limit < 1) throw const FormatException('limit 必须大于 0');
    final (content, next) = _page(text, offset, limit: limit);
    return ToolOutput(
      text:
          '$content\nrevision: $revision${next == null ? '' : '\n内容已截断，下次 offset: $next'}',
    );
  }

  Future<Map<String, Object?>> _write(Map<String, dynamic> args) async {
    final ws = _workspace(args);
    final path = _string(args, 'path');
    store.checkWritablePath(ws, path);
    final bytes = utf8.encode(_string(args, 'content'));
    if (bytes.length > WorkspaceLimits.maxWriteBytes) {
      throw const WorkspaceException.limit('单次写入不能超过 1 MiB');
    }
    final expected =
        _optionalString(args, 'expected_revision') ??
        await _currentRevision(ws, path);
    _beforeCommit();
    final file = await store.write(
      ws,
      path,
      bytes,
      expectedRevision: expected,
      runId: runId,
    );
    _record(ws, file.path);
    return {'path': file.path, 'revision': file.revision};
  }

  Future<String?> _currentRevision(String ws, String path) async =>
      await store.stat(ws, path) == null
      ? null
      : (await store.read(ws, path)).$2;

  Future<ToolOutput> _edit(Map<String, dynamic> args) async {
    final ws = _workspace(args), path = _string(args, 'path');
    store.checkWritablePath(ws, path);
    final (bytes, revision) = await store.read(ws, path);
    final expected = _optionalString(args, 'expected_revision') ?? revision;
    if (expected != revision) {
      throw const WorkspaceException.revisionMismatch('文件刚被改过，请重新读取');
    }
    final decoded = _decode(bytes);
    if (decoded == null) throw const FormatException('二进制文件不能按文字编辑');
    final bom =
        bytes.length >= 3 &&
        bytes[0] == 239 &&
        bytes[1] == 187 &&
        bytes[2] == 191;
    final text = decoded.startsWith('\ufeff') ? decoded.substring(1) : decoded;
    final crlf = text.contains('\r\n');
    String normalize(String v) =>
        crlf ? v.replaceAll('\r\n', '\n').replaceAll('\n', '\r\n') : v;
    final edits = args['edits'] is List
        ? args['edits'] as List
        : [
            {
              'oldText': _string(args, 'old_text'),
              'newText': _string(args, 'new_text'),
            },
          ];
    if (edits.isEmpty) throw const FormatException('edits 不能为空');
    final replacements = <(int, int, String)>[];
    for (final edit in edits) {
      if (edit is! Map ||
          edit['oldText'] is! String ||
          edit['newText'] is! String) {
        throw const FormatException('edits 需要 oldText/newText');
      }
      final old = normalize(edit['oldText'] as String),
          value = normalize(edit['newText'] as String);
      if (old.isEmpty) throw const FormatException('oldText 不能为空');
      final positions = <int>[];
      for (var start = 0; start <= text.length - old.length; start++) {
        if (text.startsWith(old, start)) positions.add(start);
      }
      if (positions.length != 1) {
        throw const WorkspaceException('ambiguous', 'oldText 必须在文件里唯一');
      }
      replacements.add((
        positions.single,
        positions.single + old.length,
        value,
      ));
    }
    replacements.sort((a, b) => a.$1.compareTo(b.$1));
    for (var i = 1; i < replacements.length; i++) {
      if (replacements[i].$1 < replacements[i - 1].$2) {
        throw const WorkspaceException('overlap', '编辑范围重叠');
      }
    }
    var updated = text;
    for (final r in replacements.reversed) {
      updated = updated.replaceRange(r.$1, r.$2, r.$3);
    }
    final encoded = [
      ...(bom ? [239, 187, 191] : <int>[]),
      ...utf8.encode(updated),
    ];
    if (encoded.length > WorkspaceLimits.maxWriteBytes) {
      throw const WorkspaceException.limit('编辑后的文件超过 1 MiB');
    }
    _beforeCommit();
    final file = await store.write(
      ws,
      path,
      encoded,
      expectedRevision: expected,
      runId: runId,
    );
    _record(ws, file.path);
    final firstLine =
        '\n'.allMatches(text.substring(0, replacements.first.$1)).length + 1;
    // One valid unified hunk; bounded presentation, not a patch transport.
    final oldLines = const LineSplitter().convert(text),
        newLines = const LineSplitter().convert(updated);
    var prefix = 0;
    while (prefix < oldLines.length &&
        prefix < newLines.length &&
        oldLines[prefix] == newLines[prefix]) {
      prefix++;
    }
    var suffix = 0;
    while (suffix < oldLines.length - prefix &&
        suffix < newLines.length - prefix &&
        oldLines[oldLines.length - 1 - suffix] ==
            newLines[newLines.length - 1 - suffix]) {
      suffix++;
    }
    final diff = [
      '--- a/$path',
      '+++ b/$path',
      '@@ -${prefix + 1},${oldLines.length - prefix - suffix} +${prefix + 1},${newLines.length - prefix - suffix} @@',
      for (final line
          in oldLines.skip(prefix).take(oldLines.length - prefix - suffix))
        '-$line',
      for (final line
          in newLines.skip(prefix).take(newLines.length - prefix - suffix))
        '+$line',
    ];
    return ToolOutput(
      text:
          '${diff.take(200).join('\n')}${diff.length > 200 ? '\n(diff 已截断)' : ''}\nfirst_changed_line: $firstLine\nrevision: ${file.revision}',
    );
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
        final chars = line.runes;
        final shown = chars.length > WorkspaceLimits.maxGrepLineChars
            ? '${String.fromCharCodes(chars.take(WorkspaceLimits.maxGrepLineChars - 1))}…'
            : line;
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
    store.checkWritablePath(ws, _string(args, 'from'));
    store.checkWritablePath(ws, to);
    final expected =
        _optionalString(args, 'expected_revision') ??
        (await store.read(ws, _string(args, 'from'))).$2;
    _beforeCommit();
    await store.move(
      ws,
      _string(args, 'from'),
      to,
      expectedRevision: expected,
      runId: runId,
    );
    final target = WorkspacePathRules.normalize(to);
    _record(ws, target);
    return {'path': target};
  }

  Future<Map<String, Object?>> _delete(Map<String, dynamic> args) async {
    final ws = _workspace(args);
    store.checkWritablePath(ws, _string(args, 'path'));
    final expected =
        _optionalString(args, 'expected_revision') ??
        (await store.read(ws, _string(args, 'path'))).$2;
    _beforeCommit();
    await store.delete(
      ws,
      _string(args, 'path'),
      expectedRevision: expected,
      runId: runId,
    );
    return {'deleted': true};
  }

  // ---------------------------------------------------------------------

  static Iterable<String> _entryNames(List<WorkspaceEntry> entries) =>
      entries.map((e) => e.isDirectory ? '${e.name}/' : e.name);

  static String? _decode(List<int> bytes) {
    try {
      final text = utf8.decode(bytes);
      return text.contains('\u0000') ? null : text;
    } on FormatException {
      return null;
    }
  }

  /// Complete lines only, bounded by both count and encoded bytes.
  (String, int?) _page(String text, int offset, {int limit = 2000}) {
    final lines = RegExp(
      r'[^\n]*\n|[^\n]+$',
    ).allMatches(text).map((m) => m[0]!).toList();
    final page = <String>[];
    var size = 0, i = offset - 1;
    for (; i < lines.length; i++) {
      final line = lines[i];
      if (page.length >= limit.clamp(1, WorkspaceLimits.maxReadLines) ||
          size + utf8.encode(line).length > WorkspaceLimits.maxReadBytes) {
        break;
      }
      page.add(line);
      size += utf8.encode(line).length;
    }
    if (page.isEmpty && i < lines.length) {
      return (
        '单行超过 50 KiB，无法按行读取。${enableScripts ? '可用 codemode 分段处理。' : ''}',
        i + 1,
      );
    }
    return (page.join(), i < lines.length ? i + 1 : null);
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
