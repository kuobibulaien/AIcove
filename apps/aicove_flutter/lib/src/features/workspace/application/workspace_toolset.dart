import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart' show loadYaml;
import '../domain/workspace_file_access.dart';
import '../data/managed_workspace_files.dart';
import '../data/local_workspace_files.dart';
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
/// Shared by tool-mode chat roles and the errand agent.
class WorkspaceToolset {
  WorkspaceToolset({
    required this.store,
    required Set<String> workspaceIds,
    required this.runId,
    this.onCreated,
    this.onWorkspaceChanged,
    this.onLocalDirectoryChanged,
    this.enableLocalFiles = false,
    this.userSkillRoots = const <String>[],
    String? currentLocalDirectory,
    this.isCancelled,
    this.enableScripts = false,
    this.enableShell = false,
    this.platform,
    this.runWebApp,
    this.runLocalWebApp,
    this.shellEnvironment,
    String? currentWorkspaceId,
  }) : _localDirectory = currentLocalDirectory,
       _granted = {...workspaceIds},
       _currentWorkspaceId =
           (workspaceIds.contains(currentWorkspaceId)
               ? currentWorkspaceId
               : null) ??
           (workspaceIds.contains('aicove')
               ? 'aicove'
               : workspaceIds.firstOrNull) {
    if (!_localEnabled) _localDirectory = null;
  }

  final WorkspaceStore store;
  final String runId;

  /// Adds a workspace the agent created to its role's grants.
  final Future<void> Function(WorkspaceInfo workspace)? onCreated;

  /// Persists the selection for the caller's conversation, not for this run.
  final Future<void> Function(String workspaceId)? onWorkspaceChanged;
  final Future<void> Function(String? directory)? onLocalDirectoryChanged;
  final bool enableLocalFiles;
  final List<String> userSkillRoots;
  String? _localDirectory;
  String? _fallbackNotice;
  static final _directoryInvocationKey = Object();
  _WorkspaceDirectoryInvocation? get _directoryInvocation {
    final invocation = Zone.current[_directoryInvocationKey];
    return invocation is _WorkspaceDirectoryInvocation &&
            identical(invocation.owner, this)
        ? invocation
        : null;
  }

  String? get _executionDirectory {
    final invocation = _directoryInvocation;
    return invocation == null ? _localDirectory : invocation.directory;
  }

  bool get _localEnabled =>
      enableLocalFiles &&
      [
        'macos',
        'windows',
        'linux',
      ].contains(platform ?? Platform.operatingSystem);
  String? get currentLocalDirectory => _localDirectory;

  /// Checked right before every commit; a cancelled run writes nothing more.
  final bool Function()? isCancelled;
  final bool enableScripts;
  final bool enableShell;
  final String? platform;

  /// Serves a workspace page on AIcove's loopback host and opens it in the
  /// default browser (ADR0105); returns the page URL. Null hides `workspace_run`.
  final Future<Uri> Function(String workspaceId, String path)? runWebApp;
  final Future<Uri> Function(String root, String page)? runLocalWebApp;

  /// Channel keys for `bash`, read at every command (ADR0109 补充二).
  final Map<String, String> Function()? shellEnvironment;
  String? _currentWorkspaceId;

  /// Existing approval/context labels accept a workspace ID or a native path.
  /// Managed storage and artifacts continue to use [_currentWorkspaceId].
  String? get currentWorkspaceId => _localDirectory ?? _currentWorkspaceId;

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

  /// Available workspaces, current project instructions, and local skill
  /// descriptions. Skill contents load on demand through `read`.
  Future<String?> prompt() async {
    await _ensureDirectory();
    final lines = [
      for (final info in await store.list())
        if (_granted.contains(info.id))
          '- ${info.name}（ID: ${info.id}）'
              '${info.description.isEmpty ? '' : '：${info.description}'}',
    ];

    final base =
        '$codemodeGuidance\n当前工作区：${_localDirectory ?? _currentWorkspaceId ?? '未选择'}。可用工作区：\n'
        '${lines.join('\n')}\n路径都相对当前工作区。用 workspace_open({id}) 切换；workspace_create 新建后自动切换。'
        '${_localEnabled ? '\nworkspace_open({path}) 或 {id:目录路径} 可切换本机目录，支持绝对路径、~、相对路径。文件工具可直接使用绝对路径。本机改动不参与内部撤销和同步。bash 中 cd 只影响该条命令。' : ''}'
        '${_localEnabled && platform != null ? '\n当前平台：$platform。' : ''}'
        '${_fallbackNotice == null ? '' : '\n$_fallbackNotice'}'
        '${runWebApp == null ? '' : '\n$_webAppHint'}';
    final directories = _localEnabled && _localDirectory != null
        ? await _instructionDirectories()
        : const <String>[];
    final rules = await _projectInstructions(directories);
    final skills = directories.isEmpty
        ? ''
        : await _availableSkills(directories);
    return '$base$rules$skills';
  }

  static const _ruleFileNames = [
    'AGENTS.override.md',
    'AGENTS.md',
    'CLAUDE.md',
  ];
  static const _ruleBytes = 32 * 1024;

  LocalWorkspaceFiles _localAccess(String directory) => LocalWorkspaceFiles(
    directory,
    protectedRoot: store.root.path,
    beforeCommit: _beforeCommit,
  );

  /// Shallow to deep; outside HOME, ancestors are used only if a repo is found.
  Future<List<String>> _instructionDirectories() async {
    final current = await canonicalLocalPath(_executionDirectory!);
    String? home;
    try {
      final raw =
          Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
      if (raw != null && raw.isNotEmpty) home = await canonicalLocalPath(raw);
    } on Object {
      // A missing home directory does not prevent project-local instructions.
    }
    String key(String path) =>
        (platform ?? Platform.operatingSystem) == 'windows'
        ? path.toLowerCase()
        : path;
    final inHome =
        home != null &&
        (p.equals(key(home), key(current)) ||
            p.isWithin(key(home), key(current)));
    final directories = <String>[];
    var directory = current;
    while (true) {
      directories.add(directory);
      try {
        if (await FileSystemEntity.type(p.join(directory, '.git')) !=
            FileSystemEntityType.notFound) {
          return directories.reversed.toList();
        }
      } on Object {
        // An inaccessible ancestor cannot supply a repository boundary.
      }
      if (home != null && p.equals(key(directory), key(home))) break;
      final parent = p.dirname(directory);
      if (parent == directory) break;
      directory = parent;
    }
    return inHome ? directories.reversed.toList() : [current];
  }

  Future<(String, String)?> _directoryRule(WorkspaceFileAccess access) async {
    for (final name in _ruleFileNames) {
      try {
        if (await access.stat(name) == null) continue;
        final text = _decode((await access.read(name)).$1);
        if (text != null && text.trim().isNotEmpty) {
          return (access.isLocal ? p.join(access.rootPath, name) : name, text);
        }
      } on Object {
        // Each candidate is independent: unreadable or invalid UTF-8 is skipped.
      }
    }
    return null;
  }

  static String _utf8Prefix(String text, int limit) {
    final out = StringBuffer();
    var size = 0;
    for (final rune in text.runes) {
      final char = String.fromCharCode(rune);
      size += utf8.encode(char).length;
      if (size > limit) break;
      out.write(char);
    }
    return out.toString();
  }

  static String _boundedRule(String text, String path, int limit) {
    if (utf8.encode(text).length <= limit) return text;
    final note = _ruleTruncationNote(path);
    return '${_utf8Prefix(text, limit - utf8.encode(note).length)}$note';
  }

  static String _ruleTruncationNote(String path) =>
      '\n[已截断，完整内容请用 read 读取 $path]';

  Future<String> _projectInstructions(List<String> directories) async {
    final accesses = <WorkspaceFileAccess>[
      if (_localDirectory == null && _currentWorkspaceId != null)
        ManagedWorkspaceFiles(store, _currentWorkspaceId!, runId),
      for (final directory in directories) _localAccess(directory),
    ];
    final out = StringBuffer();
    final sources = <(int, String)>[];
    var noteBytes = 0;
    for (final access in accesses) {
      final rule = await _directoryRule(access);
      if (rule == null) continue;
      final (path, text) = rule;
      final header =
          '${out.isEmpty ? '\nProject instructions (from workspace files; system and user instructions take precedence):' : ''}\n--- $path ---\n';
      sources.add((out.length, path));
      final size = utf8.encode(_ruleTruncationNote(path)).length;
      if (size > noteBytes) noteBytes = size;
      final section = '$out$header$text';
      if (utf8.encode(section).length > _ruleBytes) {
        final prefix = _utf8Prefix(section, _ruleBytes - noteBytes);
        final source = sources
            .lastWhere((entry) => entry.$1 <= prefix.length)
            .$2;
        return '$prefix${_ruleTruncationNote(source)}';
      }
      out.write('$header$text');
    }
    return out.toString();
  }

  Future<String> _availableSkills(List<String> directories) async {
    final roots = [
      ...userSkillRoots,
      for (final directory in directories) ...[
        p.join(directory, '.agents', 'skills'),
        p.join(directory, '.claude', 'skills'),
      ],
    ];
    final seen = <String>{};
    final skills = <String, (String, String)>{};
    for (final root in roots) {
      List<FileSystemEntity> children;
      try {
        children = await Directory(root).list(followLinks: false).toList();
        children.sort((a, b) => a.path.compareTo(b.path));
      } on Object {
        continue;
      }
      for (final child in children) {
        try {
          if (await FileSystemEntity.type(child.path) !=
              FileSystemEntityType.directory) {
            continue;
          }
          final file = File(p.join(child.path, 'SKILL.md'));
          final real = file.resolveSymbolicLinksSync();
          if (!seen.add(real)) continue;
          final handle = await file.open();
          late List<int> bytes;
          try {
            bytes = await handle.read(4096);
          } finally {
            await handle.close();
          }
          // Locate delimiters as bytes, then decode only the complete frontmatter.
          final prefix = latin1.decode(bytes);
          final match = RegExp(
            r'^---\r?\n([\s\S]*?)\r?\n---(?:\r?\n|$)',
          ).firstMatch(prefix);
          if (match == null) continue;
          final metadata = loadYaml(utf8.decode(latin1.encode(match[1]!)));
          if (metadata is! Map ||
              metadata['disable-model-invocation'] == true) {
            continue;
          }
          final name = metadata['name'] ?? p.basename(child.path);
          final description = metadata['description'];
          if (name is! String ||
              name.trim().isEmpty ||
              description is! String ||
              description.trim().isEmpty) {
            continue;
          }
          skills[name] = (
            description.trim().replaceAll(RegExp(r'\s+'), ' '),
            real,
          );
        } on Object {
          // Malformed metadata, broken links, and unreadable files are optional.
        }
      }
    }
    if (skills.isEmpty) return '';
    return '\n<available_skills>\n'
        "Use `read` to load a skill's SKILL.md when the task matches its description:\n"
        '${skills.entries.take(50).map((e) => '- ${e.key}: ${e.value.$1} (${e.value.$2})').join('\n')}\n'
        '</available_skills>';
  }

  static List<int> _occurrences(String text, String old) => [
    for (var i = 0; i <= text.length - old.length; i++)
      if (text.startsWith(old, i)) i,
  ];

  static final _specialHorizontal = RegExp(
    r'[\u00A0\u2002-\u200A\u202F\u205F\u3000]',
  );
  static final _trailingHorizontal = RegExp(
    r'[ \t\u00A0\u2002-\u200A\u202F\u205F\u3000]+(?=\r?\n|$)',
  );

  static (String, List<int>) _normalizeEdit(String text) {
    final out = StringBuffer();
    final origin = <int>[];
    final trailing = _trailingHorizontal.allMatches(text).iterator;
    var next = trailing.moveNext() ? trailing.current : null;
    for (var i = 0; i < text.length; i++) {
      if (next != null && i == next.start) {
        i = next.end - 1;
        next = trailing.moveNext() ? trailing.current : null;
        continue;
      }
      final char = text[i];
      out.write(switch (char) {
        '‘' || '’' || '‚' || '‛' => "'",
        '“' || '”' || '„' || '‟' => '"',
        '‐' || '‑' || '‒' || '–' || '—' || '―' || '−' => '-',
        _ when _specialHorizontal.hasMatch(char) => ' ',
        _ => char,
      });
      origin.add(i);
    }
    return (out.toString(), origin);
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
        managesOutput: true,
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
        managesOutput: true,
        handler: (args) async => (await _runScript(args)).persistentText,
        richHandler: _runScript,
      ),
    _tool(
      'workspace_open',
      _localEnabled
          ? '打开内部空间 ID 或本机目录路径，切换后返回 AGENTS.md 和顶层目录；id/path 二选一。'
          : '打开工作区：返回它的 AGENTS.md 说明和顶层目录。',
      {'id': _workspaceParam, if (_localEnabled) 'path': _pathParam},
      _localEnabled ? [] : ['id'],
      ToolEffect.readDiagnostic,
      _open,
      managesOutput: true,
    ),
    if (runWebApp != null || (_localEnabled && runLocalWebApp != null))
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
      '按行读取文本或查看图片；offset 从 1 开始，最多 2000 行或 50 KiB，返回续读行号与 revision（codemode 中读图仅返回 revision，看图请直接调用 read 或用 ws.readBytes）。',
      {
        'path': _pathParam,
        'offset': {'type': 'integer', 'description': '起始行，从 1 开始'},
        'limit': {'type': 'integer', 'description': '行数，默认 2000'},
      },
      ['path'],
      ToolEffect.readDiagnostic,
      _read,
      managesOutput: true,
    ),
    _tool(
      'write',
      '写入文本文件，整文件覆盖并自动建目录；expected_revision 可选，冲突时重新读取。本机文件不可内部撤销。',
      {
        'path': _pathParam,
        'content': {
          'type': 'string',
          'description': '文件全部内容，内部空间最多 1 MiB，本机目录无此限制',
        },
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
      'workspace_search',
      '浏览与搜索工作区文件。mode 传 list 列出目录内容（默认）；传 glob 按 pattern 通配符匹配文件路径；'
          '传 grep 按 pattern 正则表达式搜索文本内容（可搭配 glob 限定文件范围）。'
          '未传 mode 时，有 pattern 默认按 glob 找文件，无 pattern 默认按 list 列目录。',
      {
        'mode': {
          'type': 'string',
          'enum': ['list', 'glob', 'grep'],
          'description': '搜索方式：list 列目录、glob 按通配符找文件名、grep 按正则搜文件内容',
        },
        'path': _pathParam,
        'pattern': {
          'type': 'string',
          'description': 'glob 模式下为路径通配符（如 **/*.md），grep 模式下为正则表达式',
        },
        'glob': {'type': 'string', 'description': 'grep 模式下只搜索匹配该通配符的文件'},
        'include_ignored': {
          'type': 'boolean',
          'description': '是否包含默认忽略的目录（如 .git、node_modules、build）',
        },
        'cursor': _cursorParam,
      },
      [],
      ToolEffect.readDiagnostic,
      _search,
      managesOutput: true,
    ),
    _tool(
      'workspace_list',
      '列出目录下的文件和子目录。',
      {
        'path': {'type': 'string', 'description': '目录路径，默认当前目录'},
        'cursor': _cursorParam,
      },
      [],
      ToolEffect.readDiagnostic,
      _list,
      managesOutput: true,
    ),
    _tool(
      'workspace_glob',
      '按通配符找文件，例如 **/*.md、notes/*.txt。',
      {
        'pattern': {'type': 'string', 'description': '通配符，* 不跨目录，** 跨目录'},
        'path': _pathParam,
        'include_ignored': {
          'type': 'boolean',
          'description': '本机搜索包含 .git/node_modules/.dart_tool/build，默认跳过',
        },
        'cursor': _cursorParam,
      },
      ['pattern'],
      ToolEffect.readDiagnostic,
      _glob,
      managesOutput: true,
    ),
    _tool(
      'workspace_grep',
      '按正则表达式搜索文本文件的内容，返回「路径:行号: 内容」。',
      {
        'pattern': {'type': 'string', 'description': '正则表达式'},
        'glob': {'type': 'string', 'description': '只搜匹配这个通配符的文件'},
        'path': _pathParam,
        'include_ignored': {'type': 'boolean'},
        'cursor': _cursorParam,
      },
      ['pattern'],
      ToolEffect.readDiagnostic,
      _grep,
      managesOutput: true,
    ),
    _tool(
      'workspace_move',
      _localEnabled ? '移动或重命名文件；目标不能已存在（本机目录改动不可撤销）。' : '移动或重命名文件；目标不能已存在。',
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
      _localEnabled ? '删除文件（内部空间可撤销，本机目录直接删除且不可撤销）。' : '删除文件（可以撤销）。',
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
      resolveFile: _localEnabled ? resolveFile : null,
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
    final directory = _localDirectory;
    try {
      await _ensureDirectory(rejectFallback: true, consumeNotice: true);
      final context = ToolCallContext.current;
      return await WorkspaceShell(
        store: store,
        workspace: _workspace(args),
        localDirectory: directory,
        runId: runId,
        isCancelled: () =>
            (isCancelled?.call() ?? false) ||
            (context?.isCancelled?.call() ?? false),
        environment: shellEnvironment,
      ).run(
        _string(args, 'command'),
        timeout: WorkspaceShell.deadline(args['timeout']),
      );
    } on WorkspaceException catch (error) {
      return ToolOutput(text: '${error.code}: ${error.message}', isError: true);
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

  static const _workspaceParam = {
    'type': 'string',
    'description': '内部空间 ID；桌面本机能力启用时也接受本机目录路径',
  };
  static const _pathParam = {
    'type': 'string',
    'description': '相对当前工作目录的路径；桌面本机能力启用时也接受绝对路径和 ~',
  };
  static const _revisionParam = {
    'type': 'string',
    'description': '读取时得到的 revision',
  };
  static const _cursorParam = {
    'type': 'integer',
    'description': '上次结果给出的 next_cursor',
  };

  static const _stringSchema = {'type': 'string'};
  static const _boolSchema = {'type': 'boolean'};
  static const _stringsSchema = {'type': 'array', 'items': _stringSchema};
  static const _listingProperties = {
    'truncated': _boolSchema,
    'next_cursor': {'type': 'integer'},
    'skipped_count': {'type': 'integer'},
    'skipped': _stringsSchema,
    'notice': _stringSchema,
  };
  static const _outputSchemas = <String, Map<String, dynamic>>{
    'workspace_open': {
      'type': 'object',
      'properties': {
        'directory': _stringSchema,
        'name': _stringSchema,
        'description': _stringSchema,
        'agents_md': {
          'type': ['string', 'null'],
        },
        'instructions': _stringSchema,
        'available_skills': _stringSchema,
        'notice': _stringSchema,
        'entries': _stringsSchema,
        'skipped': _stringsSchema,
        'webapp_guide': _stringSchema,
      },
      'required': ['entries', 'webapp_guide'],
    },
    'workspace_run': {
      'type': 'object',
      'properties': {
        'url': _stringSchema,
        'ai_base_url': _stringSchema,
        'note': _stringSchema,
      },
      'required': ['url', 'ai_base_url', 'note'],
    },
    'workspace_create': {
      'type': 'object',
      'properties': {
        'workspace': _stringSchema,
        'name': _stringSchema,
        'notice': _stringSchema,
      },
      'required': ['workspace', 'name'],
    },
    'write': {
      'type': 'object',
      'properties': {
        'path': _stringSchema,
        'revision': _stringSchema,
        'undoable': _boolSchema,
      },
      'required': ['path', 'revision'],
    },
    'workspace_list': {
      'type': 'object',
      'properties': {'items': _stringsSchema, ..._listingProperties},
      'required': ['items'],
    },
    'workspace_glob': {
      'type': 'object',
      'properties': {
        'items': _stringsSchema,
        ..._listingProperties,
        'scope': _stringSchema,
      },
      'required': ['items'],
    },
    'workspace_grep': {
      'type': 'object',
      'properties': {
        'matches': _stringsSchema,
        ..._listingProperties,
        'scope': _stringSchema,
      },
      'required': ['matches'],
    },
    'workspace_move': {
      'type': 'object',
      'properties': {'path': _stringSchema, 'undoable': _boolSchema},
      'required': ['path'],
    },
    'workspace_delete': {
      'type': 'object',
      'properties': {'deleted': _boolSchema, 'undoable': _boolSchema},
      'required': ['deleted'],
    },
  };

  AITool _tool(
    String name,
    String description,
    Map<String, Object> properties,
    List<String> required,
    ToolEffect effect,
    Future<Object> Function(Map<String, dynamic> args) run, {
    bool managesOutput = false,
  }) => AITool(
    name: name,
    description: description,
    parameters: const {},
    inputSchema: {
      'type': 'object',
      'properties': properties,
      'required': required,
    },
    effect: effect,
    outputSchema: name == 'workspace_search'
        ? {
            'anyOf': [
              for (final key in [
                'workspace_list',
                'workspace_glob',
                'workspace_grep',
              ])
                _outputSchemas[key]!,
            ],
          }
        : _outputSchemas[name],
    managesOutput: managesOutput,
    handler: (args) async =>
        (await _invoke(run, args, name: name)).persistentText,
    richHandler: (args) => _invoke(run, args, name: name),
    controlledHandler: (args, control) async {
      control.progress('Starting $name');
      final result = await _invoke(run, args, name: name);
      control.progress('Finished $name');
      return result;
    },
  );

  Future<ToolOutput> _invoke(
    Future<Object> Function(Map<String, dynamic>) run,
    Map<String, dynamic> args, {
    required String name,
  }) {
    final invocation = _WorkspaceDirectoryInvocation(
      owner: this,
      directory: _localDirectory,
      rejectFallback: const {
        'write',
        'edit',
        'workspace_move',
        'workspace_delete',
      }.contains(name),
    );
    return runZoned(
      () => _invokeChecked(run, args, invocation),
      zoneValues: {_directoryInvocationKey: invocation},
    );
  }

  Future<ToolOutput> _invokeChecked(
    Future<Object> Function(Map<String, dynamic>) run,
    Map<String, dynamic> args,
    _WorkspaceDirectoryInvocation invocation,
  ) async {
    ToolOutput failure(String text) => ToolOutput(
      text:
          '$text${invocation.notice == null ? '' : '\nnotice: ${invocation.notice}'}',
      isError: true,
    );
    try {
      await _ensureDirectory();
      final result = await run(args);
      final notice = invocation.notice;
      if (result is ToolOutput) {
        return notice == null
            ? result
            : ToolOutput(
                text: '${result.text}\nnotice: $notice',
                images: result.images,
                isError: result.isError,
                structured: result.structured,
              );
      }
      final structured = notice == null || result is! Map
          ? result
          : {
              ...result,
              'notice': [
                notice,
                if (result['notice'] != null) result['notice'],
              ].join('\n'),
            };
      return ToolOutput(text: _format(structured), structured: structured);
    } on WorkspaceException catch (error) {
      return failure(
        error.message == stickerViewReadOnly
            ? stickerViewReadOnly
            : '${error.code}: ${error.message}',
      );
    } on FileSystemException catch (error) {
      return failure('filesystem_error: ${error.message}: ${error.path ?? ''}');
    } on FormatException catch (error) {
      return failure('invalid_argument: ${error.message}');
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

  Future<void> _selectWorkspace(String id) async {
    _beforeCommit();
    await onWorkspaceChanged?.call(id);
    _currentWorkspaceId = id;
    _localDirectory = null;
    _directoryInvocation?.directory = null;
    _fallbackNotice = null;
    await onLocalDirectoryChanged?.call(null);
  }

  static const _workspaceChangedNotice = '当前工作区已切换，此前工作区的项目规则不再适用';

  Future<Map<String, Object?>> _open(Map<String, dynamic> args) async {
    if (args['id'] != null && args['path'] != null)
      throw const FormatException('id/path 只能提供一个');
    final ws = _optionalString(args, 'id') ?? _optionalString(args, 'path');
    if (ws == null) throw const FormatException('缺少 id 或 path');
    final previous = _executionDirectory == null
        ? _currentWorkspaceId
        : await canonicalLocalPath(_executionDirectory!);
    if (args.containsKey('path') || !_granted.contains(ws)) {
      if (!_localEnabled)
        throw WorkspaceException.unauthorized('没有使用工作区 $ws 的授权');
      await _ensureDirectory();
      final expanded = _expandPath(ws);
      final base =
          _executionDirectory ?? store.directoryOf(_workspace(const {})).path;
      final target = await resolveFile(
        p.isAbsolute(expanded) ? expanded : p.join(base, expanded),
        directory: true,
      );
      if (!target.access.isLocal) {
        if (target.path.isNotEmpty)
          throw const WorkspaceException.invalidPath('内部空间请用空间 ID 打开');
        return _open({'id': target.access.workspaceId});
      }
      final directory = await canonicalLocalPath(
        (target.access as LocalWorkspaceFiles).absolute(target.path),
      );
      await Directory(directory).list().take(1).drain<void>();
      final access = LocalWorkspaceFiles(
        directory,
        protectedRoot: store.root.path,
        beforeCommit: _beforeCommit,
      );
      final skipped = <String>[];
      final entries = await access.listDirectory('', skipped: skipped);
      final rule = await _directoryRule(access);
      final guide = rule == null
          ? null
          : _boundedRule(rule.$2, rule.$1, _ruleBytes);
      _beforeCommit();
      await onLocalDirectoryChanged?.call(directory);
      _localDirectory = directory;
      _directoryInvocation?.directory = directory;
      _fallbackNotice = null;
      final directories = await _instructionDirectories();
      final instructions = await _projectInstructions(directories);
      final skills = await _availableSkills(directories);
      return {
        'directory': directory,
        if (previous != directory) 'notice': _workspaceChangedNotice,
        if (skipped.isNotEmpty) 'skipped': skipped.take(20).toList(),
        'agents_md': guide,
        if (instructions.isNotEmpty) 'instructions': instructions.trimLeft(),
        if (skills.isNotEmpty) 'available_skills': skills.trimLeft(),
        'entries': _entryNames(
          entries,
        ).take(WorkspaceLimits.maxResults).toList(),
        'webapp_guide':
            '用 workspace_run({path}) 运行 HTML，以当前本机目录为根；绝对路径在目录外时以 HTML 所在目录为根。AI 接口与内部空间一致，存档在页面同目录 .save.json，本机改动不可内部撤销。',
      };
    }
    final info = await store.get(ws);
    if (info == null) throw const WorkspaceException.notFound('工作区不存在');
    final rule = await _directoryRule(ManagedWorkspaceFiles(store, ws, runId));
    final guide = rule == null
        ? null
        : _boundedRule(rule.$2, rule.$1, _ruleBytes);
    final entries = await store.listDirectory(ws, '');
    await _selectWorkspace(ws);
    return {
      'name': info.name,
      if (previous != ws) 'notice': _workspaceChangedNotice,
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
    final target = await resolveFile(_string(args, 'path'));
    late Uri uri;
    if (target.access.isLocal) {
      if (runLocalWebApp == null)
        throw const WorkspaceException('unavailable', '本机网页预览不可用');
      final absolute = (target.access as LocalWorkspaceFiles).absolute(
        target.path,
      );
      var root = p.isWithin(target.access.rootPath, absolute)
          ? target.access.rootPath
          : p.dirname(absolute);
      final protected = await canonicalLocalPath(store.root.path);
      if (p.equals(root, protected) || p.isWithin(root, protected))
        root = p.dirname(absolute);
      uri = await runLocalWebApp!(root, p.relative(absolute, from: root));
    } else {
      if (runWebApp == null)
        throw const WorkspaceException('unavailable', '内部空间网页预览不可用');
      uri = await runWebApp!(target.access.workspaceId!, target.path);
    }
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
    await onCreated?.call(info);
    await _selectWorkspace(info.id);
    return {
      'workspace': info.id,
      'name': info.name,
      'notice': _workspaceChangedNotice,
    };
  }

  Future<ToolOutput> _read(Map<String, dynamic> args) async {
    final target = await resolveFile(_string(args, 'path'));
    final access = target.access, path = target.path;
    if (access.isLocal) return _readLocal(access, path, args);
    final ws = access.workspaceId!;
    final (bytes, revision) = await access.read(path);
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
    final target = await resolveFile(_string(args, 'path'));
    final access = target.access, path = target.path;
    access.checkWritable(path);
    final bytes = utf8.encode(_string(args, 'content'));
    final expected =
        _optionalString(args, 'expected_revision') ??
        await access.revision(path);
    _beforeCommit();
    final file = await access.write(path, bytes, expectedRevision: expected);
    if (!access.isLocal) _record(access.workspaceId!, file.path);
    return {
      'path': file.path,
      'revision': file.revision,
      if (access.isLocal) 'undoable': false,
    };
  }

  Future<ToolOutput> _edit(Map<String, dynamic> args) async {
    final target = await resolveFile(_string(args, 'path'));
    final access = target.access, path = target.path;
    access.checkWritable(path);
    final (bytes, revision) = await access.read(path);
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
      final positions = _occurrences(text, old);
      if (positions.length > 1) {
        throw WorkspaceException(
          'ambiguous',
          'oldText 必须在文件里唯一（匹配到 ${positions.length} 处）',
        );
      }
      if (positions.isNotEmpty) {
        replacements.add((
          positions.single,
          positions.single + old.length,
          value,
        ));
        continue;
      }
      final (normText, origin) = _normalizeEdit(text);
      final normOld = _normalizeEdit(old).$1;
      final fuzzyPositions = normOld.isEmpty
          ? const <int>[]
          : _occurrences(normText, normOld);
      if (fuzzyPositions.isEmpty) {
        throw const WorkspaceException(
          'not_found',
          '在文件里找不到 oldText，请先 read 确认最新内容',
        );
      }
      if (fuzzyPositions.length > 1) {
        throw WorkspaceException(
          'ambiguous',
          'oldText 必须在文件里唯一（宽松匹配到 ${fuzzyPositions.length} 处）',
        );
      }
      final start = fuzzyPositions.single;
      replacements.add((
        origin[start],
        origin[start + normOld.length - 1] + 1,
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
    _beforeCommit();
    final file = await access.write(path, encoded, expectedRevision: expected);
    if (!access.isLocal) _record(access.workspaceId!, file.path);
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
          '${diff.take(200).join('\n')}${diff.length > 200 ? '\n(diff 已截断)' : ''}\nfirst_changed_line: $firstLine\nrevision: ${file.revision}${access.isLocal ? '\nundoable: false' : ''}',
    );
  }

  Future<Map<String, Object?>> _search(Map<String, dynamic> args) =>
      switch (args['mode'] ?? (args.containsKey('pattern') ? 'glob' : 'list')) {
        'list' => _list(args),
        'glob' => _glob(args),
        'grep' => _grep(args),
        _ => throw const FormatException('mode 必须是 list、glob 或 grep'),
      };

  Future<Map<String, Object?>> _list(Map<String, dynamic> args) async {
    final target = await resolveFile(
      _optionalString(args, 'path') ?? '',
      directory: true,
    );
    final skipped = <String>[];
    final entries = await target.access.listDirectory(
      target.path,
      skipped: skipped,
    );
    return {
      ..._paged(_entryNames(entries).toList(), _int(args, 'cursor')),
      if (skipped.isNotEmpty) ...{
        'skipped_count': skipped.length,
        'skipped': skipped.take(20).toList(),
      },
    };
  }

  Future<Map<String, Object?>> _glob(Map<String, dynamic> args) async {
    final target = await resolveFile(
      _optionalString(args, 'path') ?? '',
      directory: true,
    );
    final skipped = <String>[];
    final pattern = globToRegExp(_string(args, 'pattern'));
    final paths = [
      for (final file in await target.access.files(
        path: target.path,
        includeIgnored: args['include_ignored'] == true,
        skipped: skipped,
      ))
        if (pattern.hasMatch(file.path)) file.path,
    ];
    return {
      ..._paged(paths, _int(args, 'cursor')),
      if (target.access.isLocal)
        'scope':
            '默认跳过 .git/node_modules/.dart_tool/build/.venv/venv/__pycache__，默认遵守目录内 .gitignore；include_ignored=true 可包含',
      if (skipped.isNotEmpty) ...{
        'skipped_count': skipped.length,
        'skipped': skipped.take(20).toList(),
      },
    };
  }

  Future<Map<String, Object?>> _grep(Map<String, dynamic> args) async {
    final target = await resolveFile(
      _optionalString(args, 'path') ?? '',
      directory: true,
    );
    final access = target.access;
    final skipped = <String>[];
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
    for (final file in await access.files(
      path: target.path,
      includeIgnored: args['include_ignored'] == true,
      skipped: skipped,
    )) {
      if (filter != null && !filter.hasMatch(file.path)) continue;
      var index = -1;
      try {
        await for (final line
            in access
                .openRead(file.path)
                .transform(utf8.decoder)
                .transform(const LineSplitter())) {
          index++;
          if (line.contains('\x00')) {
            if (access.isLocal) skipped.add('${file.path}: 二进制文件');
            break;
          }
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
            return {
              'matches': hits,
              'truncated': true,
              'next_cursor': seen - 1,
              if (skipped.isNotEmpty) ...{
                'skipped_count': skipped.length,
                'skipped': skipped.take(20).toList(),
              },
            };
          }
          hits.add(hit);
        }
      } on FormatException {
        if (access.isLocal) skipped.add('${file.path}: 非 UTF-8 文本');
      } on FileSystemException catch (e) {
        skipped.add('${file.path}: ${e.message}');
      } on WorkspaceException catch (e) {
        skipped.add('${file.path}: ${e.message}');
      }
    }
    return {
      'matches': hits,
      if (access.isLocal)
        'scope':
            '默认跳过 .git/node_modules/.dart_tool/build/.venv/venv/__pycache__，默认遵守目录内 .gitignore；include_ignored=true 可包含',
      if (skipped.isNotEmpty) ...{
        'skipped_count': skipped.length,
        'skipped': skipped.take(20).toList(),
      },
    };
  }

  Future<Map<String, Object?>> _move(Map<String, dynamic> args) async {
    final source = await resolveFile(_string(args, 'from'));
    final target = await resolveFile(_string(args, 'to'));
    await _checkManagedLinkMutation(_string(args, 'from'), source);
    final access = source.access;
    if (access.isLocal != target.access.isLocal ||
        access.workspaceId != target.access.workspaceId) {
      throw const WorkspaceException.invalidPath('不能跨内部空间与本机目录移动');
    }
    access.checkWritable(source.path);
    target.access.checkWritable(target.path);
    final expected =
        _optionalString(args, 'expected_revision') ??
        await access.revision(source.path);
    if (expected == null) throw const WorkspaceException.notFound('源文件不存在');
    _beforeCommit();
    await access.move(source.path, target.path, expectedRevision: expected);
    if (!access.isLocal)
      _record(access.workspaceId!, WorkspacePathRules.normalize(target.path));
    return {'path': target.path, if (access.isLocal) 'undoable': false};
  }

  Future<Map<String, Object?>> _delete(Map<String, dynamic> args) async {
    final target = await resolveFile(_string(args, 'path'));
    await _checkManagedLinkMutation(_string(args, 'path'), target);
    final access = target.access;
    access.checkWritable(target.path);
    final expected =
        _optionalString(args, 'expected_revision') ??
        await access.revision(target.path);
    if (expected == null) throw const WorkspaceException.notFound('文件不存在');
    _beforeCommit();
    await access.delete(target.path, expectedRevision: expected);
    return {'deleted': true, if (access.isLocal) 'undoable': false};
  }

  Future<void> _checkManagedLinkMutation(
    String input,
    WorkspaceFileTarget target,
  ) async {
    if (!_localEnabled || target.access.isLocal) return;
    final expanded = _expandPath(input);
    final requested = p.isAbsolute(expanded)
        ? expanded
        : p.join(
            _executionDirectory ?? store.directoryOf(_workspace(const {})).path,
            expanded,
          );
    if (await FileSystemEntity.type(requested, followLinks: false) ==
        FileSystemEntityType.link) {
      throw const WorkspaceException.invalidPath('不能通过文件链接移动或删除内部空间的目标文件');
    }
  }

  Future<String?> _ensureDirectory({
    bool rejectFallback = false,
    bool consumeNotice = false,
  }) async {
    if (!_localEnabled || _executionDirectory == null) return null;
    final invocation = _directoryInvocation;
    final previous = _executionDirectory!;
    try {
      final access = LocalWorkspaceFiles(
        previous,
        protectedRoot: store.root.path,
        beforeCommit: _beforeCommit,
      );
      await access.checked('');
      await Directory(previous).list().take(1).drain<void>();
    } on Object {
      await store.ensureDefault();
      _granted.add('aicove');
      await _selectWorkspace('aicove');
      final notice = '上次的本机目录 $previous 已不可用，已切回默认空间';
      _fallbackNotice = consumeNotice || invocation != null ? null : notice;
      if (rejectFallback || (invocation?.rejectFallback ?? false)) {
        throw WorkspaceException(
          'directory_unavailable',
          '$notice；请重新确认目标空间或路径后再执行修改',
        );
      }
      invocation?.notice = notice;
      return notice;
    }
    return null;
  }

  String _expandPath(String path) {
    if (path == '~' || path.startsWith('~/') || path.startsWith('~\\')) {
      final home =
          Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
      if (home == null) throw const WorkspaceException.invalidPath('无法取得用户主目录');
      return path == '~' ? home : p.join(home, path.substring(2));
    }
    return path;
  }

  Future<WorkspaceFileTarget> resolveFile(
    String input, {
    bool directory = false,
    bool rejectFallback = false,
  }) async {
    await _ensureDirectory(
      rejectFallback: rejectFallback,
      consumeNotice: rejectFallback,
    );
    final path = _localEnabled ? _expandPath(input) : input;
    if (!_localEnabled ||
        (_executionDirectory == null && !p.isAbsolute(path))) {
      return WorkspaceFileTarget(
        ManagedWorkspaceFiles(store, _workspace(const {}), runId),
        path,
      );
    }
    final base =
        _executionDirectory ?? store.directoryOf(_workspace(const {})).path;
    final requested = p.isAbsolute(path) ? path : p.join(base, path);
    final absolute = await canonicalLocalPath(requested);
    final managed = await canonicalLocalPath(store.root.path);
    if (p.equals(absolute, managed) || p.isWithin(managed, absolute)) {
      for (final info in await store.list()) {
        final root = await canonicalLocalPath(store.directoryOf(info.id).path);
        if (p.equals(root, absolute) || p.isWithin(root, absolute)) {
          if (!_granted.contains(info.id))
            throw const WorkspaceException.unauthorized('没有使用这个内部空间的授权');
          final relative = p.equals(root, absolute)
              ? ''
              : p.relative(absolute, from: root).split(p.separator).join('/');
          return WorkspaceFileTarget(
            ManagedWorkspaceFiles(store, info.id, runId),
            relative,
          );
        }
      }
      throw const WorkspaceException.invalidPath('应用管理目录不能通过本机文件工具访问');
    }
    final localRoot = directory
        ? (await Directory(absolute).exists() ? absolute : p.dirname(absolute))
        : base;
    return WorkspaceFileTarget(
      LocalWorkspaceFiles(
        localRoot,
        protectedRoot: store.root.path,
        beforeCommit: _beforeCommit,
      ),
      requested,
    );
  }

  Future<ToolOutput> _readLocal(
    WorkspaceFileAccess access,
    String path,
    Map<String, dynamic> args,
  ) async {
    final stat = await access.stat(path);
    if (stat == null) throw const WorkspaceException.notFound('文件不存在');
    final prefix = await access.readRange(path, offset: 0, length: 512);
    final mime = lookupMimeType(path, headerBytes: prefix);
    if (mime?.startsWith('image/') ?? false) {
      final (bytes, revision) = await access.read(path);
      final image = await prepareWorkspaceImage(bytes, path);
      if (image != null)
        return ToolOutput(text: 'revision: $revision', images: [image]);
    }
    final offset = args.containsKey('offset') ? _int(args, 'offset') : 1;
    final limit = args.containsKey('limit') ? _int(args, 'limit') : 2000;
    if (offset < 1 || limit < 1)
      throw const FormatException('offset 和 limit 必须大于 0');
    final revision = await access.revision(path);
    String content;
    int? next;
    try {
      if (prefix.contains(0)) throw const FormatException('二进制');
      (content, next) = await _localTextPage(access, path, offset, limit);
    } on FormatException {
      return ToolOutput(
        text:
            '二进制文件（${mime ?? 'application/octet-stream'}），${stat.size} 字节。可用 codemode 的 ws.readBytes 分段处理。\nrevision: $revision',
      );
    }
    if (revision != await access.revision(path))
      throw const WorkspaceException.revisionMismatch('读取期间文件变化，请重新读取');
    return ToolOutput(
      text:
          '$content\nrevision: $revision${next == null ? '' : '\n内容已截断，下次 offset: $next'}',
    );
  }

  Future<(String, int?)> _localTextPage(
    WorkspaceFileAccess access,
    String path,
    int offset,
    int limit,
  ) async {
    var index = 1, bytes = 0, count = 0;
    final output = StringBuffer();
    await for (final line
        in access
            .openRead(path)
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
      if (line.contains('\x00')) throw const FormatException('二进制文件');
      if (index++ < offset) continue;
      final size = utf8.encode(line).length + 1;
      if (count >= limit.clamp(1, WorkspaceLimits.maxReadLines) ||
          bytes + size > WorkspaceLimits.maxReadBytes) {
        if (count == 0) {
          return ('单行超过 50 KiB，可用 codemode 的 ws.readBytes 按字节分段读取。', null);
        }
        return (output.toString(), index - 1);
      }
      output.writeln(line);
      bytes += size;
      count++;
    }
    return (output.toString(), null);
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

/// Per-call state keeps nested checks and concurrent reads/writes independent.
class _WorkspaceDirectoryInvocation {
  _WorkspaceDirectoryInvocation({
    required this.owner,
    required this.directory,
    required this.rejectFallback,
  });

  final WorkspaceToolset owner;
  final bool rejectFallback;
  String? directory;
  String? notice;
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
