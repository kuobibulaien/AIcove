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
    if (!enabled) return null;
    
    final triggers = _ref.read(autoReplyTriggersProvider).valueOrNull ?? [];
    final buffer = StringBuffer();
    buffer.writeln('## Trigger Capability (Active Reply)');
    buffer.writeln('You can manage proactive triggers (active replies) for the user.');
    buffer.writeln('Current Time: ${DateTime.now().toIso8601String()}');
    buffer.writeln('Current Triggers:');
    if (triggers.isEmpty) {
      buffer.writeln('- (None)');
    } else {
      for (final t in triggers) {
        buffer.writeln('- ID: ${t.id}, Title: "${t.title}", Time: ${t.nextFireAt}, Contact: ${t.contactId ?? "Current"}, Prompt: "${t.prompt ?? ''}"');
      }
    }
    buffer.writeln('');
    buffer.writeln('To CREATE a trigger, output: <create_trigger time="YYYY-MM-DD HH:mm:ss" title="..." prompt="..." contact_id="..." />');
    buffer.writeln('  - `time`: Required. ISO 8601 format preferred (e.g., 2023-12-31 23:59:00).');
    buffer.writeln('  - `title`: Required. A short description.');
    buffer.writeln('  - `prompt`: Optional. The system instruction for the AI when the trigger fires (e.g., "Remind user to sleep").');
    buffer.writeln('  - `contact_id`: Optional. The ID of the contact to send the message to.');
    buffer.writeln('To DELETE a trigger, output: <delete_trigger id="..." />');
    buffer.writeln('The tags will be hidden from the user.');
    
    return buffer.toString();
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
