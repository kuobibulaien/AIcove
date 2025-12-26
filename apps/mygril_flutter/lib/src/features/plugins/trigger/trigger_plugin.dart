import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/app_logger.dart';
import '../domain/plugin.dart';
import 'trigger_config.dart';
import 'trigger_service.dart';
import '../../chat/data/auto_reply_trigger.dart';
import '../../chat/data/auto_reply_trigger_controller.dart';

class TriggerPlugin implements Plugin {
  TriggerConfig _config;
  final TriggerService _service;
  final Ref _ref;

  TriggerPlugin(this._config, this._ref) : _service = TriggerService();

  @override
  String get id => 'trigger';

  @override
  String get name => '智能触发器';

  @override
  String get description => '允许AI根据对话设置定时提醒';

  @override
  IconData get icon => Icons.alarm;

  @override
  bool get enabled => _config.enabled;

  @override
  Map<String, dynamic> getConfig() => _config.toJson();

  @override
  void updateConfig(Map<String, dynamic> config) {
    _config = TriggerConfig.fromJson(config);
  }

  @override
  Future<String?> getSystemPrompt({String? userMessage}) async {
    // 原设计：触发器的创建由独立的 AI 管家（ContextAnalyzer）在对话结束后处理
    // 不在聊天 AI 的提示词中注入触发器创建能力，避免：
    // 1. 污染聊天上下文（角色扮演被触发器指令干扰）
    // 2. 在对话进行中就创建触发器（违背"对话结束后"原则）
    // 
    // 触发器创建流程：
    // - 用户切后台 / 5分钟无消息 → ContextAnalyzer → 独立调用 AI 管家 → 创建触发器
    // 
    // 此插件的 processResponse 仅作为兜底，处理意外出现的标签
    return null;
  }

  @override
  Future<PluginProcessResult> processResponse(String text) async {
    if (!enabled) {
      return PluginProcessResult(processedText: text, events: []);
    }

    final events = <PluginEvent>[];
    String processedText = text;

    // Handle <create_trigger>
    // Matches <create_trigger ... > or <create_trigger ... />
    final createRegex = RegExp(r'<create_trigger\s[^>]*?>', caseSensitive: false);
    final createMatches = createRegex.allMatches(text);
    for (final match in createMatches) {
      final attrString = match.group(0) ?? ''; // Use group 0 which is the whole tag, then parse attrs
      final timeMatch = RegExp(r'time="([^"]+)"').firstMatch(attrString);
      final titleMatch = RegExp(r'title="([^"]+)"').firstMatch(attrString);
      final promptMatch = RegExp(r'prompt="([^"]+)"').firstMatch(attrString);
      final contactIdMatch = RegExp(r'contact_id="([^"]+)"').firstMatch(attrString);

      if (timeMatch != null) {
        final timeStr = timeMatch.group(1)!;
        final title = titleMatch?.group(1) ?? 'Active Reply';
        final prompt = promptMatch?.group(1);
        final contactId = contactIdMatch?.group(1);
        
        DateTime? scheduledTime;
        try {
          scheduledTime = DateTime.parse(timeStr);
        } catch (_) {
           // Try simple HH:mm format for today/tomorrow
           try {
             final now = DateTime.now();
             final parts = timeStr.split(':');
             if (parts.length >= 2) {
               final h = int.parse(parts[0]);
               final m = int.parse(parts[1]);
               var d = DateTime(now.year, now.month, now.day, h, m);
               if (d.isBefore(now)) {
                 d = d.add(const Duration(days: 1));
               }
               scheduledTime = d;
             }
           } catch (e) {
             print('[TriggerPlugin] Failed to parse time: $timeStr');
           }
        }

        if (scheduledTime != null) {
          AppLogger.info('TriggerPlugin', 'Creating trigger: $title at $scheduledTime');
          await _ref.read(autoReplyTriggersProvider.notifier).createManualTrigger(
            type: AutoReplyTriggerType.fixed,
            nextFireAt: scheduledTime,
            allowNight: true,
            requireExact: false,
            delayMinutes: 0,
            title: title,
            prompt: prompt,
            contactId: contactId,
          );

          events.add(PluginEvent(
            pluginId: this.id,
            type: 'trigger_created',
            data: {
              'time': scheduledTime.toIso8601String(),
              'title': title,
            },
          ));
        }
      }
    }

    // Handle <delete_trigger>
    final deleteRegex = RegExp(r'<delete_trigger\s[^>]*?>', caseSensitive: false);
    final deleteMatches = deleteRegex.allMatches(text);
    for (final match in deleteMatches) {
      final attrString = match.group(0) ?? '';
      final idMatch = RegExp(r'id="([^"]+)"').firstMatch(attrString);
      
      if (idMatch != null) {
        final id = idMatch.group(1)!;
        AppLogger.info('TriggerPlugin', 'Deleting trigger: $id');
        await _ref.read(autoReplyTriggersProvider.notifier).deleteTrigger(id);
        
        events.add(PluginEvent(
          pluginId: this.id,
          type: 'trigger_deleted',
          data: {'id': id},
        ));
      }
    }

    // Remove tags from text
    processedText = text.replaceAll(createRegex, '').replaceAll(deleteRegex, '').trim();

    return PluginProcessResult(
      processedText: processedText,
      events: events,
    );
  }
}
