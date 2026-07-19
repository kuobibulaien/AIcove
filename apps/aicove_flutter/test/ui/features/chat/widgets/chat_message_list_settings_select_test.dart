import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:aicove_flutter/src/core/models/message_block.dart';
import 'package:aicove_flutter/src/core/utils/message_formatter.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/features/settings/settings_models.dart';
import 'package:aicove_flutter/src/ui/features/chat/widgets/chat_message_list.dart';
import 'package:aicove_flutter/src/ui/features/chat/widgets/chat_message_list_display_cache.dart';
import 'package:aicove_flutter/src/ui/features/chat/widgets/chat_viewport_controller.dart';
import 'package:aicove_flutter/src/ui/theme/skin_provider.dart';
import 'package:aicove_flutter/src/ui/theme/skins/moetalk_skin.dart';

class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this.rootPath);
  final String rootPath;
  @override
  Future<String?> getApplicationDocumentsPath() async => rootPath;
}

class _FakeAppSettingsNotifier extends AppSettingsNotifier {
  _FakeAppSettingsNotifier(this._settings);
  final AppSettings _settings;
  @override
  Future<AppSettings> build() async => _settings;

  void debugSet(AppSettings settings) {
    state = AsyncData(settings);
  }
}

const _baseSettings = AppSettings(
  ttsEnabled: true,
  defaultModelName: 'deepseek-chat',
  defaultPersonaPrompt: '',
  modelList: <String>['deepseek-chat'],
  allKnownModels: <String>['deepseek-chat'],
  modelDisplayNames: <String, String>{},
  modelTypes: <String, String>{},
  modelConfigs: <String, ModelConfig>{},
  apiKey: '',
  apiBaseUrl: 'https://api.openai.com/v1',
  imageGenerationEnabled: false,
  maxFileUploadMB: 10,
  historyMessageLimit: 100,
  customModels: <CustomModel>[],
  providers: <ProviderAuth>[],
  modelProviderMap: <String, String>{},
  backendApiKey: '',
  messageChunkingEnabled: true,
  messageFormatConfig: MessageFormatConfig(
    enableChunking: true,
    chunkPunctuations: <String>['。'],
    minSegmentLength: 1,
  ),
  textScaleFactor: 1.0,
  uiScaleFactor: 1.0,
  imagePreviewScale: 1.0,
  autoReplySettings: AutoReplySettings(),
  globalBackgroundColor: GlobalBackgroundColor.white,
  chatBackgroundColor: ChatBackgroundColor.defaultColor,
  isDarkMode: false,
  useSystemTheme: true,
  accentColor: 'FC96AA',
  hideUserAvatar: false,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<int Function()> pumpList(WidgetTester tester) async {
    await tester.runAsync(() async {
      final tempDir =
          await Directory.systemTemp.createTemp('chat_list_select_test');
      PathProviderPlatform.instance = _FakePathProviderPlatform(tempDir.path);
      ChatMessageListDisplayCache.clear();
      await ChatMessageListDisplayCache.clearPersistent();
    });
    var buildCount = 0;
    final messages = <Message>[
      Message.fromBlocks(
        id: 'assistant_text_block',
        role: 'assistant',
        blocks: <MessageBlock>[
          TextBlock(messageId: 'assistant_text_block', content: '第一段。第二段。'),
        ],
        createdAt: DateTime(2026, 1, 1, 12, 0, 0),
        status: 'sent',
      ),
    ];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appSettingsProvider
              .overrideWith(() => _FakeAppSettingsNotifier(_baseSettings)),
        ],
        child: SkinScope(
          skin: const MoeTalkSkin(),
          child: MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 360,
                height: 520,
                child: ChatMessageList(
                  conversationId: 'conv_select_test',
                  messages: messages,
                  displayName: '测试AI',
                  avatarUrl: null,
                  viewportController: ChatViewportController(),
                  onDebugListItemCountChanged: (_) => buildCount++,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    // 等待 AsyncNotifier 首值与 post-frame 回调稳定
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    return () => buildCount;
  }

  _FakeAppSettingsNotifier notifierOf(WidgetTester tester) {
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ChatMessageList)),
    );
    return container.read(appSettingsProvider.notifier)
        as _FakeAppSettingsNotifier;
  }

  testWidgets('设置里无关字段变化不重建消息列表', (tester) async {
    final buildCount = await pumpList(tester);
    final before = buildCount();
    expect(before, greaterThan(0));

    notifierOf(tester).debugSet(_baseSettings.copyWith(ttsEnabled: false));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(buildCount(), before,
        reason: 'ttsEnabled 变化不应触发 ChatMessageList 重建');
  });

  testWidgets('uiScaleFactor 变化仍会重建消息列表', (tester) async {
    final buildCount = await pumpList(tester);
    final before = buildCount();

    notifierOf(tester).debugSet(_baseSettings.copyWith(uiScaleFactor: 1.2));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(buildCount(), greaterThan(before),
        reason: 'uiScaleFactor 变化必须触发重建');
  });

  testWidgets('messageFormatConfig 变化仍会重建消息列表', (tester) async {
    final buildCount = await pumpList(tester);
    final before = buildCount();

    notifierOf(tester).debugSet(
      _baseSettings.copyWith(
        messageFormatConfig: const MessageFormatConfig(
          enableChunking: true,
          chunkPunctuations: <String>['。'],
          minSegmentLength: 3,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(buildCount(), greaterThan(before),
        reason: 'messageFormatConfig 变化必须触发重建');
  });

  test('MessageFormatConfig 内容相同的实例应相等（select 的前提）', () {
    const a = MessageFormatConfig(
      enableChunking: true,
      chunkPunctuations: <String>['。', '！'],
      minSegmentLength: 2,
    );
    final b = MessageFormatConfig(
      enableChunking: true,
      chunkPunctuations: List<String>.of(const <String>['。', '！']),
      minSegmentLength: 2,
    );
    expect(a, equals(b));
    expect(a.hashCode, b.hashCode);
    expect(
      a,
      isNot(equals(a.copyWith(minSegmentLength: 5))),
    );
  });

  testWidgets('等值但新建的 messageFormatConfig 实例不触发列表重建', (tester) async {
    final buildCount = await pumpList(tester);
    final before = buildCount();

    final equalNewConfig = MessageFormatConfig.fromJson(
      _baseSettings.messageFormatConfig.toJson(),
    );
    expect(equalNewConfig, equals(_baseSettings.messageFormatConfig));
    notifierOf(tester).debugSet(
      _baseSettings.copyWith(
        ttsEnabled: false,
        messageFormatConfig: equalNewConfig,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(buildCount(), before,
        reason: '值相等的新配置实例不应触发 ChatMessageList 重建');
  });

  test('MessageFormatConfig copyWith()/JSON 往返保持值相等', () {
    const custom = MessageFormatConfig(
      enableChunking: true,
      filterPunctuation: true,
      chunkPunctuations: <String>['。', '！'],
      chunkPunctuationSets: <MessageChunkPunctuationSet>[
        MessageChunkPunctuationSet(
          id: 'custom',
          name: '自定义',
          punctuations: <String>['？'],
        ),
      ],
      activeChunkPunctuationSetId: 'custom',
      filterPunctuations: <String>['，'],
      stickerProbability: 0.5,
      minSegmentLength: 2,
      protectQuotes: false,
    );
    // 无参 copyWith 不得隐式改写任何字段（即使 chunkPunctuations 与激活集合不一致）
    expect(custom.copyWith(), equals(custom));
    // JSON 往返值相等
    expect(
      MessageFormatConfig.fromJson(custom.toJson()),
      equals(custom),
    );
    // 显式切换激活集合时才同步 chunkPunctuations
    final switched = custom.copyWith(activeChunkPunctuationSetId: 'custom');
    expect(switched.chunkPunctuations, <String>['？']);
    // 默认配置往返
    const def = MessageFormatConfig();
    expect(def.copyWith(), equals(def));
    expect(MessageFormatConfig.fromJson(def.toJson()), equals(def));
  });
}
