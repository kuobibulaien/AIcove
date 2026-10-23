import 'dart:convert';
import 'dart:io';

import 'package:aicove_agent_kernel/aicove_agent_kernel.dart' show ToolEffect;
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;

import '../../workspace/application/workspace_script.dart';
import '../domain/handlers/ai_tool.dart';
import 'aicove_package.dart';

/// Read-only resources from the package snapshot, never arbitrary disk paths.
class PackageSkillTools {
  PackageSkillTools(this.package);
  final AicovePackage package;
  String get readName => 'read_skill_${package.id}';
  String get runName => 'run_skill_js_${package.id}';

  Map<String, List<int>> resources(PackageSkill skill) => {
    for (final entry in package.files.entries)
      if (skill.dir != null &&
          (skill.dir!.isEmpty || entry.key.startsWith('${skill.dir}/')))
        (skill.dir!.isEmpty
                ? entry.key
                : entry.key.substring(skill.dir!.length + 1)):
            entry.value,
  };

  PackageSkill _skill(Object? name) => package.skills.firstWhere(
    (s) => s.name == name,
    orElse: () => throw ArgumentError('Unknown skill: $name'),
  );

  Map<String, dynamic> get _nameSchema => {
    'type': 'string',
    'enum': [for (final s in package.skills) s.name],
  };

  List<AITool> tools({bool executable = true}) {
    if (package.skills.isEmpty) return const [];
    Future<String?> read(Map<String, dynamic> args) async {
      final skill = _skill(args['name']);
      final path = args['path'];
      final files = resources(skill);
      if (path == null) {
        // Legacy single-file skills retain their exact response contract.
        if (skill.dir == null) return skill.content;
        final listing = files.entries
            .map((e) => '${e.key} (${e.value.length} bytes)')
            .join('\n');
        final desktop = [
          'macos',
          'windows',
          'linux',
        ].contains(Platform.operatingSystem);
        final location = desktop && package.directory != null
            ? '\nSkill directory: ${p.join(package.directory!, skill.dir!)}\n'
                  'Non-JS scripts: use bash only when available; commands follow the current tool authorization policy. '
                  'Desktop commands run with the current user permissions; git/python3 must be installed.'
            : '';
        return '${skill.content}\n\nFiles (relative to this skill):\n$listing$location';
      }
      if (path is! String ||
          !AicovePackage.isSafePath(path) ||
          !files.containsKey(path)) {
        throw ArgumentError('File is not in this skill: $path');
      }
      final bytes = files[path]!;
      final type =
          lookupMimeType(path, headerBytes: bytes.take(32).toList()) ??
          'application/octet-stream';
      String text;
      try {
        if (bytes.contains(0)) throw const FormatException();
        text = utf8.decode(bytes);
      } on FormatException {
        return jsonEncode({
          'path': path,
          'type': type,
          'size': bytes.length,
          'binary': true,
        });
      }
      final offset = args['offset'] ?? 1, limit = args['limit'] ?? 200;
      if (offset is! int ||
          offset < 1 ||
          limit is! int ||
          limit < 1 ||
          limit > 2000) {
        throw ArgumentError('offset >= 1; limit between 1 and 2000 lines');
      }
      final lines = const LineSplitter().convert(text);
      final end = (offset - 1 + limit).clamp(0, lines.length);
      return jsonEncode({
        'path': path,
        'type': type,
        'size': bytes.length,
        'offset': offset,
        'text': lines.skip(offset - 1).take(limit).join('\n'),
        if (end < lines.length) 'next_offset': end + 1,
      });
    }

    return [
      AITool(
        name: readName,
        description:
            '读取「${package.name}」技能说明和文件清单；指定 path 按技能内相对路径读取文本，offset 从 1 开始按行分页，limit 最多 2000 行；二进制只返回类型与大小。'
            '技能：${package.skills.map((s) => '${s.name}（${s.title}）').join('、')}'
            '${executable ? '。.js 文件可用 $runName 运行' : ''}',
        parameters: const {},
        effect: ToolEffect.readDiagnostic,
        inputSchema: {
          'type': 'object',
          'properties': {
            'name': _nameSchema,
            'path': {'type': 'string'},
            'offset': {'type': 'integer', 'minimum': 1},
            'limit': {'type': 'integer', 'minimum': 1, 'maximum': 2000},
          },
          'required': ['name'],
        },
        handler: read,
        richHandler: (args) async {
          try {
            return ToolOutput(text: await read(args) ?? '');
          } catch (e) {
            return ToolOutput(text: '$e', isError: true);
          }
        },
      ),
      if (executable && package.skills.any((s) => s.dir != null))
        AITool(
          name: runName,
          description:
              '在 QuickJS 中运行技能内的 .js 文件（异步函数体，args 为参数）。'
              'skill.list()/readText(path)/readBytes(path,{offset,length}) 只读本技能文件；'
              '提供 fetch、tools.list()/describe()/tools.<exportName> 和 text/console。'
              '无 Node 或本机执行权限；64 MiB 堆、默认 30 秒、最长 120 秒；嵌套调用同样经过本轮工具闸门，按需等待用户确认。',
          parameters: const {},
          effect: ToolEffect.external,
          inputSchema: {
            'type': 'object',
            'properties': {
              'name': _nameSchema,
              'path': {'type': 'string'},
              'args': {},
              'timeout_seconds': {
                'type': 'integer',
                'minimum': 1,
                'maximum': 120,
              },
            },
            'required': ['name', 'path'],
          },
          executionTimeout: const Duration(seconds: 120),
          handler: (_) async => null,
          controlledHandler: (args, control) async {
            try {
              final skill = _skill(args['name']);
              final files = resources(skill), path = args['path'];
              if (path is! String ||
                  !path.endsWith('.js') ||
                  !AicovePackage.isSafePath(path) ||
                  !files.containsKey(path)) {
                throw ArgumentError('Expected .js file inside this skill');
              }
              final seconds = args['timeout_seconds'] ?? 30;
              if (seconds is! int || seconds < 1 || seconds > 120) {
                throw ArgumentError('Invalid deadline');
              }
              final context = ToolCallContext.current;
              final access = context?.scriptTools;
              return WorkspaceScript.extension(
                runId: context?.turnId ?? 'skill_${package.id}',
                resources: files,
                tools: access == null
                    ? null
                    : ScriptToolAccess(
                        access.tools.where((t) => t.name != runName).toList(),
                        access.invoke,
                      ),
                isCancelled: () =>
                    (control.cancellation?.isCancelled ?? false) ||
                    (context?.isCancelled?.call() ?? false),
              ).run(
                utf8.decode(files[path]!),
                args: args['args'],
                timeout: Duration(seconds: seconds),
              );
            } catch (e) {
              return ToolOutput(text: '$e', isError: true);
            }
          },
        ),
    ];
  }
}
