library;

import '../../plugins/domain/handlers/ai_tool.dart';
import '../../plugins/domain/plugin.dart';
import '../../plugins/plugin_manager.dart';
import '../../plugins/mcp/mcp_connector.dart';
import '../../../core/app_logger.dart';
import 'chat_types.dart' show isProviderRefreshTimingError;

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

/// One plugin's prompt for a request.
class PluginPromptSource {
  const PluginPromptSource({
    required this.pluginId,
    required this.pluginName,
    required this.build,
  });

  final String pluginId;
  final String pluginName;
  final Future<String?> Function() build;
}

/// One plugin's tools for a request.
class PluginToolSource {
  const PluginToolSource({required this.pluginId, required this.tools});

  final String pluginId;
  final List<AITool> Function() tools;
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
/// 1) 根据会话配置筛选有效插件（发送执行阶段，2c 前保留）
/// 2) 按插件来源拼接 System Prompt 条目
/// 3) 按插件来源收集工具定义
class ChatPluginContextBuilder {
  const ChatPluginContextBuilder();

  List<Plugin> getEffectivePlugins({
    required PluginManager pluginManager,
    required Set<String>? enabledPluginIds,
    Set<String> excludedPluginIds = const <String>{},
  }) {
    final globallyEnabled = pluginManager.getEnabledPlugins();
    if (enabledPluginIds == null) {
      // 「全部插件」只覆盖内置插件；MCP 连接器能操作外部服务，必须由角色显式开启。
      return [
        for (final plugin in globallyEnabled)
          if (!excludedPluginIds.contains(plugin.id) &&
              !McpToolNaming.isConnectorPluginId(plugin.id))
            plugin,
      ];
    }
    return [
      for (final plugin in globallyEnabled)
        if (enabledPluginIds.contains(plugin.id) &&
            !excludedPluginIds.contains(plugin.id))
          plugin,
    ];
  }

  /// Builds prompt entries from per-plugin sources in order. Only Riverpod
  /// provider-refresh timing errors are retried; other errors mark the entry
  /// as failed and continue.
  Future<PluginPromptBuildResult> buildPromptEntries(
    List<PluginPromptSource> sources, {
    Duration retryDelay = const Duration(milliseconds: 120),
    int maxRetryAttempts = 1,
  }) async {
    final entries = <PluginPromptEntry>[];
    for (final source in sources) {
      try {
        final prompt = await _withRefreshRetry(
          source.pluginId,
          source.build,
          retryDelay: retryDelay,
          maxRetryAttempts: maxRetryAttempts,
        );
        final trimmedPrompt = prompt?.trim() ?? '';
        entries.add(
          PluginPromptEntry(
            order: entries.length,
            pluginId: source.pluginId,
            pluginName: source.pluginName,
            injected: trimmedPrompt.isNotEmpty,
            content: trimmedPrompt,
            reason: trimmedPrompt.isEmpty ? 'empty_prompt' : null,
          ),
        );
      } catch (e) {
        AppLogger.warning('ChatSendService', 'Failed to build plugin prompt',
            metadata: {
              'pluginId': source.pluginId,
              'error': e.toString(),
            });
        entries.add(
          PluginPromptEntry(
            order: entries.length,
            pluginId: source.pluginId,
            pluginName: source.pluginName,
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

  Future<String?> _withRefreshRetry(
    String pluginId,
    Future<String?> Function() build, {
    required Duration retryDelay,
    required int maxRetryAttempts,
  }) async {
    var attempt = 0;
    while (true) {
      try {
        return await build();
      } catch (e) {
        final retryable = isProviderRefreshTimingError(e);
        final shouldRetry = retryable && attempt < maxRetryAttempts;
        if (shouldRetry) {
          AppLogger.info('ChatSendService', '插件提示词构建命中刷新窗口，准备重试', metadata: {
            'pluginId': pluginId,
            'attempt': attempt + 1,
            'retryDelayMs': retryDelay.inMilliseconds,
          });
          attempt += 1;
          await Future<void>.delayed(retryDelay);
          continue;
        }
        rethrow;
      }
    }
  }

  /// 收集插件工具（带一次短延迟重试）。
  ///
  /// 仅对 Riverpod 在依赖切换窗口抛出的时机错误进行重试，
  /// 其他错误保持原行为（记录告警并跳过该插件）。
  Future<List<AITool>> collectToolsWithRetry(
    List<PluginToolSource> sources, {
    Duration retryDelay = const Duration(milliseconds: 120),
    int maxRetryAttempts = 1,
  }) async {
    final tools = <AITool>[];
    for (final source in sources) {
      var attempt = 0;
      while (true) {
        try {
          tools.addAll(source.tools());
          break;
        } catch (e) {
          final retryable = isProviderRefreshTimingError(e);
          final shouldRetry = retryable && attempt < maxRetryAttempts;
          if (shouldRetry) {
            AppLogger.info('ChatSendService', '插件工具收集命中刷新窗口，准备重试', metadata: {
              'pluginId': source.pluginId,
              'attempt': attempt + 1,
              'retryDelayMs': retryDelay.inMilliseconds,
            });
          } else {
            AppLogger.warning('ChatSendService', '插件工具收集失败', metadata: {
              'pluginId': source.pluginId,
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
}
