library;

import '../../plugins/time_awareness/time_awareness_plugin.dart';
import 'chat_plugin_context_builder.dart';

/// 构建发送链路 trace 相关 payload，避免门面服务继续堆积日志组装细节。
class ChatSendTracePayloadBuilder {
  const ChatSendTracePayloadBuilder();

  List<Map<String, dynamic>> buildSystemAssemblyEntries({
    required String personaPrompt,
    required bool includeInternalImageRule,
    required String internalImageContextRule,
    required PluginPromptBuildResult pluginPromptBuild,
  }) {
    final entries = <Map<String, dynamic>>[];

    void addEntry({
      required String source,
      required String label,
      required String content,
      Map<String, dynamic>? extra,
    }) {
      final trimmed = content.trim();
      if (trimmed.isEmpty) return;
      entries.add(<String, dynamic>{
        'order': entries.length,
        'source': source,
        'label': label,
        'content': trimmed,
        if (extra != null && extra.isNotEmpty) ...extra,
      });
    }

    addEntry(
      source: 'persona.userPrompt',
      label: '角色人设',
      content: personaPrompt,
    );
    if (includeInternalImageRule) {
      addEntry(
        source: 'internal.imageContextRule',
        label: '内部图片上下文规则',
        content: internalImageContextRule,
      );
    }
    for (final promptEntry in pluginPromptBuild.entries) {
      if (!promptEntry.injected) continue;
      addEntry(
        source: 'plugin.${promptEntry.pluginId}',
        label: '插件提示词',
        content: promptEntry.content,
        extra: <String, dynamic>{
          'pluginId': promptEntry.pluginId,
          'pluginName': promptEntry.pluginName,
        },
      );
    }
    return entries;
  }

  Map<String, dynamic> buildRuntimeContextPayload({
    required DateTime now,
    required DateTime? lastMessageTime,
    required List<dynamic> effectivePlugins,
    required PluginPromptBuildResult pluginPromptBuild,
    required int historyCount,
  }) {
    Map<String, dynamic>? timeAwarenessConfig;
    String? timeAwarenessPluginName;
    var timeAwarenessPluginEnabled = false;
    for (final plugin in effectivePlugins) {
      if (plugin is! TimeAwarenessPlugin) continue;
      timeAwarenessPluginName = plugin.name;
      timeAwarenessPluginEnabled = plugin.enabled;
      timeAwarenessConfig = Map<String, dynamic>.from(plugin.getConfig());
      break;
    }

    PluginPromptEntry? timePromptEntry;
    for (final promptEntry in pluginPromptBuild.entries) {
      if (promptEntry.pluginId != 'time_awareness') continue;
      timePromptEntry = promptEntry;
      break;
    }

    final elapsed =
        lastMessageTime == null ? null : now.difference(lastMessageTime);

    return <String, dynamic>{
      'clockSource': 'device_local',
      'generatedAt': now.toIso8601String(),
      'timezoneName': now.timeZoneName,
      'timezoneOffset': _formatTimezoneOffset(now.timeZoneOffset),
      'timezoneOffsetMinutes': now.timeZoneOffset.inMinutes,
      'historyCount': historyCount,
      if (lastMessageTime != null)
        'lastMessageTime': lastMessageTime.toIso8601String(),
      if (elapsed != null)
        'elapsedSinceLastMessage': <String, dynamic>{
          'milliseconds': elapsed.inMilliseconds,
          'minutes': elapsed.inMinutes,
          'human': _formatElapsedForTrace(elapsed),
        },
      'timeAwareness': <String, dynamic>{
        'pluginEnabled': timeAwarenessPluginEnabled,
        if (timeAwarenessPluginName != null)
          'pluginName': timeAwarenessPluginName,
        'promptInjected': timePromptEntry?.injected ?? false,
        if (timePromptEntry != null) 'reason': timePromptEntry.reason,
        if (timeAwarenessConfig != null) 'config': timeAwarenessConfig,
        if (timePromptEntry != null && timePromptEntry.content.isNotEmpty)
          'promptContent': timePromptEntry.content,
      },
    };
  }

  Map<String, dynamic> buildPromptAssemblyPayload({
    required List<Map<String, dynamic>> systemAssemblyEntries,
    required PluginPromptBuildResult pluginPromptBuild,
    required int messagesBeforeSystemCount,
    required int messagesAfterSystemCount,
    required List<Map<String, dynamic>> finalMessages,
    required int toolsCount,
  }) {
    final finalSystemPrompt = [
      for (final entry in systemAssemblyEntries)
        (entry['content'] ?? '').toString().trim(),
    ].where((content) => content.isNotEmpty).join('\n\n');

    return <String, dynamic>{
      'systemEntries': systemAssemblyEntries,
      'pluginPrompts': pluginPromptBuild.toJson(),
      'finalSystemPrompt': finalSystemPrompt,
      'insertedSystemMessage': finalSystemPrompt.isNotEmpty,
      'messagesCountBeforeSystem': messagesBeforeSystemCount,
      'messagesCountAfterSystem': messagesAfterSystemCount,
      'messagesCountAfterTruncate': finalMessages.length,
      'wasTruncated': finalMessages.length < messagesAfterSystemCount,
      'finalMessageRoles': <String>[
        for (final message in finalMessages) (message['role'] ?? '').toString(),
      ],
      'toolsCount': toolsCount,
    };
  }

  String _formatTimezoneOffset(Duration offset) {
    final totalMinutes = offset.inMinutes;
    final sign = totalMinutes >= 0 ? '+' : '-';
    final absoluteMinutes = totalMinutes.abs();
    final hours = (absoluteMinutes ~/ 60).toString().padLeft(2, '0');
    final minutes = (absoluteMinutes % 60).toString().padLeft(2, '0');
    return '$sign$hours:$minutes';
  }

  String? _formatElapsedForTrace(Duration elapsed) {
    final totalMinutes = elapsed.inMinutes;
    if (totalMinutes < 1) return '不足1分钟';

    final days = elapsed.inDays;
    final hours = elapsed.inHours;

    if (days >= 1) {
      final remainHours = hours - days * 24;
      if (remainHours > 0) {
        return '$days天$remainHours小时';
      }
      return '$days天';
    }

    if (hours >= 1) {
      final remainMinutes = totalMinutes - hours * 60;
      if (remainMinutes > 0) {
        return '$hours小时$remainMinutes分钟';
      }
      return '$hours小时';
    }

    return '$totalMinutes分钟';
  }
}
