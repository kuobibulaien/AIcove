import 'dart:convert';
import 'package:uuid/uuid.dart';
import 'package:http/http.dart' as http;
import '../../../core/app_logger.dart';
import '../../../core/database/repositories/memory_repository.dart';
import '../../chat/domain/message.dart';
import '../models/memory_entity.dart';
import '../utils/memory_time_formatter.dart';
import 'embedding_service.dart';
import 'hybrid_embedding_service.dart';

/// 解析后的模型配置
class ResolvedModelConfig {
  final String apiKey;
  final String baseUrl;
  final String model;

  const ResolvedModelConfig({
    required this.apiKey,
    required this.baseUrl,
    required this.model,
  });

  bool get isValid => apiKey.isNotEmpty && baseUrl.isNotEmpty && model.isNotEmpty;
}

/// 记忆服务配置
class MemoryServiceConfig {
  final bool enabled;
  final String summarizePrompt;
  final ResolvedModelConfig? summarizeModel;
  final ResolvedModelConfig? embeddingModel;
  final ResolvedModelConfig? fallbackEmbeddingModel;
  final bool fallbackEnabled;

  const MemoryServiceConfig({
    this.enabled = true,
    this.summarizePrompt = '',
    this.summarizeModel,
    this.embeddingModel,
    this.fallbackEmbeddingModel,
    this.fallbackEnabled = false,
  });
}

/// 记忆服务
///
/// 负责对话摘要提取和记忆存储/检索
/// 使用 Drift MemoryRepository 进行数据持久化
class MemoryService {
  final MemoryServiceConfig config;
  final MemoryRepository _repository;
  EmbeddingService? _embeddingService;

  bool get isInFallbackMode {
    final service = _embeddingService;
    return service is HybridEmbeddingService && service.isInFallbackMode;
  }

  bool get isEmbeddingAvailable => _embeddingService != null;

  MemoryService(this.config, this._repository) {
    _initEmbeddingService();
  }

  void _initEmbeddingService() {
    final primary = config.embeddingModel;
    final fallback = config.fallbackEmbeddingModel;

    if (primary == null || !primary.isValid) {
      AppLogger.warning('MemoryService', 'No valid embedding model configured.');
      _embeddingService = null;
      return;
    }

    _embeddingService = HybridEmbeddingService(
      primaryApiKey: primary.apiKey,
      primaryBaseUrl: primary.baseUrl,
      primaryModel: primary.model,
      fallbackEnabled: config.fallbackEnabled && fallback != null && fallback.isValid,
      fallbackBaseUrl: fallback?.baseUrl ?? '',
      fallbackModel: fallback?.model ?? '',
      fallbackApiKey: fallback?.apiKey ?? '',
    );

    AppLogger.info('MemoryService', 'Initialized with hybrid embedding', metadata: {
      'primaryModel': primary.model,
      'fallbackEnabled': config.fallbackEnabled,
    });
  }

  /// 摘要并存储记忆
  Future<void> summarizeAndStore(List<Message> messages) async {
    if (!config.enabled || messages.isEmpty) return;

    AppLogger.info('MemoryService', 'Starting memory summarization', metadata: {
      'messageCount': messages.length,
    });

    try {
      final conversationText = messages.map((m) => '${m.role}: ${m.content}').join('\n');
      final prompt = '${config.summarizePrompt}\n\nConversation:\n$conversationText';

      final summary = await _callSummarizeLLM(prompt);
      if (summary == null || summary.trim().isEmpty || summary.toLowerCase().contains('no key facts')) {
        AppLogger.info('MemoryService', 'No relevant memories found to summarize.');
        return;
      }

      final facts = LineSplitter.split(summary)
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty && !s.startsWith('- '))
          .toList();

      if (facts.isEmpty) return;

      if (_embeddingService == null) {
        AppLogger.warning('MemoryService', 'Embedding service not available.');
        return;
      }

      final embeddings = await _embeddingService!.getEmbeddings(facts);
      final now = DateTime.now();

      for (int i = 0; i < facts.length; i++) {
        final memory = MemoryEntity(
          id: const Uuid().v4(),
          content: facts[i],
          embedding: embeddings[i],
          persistenceP: 0.5, // 默认值，后续可由 AI 打分
          emotionE: 0.0,
          infoI: 0.5,
          judgeJ: 0.5,
          createdAt: now,
        );

        await _repository.addMemory(memory);
        AppLogger.debug('MemoryService', 'Stored memory', metadata: {'content': facts[i]});
      }

      AppLogger.info('MemoryService', 'Successfully stored ${facts.length} memories.');
    } catch (e) {
      AppLogger.error('MemoryService', 'Failed to summarize memories', metadata: {'error': e.toString()});
    }
  }

  Future<String?> _callSummarizeLLM(String prompt) async {
    final summarizeConfig = config.summarizeModel;
    if (summarizeConfig == null || !summarizeConfig.isValid) {
      AppLogger.warning('MemoryService', 'Summarize model not configured.');
      return null;
    }

    final url = Uri.parse('${summarizeConfig.baseUrl}/chat/completions');
    final client = http.Client();

    try {
      final response = await client.post(
        url,
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${summarizeConfig.apiKey}',
        },
        body: jsonEncode({
          'model': summarizeConfig.model,
          'messages': [
            {'role': 'user', 'content': prompt}
          ],
          'temperature': 0.3,
        }),
      );

      if (response.statusCode >= 200 && response.statusCode < 300) {
        final data = jsonDecode(utf8.decode(response.bodyBytes));
        if (data['choices'] != null && (data['choices'] as List).isNotEmpty) {
          return data['choices'][0]['message']['content'] as String?;
        }
      } else {
        AppLogger.error('MemoryService', 'LLM Call Failed: ${response.statusCode}');
      }
    } catch (e) {
      AppLogger.error('MemoryService', 'LLM Call Failed', metadata: {'error': e.toString()});
    } finally {
      client.close();
    }
    return null;
  }

  /// 搜索相关记忆（候选300 → 相似度排序 → topK=3）
  /// 返回格式化后的记忆列表（带时间戳）
  Future<List<String>> searchFormatted(String query) async {
    if (_embeddingService == null) {
      AppLogger.warning('MemoryService', 'Embedding service not available.');
      return [];
    }

    try {
      final embedding = await _embeddingService!.getEmbedding(query);
      final memories = await _repository.searchTopK(embedding);

      // 格式化输出：n天前的对话摘要"..."
      return memories.map((m) => MemoryTimeFormatter.format(m.createdAt, m.content)).toList();
    } catch (e) {
      AppLogger.error('MemoryService', 'Search Failed', metadata: {'error': e.toString()});
      return [];
    }
  }

  /// 搜索原始记忆实体
  Future<List<MemoryEntity>> search(String query) async {
    if (_embeddingService == null) return [];

    try {
      final embedding = await _embeddingService!.getEmbedding(query);
      return await _repository.searchTopK(embedding);
    } catch (e) {
      AppLogger.error('MemoryService', 'Search Failed', metadata: {'error': e.toString()});
      return [];
    }
  }

  /// 清理过期的回收站记忆
  Future<int> purgeExpiredTrash() async {
    return await _repository.purgeExpired();
  }
}
