import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:aicove_flutter/src/core/utils/message_formatter.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
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
}

const AppSettings _settings = AppSettings(
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
  messageChunkingEnabled: false,
  messageFormatConfig: MessageFormatConfig(enableChunking: false),
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

Widget _buildHost({
  required List<Message> messages,
  required ChatViewportController viewportController,
  String? contextStartMessageId,
}) {
  return ProviderScope(
    overrides: [
      appSettingsProvider
          .overrideWith(() => _FakeAppSettingsNotifier(_settings)),
    ],
    child: SkinScope(
      skin: const MoeTalkSkin(),
      child: MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 360,
              height: 520,
              child: ChatMessageList(
                key: const ValueKey<String>('topic-divider-chat-list'),
                conversationId: 'conv_topic_divider',
                messages: messages,
                displayName: '测试AI',
                avatarUrl: null,
                viewportController: viewportController,
                contextStartMessageId: contextStartMessageId,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

List<Message> _buildMessages() {
  final base = DateTime(2026, 4, 1, 10, 0);
  return <Message>[
    Message.text(
      id: 'm1',
      role: 'user',
      content: '旧话题第一句',
      createdAt: base,
      status: 'sent',
    ),
    Message.text(
      id: 'm2',
      role: 'assistant',
      content: '旧话题第二句',
      createdAt: base.add(const Duration(minutes: 1)),
      status: 'sent',
    ),
    Message.text(
      id: 'm3',
      role: 'user',
      content: '旧话题最后一句',
      createdAt: base.add(const Duration(minutes: 2)),
      status: 'sent',
    ),
  ];
}

List<Message> _buildProjectedBoundaryMessages() {
  final base = DateTime(2026, 4, 1, 11, 0);
  return <Message>[
    Message.text(
      id: 'm1',
      role: 'user',
      content: '旧话题第一句',
      createdAt: base,
      status: 'sent',
    ),
    Message(
      id: 'proj_m2',
      role: 'assistant',
      sourceMessageId: 'm2',
      content: '旧话题第二句',
      createdAt: base.add(const Duration(minutes: 1)),
      status: 'sent',
    ),
    Message(
      id: 'proj_m3',
      role: 'assistant',
      sourceMessageId: 'm3',
      content: '旧话题最后一句的投影气泡',
      createdAt: base.add(const Duration(minutes: 2)),
      status: 'sent',
    ),
  ];
}

List<Message> _buildMultiProjectedBoundaryMessages() {
  final base = DateTime(2026, 4, 1, 12, 0);
  return <Message>[
    Message.text(
      id: 'm1',
      role: 'user',
      content: '旧话题第一句',
      createdAt: base,
      status: 'sent',
    ),
    Message(
      id: 'proj_m2_text',
      role: 'assistant',
      sourceMessageId: 'm2',
      content: '旧话题最后一句的文本投影',
      createdAt: base.add(const Duration(minutes: 1)),
      status: 'sent',
    ),
    Message(
      id: 'proj_m2_media',
      role: 'assistant',
      sourceMessageId: 'm2',
      content: '旧话题最后一句的媒体投影',
      createdAt: base.add(const Duration(minutes: 1, seconds: 1)),
      status: 'sent',
    ),
  ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PathProviderPlatform previousPathProvider;
  Directory? tempDir;

  setUp(() async {
    previousPathProvider = PathProviderPlatform.instance;
    tempDir = await Directory.systemTemp.createTemp('chat_topic_divider_test');
    PathProviderPlatform.instance = _FakePathProviderPlatform(tempDir!.path);
    ChatMessageListDisplayCache.clear();
    await ChatMessageListDisplayCache.clearPersistent();
  });

  tearDown(() async {
    ChatMessageListDisplayCache.clear();
    await ChatMessageListDisplayCache.clearPersistent();
    PathProviderPlatform.instance = previousPathProvider;
    if (tempDir != null && await tempDir!.exists()) {
      await tempDir!.delete(recursive: true);
    }
  });

  testWidgets('contextStartMessageId 变化后应立即出现新话题分界线', (tester) async {
    final viewportController = ChatViewportController();
    addTearDown(viewportController.dispose);
    final messages = _buildMessages();

    await tester.pumpWidget(
      _buildHost(
        messages: messages,
        viewportController: viewportController,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('以上是历史消息'), findsNothing);

    await tester.pumpWidget(
      _buildHost(
        messages: messages,
        viewportController: viewportController,
        contextStartMessageId: 'm3',
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('以上是历史消息'), findsOneWidget);
  });

  testWidgets('contextStartMessageId 指向 raw id 时，投影消息也应出现新话题分界线',
      (tester) async {
    final viewportController = ChatViewportController();
    addTearDown(viewportController.dispose);
    final messages = _buildProjectedBoundaryMessages();

    await tester.pumpWidget(
      _buildHost(
        messages: messages,
        viewportController: viewportController,
        contextStartMessageId: 'm3',
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('以上是历史消息'), findsOneWidget);
  });

  testWidgets('同一 raw message 投影成多条前端消息时只渲染一条话题分界线', (tester) async {
    final viewportController = ChatViewportController();
    addTearDown(viewportController.dispose);
    final messages = _buildMultiProjectedBoundaryMessages();

    await tester.pumpWidget(
      _buildHost(
        messages: messages,
        viewportController: viewportController,
        contextStartMessageId: 'm2',
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('以上是历史消息'), findsOneWidget);
  });
}
