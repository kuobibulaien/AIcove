import 'dart:io';
import 'dart:convert';

import 'package:aicove_agent_kernel/aicove_agent_kernel.dart'
    show ToolEffect, ToolCallScope, GateOutcome;
import 'package:path/path.dart' as p;

import '../../../core/network/public_network.dart';
import '../../plugins/domain/handlers/ai_tool.dart';
import '../../plugins/packages/aicove_package.dart';
import '../../plugins/packages/package_providers.dart';
import '../../workspace/data/workspace_store.dart';
import 'assistant_review.dart';
import 'assistant_tool_group.dart';

/// Local installation follows the assistant run's tool authorization policy.
class AssistantPackageTools extends AssistantToolGroup {
  AssistantPackageTools({
    required this.store,
    required this.packages,
    required this.workspaceIds,
    this.localFiles,
    this.currentLocalDirectory,
    this.network = PublicNetwork.new,
    this.platform,
  });
  final Future<WorkspaceStore> Function() store;
  final AicovePackagesNotifier Function() packages;
  final Future<Set<String>> Function() workspaceIds;

  /// Whether the calling role may read this machine's files. Null means
  /// yes on desktop: only tool-mode roles get this group, and they all have
  /// local file access (ADR0111). Without it a human approval still counts.
  final bool Function()? localFiles;

  /// Resolves relative local paths, falling back to the process directory.
  final Future<String?> Function()? currentLocalDirectory;
  final PublicNetwork Function() network;
  final String? platform;
  static const installTool = 'aicove_package_install';

  @override
  List<AITool> tools() => [
    AITool(
      name: installTool,
      description:
          '安装扩展包（aicove-package.json 或标准 Agent Skills 的 SKILL.md），来源可以是文件夹、zip 或单个 SKILL.md。'
          'path 三种写法：http(s) 网址（下载 zip 或 SKILL.md）；'
          '本机绝对路径或 ~/ 路径（仅桌面端；不传 workspaceId 时相对路径按当前本机目录解析）；'
          '传 workspaceId 时为该工作区内的相对路径，空字符串表示根目录。'
          '包内链接只能指向包内；可含技能资源和 JS 插件。'
          '安装或替换同 ID 包，按当前工具权限策略执行。'
          '安装不自动为角色启用，返回 plugin_id，角色需显式开启；下一次 run 生效。',
      parameters: const {},
      inputSchema: const {
        'type': 'object',
        'properties': {
          'workspaceId': {'type': 'string'},
          'path': {'type': 'string'},
        },
        'required': ['path'],
        'additionalProperties': false,
      },
      effect: ToolEffect.write,
      handler: (args) async => jsonEncode((await _install(args)).structured),
      richHandler: _install,
    ),
  ];

  Future<ToolOutput> _install(Map<String, dynamic> args) async {
    try {
      final scope = ToolCallScope.current;
      if (scope?.outcome != GateOutcome.allowed &&
          (scope?.outcome != GateOutcome.approved ||
              !(scope?.humanApproved ?? false))) {
        throw StateError(
          'Package installation requires authorization by the tool policy',
        );
      }
      final path = args['path'];
      if (path is! String) throw ArgumentError('path is required');
      final id = args['workspaceId'];
      final notifier = packages();
      final AicovePackage package;
      if (_isUrl(path)) {
        package = await _download(Uri.parse(path), notifier);
      } else if (id == null || _isLocal(path)) {
        package = await notifier.importPath(await _localPath(path, scope));
      } else {
        if (id is! String || !(await workspaceIds()).contains(id)) {
          throw StateError('Workspace not authorized');
        }
        final source = await (await store()).packageImportSource(id, path);
        ToolCallContext.current?.cancellation?.throwIfCancelled();
        package = switch (source) {
          Directory() => await notifier.importDirectory(source),
          File() when source.path.toLowerCase().endsWith('.zip') =>
            await notifier.importZip(await source.readAsBytes()),
          _ => throw ArgumentError('Expected a package directory or .zip'),
        };
      }
      final result = {
        'plugin_id': package.pluginId,
        'id': package.id,
        'name': package.name,
        'version': package.version,
        'activation': 'roleExplicit',
        'effective_from': 'next_run',
      };
      return ToolOutput(text: jsonEncode(result), structured: result);
    } catch (e) {
      return ToolOutput(text: '$e', isError: true, structured: {'error': '$e'});
    }
  }

  static bool _isUrl(String path) =>
      path.startsWith('http://') || path.startsWith('https://');

  static bool _isLocal(String path) =>
      p.isAbsolute(path) ||
      path == '~' ||
      path.startsWith('~/') ||
      path.startsWith(r'~\');

  Future<String> _localPath(String path, ToolCallScope? scope) async {
    if (!['macos', 'windows', 'linux'].contains(
      platform ?? Platform.operatingSystem,
    )) {
      throw StateError('Installing from local paths is desktop only');
    }
    if (!(localFiles?.call() ?? true) && !(scope?.humanApproved ?? false)) {
      throw StateError('This role has no local file access');
    }
    if (path == '~' || path.startsWith('~/') || path.startsWith(r'~\')) {
      final home =
          Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
      if (home == null) throw StateError('Home directory unavailable');
      return path == '~' ? home : p.join(home, path.substring(2));
    }
    if (p.isAbsolute(path)) return path;
    final base = await currentLocalDirectory?.call() ?? Directory.current.path;
    return p.join(base, path);
  }

  /// Downloads into a private temp folder; the size cap is enforced while
  /// streaming, never from Content-Length.
  Future<AicovePackage> _download(
    Uri uri,
    AicovePackagesNotifier notifier,
  ) async {
    final problem = PublicNetwork.checkUri(uri);
    if (problem != null) throw ArgumentError(problem);
    final cancellation = ToolCallContext.current?.cancellation;
    final client = network();
    final temp = await Directory.systemTemp.createTemp('aicove_package_');
    try {
      final response = await client.fetch(
        uri,
        timeout: const Duration(minutes: 2),
        isActive: () => !(cancellation?.isCancelled ?? false),
      );
      if (response.status != 200) {
        throw StateError('Download failed: HTTP ${response.status}');
      }
      cancellation?.throwIfCancelled();
      final name = p.url.basename(response.url.path);
      final file = File(
        p.join(
          temp.path,
          name == 'SKILL.md' || name == AicovePackage.manifestName
              ? name
              : 'package.zip',
        ),
      );
      await file.writeAsBytes(response.bytes, flush: true);
      return await notifier.importFile(file);
    } finally {
      client.close();
      await temp.delete(recursive: true);
    }
  }

  @override
  AssistantRisk riskOf(String toolName, Map<String, dynamic> args) =>
      AssistantRisk.major;

  @override
  ApprovalPrompt describe(String toolName, Map<String, dynamic> args) {
    final path = '${args['path'] ?? ''}';
    final id = args['workspaceId'];
    return ApprovalPrompt(
      title: installTool,
      detail: _isUrl(path)
          ? '从网址下载并安装：$path'
          : id == null || _isLocal(path)
          ? '从这台电脑安装：$path'
          : '从空间 $id 安装：${path.isEmpty ? '根目录' : path}',
    );
  }
}
