import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/app_logger.dart';
import '../../../core/database/database_provider.dart';
import '../../chat/providers2.dart';
import '../../memory/services/memory_service.dart';
import '../../settings/app_settings.dart';
import '../domain/index.dart';
import 'memory_config.dart';

/// 长期记忆插件
///
/// 功能：
/// - 在对话结束时提取关键事实并存储为向量记忆
/// - 在用户发消息时检索相关记忆注入到 System Prompt
/// - 输出格式：n天前的对话摘要"..."
class MemoryPlugin extends BasePlugin {
  // ========== 元数据定义 ==========
  static final _metadata = PluginMetadata(
    id: 'memory',
    name: '长期记忆',
    description: '允许AI记住用户的长期喜好和重要信息',
    version: '1.0.0',
    author: 'MyGril Team',
    icon: Icons.memory,
    configSchema: {
      'enabled': ConfigField(
        type: ConfigFieldType.boolean,
        label: '启用插件',
        defaultValue: false,
      ),
      'triggerInterval': ConfigField(
        type: ConfigFieldType.integer,
        label: '触发间隔',
        description: '每隔多少条消息触发一次记忆整理',
        defaultValue: 10,
      ),
      'summarizeProviderId': ConfigField(
        type: ConfigFieldType.string,
        label: '总结模型提供商',
        description: '用于生成记忆摘要的 AI 提供商 ID',
      ),
      'summarizeModelName': ConfigField(
        type: ConfigFieldType.string,
        label: '总结模型名称',
        description: '用于生成记忆摘要的模型名称',
      ),
      'embeddingProviderId': ConfigField(
        type: ConfigFieldType.string,
        label: 'Embedding 提供商',
        description: '用于向量化的 AI 提供商 ID',
      ),
      'embeddingModelName': ConfigField(
        type: ConfigFieldType.string,
        label: 'Embedding 模型',
        description: '用于向量化的模型名称',
      ),
    },
  );

  // ========== 内部状态 ==========
  MemoryConfig _memoryConfig;
  MemoryService? _service;
  final Ref _ref;

  // ========== 构造函数 ==========
  MemoryPlugin(this._memoryConfig, this._ref) : super(metadata: _metadata) {
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
      enabled: _memoryConfig.enabled,
      summarizePrompt: _memoryConfig.summarizePrompt,
      summarizeModel: _resolveModel(settings, _memoryConfig.summarizeProviderId, _memoryConfig.summarizeModelName),
      embeddingModel: _resolveModel(settings, _memoryConfig.embeddingProviderId, _memoryConfig.embeddingModelName),
      fallbackEmbeddingModel: _resolveModel(settings, _memoryConfig.fallbackEmbeddingProviderId, _memoryConfig.fallbackEmbeddingModelName),
      fallbackEnabled: _memoryConfig.fallbackEmbeddingEnabled,
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

  // ========== 重写 enabled getter ==========
  @override
  bool get enabled => _memoryConfig.enabled;

  // ========== 生命周期方法 ==========

  @override
  Future<void> onInitialize() async {
    await super.onInitialize();
    debugPrint('[MemoryPlugin] 初始化完成');
  }

  @override
  Future<void> onDestroy() async {
    _service = null;
    await super.onDestroy();
    debugPrint('[MemoryPlugin] 已销毁');
  }

  @override
  Future<void> onConfigChanged(Map<String, dynamic> newConfig) async {
    _memoryConfig = MemoryConfig.fromJson(newConfig);
    _initService();
    debugPrint('[MemoryPlugin] 配置已更新');
  }

  // ========== 现有功能（保留） ==========

  @override
  Map<String, dynamic> getConfig() => _memoryConfig.toJson();

  @override
  void updateConfig(Map<String, dynamic> config) {
    _memoryConfig = MemoryConfig.fromJson(config);
    _initService();
  }

  @override
  Future<String?> getSystemPrompt({String? userMessage, bool supportsToolCalling = false}) async {
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
    if (msgCount > 0 && msgCount % _memoryConfig.triggerInterval == 0) {
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
