library;

import '../../plugins/time_awareness/time_awareness_plugin.dart';
import 'chat_plugin_context_builder.dart';

/// 构建发送链路 trace 相关 payload，避免门面服务继续堆积日志组装细节。
class ChatSendTracePayloadBuilder {
  const ChatSendTracePayloadBuilder();

  List<Map<String, dynamic>> buildSystemAssemblyEntries({
    required String personaPrompt,
    String handoffPrompt = '',
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
    addEntry(source: 'context.topicHandoff', label: '新话题内容摘要（非格式指令）', content: handoffPrompt);
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
    required DateTime? previousUserMessageTime,
    required List<dynamic> effectivePlugins,
    required int historyCount,
    required bool systemReminderInjected,
    String? systemReminderContent,
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

    return <String, dynamic>{
      'clockSource': 'device_local',
      'generatedAt': now.toIso8601String(),
      'timezoneName': now.timeZoneName,
      'timezoneOffset': _formatTimezoneOffset(now.timeZoneOffset),
      'timezoneOffsetMinutes': now.timeZoneOffset.inMinutes,
      'historyCount': historyCount,
      'timeAwareness': <String, dynamic>{
        'pluginEnabled': timeAwarenessPluginEnabled,
        if (timeAwarenessPluginName != null)
          'pluginName': timeAwarenessPluginName,
        'systemReminderInjected': systemReminderInjected,
        if (timeAwarenessConfig != null) 'config': timeAwarenessConfig,
        'currentTime': now.toIso8601String(),
        'previousUserMessageTime':
            previousUserMessageTime?.toIso8601String() ?? 'unknown',
        if (systemReminderContent != null && systemReminderContent.isNotEmpty)
          'systemReminderContent': systemReminderContent,
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
    required bool systemReminderInjected,
    String? systemReminderContent,
    Map<String, dynamic>? presetAssembly,
  }) {
    final finalSystemPrompt = [
      for (final message in finalMessages)
        if (message['role'] == 'system') (message['content'] ?? '').toString().trim(),
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
      'systemReminderInjected': systemReminderInjected,
      if (systemReminderContent != null && systemReminderContent.isNotEmpty)
        'systemReminderContent': systemReminderContent,
      if (presetAssembly != null && presetAssembly.isNotEmpty)
        'sillyTavernPreset': presetAssembly,
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
}
