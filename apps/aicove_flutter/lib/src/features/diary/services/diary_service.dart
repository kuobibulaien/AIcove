import 'package:uuid/uuid.dart';
import '../../../core/app_logger.dart';
import '../../../core/database/repositories/diary_repository.dart';
import '../../../core/network/json_http_client.dart';
import '../../../core/prompts/prompt_builtin_defaults.g.dart';
import '../../../core/prompts/prompt_template_renderer.dart';
import '../../chat/domain/message.dart';
import '../../chat/domain/conversation.dart';
import '../../chat/domain/persona_prompt_codec.dart';
import '../../memory/services/memory_service.dart';
import '../../memory/services/hybrid_embedding_service.dart';
import '../models/diary_entry.dart';

/// 日记服务配置
class DiaryServiceConfig {
  final bool enabled;
  final ResolvedModelConfig? summarizeModel;
  final ResolvedModelConfig? embeddingModel;
  final ResolvedModelConfig? fallbackEmbeddingModel;
  final bool fallbackEnabled;

  const DiaryServiceConfig({
    this.enabled = true,
    this.summarizeModel,
    this.embeddingModel,
    this.fallbackEmbeddingModel,
    this.fallbackEnabled = false,
  });
}

/// 日记服务
///
/// 负责以角色视角生成每日日记，作为长期记忆存储
class DiaryService {
  final DiaryServiceConfig config;
  final DiaryRepository _repository;
  HybridEmbeddingService? _embeddingService;

  bool get isEmbeddingAvailable => _embeddingService != null;

  DiaryService(this.config, this._repository) {
    _initEmbeddingService();
  }

  void _initEmbeddingService() {
    final primary = config.embeddingModel;
    final fallback = config.fallbackEmbeddingModel;

    if (primary == null || !primary.isValid) {
      AppLogger.warning('DiaryService', 'No valid embedding model configured.');
      _embeddingService = null;
      return;
    }

    _embeddingService = HybridEmbeddingService(
      primaryApiKey: primary.apiKey,
      primaryBaseUrl: primary.baseUrl,
      primaryModel: primary.model,
      fallbackEnabled:
          config.fallbackEnabled && fallback != null && fallback.isValid,
      fallbackBaseUrl: fallback?.baseUrl ?? '',
      fallbackModel: fallback?.model ?? '',
      fallbackApiKey: fallback?.apiKey ?? '',
    );
  }

  /// 生成并存储今日日记
  ///
  /// [conversation] 角色/会话信息
  /// [messages] 今天的对话消息
  /// [forceRegenerate] 是否强制重新生成（覆盖已有日记）
  Future<DiaryEntry?> generateAndSaveDiary(
    Conversation conversation,
    List<Message> messages, {
    bool forceRegenerate = false,
  }) async {
    if (!config.enabled || messages.isEmpty) return null;

    final conversationId = conversation.id;
    final today = DateTime.now();

    // 检查今天是否已有日记
    if (!forceRegenerate) {
      final existing = await _repository.getDiaryByDate(conversationId, today);
      if (existing != null) {
        AppLogger.info('DiaryService', 'Today diary already exists', metadata: {
          'conversationId': conversationId,
        });
        return existing;
      }
    }

    AppLogger.info('DiaryService', 'Generating diary', metadata: {
      'conversationId': conversationId,
      'characterName': conversation.displayName,
      'messageCount': messages.length,
    });

    try {
      // 构建日记生成 prompt
      final prompt = _buildDiaryPrompt(conversation, messages);
      final diaryContent = await _callLLM(prompt);

      if (diaryContent == null || diaryContent.trim().isEmpty) {
        AppLogger.warning('DiaryService', 'Failed to generate diary content');
        return null;
      }

      // 生成 embedding（可选）
      List<double> embedding = [];
      if (_embeddingService != null) {
        try {
          embedding = await _embeddingService!.getEmbedding(diaryContent);
        } catch (e) {
          AppLogger.warning('DiaryService', 'Failed to generate embedding',
              metadata: {'error': e.toString()});
        }
      }

      final now = DateTime.now();
      final diary = DiaryEntry(
        id: const Uuid().v4(),
        conversationId: conversationId,
        date: DateTime(today.year, today.month, today.day), // 精确到天
        content: diaryContent.trim(),
        embedding: embedding,
        createdAt: now,
      );

      await _repository.saveDiary(diary);
      AppLogger.info('DiaryService', 'Diary saved successfully', metadata: {
        'diaryId': diary.id,
        'date': diary.dateKey,
      });

      return diary;
    } catch (e) {
      AppLogger.error('DiaryService', 'Failed to generate diary',
          metadata: {'error': e.toString()});
      return null;
    }
  }

  /// 构建日记生成 prompt
  String _buildDiaryPrompt(Conversation conversation, List<Message> messages) {
    final characterName = conversation.displayName;
    final selfAddress = conversation.selfAddress ?? '我';
    final addressUser = conversation.addressUser ?? '你';
    final personaText =
        PersonaPromptCodec.parse(conversation.personaPrompt).userPrompt;
    final personaHintSummary = personaText.isNotEmpty
        ? '${personaText.substring(0, personaText.length.clamp(0, 200))}...'
        : '';

    // 格式化对话内容
    final conversationText = messages.map((m) {
      final role = m.role == 'user' ? addressUser : selfAddress;
      return '$role: ${m.content}';
    }).join('\n');

    return PromptTemplateRenderer.renderTrimmed(
      PromptBuiltinDefaults.requireTemplate('diary.generate.default'),
      <String, Object?>{
        'assistant_name': characterName,
        'self_address': selfAddress,
        'user_address': addressUser,
        'persona_hint_block': PromptTemplateRenderer.prefixedText(
          '\n角色设定参考：',
          personaHintSummary,
        ),
        'conversation_text': conversationText,
      },
    );
  }

  /// 调用 LLM 生成日记
  Future<String?> _callLLM(String prompt) async {
    final modelConfig = config.summarizeModel;
    if (modelConfig == null || !modelConfig.isValid) {
      AppLogger.warning('DiaryService', 'Summarize model not configured.');
      return null;
    }

    final url = Uri.parse('${modelConfig.baseUrl}/chat/completions');

    try {
      final response = await JsonHttpClient.postJson(
        uri: url,
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${modelConfig.apiKey}',
        },
        jsonBody: {
          'model': modelConfig.model,
          'messages': [
            {'role': 'user', 'content': prompt}
          ],
          'temperature': 0.7, // 稍高的温度让日记更有个性
        },
      );

      final choices = response.data['choices'];
      if (choices is List && choices.isNotEmpty) {
        final first = choices.first;
        if (first is Map<String, dynamic>) {
          final message = first['message'];
          if (message is Map<String, dynamic>) {
            return message['content'] as String?;
          }
        }
      }
    } on JsonHttpRequestException catch (e) {
      AppLogger.error('DiaryService', 'LLM Call Failed',
          metadata: {'statusCode': e.statusCode, 'error': e.toString()});
    } catch (e) {
      AppLogger.error('DiaryService', 'LLM Call Failed',
          metadata: {'error': e.toString()});
    }
    return null;
  }

  // ==================== 查询接口 ====================

  /// 获取指定角色的所有日记
  Future<List<DiaryEntry>> getDiaries(String conversationId,
      {int? limit}) async {
    return await _repository.getDiariesByConversation(conversationId,
        limit: limit);
  }

  /// 获取指定角色的日记数量
  Future<int> getDiaryCount(String conversationId) async {
    return await _repository.getDiaryCountByConversation(conversationId);
  }

  /// 获取指定角色今天的日记
  Future<DiaryEntry?> getTodayDiary(String conversationId) async {
    return await _repository.getDiaryByDate(conversationId, DateTime.now());
  }

  /// 检查指定角色今天是否已有日记
  Future<bool> hasTodayDiary(String conversationId) async {
    return await _repository.hasTodayDiary(conversationId);
  }

  /// 搜索相关日记（基于语义）
  Future<List<DiaryEntry>> searchDiaries(String conversationId, String query,
      {int topK = 5}) async {
    if (_embeddingService == null) return [];

    try {
      final embedding = await _embeddingService!.getEmbedding(query);
      return await _repository.searchByEmbedding(conversationId, embedding,
          topK: topK);
    } catch (e) {
      AppLogger.error('DiaryService', 'Search Failed',
          metadata: {'error': e.toString()});
      return [];
    }
  }

  /// 删除日记
  Future<void> deleteDiary(String id) async {
    await _repository.deleteDiary(id);
    AppLogger.info('DiaryService', 'Diary deleted', metadata: {'id': id});
  }

  /// 格式化日记用于注入 System Prompt
  /// 返回格式：n天前的日记"..."
  List<String> formatDiariesForPrompt(List<DiaryEntry> diaries) {
    return diaries.map((d) {
      final daysAgo = DateTime.now().difference(d.date).inDays;
      final timeDesc = daysAgo == 0
          ? '今天'
          : daysAgo == 1
              ? '昨天'
              : '$daysAgo天前';
      // 截取摘要，避免太长
      final summary = d.content.length > 100
          ? '${d.content.substring(0, 100)}...'
          : d.content;
      return '$timeDesc的日记："$summary"';
    }).toList();
  }
}
