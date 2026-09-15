import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:aicove_flutter/src/core/models/message_block.dart';
import 'package:aicove_flutter/src/core/models/block_status.dart';
import 'package:aicove_flutter/src/core/utils/message_formatter.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/presentation/widgets/message_bubble.dart';
import 'package:aicove_flutter/src/features/chat/presentation/widgets/message_action_sheet.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/ui/theme/skin_provider.dart';
import 'package:aicove_flutter/src/ui/theme/skins/moetalk_skin.dart';

class _FakeAppSettingsNotifier extends AppSettingsNotifier {
  _FakeAppSettingsNotifier(this._settings);

  final AppSettings _settings;

  @override
  Future<AppSettings> build() async => _settings;
}

AppSettings _buildSettings({required bool expandAudioText}) {
  return AppSettings(
    ttsEnabled: true,
    defaultModelName: 'deepseek-chat',
    defaultPersonaPrompt: '',
    modelList: const <String>['deepseek-chat'],
    allKnownModels: const <String>['deepseek-chat'],
    modelDisplayNames: const <String, String>{},
    modelTypes: const <String, String>{},
    modelConfigs: const <String, ModelConfig>{},
    apiKey: '',
    apiBaseUrl: 'https://api.openai.com/v1',
    imageGenerationEnabled: false,
    maxFileUploadMB: 10,
    contextWindowTokens: 272000,
    customModels: const <CustomModel>[],
    providers: const <ProviderAuth>[],
    modelProviderMap: const <String, String>{},
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
    expandAudioText: expandAudioText,
  );
}

Widget _buildAudioBubbleHost({
  required Message message,
  required bool expandAudioText,
  ProviderContainer? container,
}) {
  final settings = _buildSettings(expandAudioText: expandAudioText);
  return ProviderScope(
    parent: container,
    overrides: [
      appSettingsProvider
          .overrideWith(() => _FakeAppSettingsNotifier(settings)),
    ],
    child: SkinScope(
      skin: const MoeTalkSkin(),
      child: MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 360,
              child: MessageBubble(
                isMe: false,
                message: message,
                showAvatar: true,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const ttsText = '宝宝今天天气真好呀，一起出去散散步吧～';
  final audioMessage = Message.fromBlocks(
    id: 'msg_audio_1',
    role: 'assistant',
    blocks: [
      AudioBlock(
        messageId: 'msg_audio_1',
        url: '',
        text: ttsText,
        durationSeconds: 3.5,
        status: BlockStatus.pending,
      ),
    ],
  );

  testWidgets('默认 expandAudioText=true 时，语音气泡下方渲染转化前的文字',
      (WidgetTester tester) async {
    await tester.pumpWidget(_buildAudioBubbleHost(
      message: audioMessage,
      expandAudioText: true,
    ));
    await tester.pump();

    // 能够找到 TTS 转化前的文字
    expect(find.text(ttsText), findsOneWidget);
  });

  testWidgets('当 expandAudioText=false 时，语音气泡下方收回文字，保持原样',
      (WidgetTester tester) async {
    await tester.pumpWidget(_buildAudioBubbleHost(
      message: audioMessage,
      expandAudioText: false,
    ));
    await tester.pump();

    // 不显示转化文字
    expect(find.text(ttsText), findsNothing);
  });

  testWidgets('单条消息覆盖状态优先于全局设置（局部展开与收回）',
      (WidgetTester tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    // 全局为 false，但局部设为 true
    container.read(audioMessageTextExpandedProvider(audioMessage.id).notifier).state = true;

    await tester.pumpWidget(_buildAudioBubbleHost(
      message: audioMessage,
      expandAudioText: false,
      container: container,
    ));
    await tester.pump();

    expect(find.text(ttsText), findsOneWidget);

    // 局部切换为 false
    container.read(audioMessageTextExpandedProvider(audioMessage.id).notifier).state = false;
    await tester.pump();

    expect(find.text(ttsText), findsNothing);
  });

  testWidgets('showMessageActionMenu 在语音消息下出现转文字/隐藏文字选项',
      (WidgetTester tester) async {
    MessageAction? triggeredAction;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              Positioned(
                left: 100,
                top: 200,
                width: 120,
                height: 48,
                child: Builder(
                  builder: (context) {
                    return ElevatedButton(
                      onPressed: () {
                        final box = context.findRenderObject() as RenderBox;
                        showMessageActionMenu(
                          context,
                          targetBox: box,
                          isUserMessage: false,
                          messageText: ttsText,
                          showTranscribe: true,
                          isAudioTextExpanded: false,
                          onAction: (action) {
                            triggeredAction = action;
                          },
                        );
                      },
                      child: const Text('Open Menu'),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );

    // 点击打开长按菜单
    await tester.tap(find.text('Open Menu'));
    await tester.pumpAndSettle();

    // 验证菜单项包含「转文字」
    expect(find.text('转文字'), findsOneWidget);

    // 点击「转文字」
    await tester.tap(find.text('转文字'));
    await tester.pumpAndSettle();

    expect(triggeredAction, MessageAction.toggleAudioText);
  });
}
