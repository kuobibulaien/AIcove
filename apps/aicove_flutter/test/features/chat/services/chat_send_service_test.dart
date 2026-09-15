import 'dart:convert';
import 'dart:io';
import 'package:aicove_flutter/src/core/api/providers/gemini_adapter.dart';
import 'package:aicove_flutter/src/core/api/providers/claude_adapter.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/core/api/providers/provider_adapter.dart';
import 'package:drift/native.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:aicove_flutter/src/core/models/message_block.dart';
import 'package:aicove_flutter/src/core/utils/message_formatter.dart';
import 'package:aicove_flutter/src/core/database/database.dart' as db;
import 'package:aicove_flutter/src/core/database/database_provider.dart';
import 'package:aicove_flutter/src/core/database/converters/database_converters.dart';
import 'package:aicove_flutter/src/features/agent_context/data/silly_tavern_preset_store.dart';
import 'package:aicove_flutter/src/features/agent_context/providers/preset_recipe_provider.dart';
import 'package:aicove_flutter/src/features/agent_context/domain/tavern_compatibility_port.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/domain/persona_prompt_codec.dart';
import 'package:aicove_flutter/src/features/plugins/image/image_config.dart';
import 'package:aicove_flutter/src/features/plugins/image/drawing_preset.dart';
import 'package:aicove_flutter/src/features/plugins/image/drawing_preset_provider.dart';
import 'package:aicove_flutter/src/features/plugins/plugin_providers.dart';
import 'package:aicove_flutter/src/features/plugins/trigger/trigger_config.dart';
import 'package:aicove_flutter/src/features/plugins/trigger/trigger_plugin.dart';
import 'package:aicove_flutter/src/features/observability/trace_models.dart';
import 'package:aicove_flutter/src/features/observability/trace_store.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_request_message_builder.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_plugin_context_policy.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_send_service.dart';
import 'package:aicove_flutter/src/features/plugins/time_awareness/time_awareness_config.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';

class _FakeAppSettingsNotifier extends AppSettingsNotifier {
  _FakeAppSettingsNotifier(this._settings);

  final AppSettings _settings;

  @override
  Future<AppSettings> build() async => _settings;
}

class _FakeImagePluginConfigNotifier extends ImagePluginConfigNotifier {
  _FakeImagePluginConfigNotifier(ImageConfig initial) : super() {
    state = initial;
  }
}

class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this.rootPath);

  final String rootPath;

  @override
  Future<String?> getApplicationDocumentsPath() async => rootPath;

  @override
  Future<String?> getTemporaryPath() async => rootPath;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    final previous = PathProviderPlatform.instance;
    final root = await Directory.systemTemp.createTemp('chat_service_settings_');
    PathProviderPlatform.instance = _FakePathProviderPlatform(root.path);
    addTearDown(() async {
      PathProviderPlatform.instance = previous;
      await root.delete(recursive: true);
    });
  });

  Message msg(String id, String text, DateTime t) => Message(
        id: id,
        role: 'user',
        content: text,
        createdAt: t,
      );

  AppSettings fakeSettings({
    required String defaultModelName,
    List<String>? defaultChatModels,
    Map<String, ModelConfig>? modelConfigs,
    bool imageGenerationEnabled = false,
    CallFlowMode callFlowMode = CallFlowMode.auto,
    AutoReplySettings autoReplySettings = const AutoReplySettings(),
  }) {
    return AppSettings(
      ttsEnabled: true,
      defaultModelName: defaultModelName,
      defaultPersonaPrompt: '',
      modelList: const <String>[],
      allKnownModels: const <String>[],
      modelDisplayNames: const <String, String>{},
      modelTypes: const <String, String>{},
      modelConfigs: modelConfigs ?? const <String, ModelConfig>{},
      apiKey: '',
      apiBaseUrl: 'https://api.openai.com/v1',
      imageGenerationEnabled: imageGenerationEnabled,
      maxFileUploadMB: 10,
      contextWindowTokens: 272000,
      customModels: const <CustomModel>[],
      providers: const <ProviderAuth>[
        ProviderAuth(
          id: 'openai',
          apiKeys: <String>['test-key'],
          apiBaseUrl: 'https://api.openai.com/v1',
        ),
      ],
      modelProviderMap: const <String, String>{
        'openai:gpt-4o': 'openai',
        'openai:gpt-4o-mini': 'openai',
        'openai:gpt-4.1-mini': 'openai',
        'openai:gpt-3.5-turbo': 'openai',
        'gpt-4o': 'openai',
        'gpt-4o-mini': 'openai',
        'gpt-4.1-mini': 'openai',
        'gpt-3.5-turbo': 'openai',
      },
      backendApiKey: '',
      messageChunkingEnabled: false,
      messageFormatConfig: const MessageFormatConfig(),
      textScaleFactor: 1.0,
      uiScaleFactor: 1.0,
      imagePreviewScale: 1.0,
      autoReplySettings: autoReplySettings,
      globalBackgroundColor: GlobalBackgroundColor.white,
      chatBackgroundColor: ChatBackgroundColor.defaultColor,
      isDarkMode: false,
      useSystemTheme: true,
      accentColor: 'FC96AA',
      hideUserAvatar: true,
      defaultChatModels: defaultChatModels ?? <String>[defaultModelName],
      callFlowSettings: CallFlowSettings(mode: callFlowMode),
    );
  }

  test('prepareHistory keeps only messages after contextStartMessageId', () {
    final now = DateTime.now();
    final conv = Conversation(
      id: 'conv_1',
      title: 'Chat',
      displayName: 'Chat',
      createdAt: now,
      updatedAt: now,
      contextStartMessageId: 'm2',
      messages: [
        msg('m1', 'old 1', now.subtract(const Duration(minutes: 4))),
        msg('m2', 'old 2', now.subtract(const Duration(minutes: 3))),
        msg('m3', 'new 1', now.subtract(const Duration(minutes: 2))),
        msg('m4', 'new 2', now.subtract(const Duration(minutes: 1))),
      ],
    );
    final userMsg = msg('m5', 'new user', now);

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final service = container.read(chatSendServiceProvider);

    final history = service.prepareHistory(
      conv: conv,
      userMsg: userMsg,
    );

    expect(history.map((m) => m.id).toList(), ['m3', 'm4', 'm5']);
  });

  test('prepareHistory keeps all messages after context slicing', () {
    final now = DateTime.now();
    final conv = Conversation(
      id: 'conv_2',
      title: 'Chat',
      displayName: 'Chat',
      createdAt: now,
      updatedAt: now,
      contextStartMessageId: 'm1',
      messages: [
        msg('m1', 'old', now.subtract(const Duration(minutes: 4))),
        msg('m2', 'new 1', now.subtract(const Duration(minutes: 3))),
        msg('m3', 'new 2', now.subtract(const Duration(minutes: 2))),
        msg('m4', 'new 3', now.subtract(const Duration(minutes: 1))),
      ],
    );
    final userMsg = msg('m5', 'new user', now);

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final service = container.read(chatSendServiceProvider);

    final history = service.prepareHistory(
      conv: conv,
      userMsg: userMsg,
    );

    expect(history.map((m) => m.id).toList(), ['m2', 'm3', 'm4', 'm5']);
  });

  test('prepareHistory keeps full history when marker is missing', () {
    final now = DateTime.now();
    final conv = Conversation(
      id: 'conv_3',
      title: 'Chat',
      displayName: 'Chat',
      createdAt: now,
      updatedAt: now,
      contextStartMessageId: 'missing',
      messages: [
        msg('m1', 'a', now.subtract(const Duration(minutes: 3))),
        msg('m2', 'b', now.subtract(const Duration(minutes: 2))),
        msg('m3', 'c', now.subtract(const Duration(minutes: 1))),
      ],
    );
    final userMsg = msg('m4', 'd', now);

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final service = container.read(chatSendServiceProvider);

    final history = service.prepareHistory(
      conv: conv,
      userMsg: userMsg,
    );

    expect(history.map((m) => m.id).toList(), ['m1', 'm2', 'm3', 'm4']);
  });

  test('prepareHistoryFromStore uses full persisted history, not UI page',
      () async {
    final appDb = db.AppDatabase.forTesting(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(appDb),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await appDb.close();
    });

    final convRepo = container.read(conversationRepositoryProvider);
    final msgRepo = container.read(messageRepositoryProvider);
    final service = container.read(chatSendServiceProvider);

    final base = DateTime(2026, 1, 1, 12, 0, 0);
    final conv = Conversation(
      id: 'conv_db_full',
      title: 'Chat',
      displayName: 'Chat',
      createdAt: base,
      updatedAt: base,
      messages: [
        msg('m4', 'ui only 4', base.add(const Duration(minutes: 4))),
        msg('m5', 'ui only 5', base.add(const Duration(minutes: 5))),
      ],
    );
    await convRepo.upsert(ConversationConverter.toCompanion(conv));

    for (var i = 1; i <= 5; i++) {
      final m = msg('m$i', 'db $i', base.add(Duration(minutes: i)));
      await msgRepo.upsert(MessageConverter.toCompanion(m, conv.id));
    }

    final userMsg =
        msg('m6', 'current input', base.add(const Duration(minutes: 6)));
    final history = await service.prepareHistoryFromStore(
      conv: conv,
      userMsg: userMsg,
    );

    expect(history.map((m) => m.id).toList(),
        ['m1', 'm2', 'm3', 'm4', 'm5', 'm6']);
  });

  test('prepareHistoryFromStore excludes manually deleted messages', () async {
    final appDb = db.AppDatabase.forTesting(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(appDb),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await appDb.close();
    });

    final convRepo = container.read(conversationRepositoryProvider);
    final msgRepo = container.read(messageRepositoryProvider);
    final service = container.read(chatSendServiceProvider);

    final base = DateTime(2026, 1, 1, 12, 0, 0);
    final conv = Conversation(
      id: 'conv_db_deleted',
      title: 'Chat',
      displayName: 'Chat',
      createdAt: base,
      updatedAt: base,
      contextStartMessageId: 'm1',
      messages: [
        msg('m4', 'ui latest', base.add(const Duration(minutes: 4))),
      ],
    );
    await convRepo.upsert(ConversationConverter.toCompanion(conv));

    for (var i = 1; i <= 4; i++) {
      final m = msg('m$i', 'db $i', base.add(Duration(minutes: i)));
      await msgRepo.upsert(MessageConverter.toCompanion(m, conv.id));
    }

    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final purgeAt = nowMs + 30 * 24 * 60 * 60 * 1000;
    await msgRepo.softDelete('m2', nowMs, purgeAt); // 手动删除的消息
    await msgRepo.markReplaced('m3', 'm4', nowMs, purgeAt); // 被重生成覆盖

    final userMsg =
        msg('m5', 'current input', base.add(const Duration(minutes: 5)));
    final history = await service.prepareHistoryFromStore(
      conv: conv,
      userMsg: userMsg,
    );

    expect(history.map((m) => m.id).toList(), ['m4', 'm5']);
  });

  test('createUserMessage keeps both image and text when sent together', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final service = container.read(chatSendServiceProvider);

    final msg = service.createUserMessage(
      text: '这是图片说明文字',
      imagePath: '/tmp/demo.png',
    );

    final blocks = msg.blocks;
    expect(blocks, isNotNull);
    expect(blocks!.whereType<ImageBlock>().length, 1);
    expect(blocks.whereType<TextBlock>().length, 1);
    expect(blocks.whereType<TextBlock>().first.content, '这是图片说明文字');
  });

  test('non-vision assistant image no longer injects hidden image marker', () {
    final text = ChatSendService.buildNonVisionImageMessageText(
      role: 'assistant',
      description: '一只猫在草地上',
    );

    expect(text, isNull);
  });

  test('non-vision user image falls back to plain description text', () {
    final text = ChatSendService.buildNonVisionImageMessageText(
      role: 'user',
      description: '一只猫在草地上',
    );

    expect(text, isNotNull);
    expect(text, '一只猫在草地上');
    expect(text, isNot(contains('[图片]')));
    expect(text, isNot(contains('图片已转换为文本描述')));
  });

  test(
      'internal image context tool block should be ignored in request messages',
      () async {
    final builder = ChatRequestMessageBuilder(
      readImageAsBase64: (_) async => null,
    );
    final message = Message.fromBlocks(
      id: 'msg_hidden_image_context',
      role: 'assistant',
      blocks: [
        TextBlock(messageId: 'msg_hidden_image_context', content: '正文'),
        ToolBlock(
          messageId: 'msg_hidden_image_context',
          toolName: ChatRequestMessageBuilder.internalImageContextToolName,
          result: ChatRequestMessageBuilder.buildImageContextPayload(
            role: 'assistant',
            status: 'failed',
            rawPrompt: '1girl, cat ears',
            reason: 'novelai timeout',
            imagePresent: false,
          ),
        ),
      ],
      createdAt: DateTime(2026, 3, 18, 12, 0, 0),
    );

    final result = await builder.buildRequestMessages(
      [message],
      settings: fakeSettings(defaultModelName: 'openai:gpt-4o'),
    );

    expect(result, hasLength(1));
    expect(result.single['content'], '正文');
  });

  test('image send chain skips vision assistant when chat model has vision',
      () {
    final settings = fakeSettings(
      defaultModelName: 'openai:gpt-4.1-mini',
      defaultChatModels: const <String>['openai:gpt-4.1-mini'],
      modelConfigs: const <String, ModelConfig>{
        'openai:gpt-4.1-mini': ModelConfig(
          chatCapabilities: <String>['vision'],
        ),
      },
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final service = container.read(chatSendServiceProvider);

    final chain = service.buildImageSendModelRefs(settings);

    expect(chain, <String>['openai:gpt-4.1-mini']);
    expect(chain, isNot(contains('openai:gpt-4o-mini')));
  });

  test('image send chain keeps chat model first when chat model has no vision',
      () {
    final settings = fakeSettings(
      defaultModelName: 'openai:gpt-3.5-turbo',
      defaultChatModels: const <String>['openai:gpt-3.5-turbo'],
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final service = container.read(chatSendServiceProvider);

    final chain = service.buildImageSendModelRefs(settings);

    expect(chain, <String>['openai:gpt-3.5-turbo']);
  });

  test(
      'image send chain skips vision assistant when capability is auto-detected',
      () {
    final settings = fakeSettings(
      defaultModelName: 'openai:gpt-4o',
      defaultChatModels: const <String>['openai:gpt-4o'],
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final service = container.read(chatSendServiceProvider);

    final chain = service.buildImageSendModelRefs(settings);

    expect(chain, <String>['openai:gpt-4o']);
    expect(chain, isNot(contains('openai:gpt-4o-mini')));
  });

  test('assistant generated image is omitted in non-vision flow', () async {
    final builder = ChatRequestMessageBuilder(
      readImageAsBase64: (_) async => null,
    );
    final settings = fakeSettings(
      defaultModelName: 'openai:gpt-3.5-turbo',
      defaultChatModels: const <String>['openai:gpt-3.5-turbo'],
    );
    final message = Message.fromBlocks(
      id: 'msg_assistant_image',
      role: 'assistant',
      blocks: [
        ImageBlock(
          messageId: 'msg_assistant_image',
          url: 'https://example.com/generated.png',
          prompt: '黄昏下的城市天际线',
        ),
      ],
      createdAt: DateTime(2026, 1, 1, 12, 0, 0),
    );

    final result = await builder.buildRequestMessages(
      [message],
      settings: settings,
      supportsVision: false,
    );

    expect(result, isEmpty);
  });

  for (final mime in ['audio/mpeg', 'video/mp4']) {
    test('media bytes reach the current chat provider: $mime', () async {
      final root = await Directory.systemTemp.createTemp('media_request_');
      addTearDown(() => root.delete(recursive: true));
      final file = File('${root.path}/sample');
      await file.writeAsBytes([1, 2, 3, 4]);
      final builder = ChatRequestMessageBuilder(readImageAsBase64: (_) async => null);
      final message = Message.fromBlocks(id: 'media', role: 'user', createdAt: DateTime(2026), blocks: [
        TextBlock(messageId: 'media', content: '请总结附件'),
        FileBlock(messageId: 'media', fileName: 'sample', filePath: file.path, mimeType: mime, fileSize: 4),
      ]);
      final messages = await builder.buildRequestMessages([message], settings: fakeSettings(defaultModelName: 'gemini:gemini-2.5-pro'));
      final body = GeminiAdapter().buildRequestBody(model: 'gemini-2.5-pro', messages: messages);
      final parts = ((body['contents'] as List).single as Map)['parts'] as List;
      expect(parts.first['text'], '请总结附件');
      expect(parts.last['inlineData'], {'mimeType': mime, 'data': 'AQIDBA=='});
      expect(() => ClaudeAdapter().buildRequestBody(model: 'claude-sonnet', messages: messages), throwsUnsupportedError);
      await file.writeAsBytes(List.filled(1024 * 1024 + 1, 0));
      await expectLater(builder.buildRequestMessages([message], settings: fakeSettings(defaultModelName: 'gemini:gemini-2.5-pro').copyWith(maxFileUploadMB: 1)), throwsStateError);
    });
  }

  test('createUserFileMessage infers audio mime and preserves caption text',
      () async {
    final file = File(
      '${Directory.systemTemp.path}/aicove_test_audio_${DateTime.now().millisecondsSinceEpoch}.mp3',
    );
    await file.writeAsBytes(const <int>[1, 2, 3, 4]);
    addTearDown(() async {
      if (await file.exists()) {
        await file.delete();
      }
    });

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final service = container.read(chatSendServiceProvider);

    final message = await service.createUserFileMessage(
      filePath: file.path,
      text: '帮我总结这个音频',
    );

    final fileBlock = message.blocks?.whereType<FileBlock>().single;
    final textBlock = message.blocks?.whereType<TextBlock>().single;
    expect(fileBlock, isNotNull);
    expect(fileBlock!.mimeType, 'audio/mpeg');
    expect(textBlock?.content, '帮我总结这个音频');
  });

  test('disabled media drops generated blocks and tool pairs but preserves uploads', () async {
    var imageReads = 0;
    final builder = ChatRequestMessageBuilder(readImageAsBase64: (_) async {
      imageReads++;
      return 'image-bytes';
    });
    final now = DateTime(2026, 9, 11);
    final history = [
      Message.fromBlocks(id: 'generated', role: 'assistant', createdAt: now, blocks: [
        TextBlock(messageId: 'generated', content: 'text<tts>VOICE_SECRET</tts>'),
        ImageBlock(messageId: 'generated', localPath: '/unused/generated.png'),
        ToolBlock(messageId: 'generated', toolName: 'draw_image', toolCallId: 'draw', arguments: {'prompt': 'IMAGE_SECRET'}, result: {'url': 'IMAGE_SECRET'}),
        ToolBlock(messageId: 'generated', toolName: 'speak', toolCallId: 'voice', arguments: {'text': 'VOICE_SECRET'}, result: {'audio': 'VOICE_SECRET'}),
      ]),
      Message.fromBlocks(id: 'upload', role: 'user', createdAt: now, blocks: [
        TextBlock(messageId: 'upload', content: 'question'),
        ImageBlock(messageId: 'upload', url: 'https://example.invalid/user.png'),
      ]),
    ];
    final result = await builder.buildRequestMessages(history,
      settings: fakeSettings(defaultModelName: 'openai:gpt-4o'),
      pluginPolicy: const ChatPluginContextPolicy(imageEnabled: false, ttsEnabled: false));
    expect(imageReads, 0);
    expect(result.first, {'role': 'assistant', 'content': 'text'});
    expect(result.last['content'], hasLength(2));
    expect(jsonEncode(result), isNot(contains('_SECRET')));
    expect(history.first.blocks, hasLength(4));
  });

  test('a user message reduced to nothing cannot silently replay an older question', () async {
    final builder = ChatRequestMessageBuilder(readImageAsBase64: (_) async => null);
    final now = DateTime(2026, 9, 11);
    await expectLater(builder.buildRequestMessages([
      msg('old', 'previous question', now), msg('new', '<tts>hidden</tts>', now),
    ], settings: fakeSettings(defaultModelName: 'openai:gpt-4o'),
      pluginPolicy: const ChatPluginContextPolicy(imageEnabled: false, ttsEnabled: false)),
      throwsA(isA<StateError>()));
  });

  for (final includeHistory in [false, true]) {
    test('disabled plugins leave clean context (history=$includeHistory)', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final now = DateTime(2026, 9, 11);
      final container = ProviderContainer(overrides: [
        appSettingsProvider.overrideWith(() => _FakeAppSettingsNotifier(
          fakeSettings(defaultModelName: 'openai:gpt-4o'),
        )),
      ]);
      addTearDown(container.dispose);
      final history = <Message>[
        if (includeHistory) Message(
          id: 'old', role: 'assistant', createdAt: now,
          content: 'before<IMAGE source="history">secret image</IMAGE><tts voice="a">secret voice</tts>after',
        ),
        Message(id: 'latest', role: 'user', content: 'hello', createdAt: now),
      ];
      final original = history.first.content;
      final config = await container.read(chatSendServiceProvider).prepareApiConfig(
        conv: Conversation(id: 'clean', title: 'clean', displayName: 'clean', personaPrompt: '',
          enabledPlugins: const [], createdAt: now, updatedAt: now, messages: const []),
        history: history, userText: 'hello',
      );
      expect(config.messages.where((m) => m['role'] == 'system'), isEmpty);
      expect(config.tools ?? [], isEmpty);
      expect(config.messages, [
        if (includeHistory) {'role': 'assistant', 'content': 'beforeafter'},
        {'role': 'user', 'content': 'hello'},
      ]);
      expect(history.first.content, original);
    });
  }

  test('prepareApiConfig should keep draw prompt out of system and into tool',
      () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final now = DateTime(2026, 3, 7, 12, 0, 0);
    final settings = fakeSettings(
      defaultModelName: 'openai:gpt-4o',
      defaultChatModels: const <String>['openai:gpt-4o'],
      modelConfigs: const <String, ModelConfig>{
        'openai:gpt-4o': ModelConfig(
          chatCapabilities: <String>['tools', 'vision'],
        ),
      },
    ).copyWith(
      imageGenerationEnabled: true,
      modelTypes: const <String, String>{
        'openai:gpt-4o': 'chat',
        'openai:test-image-model': 'image',
        'test-image-model': 'image',
      },
      providers: const <ProviderAuth>[
        ProviderAuth(
          id: 'openai',
          apiKeys: <String>['test-key'],
          apiBaseUrl: 'https://api.openai.com/v1',
          models: <String>['test-image-model'],
          visibleModels: <String>['test-image-model'],
          capabilities: <String>['chat', 'image'],
        ),
      ],
      modelProviderMap: const <String, String>{
        'openai:gpt-4o': 'openai',
        'gpt-4o': 'openai',
        'openai:test-image-model': 'openai',
        'test-image-model': 'openai',
      },
    );
    const imageConfig = ImageConfig(
      systemPromptPresets: <DrawingPromptPreset>[
        DrawingPromptPreset(
          name: '全局预设',
          content: ImageConfig.defaultToolDescriptionPresetMarker,
        ),
      ],
      selectedSystemPromptPresetName: '全局预设',
    );
    final conv = Conversation(
      id: 'conv_draw_tool_prompt',
      title: 'Chat',
      displayName: 'Chat',
      addressUser: '宝贝',
      personaPrompt: PersonaPromptCodec.compose(
        userPrompt: '你是测试助手。',
        customDrawingPrompt: '第一视角，保持人物一致性。',
      ),
      enabledPlugins: const <String>['image'],
      createdAt: now,
      updatedAt: now,
      messages: const <Message>[],
    );
    final userMsg = Message(
      id: 'msg_user',
      role: 'user',
      content: '画一张自拍',
      createdAt: now,
    );
    final container = ProviderContainer(
      overrides: [
        appSettingsProvider
            .overrideWith(() => _FakeAppSettingsNotifier(settings)),
        imagePluginConfigProvider
            .overrideWith((ref) => _FakeImagePluginConfigNotifier(imageConfig)),
      ],
    );
    addTearDown(container.dispose);
    final service = container.read(chatSendServiceProvider);
    await container.read(appSettingsProvider.future);

    final apiConfig = await service.prepareApiConfig(
      conv: conv,
      history: <Message>[userMsg],
      userText: userMsg.content,
    );

    final systemMessage = apiConfig.messages.firstWhere(
      (msg) => msg['role'] == 'system',
      orElse: () => const <String, dynamic>{},
    );
    final systemContent = (systemMessage['content'] ?? '').toString();
    expect(systemContent, contains('你是测试助手。'));
    expect(systemContent, isNot(contains('你应该称呼用户为')));
    expect(systemContent, isNot(contains('第一视角，保持人物一致性。')));

    final drawTool = apiConfig.tools!.firstWhere(
      (tool) =>
          ((tool['function'] as Map<String, dynamic>)['name'] ?? '')
              .toString() ==
          'draw_image',
    );
    final function = drawTool['function'] as Map<String, dynamic>;
    final parameters = function['parameters'] as Map<String, dynamic>;
    final properties = parameters['properties'] as Map<String, dynamic>;
    final promptSchema = properties['prompt'] as Map<String, dynamic>;
    final promptDescription = (promptSchema['description'] ?? '').toString();
    expect(promptDescription, contains('第一视角，保持人物一致性。'));
  });

  test(
      'prepareApiConfig should route non-vision auto image flow into inline <image> mode',
      () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final now = DateTime(2026, 3, 18, 12, 0, 0);
    final settings = fakeSettings(
      defaultModelName: 'openai:gpt-3.5-turbo',
      defaultChatModels: const <String>['openai:gpt-3.5-turbo'],
      modelConfigs: const <String, ModelConfig>{
        'openai:gpt-3.5-turbo': ModelConfig(
          chatCapabilities: <String>['tools'],
        ),
      },
      imageGenerationEnabled: true,
      callFlowMode: CallFlowMode.auto,
    ).copyWith(
      modelTypes: const <String, String>{
        'openai:gpt-3.5-turbo': 'chat',
        'openai:test-image-model': 'image',
      },
      providers: const <ProviderAuth>[
        ProviderAuth(
          id: 'openai',
          apiKeys: <String>['test-key'],
          apiBaseUrl: 'https://api.openai.com/v1',
          models: <String>['gpt-3.5-turbo', 'test-image-model'],
          visibleModels: <String>['gpt-3.5-turbo', 'test-image-model'],
          capabilities: <String>['chat', 'image'],
        ),
      ],
      modelProviderMap: const <String, String>{
        'openai:gpt-3.5-turbo': 'openai',
        'openai:test-image-model': 'openai',
        'gpt-3.5-turbo': 'openai',
        'test-image-model': 'openai',
      },
    );
    const imageConfig = ImageConfig(selectedModelId: 'openai:test-image-model');
    final conv = Conversation(
      id: 'conv_force_inline_image_mode',
      title: 'Chat',
      displayName: 'Chat',
      personaPrompt: PersonaPromptCodec.compose(
        userPrompt: '你是测试助手。',
        customDrawingPrompt: '第一人称自拍视角。',
      ),
      enabledPlugins: const <String>['image'],
      createdAt: now,
      updatedAt: now,
      messages: const <Message>[],
    );
    final userMsg = Message(
      id: 'msg_force_inline_image_mode',
      role: 'user',
      content: '画一张自拍',
      createdAt: now,
    );
    final container = ProviderContainer(
      overrides: [
        appSettingsProvider
            .overrideWith(() => _FakeAppSettingsNotifier(settings)),
        imagePluginConfigProvider
            .overrideWith((ref) => _FakeImagePluginConfigNotifier(imageConfig)),
      ],
    );
    addTearDown(container.dispose);
    final service = container.read(chatSendServiceProvider);

    final apiConfig = await service.prepareApiConfig(
      conv: conv,
      history: <Message>[userMsg],
      userText: userMsg.content,
    );

    final systemMessage = apiConfig.messages.firstWhere(
      (msg) => msg['role'] == 'system',
      orElse: () => const <String, dynamic>{},
    );
    final systemContent = (systemMessage['content'] ?? '').toString();
    expect(systemContent, contains('<image>英文正向提示词</image>'));
    expect(systemContent, contains('NovelAI'));
    expect(systemContent, contains('第一人称自拍视角。'));
    final drawTools = apiConfig.tools?.where((tool) {
      final function = tool['function'] as Map<String, dynamic>?;
      return function?['name'] == 'draw_image';
    }).toList();
    expect(drawTools, anyOf(isNull, isEmpty));
  });

  test('two role requests keep independent drawing snapshots across preset edits', () async {
    final root = await Directory.systemTemp.createTemp('drawing-owner-test-');
    final previousPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _FakePathProviderPlatform(root.path);
    addTearDown(() async { PathProviderPlatform.instance = previousPaths; await root.delete(recursive: true); });
    const a = DrawingPreset(id: 'a', name: 'A绘图', config: ImageConfig(selectedProviderId: 'openai',
      selectedModelId: 'openai:image-a', defaultWidth: 768, drawingSystemPrompt: 'rule A'));
    const b = DrawingPreset(id: 'b', name: 'B绘图', config: ImageConfig(selectedProviderId: 'other',
      selectedModelId: 'other:image-b', defaultWidth: 1024, drawingSystemPrompt: 'rule B'));
    final catalog = DrawingPresetCatalog(presets: [a, b], defaultPresetId: 'a', legacyConfig: const ImageConfig());
    SharedPreferences.setMockInitialValues({PreferencesDrawingPresetStore.storageKey: jsonEncode(catalog.toJson())});
    final settings = fakeSettings(imageGenerationEnabled: true, defaultModelName: 'openai:gpt-4o',
      defaultChatModels: ['openai:gpt-4o'], modelConfigs: const {
        'openai:gpt-4o': ModelConfig(chatCapabilities: ['tools', 'vision'])});
    final container = ProviderContainer(overrides: [appSettingsProvider.overrideWith(() => _FakeAppSettingsNotifier(settings))]);
    addTearDown(container.dispose);
    final service = container.read(chatSendServiceProvider);
    final now = DateTime(2026, 9, 6);
    Conversation role(String id) => Conversation(id: id, title: id, displayName: id,
      personaPrompt: PersonaPromptCodec.compose(userPrompt: id, drawingPresetId: id),
      enabledPlugins: const ['image'], createdAt: now, updatedAt: now, messages: const []);
    final history = [Message(id: 'user', role: 'user', content: '画图', createdAt: now)];
    final requestA = await service.prepareApiConfig(conv: role('a'), history: history, userText: '画图');
    final requestB = await service.prepareApiConfig(conv: role('b'), history: history, userText: '画图');
    await container.read(drawingPresetCatalogProvider.notifier).savePreset(DrawingPreset(id: 'a', name: 'A修改',
      config: a.config.copyWith(defaultWidth: 1280)));
    await container.read(drawingPresetCatalogProvider.notifier).setDefault('b');
    expect(requestA.drawingConfig!.defaultWidth, 768);
    expect(requestB.drawingConfig!.defaultWidth, 1024);
    expect(requestA.drawingConfig!.selectedProviderId, 'openai');
    expect(requestB.drawingConfig!.selectedProviderId, 'other');
    expect(requestA.boundTools!.firstWhere((t) => t.name == 'draw_image').parameters['prompt']!.description, 'rule A');
    expect(requestB.boundTools!.firstWhere((t) => t.name == 'draw_image').parameters['prompt']!.description, 'rule B');
    final next = await service.prepareApiConfig(conv: role('a'), history: history, userText: '画图');
    expect(next.drawingConfig!.defaultWidth, 1280);
  });

  test(
      'prepareApiConfig should preserve explicit artist preset disable binding',
      () async {
    final root = await Directory.systemTemp.createTemp('drawing-legacy-test-');
    final previousPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _FakePathProviderPlatform(root.path);
    addTearDown(() async { PathProviderPlatform.instance = previousPaths; await root.delete(recursive: true); });
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final now = DateTime(2026, 3, 7, 12, 0, 0);
    final settings = fakeSettings(
      imageGenerationEnabled: true,
      defaultModelName: 'openai:gpt-4o',
      defaultChatModels: const <String>['openai:gpt-4o'],
      modelConfigs: const <String, ModelConfig>{
        'openai:gpt-4o': ModelConfig(
          chatCapabilities: <String>['tools'],
        ),
      },
    );
    const imageConfig = ImageConfig(
      artistPresets: <ArtistPreset>[
        ArtistPreset(name: '全局画风', content: 'global style'),
      ],
      selectedArtistPresetName: '全局画风',
    );
    SharedPreferences.setMockInitialValues({'aicove.plugins.image.config': jsonEncode(imageConfig.toJson())});
    final conv = Conversation(
      id: 'conv_artist_binding',
      title: 'Chat',
      displayName: 'Chat',
      personaPrompt: PersonaPromptCodec.compose(
        userPrompt: '你是测试助手。',
        drawingArtistPresetName: PersonaPromptCodec.artistPresetDisabledBinding,
      ),
      enabledPlugins: const <String>['image'],
      createdAt: now,
      updatedAt: now,
      messages: const <Message>[],
    );
    final userMsg = Message(
      id: 'msg_user',
      role: 'user',
      content: '画一张自拍',
      createdAt: now,
    );
    final container = ProviderContainer(
      overrides: [
        appSettingsProvider
            .overrideWith(() => _FakeAppSettingsNotifier(settings)),
        imagePluginConfigProvider
            .overrideWith((ref) => _FakeImagePluginConfigNotifier(imageConfig)),
      ],
    );
    addTearDown(container.dispose);
    final service = container.read(chatSendServiceProvider);

    final apiConfig = await service.prepareApiConfig(
      conv: conv,
      history: <Message>[userMsg],
      userText: userMsg.content,
    );

    expect(apiConfig.drawingConfig, isNotNull);
    expect(apiConfig.drawingConfig!.selectedArtistPreset, isNull);
    // 旧“禁用画师串”已迁移成快照值，不再透传旧名称覆盖参数。
    expect(apiConfig.boundImageArtistPresetName, isNull);
  });

  test(
      'prepareApiConfig should write runtimeContext and promptAssembly to trace',
      () async {
    final tempDir = await Directory.systemTemp.createTemp('aicove_trace_');
    final previousPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _FakePathProviderPlatform(tempDir.path);
    TraceStore.instance.debugResetForTest();
    SharedPreferences.setMockInitialValues(<String, Object>{
      'aicove.plugins.time_awareness.config': jsonEncode(
        TimeAwarenessConfig(
          enabled: true,
          includeCurrentTime: true,
          includeMessageTimestamp: true,
          currentTimePromptTemplate: '当前时间: {datetime}',
        ).toJson(),
      ),
    });
    addTearDown(() async {
      PathProviderPlatform.instance = previousPathProvider;
      TraceStore.instance.debugResetForTest();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    final settings = fakeSettings(
      defaultModelName: 'openai:gpt-4o-mini',
      defaultChatModels: const <String>['openai:gpt-4o-mini'],
    );
    final now = DateTime(2026, 3, 12, 20, 0, 0);
    final conv = Conversation(
      id: 'conv_trace_runtime',
      title: 'Chat',
      displayName: 'Chat',
      personaPrompt: PersonaPromptCodec.compose(
        userPrompt: '你是贴心助手。',
      ),
      enabledPlugins: const <String>['time_awareness'],
      createdAt: now,
      updatedAt: now,
      messages: const <Message>[],
    );
    final assistantMsg = Message(
      id: 'msg_prev',
      role: 'assistant',
      content: '上一轮回复',
      createdAt: now.subtract(const Duration(hours: 3, minutes: 20)),
    );
    final userMsg = Message(
      id: 'msg_user',
      role: 'user',
      content: '现在几点了？',
      createdAt: now,
    );
    final container = ProviderContainer(
      overrides: [
        appSettingsProvider
            .overrideWith(() => _FakeAppSettingsNotifier(settings)),
      ],
    );
    addTearDown(container.dispose);
    final service = container.read(chatSendServiceProvider);
    final traceContext = await TraceStore.instance.startTurn(
      sessionId: conv.id,
      turnId: userMsg.id,
    );

    await service.prepareApiConfig(
      conv: conv,
      history: <Message>[assistantMsg, userMsg],
      userText: userMsg.content,
      traceContext: traceContext,
    );
    await TraceStore.instance.waitForPendingWrites();

    final events = await TraceStore.instance.readEventsByTraceId(
      traceContext.traceId,
    );
    final apiConfigEvent = events.lastWhere(
      (event) => event.stage == TraceStage.apiConfigReady.value,
    );
    final envelope = await TraceStore.instance.readPayloadByRef(
      apiConfigEvent.payloadRef,
    );

    expect(envelope, isNotNull);
    final payload = envelope!['payload'] as Map<String, dynamic>;
    final runtimeContext = payload['runtimeContext'] as Map<String, dynamic>;
    final promptAssembly = payload['promptAssembly'] as Map<String, dynamic>;

    expect(runtimeContext['clockSource'], 'device_local');
    expect(runtimeContext['timezoneName'], isNotNull);
    expect(runtimeContext['timeAwareness'], isA<Map>());
    expect(
      (runtimeContext['timeAwareness']
          as Map<String, dynamic>)['systemReminderInjected'],
      isTrue,
    );
    expect(
      (runtimeContext['timeAwareness']
              as Map<String, dynamic>)['systemReminderContent']
          .toString(),
      contains('当前时间:'),
    );
    expect(
      (runtimeContext['timeAwareness']
              as Map<String, dynamic>)['previousUserMessageTime']
          .toString(),
      'unknown',
    );

    expect(promptAssembly['systemEntries'], isA<List>());
    expect(promptAssembly['pluginPrompts'], isA<List>());
    expect(promptAssembly['systemReminderInjected'], isTrue);
    expect(
      promptAssembly['finalSystemPrompt'].toString(),
      contains('你是贴心助手。'),
    );
    expect(
      promptAssembly['finalSystemPrompt'].toString(),
      isNot(contains('以下是当前会话启用的特殊标签说明')),
    );
    expect(
      promptAssembly['finalSystemPrompt'].toString(),
      contains('<system-reminder>'),
    );
  });

  test(
      'prepareApiConfig should insert system reminder before current user message',
      () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'aicove.plugins.time_awareness.config': jsonEncode(
        TimeAwarenessConfig(
          enabled: true,
          includeCurrentTime: true,
          includeMessageTimestamp: true,
        ).toJson(),
      ),
    });

    final settings = fakeSettings(
      defaultModelName: 'openai:gpt-4o-mini',
      defaultChatModels: const <String>['openai:gpt-4o-mini'],
    );
    final now = DateTime(2026, 3, 12, 20, 0, 0);
    final conv = Conversation(
      id: 'conv_system_reminder',
      title: 'Chat',
      displayName: 'Chat',
      personaPrompt: PersonaPromptCodec.compose(
        userPrompt: '你是贴心助手。',
      ),
      enabledPlugins: const <String>['time_awareness'],
      createdAt: now,
      updatedAt: now,
      messages: const <Message>[],
    );
    final previousUserMsg = Message(
      id: 'msg_prev_user',
      role: 'user',
      content: '昨晚睡前和你说晚安',
      createdAt: now.subtract(const Duration(hours: 10)),
    );
    final assistantMsg = Message(
      id: 'msg_prev_assistant',
      role: 'assistant',
      content: '晚安呀',
      createdAt: now.subtract(const Duration(hours: 9, minutes: 50)),
    );
    final currentUserMsg = Message(
      id: 'msg_current_user',
      role: 'user',
      content: '现在几点了？',
      createdAt: now,
    );
    final container = ProviderContainer(
      overrides: [
        appSettingsProvider
            .overrideWith(() => _FakeAppSettingsNotifier(settings)),
      ],
    );
    addTearDown(container.dispose);
    final service = container.read(chatSendServiceProvider);

    final apiConfig = await service.prepareApiConfig(
      conv: conv,
      history: <Message>[previousUserMsg, assistantMsg, currentUserMsg],
      userText: currentUserMsg.content,
    );

    final reminderIndex = apiConfig.messages.lastIndexWhere((message) {
      final content = (message['content'] ?? '').toString();
      return (message['role'] ?? '').toString() == 'user' &&
          content.trimLeft().startsWith('<system-reminder>');
    });

    expect(reminderIndex, greaterThan(0));
    expect(apiConfig.messages[reminderIndex + 1]['role'], 'user');
    expect(apiConfig.messages[reminderIndex + 1]['content'], contains('现在几点了'));
    expect(
      apiConfig.messages[reminderIndex]['content'].toString(),
      contains('当前时间:'),
    );
    expect(
      apiConfig.messages[reminderIndex]['content'].toString(),
      contains('用户上一次发消息的时间为'),
    );
    expect(
      apiConfig.messages[reminderIndex]['content'].toString(),
      contains('2026-03-12 10:00:00'),
    );
  });

  for (final imageActive in [false, true]) {
  test('prepareApiConfig should inject image failure into system reminder only (enabled=$imageActive)',
      () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final settings = fakeSettings(
      defaultModelName: 'openai:gpt-4o-mini',
      defaultChatModels: const <String>['openai:gpt-4o-mini'],
    ).copyWith(imageGenerationEnabled: imageActive);
    final now = DateTime(2026, 3, 23, 12, 0, 0);
    final conv = Conversation(
      id: 'conv_image_failure_reminder',
      title: 'Chat',
      displayName: 'Chat',
      personaPrompt: PersonaPromptCodec.compose(
        userPrompt: '你是贴心助手。',
      ),
      enabledPlugins: imageActive ? const ['image'] : const [],
      createdAt: now,
      updatedAt: now,
      messages: const <Message>[],
    );
    final previousAssistantMsg = Message.fromBlocks(
      id: 'msg_prev_assistant_failure',
      role: 'assistant',
      blocks: [
        TextBlock(
          messageId: 'msg_prev_assistant_failure',
          content: '刚才试着给你生成图片。',
        ),
        ToolBlock(
          messageId: 'msg_prev_assistant_failure',
          toolName: ChatRequestMessageBuilder.internalImageContextToolName,
          result: ChatRequestMessageBuilder.buildImageContextPayload(
            role: 'assistant',
            status: 'failed',
            rawPrompt: '1girl, cat ears',
            prompt: 'artist style, 1girl, cat ears',
            reason: 'novelai timeout',
            imagePresent: false,
          ),
        ),
      ],
      createdAt: now.subtract(const Duration(minutes: 2)),
    );
    final currentUserMsg = Message(
      id: 'msg_current_user_after_failure',
      role: 'user',
      content: '那你继续说吧',
      createdAt: now,
    );
    final container = ProviderContainer(
      overrides: [
        appSettingsProvider
            .overrideWith(() => _FakeAppSettingsNotifier(settings)),
      ],
    );
    addTearDown(container.dispose);
    final service = container.read(chatSendServiceProvider);

    final apiConfig = await service.prepareApiConfig(
      conv: conv,
      history: <Message>[previousAssistantMsg, currentUserMsg],
      userText: currentUserMsg.content,
    );

    if (!imageActive) {
      final contents = jsonEncode(apiConfig.messages);
      expect(contents, isNot(contains('<image')));
      expect(contents, isNot(contains('image_generation_failure')));
      expect(contents, isNot(contains('<system-reminder>')));
      return;
    }

    final reminderIndex = apiConfig.messages.lastIndexWhere((message) {
      final content = (message['content'] ?? '').toString();
      return (message['role'] ?? '').toString() == 'user' &&
          content.trimLeft().startsWith('<system-reminder>');
    });

    expect(reminderIndex, greaterThanOrEqualTo(0));
    final reminderContent =
        apiConfig.messages[reminderIndex]['content'].toString();
    expect(reminderContent, contains('image_generation_failed=true'));
    expect(
      reminderContent,
      contains('image_generation_failure_reason=novelai timeout'),
    );
    expect(
      reminderContent,
      contains('image_generation_failure_raw_prompt=1girl, cat ears'),
    );
    expect(
      reminderContent,
      contains('image_generation_failure_prompt=artist style, 1girl, cat ears'),
    );
    expect(reminderContent, isNot(contains('<image source="history"')));
    expect(apiConfig.messages[reminderIndex + 1]['role'], 'user');
    expect(
        apiConfig.messages[reminderIndex + 1]['content'], contains('那你继续说吧'));

    final joinedContents = apiConfig.messages
        .map((message) => (message['content'] ?? '').toString())
        .join('\n');
    expect(joinedContents, isNot(contains('<image source="history"')));
  });

  }

  for (final imageActive in [false, true]) {
  test(
      'prepareApiConfig should inject internal image history guard into system prompt (enabled=$imageActive)',
      () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final settings = fakeSettings(
      defaultModelName: 'openai:gpt-4o-mini',
      defaultChatModels: const <String>['openai:gpt-4o-mini'],
    ).copyWith(imageGenerationEnabled: imageActive);
    final now = DateTime(2026, 4, 16, 13, 0, 0);
    final internalImageHistoryText =
        ChatRequestMessageBuilder.buildInternalImageContextText(
      ChatRequestMessageBuilder.buildImageContextPayload(
        role: 'assistant',
        status: 'failed',
        rawPrompt: '1girl, blue hair',
        reason: 'image generation timeout',
        imagePresent: false,
      ),
    );
    final conv = Conversation(
      id: 'conv_internal_image_history_guard',
      title: 'Chat',
      displayName: 'Chat',
      personaPrompt: PersonaPromptCodec.compose(
        userPrompt: '你是测试助手。',
      ),
      enabledPlugins: imageActive ? const ['image'] : const [],
      createdAt: now,
      updatedAt: now,
      messages: const <Message>[],
    );
    final previousAssistantMsg = Message(
      id: 'msg_prev_with_internal_image_history',
      role: 'assistant',
      content: '前文$internalImageHistoryText后文',
      createdAt: now.subtract(const Duration(minutes: 2)),
    );
    final currentUserMsg = Message(
      id: 'msg_current_user_with_guard',
      role: 'user',
      content: '继续说刚才的话题',
      createdAt: now,
    );
    final container = ProviderContainer(
      overrides: [
        appSettingsProvider
            .overrideWith(() => _FakeAppSettingsNotifier(settings)),
      ],
    );
    addTearDown(container.dispose);
    final service = container.read(chatSendServiceProvider);

    final apiConfig = await service.prepareApiConfig(
      conv: conv,
      history: <Message>[previousAssistantMsg, currentUserMsg],
      userText: currentUserMsg.content,
    );

    if (!imageActive) {
      final contents = jsonEncode(apiConfig.messages);
      expect(contents, isNot(contains('<image')));
      expect(contents, isNot(contains('image_generation_failure')));
      expect(contents, isNot(contains('<system-reminder>')));
      return;
    }

    final systemMessage = apiConfig.messages.firstWhere(
      (message) => message['role'] == 'system',
      orElse: () => const <String, dynamic>{},
    );
    final systemContent = (systemMessage['content'] ?? '').toString();

    expect(systemContent, contains('你是测试助手。'));
    expect(
      systemContent,
      contains('<image source="history" ...>...</image> 是内部图片上下文记录'),
    );
  });

  }

  test('trigger plugin should not inject system prompt', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final pluginProvider = Provider<TriggerPlugin>(
      (ref) => TriggerPlugin(const TriggerConfig(enabled: true), ref),
    );
    final plugin = container.read(pluginProvider);

    final prompt = await plugin.getSystemPrompt(
      userMessage: '明天八点提醒我',
      supportsToolCalling: true,
    );

    expect(prompt, isNull);
  });

  test('prepareApiConfig resolves thinking level: session > model default > software default',
      () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final now = DateTime(2026, 4, 16, 12, 0, 0);
    const modelRef = 'openai:gpt-5.2';
    final settings = fakeSettings(
      defaultModelName: modelRef,
      defaultChatModels: const <String>[modelRef],
      modelConfigs: const <String, ModelConfig>{
        modelRef: ModelConfig(thinkingLevel: ThinkingLevel.medium),
      },
    );
    Conversation buildConv(Map<String, ThinkingLevel> levels) => Conversation(
          id: 'conv_thinking',
          title: 'Chat',
          displayName: 'Chat',
          thinkingLevels: levels,
          createdAt: now,
          updatedAt: now,
        );
    final userMsg = Message(
      id: 'msg_thinking',
      role: 'user',
      content: 'hi',
      createdAt: now,
    );
    final container = ProviderContainer(
      overrides: [
        appSettingsProvider
            .overrideWith(() => _FakeAppSettingsNotifier(settings)),
      ],
    );
    addTearDown(container.dispose);
    final service = container.read(chatSendServiceProvider);

    final withSession = await service.prepareApiConfig(
      conv: buildConv(const {modelRef: ThinkingLevel.xhigh}),
      history: <Message>[userMsg],
      userText: userMsg.content,
    );
    expect(withSession.providerRequestOptions?.thinkingLevel,
        ThinkingLevel.xhigh);
    expect(withSession.providerRequestOptions?.thinkingScheme,
        ThinkingScheme.openaiEffort);

    final modelDefault = await service.prepareApiConfig(
      conv: buildConv(const {}),
      history: <Message>[userMsg],
      userText: userMsg.content,
    );
    expect(modelDefault.providerRequestOptions?.thinkingLevel,
        ThinkingLevel.medium);

    // 另一个模型的会话覆盖不影响当前模型（会话内按模型隔离）
    final otherModel = await service.prepareApiConfig(
      conv: buildConv(const {'openai:o3': ThinkingLevel.high}),
      history: <Message>[userMsg],
      userText: userMsg.content,
    );
    expect(otherModel.providerRequestOptions?.thinkingLevel,
        ThinkingLevel.medium);
  });

  test(
      'prepareApiConfig should register trigger tools when both switches enabled',
      () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final now = DateTime(2026, 4, 16, 12, 0, 0);
    final settings = fakeSettings(
      defaultModelName: 'openai:gpt-4o-mini',
      defaultChatModels: const <String>['openai:gpt-4o-mini'],
      modelConfigs: const <String, ModelConfig>{
        'openai:gpt-4o-mini': ModelConfig(
          chatCapabilities: <String>['tools'],
        ),
      },
      autoReplySettings: const AutoReplySettings(
        enabled: true,
        allowAiSetReminders: true,
      ),
    );
    final conv = Conversation(
      id: 'conv_trigger_role_separation',
      title: 'Chat',
      displayName: 'Chat',
      personaPrompt: PersonaPromptCodec.compose(
        userPrompt: '你是测试助手。',
      ),
      enabledPlugins: const <String>['trigger'],
      createdAt: now,
      updatedAt: now,
      messages: const <Message>[],
    );
    final userMsg = Message(
      id: 'msg_trigger_role_separation',
      role: 'user',
      content: '随便聊聊今天过得怎么样',
      createdAt: now,
    );
    final container = ProviderContainer(
      overrides: [
        appSettingsProvider
            .overrideWith(() => _FakeAppSettingsNotifier(settings)),
      ],
    );
    addTearDown(container.dispose);
    final service = container.read(chatSendServiceProvider);

    final apiConfig = await service.prepareApiConfig(
      conv: conv,
      history: <Message>[userMsg],
      userText: userMsg.content,
    );

    final toolNames = <String>[
      for (final tool in apiConfig.tools ?? const <Map<String, dynamic>>[])
        ((tool['function'] as Map<String, dynamic>?)?['name'] ?? '').toString(),
    ];
    expect(toolNames, contains('create_reminder'));
    expect(toolNames, contains('delete_reminder'));
    expect(toolNames, contains('list_reminders'));
    expect(toolNames, contains('search_reminders'));
    // 无预设时 options 仍会构造（承载思考档位），但预设字段全部为空。
    final options = apiConfig.providerRequestOptions;
    expect(options, isNotNull);
    expect(options!.temperature, isNull);
    expect(options.reasoningEffort, isNull);
    expect(options.useSystemPrompt, isTrue);
    // gpt-4o-mini 未识别为原生档位模型 → generic → 软件默认 auto
    expect(options.thinkingLevel, ThinkingLevel.auto);
    expect(options.thinkingScheme, ThinkingScheme.generic);
    expect(apiConfig.presetRegexScripts, isEmpty);
    expect(apiConfig.presetRegexAuthorized, isFalse);
    expect(apiConfig.presetStreamResponse, isNull);
  });

  test(
      'prepareApiConfig should still exclude trigger tools when main switch is off',
      () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final now = DateTime(2026, 4, 16, 12, 0, 0);
    final settings = fakeSettings(
      defaultModelName: 'openai:gpt-4o-mini',
      defaultChatModels: const <String>['openai:gpt-4o-mini'],
      modelConfigs: const <String, ModelConfig>{
        'openai:gpt-4o-mini': ModelConfig(
          chatCapabilities: <String>['tools'],
        ),
      },
      autoReplySettings: const AutoReplySettings(
        enabled: false,
        allowAiSetReminders: true,
      ),
    );
    final conv = Conversation(
      id: 'conv_trigger_role_separation_disabled',
      title: 'Chat',
      displayName: 'Chat',
      personaPrompt: PersonaPromptCodec.compose(
        userPrompt: '你是测试助手。',
      ),
      enabledPlugins: const <String>['trigger'],
      createdAt: now,
      updatedAt: now,
      messages: const <Message>[],
    );
    final userMsg = Message(
      id: 'msg_trigger_role_separation_disabled',
      role: 'user',
      content: '随便聊聊今天过得怎么样',
      createdAt: now,
    );
    final container = ProviderContainer(
      overrides: [
        appSettingsProvider
            .overrideWith(() => _FakeAppSettingsNotifier(settings)),
      ],
    );
    addTearDown(container.dispose);
    final service = container.read(chatSendServiceProvider);

    final apiConfig = await service.prepareApiConfig(
      conv: conv,
      history: <Message>[userMsg],
      userText: userMsg.content,
    );

    final toolNames = <String>[
      for (final tool in apiConfig.tools ?? const <Map<String, dynamic>>[])
        ((tool['function'] as Map<String, dynamic>?)?['name'] ?? '').toString(),
    ];
    expect(toolNames, isNot(contains('create_reminder')));
    expect(toolNames, isNot(contains('delete_reminder')));
    expect(toolNames, isNot(contains('list_reminders')));
    expect(toolNames, isNot(contains('search_reminders')));
  });

  test('prepareApiConfig applies bound SillyTavern preset to final messages',
      () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final temp = await Directory.systemTemp.createTemp('aicove_st_runtime_');
    addTearDown(() async {
      if (await temp.exists()) await temp.delete(recursive: true);
    });
    final previousPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _FakePathProviderPlatform(temp.path);
    TraceStore.instance.debugResetForTest();
    addTearDown(() {
      PathProviderPlatform.instance = previousPathProvider;
      TraceStore.instance.debugResetForTest();
    });
    final store = SillyTavernPresetStore(
      documentsDirectoryResolver: () async => temp,
    );
    const source = '''
{
  "name":"Runtime Preset",
  "function_calling":false,
  "assistant_prefill":"PREFILL",
  "temperature":0.33,
  "top_p":0.77,
  "prompts":[
    {"identifier":"main","role":"system","content":"MAIN {{char}} / {{user}}<image>PRESET_IMAGE_SECRET</image><tts>PRESET_VOICE_SECRET</tts>"},
    {"identifier":"charDescription","marker":true,"role":"system"},
    {"identifier":"attached","role":"system","content":"ATTACHED","attach_index":1,"attach_role":"user","attach_side":"end"},
    {"identifier":"chatHistory","marker":true},
    {"identifier":"tail","role":"system","content":"TAIL"}
  ],
  "prompt_order":[{"order":[
    {"identifier":"main","enabled":true},
    {"identifier":"charDescription","enabled":true},
    {"identifier":"attached","enabled":true},
    {"identifier":"chatHistory","enabled":true},
    {"identifier":"tail","enabled":true}
  ]}]
}
''';
    final preset = await store.importSource(
      source,
      sourceFileName: 'runtime.json',
    );
    final settings = fakeSettings(
      defaultModelName: 'openai:gpt-4o-mini',
      defaultChatModels: const <String>['openai:gpt-4o-mini'],
      modelConfigs: const <String, ModelConfig>{
        'openai:gpt-4o-mini': ModelConfig(
          chatCapabilities: <String>['tools'],
        ),
      },
      autoReplySettings: const AutoReplySettings(
        enabled: true,
        allowAiSetReminders: true,
      ),
    ).copyWith(userName: '小云');
    final now = DateTime(2026, 8, 27, 12);
    final conv = Conversation(
      id: 'conv_st_runtime',
      title: 'Alice',
      displayName: '爱丽丝',
      personaPrompt: PersonaPromptCodec.compose(userPrompt: '角色人设正文'),
      recipeId: preset.id,
      enabledPlugins: const <String>['trigger'],
      createdAt: now,
      updatedAt: now,
    );
    final history = <Message>[
      Message(
        id: 'u1',
        role: 'user',
        content: '你好',
        createdAt: now,
      ),
      Message(
        id: 'a1',
        role: 'assistant',
        content: '你好呀',
        createdAt: now,
      ),
    ];
    final container = ProviderContainer(
      overrides: [
        appSettingsProvider
            .overrideWith(() => _FakeAppSettingsNotifier(settings)),
        sillyTavernPresetStoreProvider.overrideWithValue(store),
      ],
    );
    addTearDown(container.dispose);
    final service = container.read(chatSendServiceProvider);
    final traceContext = await TraceStore.instance.startTurn(
      sessionId: conv.id,
      turnId: history.last.id,
    );

    final apiConfig = await service.prepareApiConfig(
      conv: conv,
      history: history,
      userText: '你好',
      traceContext: traceContext,
    );

    final contents =
        apiConfig.messages.map((message) => message['content']).toList();
    expect(contents.first, 'MAIN 爱丽丝 / 小云');
    expect(contents.join(), isNot(contains('PRESET_IMAGE_SECRET')));
    expect(contents.join(), isNot(contains('PRESET_VOICE_SECRET')));
    expect(contents[1], '角色人设正文');
    expect(contents.join(), isNot(contains('特殊标签说明')));
    expect(contents.sublist(contents.length - 4), <dynamic>[
      '你好\n\nATTACHED',
      '你好呀',
      'TAIL',
      'PREFILL',
    ]);
    expect(apiConfig.modelTemperature, 0.33);
    expect(apiConfig.modelTopP, 0.77);
    expect(apiConfig.tools, isNull);
    expect(
      apiConfig.messages.where((message) => message['content'] == '角色人设正文'),
      hasLength(1),
    );
    await TraceStore.instance.waitForPendingWrites();
    final events = await TraceStore.instance.readEventsByTraceId(
      traceContext.traceId,
    );
    final event = events.lastWhere(
      (item) => item.stage == TraceStage.apiConfigReady.value,
    );
    final envelope =
        await TraceStore.instance.readPayloadByRef(event.payloadRef);
    final payload = envelope!['payload'] as Map<String, dynamic>;
    final assembly = payload['promptAssembly'] as Map<String, dynamic>;
    final presetTrace = assembly['sillyTavernPreset'] as Map<String, dynamic>;
    expect(presetTrace['recipeId'], preset.id);
    expect(presetTrace['presetName'], 'Runtime Preset');
    expect(presetTrace['attachmentCount'], 1);
    expect(presetTrace['assistantPrefillDeclared'], isTrue);
    expect(presetTrace['assistantPrefillApplied'], isTrue);
    expect(presetTrace['toolsEffectiveCount'], 0);
    expect(presetTrace['entries'], isNotEmpty);
  });

  test('tavern final request follows entry switches, world regex, default and owner snapshot', () async {
    SharedPreferences.setMockInitialValues({});
    final temp = await Directory.systemTemp.createTemp('tavern_e2e_');
    addTearDown(() => temp.delete(recursive: true));
    final store = SillyTavernPresetStore(documentsDirectoryResolver: () async => temp);
    const source = '''{"name":"真实组合","function_calling":false,"prompts":[
      {"identifier":"main","content":"MAIN","role":"system"},
      {"identifier":"worldInfoBefore","marker":true},
      {"identifier":"charDescription","marker":true},
      {"identifier":"worldInfoAfter","marker":true},
      {"identifier":"chatHistory","marker":true}],"prompt_order":[
      {"identifier":"main","enabled":true},
      {"identifier":"worldInfoBefore","enabled":true},
      {"identifier":"charDescription","enabled":true},
      {"identifier":"worldInfoAfter","enabled":true},
      {"identifier":"chatHistory","enabled":true}]}''';
    final preset = await store.importSource(source, sourceFileName: 'e2e.json');
    await store.importRegex(preset.id, '''[
      {"id":"user","findRegex":"猫","replaceString":"森林","placement":[1],"promptOnly":true},
      {"id":"wi","findRegex":"旧词","replaceString":"新词","placement":[5],"promptOnly":true}]
    ''');
    await store.setRegexAuthorization(preset.id, true);
    await store.importWorldBook(preset.id, '''{"entries":{
      "0":{"key":["森林"],"content":"BEFORE {{char}} 旧词","position":0},
      "1":{"constant":true,"content":"AFTER","position":1},
      "2":{"constant":true,"content":"DEPTH","position":4,"depth":1,"role":2}}}''', '世界.json');
    await store.savePluginSettings(TavernPluginSettings(defaultPresetId: preset.id));
    final now = DateTime(2026, 9, 6);
    final a = Conversation(id: 'tavern-a', title: 'Alice', displayName: 'Alice',
      personaPrompt: PersonaPromptCodec.compose(userPrompt: 'PERSONA'),
      enabledPlugins: const [], createdAt: now, updatedAt: now);
    final bPreset = await store.importSource(source.replaceAll('MAIN', 'B_MAIN'), sourceFileName: 'b.json');
    final b = a.copyWith(id: 'tavern-b', recipeId: bPreset.id);
    final history = [Message(id: 'u', role: 'user', content: '猫', createdAt: now)];
    final settings = fakeSettings(defaultModelName: 'openai:gpt-4o-mini',
      defaultChatModels: const ['openai:gpt-4o-mini']);
    final container = ProviderContainer(overrides: [
      appSettingsProvider.overrideWith(() => _FakeAppSettingsNotifier(settings)),
      sillyTavernPresetStoreProvider.overrideWithValue(store),
    ]);
    addTearDown(container.dispose);
    final service = container.read(chatSendServiceProvider);
    final first = await service.prepareApiConfig(conv: a, history: history, userText: '猫');
    final contents = first.messages.map((m) => m['content']).toList();
    expect(contents, containsAllInOrder(['MAIN', 'BEFORE Alice 新词', 'PERSONA', 'AFTER', 'DEPTH', '森林']));
    expect(first.messages.firstWhere((m) => m['content'] == 'DEPTH')['role'], 'assistant');
    expect(history.single.content, '猫');
    final bookId = (await store.get(preset.id))!.worldBooks.single.id;
    await store.setPromptEnabled(preset.id, 'main', false);
    await store.setWorldEntryEnabled(preset.id, bookId, '1', false);
    await store.setRegexEnabled(preset.id, 'user', false);
    final second = await service.prepareApiConfig(conv: a, history: history, userText: '猫');
    final secondText = second.messages.map((m) => m['content']).join('\n');
    expect(secondText, isNot(contains('MAIN')));
    expect(secondText, isNot(contains('BEFORE')));
    expect(secondText, isNot(contains('AFTER')));
    expect(secondText, contains('DEPTH'));
    expect(secondText, contains('猫'));
    expect(first.presetRegexScripts.first.disabled, isFalse);
    expect(first.messages.map((m) => m['content']), contents);
    final bResult = await service.prepareApiConfig(conv: b, history: history, userText: '猫');
    expect(bResult.messages.first['content'], 'B_MAIN');
    expect(bResult.messages.map((m) => m['content']).join(), isNot(contains('DEPTH')));
    await store.savePluginSettings(TavernPluginSettings(enabled: false, defaultPresetId: preset.id));
    final off = await service.prepareApiConfig(conv: b, history: history, userText: '猫');
    expect(off.messages.map((m) => m['content']).join(), isNot(contains('B_MAIN')));
    expect(off.presetRegexScripts, isEmpty);
  });

  test('prepareApiConfig rejects a missing explicit preset instead of changing context silently', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final temp = await Directory.systemTemp.createTemp('aicove_st_fallback_');
    addTearDown(() async {
      if (await temp.exists()) await temp.delete(recursive: true);
    });
    final store = SillyTavernPresetStore(
      documentsDirectoryResolver: () async => temp,
    );
    final settings = fakeSettings(
      defaultModelName: 'openai:gpt-4o-mini',
      defaultChatModels: const <String>['openai:gpt-4o-mini'],
    );
    final now = DateTime(2026, 8, 27, 12);
    final conv = Conversation(
      id: 'conv_st_fallback',
      title: 'Chat',
      displayName: 'Chat',
      personaPrompt: PersonaPromptCodec.compose(userPrompt: '默认人设仍生效'),
      recipeId: 'st_preset_aaaaaaaaaaaaaaaaaaaaaaaa',
      enabledPlugins: const <String>[],
      createdAt: now,
      updatedAt: now,
    );
    final userMessage = Message(
      id: 'u1',
      role: 'user',
      content: '回退测试',
      createdAt: now,
    );
    final container = ProviderContainer(
      overrides: [
        appSettingsProvider
            .overrideWith(() => _FakeAppSettingsNotifier(settings)),
        sillyTavernPresetStoreProvider.overrideWithValue(store),
      ],
    );
    addTearDown(container.dispose);
    final service = container.read(chatSendServiceProvider);

    await expectLater(service.prepareApiConfig(
      conv: conv,
      history: <Message>[userMessage],
      userText: userMessage.content,
    ), throwsStateError);
  });
}
