import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:aicove_flutter/src/core/api/agent_api.dart';
import 'package:aicove_flutter/src/core/database/database.dart';
import 'package:aicove_flutter/src/core/database/database_provider.dart';
import 'package:aicove_flutter/src/core/utils/message_formatter.dart';
import 'package:aicove_flutter/src/features/chat/conversation_providers.dart';
import 'package:aicove_flutter/src/features/chat/data/auto_reply_trigger.dart';
import 'package:aicove_flutter/src/features/chat/data/auto_reply_trigger_controller.dart';
import 'package:aicove_flutter/src/features/chat/data/context_analyzer.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart'
    as chat_domain;
import 'package:aicove_flutter/src/features/plugins/plugin_manager.dart';
import 'package:aicove_flutter/src/features/plugins/plugin_providers.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';

class _FakeAppSettingsNotifier extends AppSettingsNotifier {
  _FakeAppSettingsNotifier(this._settings);

  final AppSettings _settings;

  @override
  Future<AppSettings> build() async => _settings;
}

class _FakeConversationsNotifier extends ConversationsNotifier {
  _FakeConversationsNotifier(this._seed);

  final List<chat_domain.Conversation> _seed;

  @override
  Future<List<chat_domain.Conversation>> build() async => _seed;
}

class _RecordingAgentApiClient extends AgentApiClient {
  List<Map<String, dynamic>> capturedMessages = const <Map<String, dynamic>>[];

  @override
  Future<String> sendMessage({
    required String agentId,
    required String sessionId,
    required String modelFullId,
    required List<Map<String, dynamic>> messages,
    required String userText,
    double? temperature,
    String? token,
    Map<String, dynamic>? toolPrefs,
    String? providerApiBase,
    String? providerApiKey,
    int? maxTokens,
  }) async {
    capturedMessages = messages;
    return jsonEncode(<Map<String, dynamic>>[
      <String, dynamic>{
        'title': '晚点提醒',
        'delay_minutes': 30,
        'allow_night': false,
        'priority': 'medium',
        'prompt': '30分钟后提醒一下',
      },
    ]);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  AppSettings _buildSettings() {
    return const AppSettings(
      ttsEnabled: true,
      defaultModelName: 'openai:gpt-4o-mini',
      defaultPersonaPrompt: '',
      modelList: <String>['openai:gpt-4o-mini'],
      allKnownModels: <String>['openai:gpt-4o-mini'],
      modelDisplayNames: <String, String>{},
      modelTypes: <String, String>{},
      modelConfigs: <String, ModelConfig>{},
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
        ),
      ],
      modelProviderMap: <String, String>{'openai:gpt-4o-mini': 'openai'},
      backendApiKey: '',
      messageChunkingEnabled: false,
      messageFormatConfig: MessageFormatConfig(enableChunking: false),
      textScaleFactor: 1.0,
      uiScaleFactor: 1.0,
      imagePreviewScale: 1.0,
      autoReplySettings: AutoReplySettings(enabled: true),
      globalBackgroundColor: GlobalBackgroundColor.white,
      chatBackgroundColor: ChatBackgroundColor.defaultColor,
      isDarkMode: false,
      useSystemTheme: true,
      accentColor: 'FC96AA',
      hideUserAvatar: true,
      defaultChatModels: <String>['openai:gpt-4o-mini'],
    );
  }

  Future<void> _insertConversation(
    AppDatabase db,
    chat_domain.Conversation conv,
  ) async {
    await db.into(db.conversations).insert(
          ConversationsCompanion.insert(
            id: conv.id,
            title: conv.title,
            displayName: conv.displayName,
            personaPrompt: Value(conv.personaPrompt),
            createdAt: conv.createdAt.millisecondsSinceEpoch,
            updatedAt: conv.updatedAt.millisecondsSinceEpoch,
          ),
        );
  }

  Future<void> _insertMessage(
    AppDatabase db,
    String conversationId, {
    required String id,
    required String role,
    required String content,
    required int createdAt,
  }) async {
    await db.into(db.messages).insert(
          MessagesCompanion.insert(
            id: id,
            conversationId: conversationId,
            role: role,
            content: content,
            createdAt: createdAt,
          ),
        );
  }

  test('ContextAnalyzer 应从 ChatHistoryStore 读取真实消息', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    final now = DateTime(2026, 3, 12, 12).millisecondsSinceEpoch;
    final conversation = chat_domain.Conversation(
      id: 'conv_hist',
      title: '会话',
      displayName: '会话',
      createdAt: DateTime.fromMillisecondsSinceEpoch(now),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(now),
      messages: const [],
    );
    await _insertConversation(db, conversation);
    await _insertMessage(
      db,
      conversation.id,
      id: 'msg_user',
      role: 'user',
      content: '我今晚十点睡觉',
      createdAt: now,
    );
    await _insertMessage(
      db,
      conversation.id,
      id: 'msg_ai',
      role: 'assistant',
      content: '那我晚安前再来找你',
      createdAt: now + 1,
    );

    final fakeAgent = _RecordingAgentApiClient();
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWith((ref) => db),
        appSettingsProvider
            .overrideWith(() => _FakeAppSettingsNotifier(_buildSettings())),
        pluginManagerProvider.overrideWithValue(PluginManager()),
        conversationsProvider
            .overrideWith(() => _FakeConversationsNotifier([conversation])),
        contextAnalyzerProvider.overrideWith(
          (ref) => ContextAnalyzer(ref, agent: fakeAgent),
        ),
      ],
    );
    addTearDown(container.dispose);

    await container.read(autoReplyTriggersProvider.future);
    await container.read(contextAnalyzerProvider).analyzeAndSchedule(conversation);

    final joined = jsonEncode(fakeAgent.capturedMessages);
    expect(joined, contains('我今晚十点睡觉'));
    expect(joined, contains('那我晚安前再来找你'));

    final triggers = container.read(autoReplyTriggersProvider).valueOrNull ?? [];
    expect(triggers, hasLength(1));
    expect(triggers.single.contextLastUserMessageId, 'msg_user');
  });

  test('AutoReplyTriggerController 创建手动提醒时应读取数据库里的最后用户消息', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    final now = DateTime(2026, 3, 12, 14).millisecondsSinceEpoch;
    final conversation = chat_domain.Conversation(
      id: 'conv_trigger',
      title: '提醒会话',
      displayName: '提醒会话',
      createdAt: DateTime.fromMillisecondsSinceEpoch(now),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(now),
      messages: const [],
    );
    await _insertConversation(db, conversation);
    await _insertMessage(
      db,
      conversation.id,
      id: 'msg_last_user',
      role: 'user',
      content: '记得一小时后叫我',
      createdAt: now,
    );

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWith((ref) => db),
        appSettingsProvider
            .overrideWith(() => _FakeAppSettingsNotifier(_buildSettings())),
        conversationsProvider
            .overrideWith(() => _FakeConversationsNotifier([conversation])),
      ],
    );
    addTearDown(container.dispose);

    container.read(activeConversationIdProvider.notifier).state = conversation.id;
    await container.read(autoReplyTriggersProvider.future);
    await container.read(autoReplyTriggersProvider.notifier).createManualTrigger(
          type: AutoReplyTriggerType.delay,
          nextFireAt: DateTime.fromMillisecondsSinceEpoch(now)
              .add(const Duration(minutes: 30)),
          allowNight: true,
          requireExact: false,
        );

    final triggers = container.read(autoReplyTriggersProvider).valueOrNull ?? [];
    expect(triggers, hasLength(1));
    expect(triggers.single.contextLastUserMessageId, 'msg_last_user');
  });
}
