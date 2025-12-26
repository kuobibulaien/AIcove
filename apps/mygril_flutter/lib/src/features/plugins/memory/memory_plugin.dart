import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/app_logger.dart';
import '../../../core/database/database_provider.dart';
import '../../chat/providers2.dart';
import '../../memory/services/memory_service.dart';
import '../../settings/app_settings.dart';
import '../domain/plugin.dart';
import 'memory_config.dart';

/// 长期记忆插件
///
/// 功能：
/// - 在对话结束时提取关键事实并存储为向量记忆
/// - 在用户发消息时检索相关记忆注入到 System Prompt
/// - 输出格式：n天前的对话摘要"..."
class MemoryPlugin implements Plugin {
  MemoryConfig _config;
  MemoryService? _service;
  final Ref _ref;

  MemoryPlugin(this._config, this._ref) {
    _initService();
  }

  void _initService() {
    final appSettings = _ref.read(appSettingsProvider).valueOrNull;
    if (appSettings == null) {
      AppLogger.warning('MemoryPlugin', 'AppSettings not available. Service init delayed.');
      return;
    }

    final repository = _ref.read(memoryRepositoryProvider);
    final serviceConfig = _resolveConfig(appSettings);
    _service = MemoryService(serviceConfig, repository);

    AppLogger.info('MemoryPlugin', 'Service initialized', metadata: {
      'embeddingAvailable': _service?.isEmbeddingAvailable ?? false,
    });
  }

  MemoryServiceConfig _resolveConfig(AppSettings settings) {
    return MemoryServiceConfig(
      enabled: _config.enabled,
      summarizePrompt: _config.summarizePrompt,
      summarizeModel: _resolveModel(settings, _config.summarizeProviderId, _config.summarizeModelName),
      embeddingModel: _resolveModel(settings, _config.embeddingProviderId, _config.embeddingModelName),
      fallbackEmbeddingModel: _resolveModel(settings, _config.fallbackEmbeddingProviderId, _config.fallbackEmbeddingModelName),
      fallbackEnabled: _config.fallbackEmbeddingEnabled,
    );
  }

  ResolvedModelConfig? _resolveModel(AppSettings settings, String? providerId, String? modelName) {
    if (providerId == null || providerId.isEmpty) return null;
    if (modelName == null || modelName.isEmpty) return null;

    final provider = settings.providers.firstWhere(
      (p) => p.id == providerId && p.enabled,
      orElse: () => const ProviderAuth(id: '', apiKeys: [], apiBaseUrl: ''),
    );

    if (provider.id.isEmpty || provider.apiKeys.isEmpty) {
      return null;
    }

    return ResolvedModelConfig(
      apiKey: provider.apiKeys.first,
      baseUrl: provider.apiBaseUrl,
      model: modelName,
    );
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
    _initService();
  }

  @override
  Future<String?> getSystemPrompt({String? userMessage}) async {
    if (!enabled || _service == null || userMessage == null || userMessage.trim().isEmpty) {
      return null;
    }

    try {
      // 使用新的格式化搜索方法
      final formattedMemories = await _service!.searchFormatted(userMessage);
      if (formattedMemories.isEmpty) return null;

      final buffer = StringBuffer();
      buffer.writeln('## 相关记忆');
      buffer.writeln('以下是你记住的关于用户的一些事实，可能与当前对话相关：');

      for (final mem in formattedMemories) {
        buffer.writeln('- $mem');
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

    _checkAndTriggerSummarization();
    return PluginProcessResult(processedText: text, events: []);
  }

  void _checkAndTriggerSummarization() {
    if (_service == null) return;

    final conv = _ref.read(activeConversationProvider);
    if (conv == null) return;

    final msgCount = conv.messages.length;
    if (msgCount > 0 && msgCount % _config.triggerInterval == 0) {
      AppLogger.info('MemoryPlugin', 'Triggering memory summarization', metadata: {'msgCount': msgCount});

      Future(() async {
        final messagesToAnalyze = conv.messages.length > 20 ? conv.messages.sublist(conv.messages.length - 20) : conv.messages;
        await _service!.summarizeAndStore(messagesToAnalyze);
      });
    }
  }

  /// 会话结束时触发的记忆整理
  Future<void> onSessionEnd() async {
    if (!enabled || _service == null) return;

    final conv = _ref.read(activeConversationProvider);
    if (conv == null || conv.messages.isEmpty) {
      return;
    }

    AppLogger.info('MemoryPlugin', 'Session ended, summarizing conversation...', metadata: {
      'messageCount': conv.messages.length,
    });

    try {
      final messagesToAnalyze = conv.messages.length > 30 ? conv.messages.sublist(conv.messages.length - 30) : conv.messages;
      await _service!.summarizeAndStore(messagesToAnalyze);

      // 清理过期的回收站记忆
      final purged = await _service!.purgeExpiredTrash();
      if (purged > 0) {
        AppLogger.info('MemoryPlugin', 'Purged $purged expired memories from trash.');
      }
    } catch (e) {
      AppLogger.error('MemoryPlugin', 'Failed to summarize on session end', metadata: {'error': e.toString()});
    }
  }

  MemoryService? get service => _service;
}
