import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:aicove_flutter/src/core/models/message_block.dart';
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('debug list', (tester) async {
    final tempDir = await Directory.systemTemp.createTemp('debug_chat_list');
    PathProviderPlatform.instance = _FakePathProviderPlatform(tempDir.path);
    ChatMessageListDisplayCache.clear();
    await ChatMessageListDisplayCache.clearPersistent();
    const settings = AppSettings(
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
              .overrideWith(() => _FakeAppSettingsNotifier(settings))
        ],
        child: SkinScope(
          skin: const MoeTalkSkin(),
          child: MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 360,
                height: 520,
                child: ChatMessageList(
                  conversationId: 'conv_test',
                  messages: messages,
                  displayName: '测试AI',
                  avatarUrl: null,
                  viewportController: ChatViewportController(),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    final texts = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data)
        .whereType<String>()
        .toList();
    // ignore: avoid_print
    print('TEXTS=$texts');
    // ignore: avoid_print
    print('chunk1=${find.text('第一段。').evaluate().length}');
    // ignore: avoid_print
    print('chunk2=${find.text('第二段。').evaluate().length}');
    // ignore: avoid_print
    print('full=${find.text('第一段。第二段。').evaluate().length}');
  });
}
