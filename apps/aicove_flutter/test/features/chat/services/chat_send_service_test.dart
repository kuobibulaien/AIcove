import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:drift/native.dart';

import 'package:aicove_flutter/src/core/models/message_block.dart';
import 'package:aicove_flutter/src/core/utils/message_formatter.dart';
import 'package:aicove_flutter/src/core/database/database.dart' as db;
import 'package:aicove_flutter/src/core/database/database_provider.dart';
import 'package:aicove_flutter/src/core/database/converters/database_converters.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_send_service.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';

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

  test('non-vision assistant image should not inject placeholder text', () {
    final text = ChatSendService.buildNonVisionImageMessageText(
      role: 'assistant',
      description: '一只猫在草地上',
    );

    expect(text, isNull);
  });

  test('non-vision user image uses neutral description text', () {
    final text = ChatSendService.buildNonVisionImageMessageText(
      role: 'user',
      description: '一只猫在草地上',
    );

    expect(text, isNotNull);
    expect(text, contains('用户刚刚发送了一张图片'));
    expect(text, isNot(contains('[图片]')));
    expect(text, isNot(contains('图片已转换为文本描述')));
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

  test(
      'image send chain prepends vision assistant when chat model has no vision',
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

    expect(chain.first, 'openai:gpt-4o-mini');
    expect(chain, contains('openai:gpt-3.5-turbo'));
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
      'image send chain prefers vision assistant when preference switch is enabled',
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

    expect(chain, <String>['openai:gpt-4o-mini', 'openai:gpt-4o']);
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
}
