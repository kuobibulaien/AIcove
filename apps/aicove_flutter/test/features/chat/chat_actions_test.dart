import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/core/database/database.dart'
    hide Conversation, Message;
import 'package:aicove_flutter/src/core/database/database_provider.dart';
import 'package:aicove_flutter/src/core/app_logger.dart';
import 'package:aicove_flutter/src/core/models/message_block.dart';
import 'package:aicove_flutter/src/core/services/attachment_picker_service.dart';
import 'package:aicove_flutter/src/features/chat/chat_actions.dart';
import 'package:aicove_flutter/src/features/chat/conversation_providers.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_send_service.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/core/utils/message_formatter.dart';

class _FakeConversationsNotifier extends ConversationsNotifier {
  _FakeConversationsNotifier(this._seed);

  final List<Conversation> _seed;

  @override
  Future<List<Conversation>> build() async => _seed;

  @override
  Future<void> setAll(
    List<Conversation> list, {
    bool persist = true,
  }) async {
    state = AsyncValue.data(list);
  }
}

class _RecordingConversationsNotifier extends _FakeConversationsNotifier {
  _RecordingConversationsNotifier(super.seed);

  final List<List<Conversation>> snapshots = <List<Conversation>>[];

  @override
  Future<void> setAll(
    List<Conversation> list, {
    bool persist = true,
  }) async {
    snapshots.add([
      for (final conv in list)
        conv.copyWith(messages: List<Message>.from(conv.messages)),
    ]);
    state = AsyncValue.data(list);
  }
}

Future<void> _insertConversation(AppDatabase db, Conversation conv) async {
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

Future<void> _insertMessage(AppDatabase db, String convId, Message msg) async {
  await db.into(db.messages).insert(
        MessagesCompanion.insert(
          id: msg.id,
          conversationId: convId,
          role: msg.role,
          content: msg.content,
          status: Value(msg.status ?? 'sent'),
          createdAt: msg.createdAt.millisecondsSinceEpoch,
        ),
      );
}

Future<void> _insertTextBlock(AppDatabase db, String messageId, String blockId,
    {int sortOrder = 0}) async {
  final block = TextBlock(
    id: blockId,
    messageId: messageId,
    content: 'block:$blockId',
  );
  await db.into(db.messageBlocks).insert(
        MessageBlocksCompanion.insert(
          id: block.id,
          messageId: block.messageId,
          type: 'mainText',
          data: jsonEncode(block.toJson()),
          sortOrder: Value(sortOrder),
          createdAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );
}

AppSettings _buildTestSettings({double streamSegmentDelaySeconds = 0}) {
  const defaultModelRef = 'openai:gpt-4o-mini';
  return AppSettings(
    ttsEnabled: true,
    defaultModelName: defaultModelRef,
    defaultPersonaPrompt: '',
    modelList: const <String>[defaultModelRef],
    allKnownModels: const <String>[defaultModelRef],
    modelDisplayNames: const <String, String>{},
    modelTypes: const <String, String>{},
    modelConfigs: const <String, ModelConfig>{},
    apiKey: '',
    apiBaseUrl: 'https://api.openai.com/v1',
    imageGenerationEnabled: false,
    maxFileUploadMB: 10,
    historyMessageLimit: 100,
    customModels: const <CustomModel>[],
    providers: const <ProviderAuth>[
      ProviderAuth(
        id: 'openai',
        apiKeys: <String>['test-key'],
        apiBaseUrl: 'https://api.openai.com/v1',
      ),
    ],
    modelProviderMap: const <String, String>{
      defaultModelRef: 'openai',
      'gpt-4o-mini': 'openai',
    },
    backendApiKey: '',
    messageChunkingEnabled: true,
    messageFormatConfig: const MessageFormatConfig(
      enableChunking: true,
      chunkPunctuations: <String>['。'],
      minSegmentLength: 1,
    ),
    textScaleFactor: 1.0,
    uiScaleFactor: 1.0,
    imagePreviewScale: 1.0,
    autoReplySettings: const AutoReplySettings(),
    globalBackgroundColor: GlobalBackgroundColor.white,
    chatBackgroundColor: ChatBackgroundColor.defaultColor,
    isDarkMode: false,
    useSystemTheme: true,
    accentColor: 'FC96AA',
    hideUserAvatar: true,
    defaultChatModels: const <String>[defaultModelRef],
    streamSegmentDelaySeconds: streamSegmentDelaySeconds,
  );
}

class _FakeAppSettingsNotifier extends AppSettingsNotifier {
  _FakeAppSettingsNotifier(this._settings);

  final AppSettings _settings;

  @override
  Future<AppSettings> build() async => _settings;
}

class _SpyStreamingSendService extends ChatSendService {
  _SpyStreamingSendService(super.ref, this._settings);

  final AppSettings _settings;

  bool lastEnableStreaming = false;
  bool sawDeltaCallback = false;
  bool sawResetCallback = false;
  bool sawToolObservedCallback = false;
  bool sawFallbackCallback = false;
  int executeCalls = 0;

  @override
  Future<ApiConfig> prepareApiConfig({
    required Conversation conv,
    required List<Message> history,
    required String? userText,
    TraceLogger? trace,
    String? overrideModel,
  }) async {
    return ApiConfig(
      settings: _settings,
      modelFullId: overrideModel ?? _settings.defaultModelName,
      providerApiBase: _settings.apiBaseUrl,
      providerApiKey: null,
      customConfig: const <String, dynamic>{},
      toolPrefs: const <String, dynamic>{},
      messages: const <Map<String, dynamic>>[],
      tools: null,
      enabledPluginIds: null,
      modelTemperature: null,
      modelTopP: null,
      modelContextMessageLimit: null,
    );
  }

  @override
  Future<ApiCallResult> executeApiCall({
    required ApiConfig config,
    required String sessionId,
    required String? userText,
    String? turnId,
    TraceLogger? trace,
    int maxRounds = 5,
    void Function(String toolName)? onToolExecuting,
    bool enableStreaming = false,
    void Function(String delta)? onStreamTextDelta,
    void Function()? onStreamTextReset,
    void Function()? onStreamToolCallObserved,
    void Function()? onStreamingFallback,
  }) async {
    executeCalls += 1;
    lastEnableStreaming = enableStreaming;
    sawDeltaCallback = onStreamTextDelta != null;
    sawResetCallback = onStreamTextReset != null;
    sawToolObservedCallback = onStreamToolCallObserved != null;
    sawFallbackCallback = onStreamingFallback != null;
    onStreamTextDelta?.call('先来一句。');
    return const ApiCallResult(
      replyText: '先来一句。',
      processedText: '先来一句。',
      pluginEvents: [],
      toolResults: <Map<String, dynamic>>[],
    );
  }

  @override
  AssistantMessageBuildResult buildAssistantMessages({
    required ApiCallResult apiResult,
    required AppSettings settings,
  }) {
    return AssistantMessageBuildResult(
      messages: <Message>[
        Message(
          id: 'assistant_result',
          role: 'assistant',
          content: apiResult.processedText,
          createdAt: DateTime.now(),
          status: 'sent',
        ),
      ],
      lastMessageText: apiResult.processedText,
    );
  }
}

class _FallbackAfterDeltaSendService extends ChatSendService {
  _FallbackAfterDeltaSendService(super.ref, this._settings);

  final AppSettings _settings;

  @override
  Future<ApiConfig> prepareApiConfig({
    required Conversation conv,
    required List<Message> history,
    required String? userText,
    TraceLogger? trace,
    String? overrideModel,
  }) async {
    return ApiConfig(
      settings: _settings,
      modelFullId: overrideModel ?? _settings.defaultModelName,
      providerApiBase: _settings.apiBaseUrl,
      providerApiKey: null,
      customConfig: const <String, dynamic>{},
      toolPrefs: const <String, dynamic>{},
      messages: const <Map<String, dynamic>>[],
      tools: null,
      enabledPluginIds: null,
      modelTemperature: null,
      modelTopP: null,
      modelContextMessageLimit: null,
    );
  }

  @override
  Future<ApiCallResult> executeApiCall({
    required ApiConfig config,
    required String sessionId,
    required String? userText,
    String? turnId,
    TraceLogger? trace,
    int maxRounds = 5,
    void Function(String toolName)? onToolExecuting,
    bool enableStreaming = false,
    void Function(String delta)? onStreamTextDelta,
    void Function()? onStreamTextReset,
    void Function()? onStreamToolCallObserved,
    void Function()? onStreamingFallback,
  }) async {
    onStreamTextDelta?.call('前置流式文本。');
    onStreamingFallback?.call();
    return const ApiCallResult(
      replyText: '前置流式文本。',
      processedText: '前置流式文本。',
      pluginEvents: [],
      toolResults: <Map<String, dynamic>>[],
    );
  }

  @override
  AssistantMessageBuildResult buildAssistantMessages({
    required ApiCallResult apiResult,
    required AppSettings settings,
  }) {
    final now = DateTime.now();
    const imageMsgId = 'assistant_image';
    return AssistantMessageBuildResult(
      messages: <Message>[
        Message(
          id: 'assistant_result',
          role: 'assistant',
          content: apiResult.processedText,
          createdAt: now,
          status: 'sent',
        ),
        Message.fromBlocks(
          id: imageMsgId,
          role: 'assistant',
          blocks: [
            ImageBlock(
              messageId: imageMsgId,
              localPath: r'C:\tmp\stream_image.png',
            ),
          ],
          createdAt: now.add(const Duration(milliseconds: 1)),
          status: 'sent',
        ),
      ],
      lastMessageText: '[图片]',
    );
  }
}

class _MultiDeltaStreamingSendService extends ChatSendService {
  _MultiDeltaStreamingSendService(super.ref, this._settings);

  final AppSettings _settings;

  @override
  Future<ApiConfig> prepareApiConfig({
    required Conversation conv,
    required List<Message> history,
    required String? userText,
    TraceLogger? trace,
    String? overrideModel,
  }) async {
    return ApiConfig(
      settings: _settings,
      modelFullId: overrideModel ?? _settings.defaultModelName,
      providerApiBase: _settings.apiBaseUrl,
      providerApiKey: null,
      customConfig: const <String, dynamic>{},
      toolPrefs: const <String, dynamic>{},
      messages: const <Map<String, dynamic>>[],
      tools: null,
      enabledPluginIds: null,
      modelTemperature: null,
      modelTopP: null,
      modelContextMessageLimit: null,
    );
  }

  @override
  Future<ApiCallResult> executeApiCall({
    required ApiConfig config,
    required String sessionId,
    required String? userText,
    String? turnId,
    TraceLogger? trace,
    int maxRounds = 5,
    void Function(String toolName)? onToolExecuting,
    bool enableStreaming = false,
    void Function(String delta)? onStreamTextDelta,
    void Function()? onStreamTextReset,
    void Function()? onStreamToolCallObserved,
    void Function()? onStreamingFallback,
  }) async {
    onStreamTextDelta?.call('第一段。');
    await Future.delayed(const Duration(milliseconds: 45));
    onStreamTextDelta?.call('第二段。');
    await Future.delayed(const Duration(milliseconds: 45));
    onStreamTextDelta?.call('第三段。');
    await Future.delayed(const Duration(milliseconds: 45));
    return const ApiCallResult(
      replyText: '第一段。第二段。第三段。',
      processedText: '第一段。第二段。第三段。',
      pluginEvents: [],
      toolResults: <Map<String, dynamic>>[],
    );
  }

  @override
  AssistantMessageBuildResult buildAssistantMessages({
    required ApiCallResult apiResult,
    required AppSettings settings,
  }) {
    return AssistantMessageBuildResult(
      messages: <Message>[
        Message(
          id: 'assistant_result',
          role: 'assistant',
          content: apiResult.processedText,
          createdAt: DateTime.now(),
          status: 'sent',
        ),
      ],
      lastMessageText: apiResult.processedText,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('recallFailedMessage 会删除失败消息并软删除数据库记录', () async {
    final now = DateTime.now();
    final failed = Message(
      id: 'msg_failed',
      role: 'user',
      content: '发送失败内容',
      createdAt: now,
      status: 'failed',
    );
    final conv = Conversation(
      id: 'conv_1',
      title: 'C1',
      displayName: 'C1',
      createdAt: now,
      updatedAt: now,
      messages: [failed],
      lastMessage: failed.displayText,
      lastMessageTime: failed.createdAt,
    );

    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await _insertConversation(db, conv);
    await _insertMessage(db, conv.id, failed);

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        conversationsProvider.overrideWith(
          () => _FakeConversationsNotifier([conv]),
        ),
        activeConversationProvider.overrideWith((ref) {
          final list = ref.watch(conversationsProvider).valueOrNull;
          if (list == null || list.isEmpty) return null;
          return list.first;
        }),
      ],
    );
    addTearDown(container.dispose);

    await container.read(conversationsProvider.future);
    final actions = container.read(chatActionsProvider);

    await actions.recallFailedMessage(failed.id);

    final updated = container.read(conversationsProvider).valueOrNull!.first;
    expect(updated.messages, isEmpty);
    expect(container.read(editingTextProvider), failed.displayText);

    final repo = container.read(messageRepositoryProvider);
    final dbMessage = await repo.getById(failed.id);
    expect(dbMessage, isNotNull);
    expect(dbMessage!.deletedAt, isNotNull);
  });

  test('recallFailedMessage 会回填失败图文消息的文字和图片附件', () async {
    final now = DateTime.now();
    const imagePath = r'C:\tmp\demo_recall.png';
    final failed = Message.fromBlocks(
      id: 'msg_failed_img',
      role: 'user',
      blocks: [
        ImageBlock(
          messageId: 'msg_failed_img',
          localPath: imagePath,
        ),
        TextBlock(
          messageId: 'msg_failed_img',
          content: '这是撤回后的说明文字',
        ),
      ],
      createdAt: now,
      status: 'failed',
    );
    final conv = Conversation(
      id: 'conv_img',
      title: 'C_IMG',
      displayName: 'C_IMG',
      createdAt: now,
      updatedAt: now,
      messages: [failed],
      lastMessage: failed.displayText,
      lastMessageTime: failed.createdAt,
    );

    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await _insertConversation(db, conv);
    await _insertMessage(db, conv.id, failed);

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        conversationsProvider.overrideWith(
          () => _FakeConversationsNotifier([conv]),
        ),
        activeConversationProvider.overrideWith((ref) {
          final list = ref.watch(conversationsProvider).valueOrNull;
          if (list == null || list.isEmpty) return null;
          return list.first;
        }),
      ],
    );
    addTearDown(container.dispose);

    await container.read(conversationsProvider.future);
    final actions = container.read(chatActionsProvider);

    await actions.recallFailedMessage(failed.id);

    expect(container.read(editingTextProvider), '这是撤回后的说明文字');

    final recalledAttachment = container.read(recalledAttachmentProvider);
    expect(recalledAttachment, isNotNull);
    expect(recalledAttachment!.type, AttachmentType.image);
    expect(recalledAttachment.path, imagePath);
  });

  test('deleteMessage 会删除单条消息并清理引用态', () async {
    final now = DateTime.now();
    final userMsg = Message(
      id: 'msg_user',
      role: 'user',
      content: '第一条',
      createdAt: now.subtract(const Duration(minutes: 1)),
      status: 'sent',
    );
    final aiMsg = Message(
      id: 'msg_ai',
      role: 'assistant',
      content: '第二条',
      createdAt: now,
      status: 'sent',
    );
    final conv = Conversation(
      id: 'conv_2',
      title: 'C2',
      displayName: 'C2',
      createdAt: now,
      updatedAt: now,
      messages: [userMsg, aiMsg],
      lastMessage: aiMsg.displayText,
      lastMessageTime: aiMsg.createdAt,
    );

    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await _insertConversation(db, conv);
    await _insertMessage(db, conv.id, userMsg);
    await _insertMessage(db, conv.id, aiMsg);
    await _insertTextBlock(db, userMsg.id, 'blk_user_1');
    await _insertTextBlock(db, aiMsg.id, 'blk_ai_1');

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        conversationsProvider.overrideWith(
          () => _FakeConversationsNotifier([conv]),
        ),
        activeConversationProvider.overrideWith((ref) {
          final list = ref.watch(conversationsProvider).valueOrNull;
          if (list == null || list.isEmpty) return null;
          return list.first;
        }),
      ],
    );
    addTearDown(container.dispose);

    await container.read(conversationsProvider.future);
    final actions = container.read(chatActionsProvider);

    container.read(quotedMessageProvider.notifier).state = const QuotedMessage(
      id: 'msg_ai',
      content: '第二条',
      isUser: false,
    );

    await actions.deleteMessage(aiMsg.id);

    final updated = container.read(conversationsProvider).valueOrNull!.first;
    expect(updated.messages.length, 1);
    expect(updated.messages.first.id, userMsg.id);
    expect(updated.lastMessage, userMsg.displayText);
    expect(container.read(quotedMessageProvider), isNull);

    final repo = container.read(messageRepositoryProvider);
    final blockRepo = container.read(messageBlockRepositoryProvider);
    final deleted = await repo.getById(aiMsg.id);
    final remained = await repo.getById(userMsg.id);
    final deletedBlocks = await blockRepo.getByMessage(aiMsg.id);
    final remainedBlocks = await blockRepo.getByMessage(userMsg.id);
    expect(deleted, isNotNull);
    expect(deleted!.deletedAt, isNotNull);
    expect(remained, isNotNull);
    expect(remained!.deletedAt, isNull);
    expect(deletedBlocks, isEmpty);
    expect(remainedBlocks.length, 1);

    final deletedBlockRaw = await blockRepo.getById('blk_ai_1');
    final remainedBlockRaw = await blockRepo.getById('blk_user_1');
    expect(deletedBlockRaw, isNotNull);
    expect(deletedBlockRaw!.deletedAt, isNotNull);
    expect(remainedBlockRaw, isNotNull);
    expect(remainedBlockRaw!.deletedAt, isNull);
  });

  test('retry 会使用流式参数调用 API', () async {
    final now = DateTime.now();
    final failedUser = Message(
      id: 'msg_user_retry',
      role: 'user',
      content: '重试一下',
      createdAt: now.subtract(const Duration(seconds: 1)),
      status: 'failed',
    );
    final conv = Conversation(
      id: 'conv_retry',
      title: 'Retry',
      displayName: 'Retry',
      createdAt: now,
      updatedAt: now,
      messages: [failedUser],
      lastMessage: failedUser.displayText,
      lastMessageTime: failedUser.createdAt,
    );
    final settings = _buildTestSettings();

    late _SpyStreamingSendService spyService;
    final container = ProviderContainer(
      overrides: [
        appSettingsProvider.overrideWith(
          () => _FakeAppSettingsNotifier(settings),
        ),
        chatSendServiceProvider.overrideWith((ref) {
          spyService = _SpyStreamingSendService(ref, settings);
          return spyService;
        }),
        conversationsProvider.overrideWith(
          () => _FakeConversationsNotifier([conv]),
        ),
        activeConversationProvider.overrideWith((ref) {
          final list = ref.watch(conversationsProvider).valueOrNull;
          if (list == null || list.isEmpty) return null;
          return list.first;
        }),
      ],
    );
    addTearDown(container.dispose);

    await container.read(conversationsProvider.future);
    await container.read(appSettingsProvider.future);
    final actions = container.read(chatActionsProvider);

    await actions.retry(failedUser.id);

    expect(spyService.executeCalls, 1);
    expect(spyService.lastEnableStreaming, isTrue);
    expect(spyService.sawDeltaCallback, isTrue);
    expect(spyService.sawResetCallback, isTrue);
    expect(spyService.sawToolObservedCallback, isTrue);
    expect(spyService.sawFallbackCallback, isTrue);
  });

  test('regenerate 会使用流式参数调用 API', () async {
    final now = DateTime.now();
    final userMsg = Message(
      id: 'msg_user_regen',
      role: 'user',
      content: '你好呀',
      createdAt: now.subtract(const Duration(seconds: 2)),
      status: 'sent',
    );
    final aiMsg = Message(
      id: 'msg_ai_regen',
      role: 'assistant',
      content: '旧回复',
      createdAt: now.subtract(const Duration(seconds: 1)),
      status: 'sent',
    );
    final conv = Conversation(
      id: 'conv_regen',
      title: 'Regen',
      displayName: 'Regen',
      createdAt: now,
      updatedAt: now,
      messages: [userMsg, aiMsg],
      lastMessage: aiMsg.displayText,
      lastMessageTime: aiMsg.createdAt,
    );
    final settings = _buildTestSettings();

    late _SpyStreamingSendService spyService;
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await _insertConversation(db, conv);
    await _insertMessage(db, conv.id, userMsg);
    await _insertMessage(db, conv.id, aiMsg);

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        appSettingsProvider.overrideWith(
          () => _FakeAppSettingsNotifier(settings),
        ),
        chatSendServiceProvider.overrideWith((ref) {
          spyService = _SpyStreamingSendService(ref, settings);
          return spyService;
        }),
        conversationsProvider.overrideWith(
          () => _FakeConversationsNotifier([conv]),
        ),
        activeConversationProvider.overrideWith((ref) {
          final list = ref.watch(conversationsProvider).valueOrNull;
          if (list == null || list.isEmpty) return null;
          return list.first;
        }),
      ],
    );
    addTearDown(container.dispose);

    await container.read(conversationsProvider.future);
    await container.read(appSettingsProvider.future);
    final actions = container.read(chatActionsProvider);

    await actions.regenerate(aiMsg.id);

    expect(spyService.executeCalls, 1);
    expect(spyService.lastEnableStreaming, isTrue);
    expect(spyService.sawDeltaCallback, isTrue);
    expect(spyService.sawResetCallback, isTrue);
    expect(spyService.sawToolObservedCallback, isTrue);
    expect(spyService.sawFallbackCallback, isTrue);
  });

  test('send 在收到 delta 后发生流式回退时，仍保留流式文本并仅后补图片', () async {
    final now = DateTime.now();
    final conv = Conversation(
      id: 'conv_stream_fallback',
      title: 'StreamFallback',
      displayName: 'StreamFallback',
      createdAt: now,
      updatedAt: now,
      messages: const [],
      lastMessage: '',
      lastMessageTime: now,
    );
    final settings = _buildTestSettings();

    final container = ProviderContainer(
      overrides: [
        appSettingsProvider.overrideWith(
          () => _FakeAppSettingsNotifier(settings),
        ),
        chatSendServiceProvider.overrideWith(
          (ref) => _FallbackAfterDeltaSendService(ref, settings),
        ),
        conversationsProvider.overrideWith(
          () => _FakeConversationsNotifier([conv]),
        ),
        activeConversationProvider.overrideWith((ref) {
          final list = ref.watch(conversationsProvider).valueOrNull;
          if (list == null || list.isEmpty) return null;
          return list.first;
        }),
      ],
    );
    addTearDown(container.dispose);

    await container.read(conversationsProvider.future);
    await container.read(appSettingsProvider.future);
    final actions = container.read(chatActionsProvider);

    await actions.send('测试回退后是否保留流式文本');

    final updated = container.read(conversationsProvider).valueOrNull!.first;
    final assistantMessages = updated.messages
        .where((m) => m.role == 'assistant')
        .toList(growable: false);
    expect(
      assistantMessages.any((m) => m.id == 'assistant_result'),
      isFalse,
      reason: '有 delta 后不应走删占位重建文本',
    );
    expect(
      assistantMessages.any((m) => m.displayText.contains('前置流式文本')),
      isTrue,
    );
    expect(
      assistantMessages
          .any((m) => m.blocks?.any((b) => b is ImageBlock) ?? false),
      isTrue,
    );
  });

  test('send 在分段延迟模式下完成时，不会撤回已流出的文本段', () async {
    final now = DateTime.now();
    final conv = Conversation(
      id: 'conv_stream_finalize',
      title: 'StreamFinalize',
      displayName: 'StreamFinalize',
      createdAt: now,
      updatedAt: now,
      messages: const [],
      lastMessage: '',
      lastMessageTime: now,
    );
    final settings = _buildTestSettings(streamSegmentDelaySeconds: 0.02);

    late _RecordingConversationsNotifier recordingNotifier;
    final container = ProviderContainer(
      overrides: [
        appSettingsProvider.overrideWith(
          () => _FakeAppSettingsNotifier(settings),
        ),
        chatSendServiceProvider.overrideWith(
          (ref) => _MultiDeltaStreamingSendService(ref, settings),
        ),
        conversationsProvider.overrideWith(() {
          recordingNotifier = _RecordingConversationsNotifier([conv]);
          return recordingNotifier;
        }),
        activeConversationProvider.overrideWith((ref) {
          final list = ref.watch(conversationsProvider).valueOrNull;
          if (list == null || list.isEmpty) return null;
          return list.first;
        }),
      ],
    );
    addTearDown(container.dispose);

    await container.read(conversationsProvider.future);
    await container.read(appSettingsProvider.future);
    final actions = container.read(chatActionsProvider);

    await actions.send('测试流式收尾不回退');

    final sealedCounts = <int>[];
    for (final snapshot in recordingNotifier.snapshots) {
      final current = snapshot.first;
      final count = current.messages
          .where((m) => m.role == 'assistant')
          .map((m) => m.displayText.trim())
          .where((text) => text.isNotEmpty && text != '生成中...')
          .length;
      if (count > 0) {
        sealedCounts.add(count);
      }
    }

    final compactCounts = <int>[];
    for (final count in sealedCounts) {
      if (compactCounts.isEmpty || compactCounts.last != count) {
        compactCounts.add(count);
      }
    }

    expect(compactCounts, isNotEmpty);
    for (var i = 1; i < compactCounts.length; i++) {
      expect(
        compactCounts[i] >= compactCounts[i - 1],
        isTrue,
        reason: '流式完成阶段不应撤回已出现分段，counts=$compactCounts',
      );
    }

    final updated = container.read(conversationsProvider).valueOrNull!.first;
    final finalAssistantTexts = updated.messages
        .where((m) => m.role == 'assistant')
        .map((m) => m.displayText.trim())
        .where((text) => text.isNotEmpty && text != '生成中...')
        .toList(growable: false);
    expect(finalAssistantTexts.join(''), contains('第一段。'));
    expect(finalAssistantTexts.join(''), contains('第二段。'));
    expect(finalAssistantTexts.join(''), contains('第三段。'));
  });
}
