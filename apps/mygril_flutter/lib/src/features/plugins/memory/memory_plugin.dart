import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/app_logger.dart';
import '../../chat/providers2.dart';
import '../../memory/services/memory_service.dart';
import '../domain/plugin.dart';
import 'memory_config.dart';

class MemoryPlugin implements Plugin {
  MemoryConfig _config;
  late final MemoryService _service;
  final Ref _ref;

  MemoryPlugin(this._config, this._ref) {
    _service = MemoryService(_config);
  }

  @override
  String get id => 'memory';

  @override
  String get name => '长期记忆';

  @override
  String get description => '允许AI记住用户的长期喜好和重要信息';

  @override
  IconData get icon => Icons.memory;

  @override
  bool get enabled => _config.enabled;

  @override
  Map<String, dynamic> getConfig() => _config.toJson();

  @override
  void updateConfig(Map<String, dynamic> config) {
    _config = MemoryConfig.fromJson(config);
    // Re-init service with new config if needed, but for now simple replacement
    // In a real app we might need to recreate the service or update its config
  }

  @override
  Future<String?> getSystemPrompt({String? userMessage}) async {
    if (!enabled || userMessage == null || userMessage.trim().isEmpty) {
      return null;
    }

    try {
      final memories = await _service.search(userMessage);
      if (memories.isEmpty) return null;

      final buffer = StringBuffer();
      buffer.writeln('## Relevant Memories');
      buffer.writeln('Here are some facts you remember about the user that might be relevant:');
      for (final mem in memories) {
        buffer.writeln('- ${mem.content}');
      }
      return buffer.toString();
    } catch (e) {
      AppLogger.error('MemoryPlugin', 'Failed to get memories', metadata: {'error': e.toString()});
      return null;
    }
  }

  @override
  Future<PluginProcessResult> processResponse(String text) async {
    if (!enabled) {
      return PluginProcessResult(processedText: text, events: []);
    }

    // Trigger summarization in background if needed
    // We don't await this to avoid blocking the UI
    _checkAndTriggerSummarization();

    return PluginProcessResult(processedText: text, events: []);
  }

  void _checkAndTriggerSummarization() {
    final conv = _ref.read(activeConversationProvider);
    if (conv == null) return;

    final msgCount = conv.messages.length;
    // Simple trigger: Every N messages
    if (msgCount > 0 && msgCount % _config.triggerInterval == 0) {
      AppLogger.info('MemoryPlugin', 'Triggering memory summarization', metadata: {'msgCount': msgCount});
      
      // Run in background
      Future(() async {
        // Take last N messages + some context
        final messagesToAnalyze = conv.messages.length > 20 
            ? conv.messages.sublist(conv.messages.length - 20) 
            : conv.messages;
            
        await _service.summarizeAndStore(messagesToAnalyze);
      });
    }
  }
}
