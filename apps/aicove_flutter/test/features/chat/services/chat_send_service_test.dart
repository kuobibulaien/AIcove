import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:drift/native.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:aicove_flutter/src/core/models/message_block.dart';
import 'package:aicove_flutter/src/core/utils/message_formatter.dart';
import 'package:aicove_flutter/src/core/database/database.dart' as db;
import 'package:aicove_flutter/src/core/database/database_provider.dart';
import 'package:aicove_flutter/src/core/database/converters/database_converters.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/domain/persona_prompt_codec.dart';
import 'package:aicove_flutter/src/features/plugins/image/image_config.dart';
import 'package:aicove_flutter/src/features/plugins/plugin_providers.dart';
import 'package:aicove_flutter/src/features/plugins/trigger/trigger_config.dart';
import 'package:aicove_flutter/src/features/plugins/trigger/trigger_plugin.dart';
import 'package:aicove_flutter/src/features/observability/trace_models.dart';
import 'package:aicove_flutter/src/features/observability/trace_store.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_request_message_builder.dart';
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

  Message msg(String id, String text, DateTime t) => Message(
        id: id,
        role: 'user',
        content: text,
        createdAt: t,
      );

  AppSettings fakeSettings({
    required String defaultModelName,
    List<String>? defaultChatModels,
    String? defaultVisionModel,
    bool preferVisionAssistant = false,
    Map<String, ModelConfig>? modelConfigs,
    bool imageGenerationEnabled = false,
    CallFlowMode callFlowMode = CallFlowMode.auto,
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
      autoReplySettings: const AutoReplySettings(),
      globalBackgroundColor: GlobalBackgroundColor.white,
      chatBackgroundColor: ChatBackgroundColor.defaultColor,
      isDarkMode: false,
      useSystemTheme: true,
      accentColor: 'FC96AA',
      hideUserAvatar: true,
      defaultChatModels: defaultChatModels ?? <String>[defaultModelName],
      defaultVisionModel: defaultVisionModel,
      preferVisionAssistant: preferVisionAssistant,
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
      limit: 20,
    );

    expect(history.map((m) => m.id).toList(), ['m3', 'm4', 'm5']);
  });

  test('prepareHistory still applies message limit after context slicing', () {
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
      limit: 2,
    );

    expect(history.map((m) => m.id).toList(), ['m4', 'm5']);
  });

  test('prepareHistory falls back to normal limit when marker is missing', () {
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
      limit: 3,
    );

    expect(history.map((m) => m.id).toList(), ['m2', 'm3', 'm4']);
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
      limit: 20,
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
      limit: 20,
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

  test('non-vision description reuses image prompt before vision fallback',
      () async {
    var visionCalled = false;
    final block = ImageBlock(
      messageId: 'msg_1',
      localPath: '/tmp/demo.png',
      prompt: '1girl, blue hair, smile',
    );

    final description =
        await ChatSendService.resolveImageDescriptionForNonVision(
      imageBlock: block,
      translateWithVision: () async {
        visionCalled = true;
        return 'vision generated description';
      },
    );

    expect(description, '1girl, blue hair, smile');
    expect(visionCalled, isFalse);
  });

  test('non-vision description calls vision fallback when prompt is missing',
      () async {
    var visionCalled = false;
    final block = ImageBlock(
      messageId: 'msg_2',
      localPath: '/tmp/demo2.png',
    );

    final description =
        await ChatSendService.resolveImageDescriptionForNonVision(
      imageBlock: block,
      translateWithVision: () async {
        visionCalled = true;
        return 'vision generated description';
      },
    );

    expect(description, 'vision generated description');
    expect(visionCalled, isTrue);
  });

  test('non-vision description reuses cached description', () async {
    var visionCalled = false;
    final block = ImageBlock(
      messageId: 'msg_2_cache',
      localPath: '/tmp/demo2.png',
    );

    final description =
        await ChatSendService.resolveImageDescriptionForNonVision(
      imageBlock: block,
      cachedDescription: '缓存描述',
      translateWithVision: () async {
        visionCalled = true;
        return 'vision generated description';
      },
    );

    expect(description, '缓存描述');
    expect(visionCalled, isFalse);
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

  test('vision translation request uses system prompt + single image only', () {
    final messages = ChatSendService.buildVisionTranslationMessages(
      imagePart: const <String, dynamic>{
        'type': 'image_url',
        'image_url': <String, dynamic>{'url': 'https://example.com/cat.jpg'},
      },
    );

    expect(messages.length, 2);
    expect(messages.first['role'], 'system');
    expect(
      messages.first['content'],
      ChatSendService.visionDescriptionSystemPrompt,
    );
    expect(messages[1]['role'], 'user');
    final content = messages[1]['content'] as List<dynamic>;
    expect(content.length, 1);
    expect((content.first as Map<String, dynamic>)['type'], 'image_url');
  });

  test('image send chain skips vision assistant when chat model has vision',
      () {
    final settings = fakeSettings(
      defaultModelName: 'openai:gpt-4.1-mini',
      defaultChatModels: const <String>['openai:gpt-4.1-mini'],
      defaultVisionModel: 'openai:gpt-4o-mini',
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
      defaultVisionModel: 'openai:gpt-4o-mini',
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
      defaultVisionModel: 'openai:gpt-4o-mini',
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final service = container.read(chatSendServiceProvider);

    final chain = service.buildImageSendModelRefs(settings);

    expect(chain, <String>['openai:gpt-4o']);
    expect(chain, isNot(contains('openai:gpt-4o-mini')));
  });

  test(
      'image send chain keeps chat model first when preference switch is enabled',
      () {
    final settings = fakeSettings(
      defaultModelName: 'openai:gpt-4o',
      defaultChatModels: const <String>['openai:gpt-4o'],
      defaultVisionModel: 'openai:gpt-4o-mini',
      preferVisionAssistant: true,
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final service = container.read(chatSendServiceProvider);

    final chain = service.buildImageSendModelRefs(settings);

    expect(chain, <String>['openai:gpt-4o']);
  });

  test(
      'image send chain falls back to chat models when preference switch is enabled but vision model is missing',
      () {
    final settings = fakeSettings(
      defaultModelName: 'openai:gpt-4o',
      defaultChatModels: const <String>['openai:gpt-4o'],
      defaultVisionModel: null,
      preferVisionAssistant: true,
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final service = container.read(chatSendServiceProvider);

    final chain = service.buildImageSendModelRefs(settings);

    expect(chain, <String>['openai:gpt-4o']);
  });

  test('preferVisionAssistant treats vision chat model as non-vision flow', () {
    final settings = fakeSettings(
      defaultModelName: 'openai:gpt-4o',
      defaultChatModels: const <String>['openai:gpt-4o'],
      defaultVisionModel: 'openai:gpt-4o-mini',
      preferVisionAssistant: true,
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final service = container.read(chatSendServiceProvider);

    final shouldPreprocess = service.shouldUseNonVisionImageFlow(
      settings: settings,
      modelRef: 'openai:gpt-4o',
    );

    expect(shouldPreprocess, isTrue);
  });

  test('assistant generated image is omitted in non-vision flow', () async {
    final builder = ChatRequestMessageBuilder(
      readImageAsBase64: (_) async => null,
    );
    final settings = fakeSettings(
      defaultModelName: 'openai:gpt-3.5-turbo',
      defaultChatModels: const <String>['openai:gpt-3.5-turbo'],
      defaultVisionModel: 'openai:gpt-4o-mini',
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

  test(
      'prepareApiConfig should preserve explicit artist preset disable binding',
      () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final now = DateTime(2026, 3, 7, 12, 0, 0);
    final settings = fakeSettings(
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

    expect(
      apiConfig.boundImageArtistPresetName,
      PersonaPromptCodec.artistPresetDisabledBinding,
    );
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
      contains('current_datetime='),
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
      contains('以下是当前会话启用的特殊标签说明'),
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
      return (message['role'] ?? '').toString() == 'system' &&
          content.trimLeft().startsWith('<system-reminder>');
    });

    expect(reminderIndex, greaterThan(0));
    expect(apiConfig.messages[reminderIndex + 1]['role'], 'user');
    expect(apiConfig.messages[reminderIndex + 1]['content'], contains('现在几点了'));
    expect(
      apiConfig.messages[reminderIndex]['content'].toString(),
      contains('current_datetime='),
    );
    expect(
      apiConfig.messages[reminderIndex]['content'].toString(),
      contains('previous_user_message_datetime=2026-03-12 10:00:00'),
    );
  });

  test('prepareApiConfig should inject image failure into system reminder only',
      () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final settings = fakeSettings(
      defaultModelName: 'openai:gpt-4o-mini',
      defaultChatModels: const <String>['openai:gpt-4o-mini'],
    );
    final now = DateTime(2026, 3, 23, 12, 0, 0);
    final conv = Conversation(
      id: 'conv_image_failure_reminder',
      title: 'Chat',
      displayName: 'Chat',
      personaPrompt: PersonaPromptCodec.compose(
        userPrompt: '你是贴心助手。',
      ),
      enabledPlugins: const <String>[],
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

    final reminderIndex = apiConfig.messages.lastIndexWhere((message) {
      final content = (message['content'] ?? '').toString();
      return (message['role'] ?? '').toString() == 'system' &&
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
}
