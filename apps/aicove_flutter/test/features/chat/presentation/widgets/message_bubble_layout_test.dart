import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:aicove_flutter/src/core/models/message_block.dart';
import 'package:aicove_flutter/src/core/utils/message_formatter.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/presentation/widgets/message_bubble.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/features/settings/settings_models.dart';
import 'package:aicove_flutter/src/ui/theme/skin_provider.dart';
import 'package:aicove_flutter/src/ui/theme/skins/moetalk_skin.dart';

class _FakeAppSettingsNotifier extends AppSettingsNotifier {
  _FakeAppSettingsNotifier(this._settings);

  final AppSettings _settings;

  @override
  Future<AppSettings> build() async => _settings;
}

const _assistantId = 'assistant_case';
const _userId = 'user_case';
const _assistantText = '[assistant] 用于校验气泡最大宽度约束';
const _userText = '[user] 用于校验气泡最大宽度约束';

AppSettings _buildSettings({required bool hideUserAvatar}) {
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
    historyMessageLimit: 100,
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
    hideUserAvatar: hideUserAvatar,
  );
}

Widget _buildLayoutHost({required bool hideUserAvatar}) {
  final settings = _buildSettings(hideUserAvatar: hideUserAvatar);
  return ProviderScope(
    key: ValueKey<String>('scope_hide_user_avatar_$hideUserAvatar'),
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
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  MessageBubble(
                    isMe: false,
                    message: Message.text(
                      id: _assistantId,
                      role: 'assistant',
                      content: _assistantText,
                    ),
                    showAvatar: true,
                  ),
                  const SizedBox(height: 8),
                  MessageBubble(
                    isMe: true,
                    message: Message.text(
                      id: _userId,
                      role: 'user',
                      content: _userText,
                    ),
                    showAvatar: true,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

double _bubbleMaxWidth(WidgetTester tester, String messageId) {
  final finder = find.byKey(
    ValueKey<String>('message_bubble_constraints_$messageId'),
  );
  expect(finder, findsOneWidget);
  final constrained = tester.widget<ConstrainedBox>(finder);
  return constrained.constraints.maxWidth;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('双头像模式下，左右消息气泡最大宽度应一致', (tester) async {
    await tester.pumpWidget(_buildLayoutHost(hideUserAvatar: false));
    await tester.pumpAndSettle();

    final assistantWidth = _bubbleMaxWidth(tester, _assistantId);
    final userWidth = _bubbleMaxWidth(tester, _userId);

    expect((assistantWidth - userWidth).abs(), lessThanOrEqualTo(1.0));
  });

  testWidgets('隐藏用户头像后，对方消息气泡应变宽（从双侧留白变单侧留白）', (tester) async {
    await tester.pumpWidget(_buildLayoutHost(hideUserAvatar: false));
    await tester.pumpAndSettle();
    final withUserAvatar = _bubbleMaxWidth(tester, _assistantId);

    await tester.pumpWidget(_buildLayoutHost(hideUserAvatar: true));
    await tester.pumpAndSettle();
    final withoutUserAvatar = _bubbleMaxWidth(tester, _assistantId);

    expect(withoutUserAvatar, greaterThan(withUserAvatar + 20));
  });

  testWidgets('图片加 ToolBlock 时不应渲染空文本气泡', (tester) async {
    const messageId = 'image_tool_case';
    final settings = _buildSettings(hideUserAvatar: false);
    final message = Message.fromBlocks(
      id: messageId,
      role: 'assistant',
      blocks: [
        ImageBlock(messageId: messageId, base64: 'a'),
        ToolBlock(
          messageId: messageId,
          toolName: 'draw_image',
          toolCallId: 'tool_1',
        ),
      ],
      status: 'sent',
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appSettingsProvider
              .overrideWith(() => _FakeAppSettingsNotifier(settings)),
        ],
        child: SkinScope(
          skin: const MoeTalkSkin(),
          child: MaterialApp(
            home: Scaffold(
              body: MessageBubble(
                isMe: false,
                message: message,
                showAvatar: true,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('message_bubble_image_tool_case')),
      findsNothing,
    );
  });
}
