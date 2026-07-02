import 'dart:convert';

import 'package:drift/drift.dart' hide isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/core/database/database.dart' as db;
import 'package:aicove_flutter/src/core/database/repositories/conversation_repository.dart';
import 'package:aicove_flutter/src/core/database/repositories/diary_repository.dart';
import 'package:aicove_flutter/src/core/database/repositories/memory_repository.dart';
import 'package:aicove_flutter/src/core/database/repositories/message_repository.dart';
import 'package:aicove_flutter/src/core/utils/message_formatter.dart';
import 'package:aicove_flutter/src/features/background_agent/background_agent_service.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart' as chat;
import 'package:aicove_flutter/src/features/chat/services/chat_types.dart';
import 'package:aicove_flutter/src/features/memory/services/embedding_service.dart';
import 'package:aicove_flutter/src/features/memory/services/memory_service.dart';
import 'package:aicove_flutter/src/features/plugins/domain/plugin.dart';
import 'package:aicove_flutter/src/features/plugins/domain/handlers/ai_tool.dart';
import 'package:aicove_flutter/src/features/plugins/memory/memory_plugin.dart';
import 'package:aicove_flutter/src/features/plugins/plugin_manager.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';

AppSettings _buildTestSettings() {
  const modelRef = 'openai:gpt-3.5-turbo';
  return const AppSettings(
    ttsEnabled: false,
    defaultModelName: modelRef,
    defaultPersonaPrompt: '',
    modelList: <String>[modelRef],
    allKnownModels: <String>[modelRef],
    modelDisplayNames: <String, String>{},
    modelTypes: <String, String>{},
    modelConfigs: <String, ModelConfig>{
      modelRef: ModelConfig(chatCapabilities: <String>['tools']),
    },
    apiKey: '',
    apiBaseUrl: 'https://api.openai.com/v1',
    imageGenerationEnabled: false,
    maxFileUploadMB: 10,
    historyMessageLimit: 100,
    customModels: <CustomModel>[],
    providers: <ProviderAuth>[
      ProviderAuth(
        id: 'openai',
        apiKeys: <String>['test-key'],
        apiBaseUrl: 'https://api.openai.com/v1',
        models: <String>['gpt-3.5-turbo'],
        visibleModels: <String>['gpt-3.5-turbo'],
      ),
    ],
    modelProviderMap: <String, String>{
      modelRef: 'openai',
      'gpt-3.5-turbo': 'openai',
    },
    backendApiKey: '',
    messageChunkingEnabled: false,
    messageFormatConfig: MessageFormatConfig(),
    textScaleFactor: 1.0,
    uiScaleFactor: 1.0,
    imagePreviewScale: 1.0,
    autoReplySettings: AutoReplySettings(),
    globalBackgroundColor: GlobalBackgroundColor.white,
    chatBackgroundColor: ChatBackgroundColor.defaultColor,
    isDarkMode: false,
    useSystemTheme: true,
    accentColor: 'FC96AA',
    hideUserAvatar: true,
    defaultChatModels: <String>[modelRef],
  );
}

class _FakeEmbeddingService implements EmbeddingService {
  @override
  Future<List<double>> getEmbedding(String text) async {
    return <double>[
      text.length.toDouble(),
      text.runes.length.toDouble(),
    ];
  }

  @override
  Future<List<List<double>>> getEmbeddings(List<String> texts) async {
    return Future.wait(texts.map(getEmbedding));
  }
}

Future<void> _insertConversation(
  db.AppDatabase database, {
  required String id,
  String displayName = '小璃',
  String? selfAddress = '我',
  String? addressUser = '宝宝',
  String personaPrompt = '你是温柔细腻、会认真记住细节的陪伴型角色。',
}) async {
  final now = DateTime.now().millisecondsSinceEpoch;
  await database.into(database.conversations).insert(
        db.ConversationsCompanion.insert(
          id: id,
          title: id,
          displayName: displayName,
          selfAddress: Value(selfAddress),
          addressUser: Value(addressUser),
          personaPrompt: Value(personaPrompt),
          createdAt: now,
          updatedAt: now,
        ),
      );
}

BackgroundAgentService _buildBackgroundAgentService({
  required List<String> responses,
  void Function(ApiConfig config)? onConfig,
}) {
  final queue = List<String>.from(responses);
  return BackgroundAgentService(
    loadRecentMessages: (_, __) async => const <chat.Message>[],
    loadSettings: () async => _buildTestSettings(),
    readPluginManager: () => PluginManager(),
    requestConfigResolver: ({
      required AppSettings settings,
      required String? modelRef,
    }) async {
      return const BackgroundAgentRequestConfig(
        modelFullId: 'openai:gpt-3.5-turbo',
        providerApiBase: 'https://api.openai.com/v1',
        providerApiKey: 'test-key',
        customConfig: <String, dynamic>{},
        modelTemperature: null,
        modelTopP: null,
        modelContextMessageLimit: null,
      );
    },
    executor: ({
      required ApiConfig config,
      required List<AITool> availableTools,
      required String sessionId,
      required int maxRounds,
    }) async {
      onConfig?.call(config);
      final reply = queue.removeAt(0);
      return ApiCallResult(
        replyText: '',
        processedText: reply,
        pluginEvents: const <PluginEvent>[],
        toolResults: const <Map<String, dynamic>>[],
      );
    },
    sessionIdFactory: (_) => 'memory_agent_test',
  );
}

List<chat.Message> _buildMessages(DateTime start) {
  return <chat.Message>[
    chat.Message.text(
      id: 'u1_${start.millisecondsSinceEpoch}',
      role: 'user',
      content: '我今天先把论文提纲改了一版，晚上想早点休息。',
      createdAt: start,
    ),
    chat.Message.text(
      id: 'a1_${start.millisecondsSinceEpoch}',
      role: 'assistant',
      content: '好，我陪你一起整理思路。',
      createdAt: start.add(const Duration(minutes: 2)),
    ),
  ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('角色专属记忆 Prompt 会把分层限定在当前角色下', () {
    final prompt = buildRoleScopedMemoryPrompt(
      roleLabel: '小璃',
      profilePrompt: '''
## 用户画像
- 对批评很敏感
- 情绪低落时更需要陪伴
''',
      relatedMemories: const <String>[
        '3天前，用户提到最近最怕复诊时被否定。',
      ],
    );

    expect(prompt, contains('## 当前角色专属记忆库'));
    expect(prompt, contains('当前角色：小璃'));
    expect(prompt, contains('### L1 用户攻略'));
    expect(prompt, contains('### L2/L3/L4 相关记忆'));
    expect(prompt, contains('以下 L1/L2/L3/L4 记忆仅属于当前角色'));
    expect(prompt, isNot(contains('## 用户画像')));
  });

  group('MemoryService L3 日记化', () {
    late db.AppDatabase database;
    late ConversationRepository conversationRepository;
    late DiaryRepository diaryRepository;
    late MemoryRepository memoryRepository;
    late MessageRepository messageRepository;

    setUp(() async {
      database = db.AppDatabase.forTesting(NativeDatabase.memory());
      conversationRepository = ConversationRepository(database);
      diaryRepository = DiaryRepository(database);
      memoryRepository = MemoryRepository(database);
      messageRepository = MessageRepository(database);
      await _insertConversation(database, id: 'conv_diary');
    });

    tearDown(() async {
      await database.close();
    });

    test('使用后台 agent 生成多条 L3 事件并聚合成单日日记', () async {
      ApiConfig? capturedConfig;
      final service = MemoryService(
        const MemoryServiceConfig(
          enabled: true,
          summarizeModelRef: 'openai:gpt-3.5-turbo',
          enableCapacityCompress: false,
          enableMemoryMerge: false,
          enableProfileLayer: false,
          enablePreFlush: false,
        ),
        memoryRepository,
        messageRepository,
        backgroundAgentService: _buildBackgroundAgentService(
          responses: <String>[
            jsonEncode(
              <String, dynamic>{
                'items': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'fact': '今天我陪宝宝把论文提纲重新理了一遍，看到她终于没那么乱了。',
                    'category': 'temporary_state',
                    'target_layer': 'L3',
                  },
                  <String, dynamic>{
                    'fact': '晚上我记下宝宝想先补觉，明天再继续改论文。',
                    'category': 'daily_chatter',
                    'target_layer': 'L3',
                  },
                ],
                'profile_suggestion': <String, dynamic>{},
              },
            ),
          ],
          onConfig: (config) {
            capturedConfig = config;
          },
        ),
        conversationRepository: conversationRepository,
        diaryRepository: diaryRepository,
        embeddingServiceOverride: _FakeEmbeddingService(),
      );

      final messages = _buildMessages(DateTime(2026, 3, 16, 21, 0));
      await service.summarizeAndStore(
        messages,
        conversationId: 'conv_diary',
      );

      final diary = await diaryRepository.getDiaryByDate(
        'conv_diary',
        DateTime(2026, 3, 16),
      );
      expect(diary, isNotNull);
      expect(
        diary!.content,
        '今天我陪宝宝把论文提纲重新理了一遍，看到她终于没那么乱了。\n\n晚上我记下宝宝想先补觉，明天再继续改论文。',
      );
      expect(diary.embedding, isNotEmpty);

      final memories = await memoryRepository.getAllActive(
        conversationId: 'conv_diary',
        includeProfile: false,
      );
      final l3Contents = memories
          .where((memory) => memory.layer == 'L3')
          .map((memory) => memory.content)
          .toList(growable: false);
      expect(
        l3Contents,
        containsAll(<String>[
          '2026-03-16，今天我陪宝宝把论文提纲重新理了一遍，看到她终于没那么乱了。',
          '2026-03-16，晚上我记下宝宝想先补觉，明天再继续改论文。',
        ]),
      );
      expect(capturedConfig, isNotNull);
      final systemPrompt = capturedConfig!.messages.first['content'] as String;
      expect(systemPrompt, contains('当前记忆库类型：角色专属记忆库'));
      expect(systemPrompt, contains('当前记忆库 ID：conv_diary'));
      expect(systemPrompt, contains('L1 / L2 / L3 / L4'));
      expect(systemPrompt, contains('角色名：小璃'));
      expect(systemPrompt, contains('对用户称呼优先使用：宝宝'));
      expect(systemPrompt, contains('target_layer = L3'));
    });

    test('同一天再次总结时会把新的 L3 事件追加到已有日记', () async {
      final service = MemoryService(
        const MemoryServiceConfig(
          enabled: true,
          summarizeModelRef: 'openai:gpt-3.5-turbo',
          enableCapacityCompress: false,
          enableMemoryMerge: false,
          enableProfileLayer: false,
          enablePreFlush: false,
        ),
        memoryRepository,
        messageRepository,
        backgroundAgentService: _buildBackgroundAgentService(
          responses: <String>[
            jsonEncode(
              <String, dynamic>{
                'items': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'fact': '下午我先陪宝宝把论文提纲列成了三段。',
                    'category': 'temporary_state',
                    'target_layer': 'L3',
                  },
                ],
                'profile_suggestion': <String, dynamic>{},
              },
            ),
            jsonEncode(
              <String, dynamic>{
                'items': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'fact': '晚上我又提醒宝宝先去睡觉，明早再继续改。',
                    'category': 'temporary_state',
                    'target_layer': 'L3',
                  },
                ],
                'profile_suggestion': <String, dynamic>{},
              },
            ),
          ],
        ),
        conversationRepository: conversationRepository,
        diaryRepository: diaryRepository,
        embeddingServiceOverride: _FakeEmbeddingService(),
      );

      await service.summarizeAndStore(
        _buildMessages(DateTime(2026, 3, 16, 14, 0)),
        conversationId: 'conv_diary',
      );
      await service.summarizeAndStore(
        _buildMessages(DateTime(2026, 3, 16, 22, 0)),
        conversationId: 'conv_diary',
      );

      final diary = await diaryRepository.getDiaryByDate(
        'conv_diary',
        DateTime(2026, 3, 16),
      );
      expect(diary, isNotNull);
      expect(
        diary!.content,
        '下午我先陪宝宝把论文提纲列成了三段。\n\n晚上我又提醒宝宝先去睡觉，明早再继续改。',
      );
      expect(
        await diaryRepository.getDiaryCountByConversation('conv_diary'),
        1,
      );
    });

    test('缺少后台 agent 配置时不会退回旧直连总结逻辑', () async {
      final service = MemoryService(
        const MemoryServiceConfig(
          enabled: true,
          summarizeModelRef: 'openai:gpt-3.5-turbo',
          enableCapacityCompress: false,
          enableMemoryMerge: false,
          enableProfileLayer: false,
          enablePreFlush: false,
        ),
        memoryRepository,
        messageRepository,
        conversationRepository: conversationRepository,
        diaryRepository: diaryRepository,
        embeddingServiceOverride: _FakeEmbeddingService(),
      );

      expect(
        () => service.summarizeAndStore(
          _buildMessages(DateTime(2026, 3, 16, 21, 0)),
          conversationId: 'conv_diary',
        ),
        throwsA(isA<StateError>()),
      );
    });
  });
}
