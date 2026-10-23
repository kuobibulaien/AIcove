import '../../agent_plugins/plugin_request_context.dart';
import '../../agent_plugins/plugin_request_scope.dart';
import '../../plugins/domain/handlers/ai_tool.dart';
import 'workspace_toolset.dart';

/// 工具模式的角色直接拥有工作区工具（ADR0097）。聊天模式的角色仍由杂活
/// Agent 去办，这里不装配。
class WorkspaceRequestScope extends PluginRequestScope {
  WorkspaceRequestScope(this.toolset, {required this.supportsTools});

  final WorkspaceToolset toolset;
  final bool supportsTools;

  @override
  String get pluginId => 'workspace';

  @override
  String get pluginName => '空间';

  @override
  bool get active => supportsTools;

  @override
  Future<String?> prompt(PluginRequestContext ctx) async =>
      supportsTools ? toolset.prompt() : null;

  @override
  List<AITool> tools() => supportsTools ? toolset.tools() : const [];
}
