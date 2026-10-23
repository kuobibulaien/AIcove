import 'dart:io';
import 'dart:convert';

import 'package:aicove_agent_kernel/aicove_agent_kernel.dart'
    show ToolEffect, ToolCallScope, GateOutcome;

import '../../plugins/domain/handlers/ai_tool.dart';
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
  });
  final Future<WorkspaceStore> Function() store;
  final AicovePackagesNotifier Function() packages;
  final Future<Set<String>> Function() workspaceIds;
  static const installTool = 'aicove_package_install';

  @override
  List<AITool> tools() => [
    AITool(
      name: installTool,
      description:
          '从已授权工作区的本地文件夹或 zip 安装扩展包（aicove-package.json 或标准 Agent Skills 的 SKILL.md）。'
          'path 相对工作区根目录，空字符串表示根目录；不接受 URL 或任意绝对路径。'
          '单包 20 MiB、1000 文件、单文件 8 MiB；可含技能资源和 JS 插件。'
          '安装或替换同 ID 包，按当前工具权限策略执行。'
          '安装不自动为角色启用，返回 plugin_id，角色需显式开启；下一次 run 生效。',
      parameters: const {},
      inputSchema: const {
        'type': 'object',
        'properties': {
          'workspaceId': {'type': 'string'},
          'path': {'type': 'string'},
        },
        'required': ['workspaceId', 'path'],
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
      final id = args['workspaceId'];
      if (id is! String || !(await workspaceIds()).contains(id)) {
        throw StateError('Workspace not authorized');
      }
      final source = await (await store()).packageImportSource(
        id,
        args['path'] as String,
      );
      ToolCallContext.current?.cancellation?.throwIfCancelled();
      final notifier = packages();
      final package = switch (source) {
        Directory() => await notifier.importDirectory(source),
        File() when source.path.toLowerCase().endsWith('.zip') =>
          await notifier.importZip(await source.readAsBytes()),
        _ => throw ArgumentError('Expected a package directory or .zip'),
      };
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

  @override
  AssistantRisk riskOf(String toolName, Map<String, dynamic> args) =>
      AssistantRisk.major;

  @override
  ApprovalPrompt describe(String toolName, Map<String, dynamic> args) =>
      ApprovalPrompt(
        title: installTool,
        detail: '${args['workspaceId']}:${args['path']}',
      );
}
