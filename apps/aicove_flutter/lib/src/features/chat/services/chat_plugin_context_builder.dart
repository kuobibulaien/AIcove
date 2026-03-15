library;

import '../../plugins/domain/handlers/ai_tool.dart';
import '../../plugins/domain/plugin.dart';
import '../../plugins/plugin_manager.dart';
import '../../plugins/memory/memory_plugin.dart';
import '../../../core/app_logger.dart';

class PluginPromptEntry {
  const PluginPromptEntry({
    required this.order,
    required this.pluginId,
    required this.pluginName,
    required this.injected,
    required this.content,
    this.reason,
    this.error,
  });

  final int order;
  final String pluginId;
  final String pluginName;
  final bool injected;
  final String content;
  final String? reason;
  final String? error;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'order': order,
      'pluginId': pluginId,
      'pluginName': pluginName,
      'injected': injected,
      'content': content,
      if (reason != null) 'reason': reason,
      if (error != null) 'error': error,
    };
  }
}

class PluginPromptBuildResult {
  const PluginPromptBuildResult({
    required this.entries,
  });

  final List<PluginPromptEntry> entries;

  String get mergedPrompt => [
        for (final entry in entries)
          if (entry.injected && entry.content.trim().isNotEmpty)
            entry.content.trim(),
      ].join('\n\n');

  List<Map<String, dynamic>> toJson() {
    return <Map<String, dynamic>>[
      for (final entry in entries) entry.toJson(),
    ];
  }
}

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
    String? conversationId,
  }) async {
    final result = await buildPluginPromptEntriesWithFilter(
      plugins,
      userMessage: userMessage,
      supportsToolCalling: supportsToolCalling,
      conversationId: conversationId,
    );
    return result.mergedPrompt;
  }

  Future<PluginPromptBuildResult> buildPluginPromptEntriesWithFilter(
    List<Plugin> plugins, {
    required String userMessage,
    required bool supportsToolCalling,
    String? conversationId,
  }) async {
    if (plugins.isEmpty) {
      return const PluginPromptBuildResult(entries: <PluginPromptEntry>[]);
    }

    final entries = <PluginPromptEntry>[];
    for (final plugin in plugins) {
      try {
        final prompt = plugin is MemoryPlugin
            ? await plugin.getSystemPrompt(
                userMessage: userMessage,
                supportsToolCalling: supportsToolCalling,
                conversationId: conversationId,
              )
            : await plugin.getSystemPrompt(
                userMessage: userMessage,
                supportsToolCalling: supportsToolCalling,
              );
        final trimmedPrompt = prompt?.trim() ?? '';
        entries.add(
          PluginPromptEntry(
            order: entries.length,
            pluginId: plugin.id,
            pluginName: plugin.name,
            injected: trimmedPrompt.isNotEmpty,
            content: trimmedPrompt,
            reason: trimmedPrompt.isEmpty ? 'empty_prompt' : null,
          ),
        );
      } catch (e) {
        AppLogger.warning('ChatSendService', 'Failed to build plugin prompt',
            metadata: {
              'pluginId': plugin.id,
              'error': e.toString(),
            });
        entries.add(
          PluginPromptEntry(
            order: entries.length,
            pluginId: plugin.id,
            pluginName: plugin.name,
            injected: false,
            content: '',
            reason: 'build_failed',
            error: e.toString(),
          ),
        );
      }
    }
    return PluginPromptBuildResult(entries: entries);
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

  /// 收集插件工具（带一次短延迟重试）。
  ///
  /// 仅对 Riverpod 在依赖切换窗口抛出的时机错误进行重试，
  /// 其他错误保持原行为（记录告警并跳过该插件）。
  Future<List<AITool>> collectPluginToolsWithRetry(
    List<Plugin> plugins, {
    Duration retryDelay = const Duration(milliseconds: 120),
    int maxRetryAttempts = 1,
  }) async {
    final tools = <AITool>[];
    for (final plugin in plugins) {
      var attempt = 0;
      while (true) {
        try {
          tools.addAll(plugin.getTools());
          break;
        } catch (e) {
          final retryable = _isProviderRefreshTimingError(e);
          final shouldRetry = retryable && attempt < maxRetryAttempts;
          if (shouldRetry) {
            AppLogger.info('ChatSendService', '插件工具收集命中刷新窗口，准备重试', metadata: {
              'pluginId': plugin.id,
              'attempt': attempt + 1,
              'retryDelayMs': retryDelay.inMilliseconds,
            });
          } else {
            AppLogger.warning('ChatSendService', '插件工具收集失败', metadata: {
              'pluginId': plugin.id,
              'error': e.toString(),
              'attempt': attempt + 1,
              'retryable': retryable,
            });
          }
          if (!shouldRetry) {
            break;
          }
          attempt += 1;
          await Future<void>.delayed(retryDelay);
        }
      }
    }
    return tools;
  }

  bool _isProviderRefreshTimingError(Object error) {
    final message = error.toString();
    return message.contains(
          'Cannot use ref functions after the dependency of a provider changed but before the provider rebuilt',
        ) ||
        message.contains('!_didChangeDependency');
  }
}
