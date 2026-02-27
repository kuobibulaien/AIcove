library;

import '../../plugins/domain/handlers/ai_tool.dart';
import '../../plugins/domain/plugin.dart';
import '../../plugins/plugin_manager.dart';
import '../../../core/app_logger.dart';

/// 插件上下文构建器。
///
/// 负责：
/// 1) 根据会话配置筛选有效插件
/// 2) 拼接插件 System Prompt
/// 3) 收集插件工具定义
class ChatPluginContextBuilder {
  const ChatPluginContextBuilder();

  List<Plugin> getEffectivePlugins({
    required PluginManager pluginManager,
    required Set<String>? enabledPluginIds,
  }) {
    final globallyEnabled = pluginManager.getEnabledPlugins();
    if (enabledPluginIds == null) {
      return globallyEnabled;
    }
    return [
      for (final plugin in globallyEnabled)
        if (enabledPluginIds.contains(plugin.id)) plugin,
    ];
  }

  Future<String> buildPluginPromptsWithFilter(
    List<Plugin> plugins, {
    required String userMessage,
    required bool supportsToolCalling,
  }) async {
    if (plugins.isEmpty) return '';

    final prompts = <String>[];
    for (final plugin in plugins) {
      try {
        final prompt = await plugin.getSystemPrompt(
          userMessage: userMessage,
          supportsToolCalling: supportsToolCalling,
        );
        if (prompt != null && prompt.isNotEmpty) {
          prompts.add(prompt);
        }
      } catch (e) {
        AppLogger.warning('ChatSendService', 'Failed to build plugin prompt',
            metadata: {
              'pluginId': plugin.id,
              'error': e.toString(),
            });
      }
    }
    return prompts.join('\n\n');
  }

  List<AITool> collectPluginTools(List<Plugin> plugins) {
    final tools = <AITool>[];
    for (final plugin in plugins) {
      try {
        tools.addAll(plugin.getTools());
      } catch (e) {
        AppLogger.warning('ChatSendService', '插件工具收集失败', metadata: {
          'pluginId': plugin.id,
          'error': e.toString(),
        });
      }
    }
    return tools;
  }
}
