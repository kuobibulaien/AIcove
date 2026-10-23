import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/presentation/widgets/message_bubble.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_message_processor.dart';
import 'package:aicove_flutter/src/features/plugins/domain/plugin.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/ui/theme/skin_provider.dart';
import 'package:aicove_flutter/src/ui/theme/skins/moetalk_skin.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../helpers/release_source_preview.dart';
import 'pages/chat_interface_test_support.dart';

void main() {
  for (final width in [390.0, 1000.0]) {
    testWidgets('sticker markup is absent from rendered bubbles width=$width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 360);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await loadReleasePreviewFonts(tester);

      const raw = '晚安呀，做个好梦～<sticker tag="晚安"/>';
      final converted = chatMessageProcessor
          .buildAssistantMessages(
            replyText: raw,
            processedText: '晚安呀，做个好梦～',
            pluginEvents: [
              PluginEvent(
                pluginId: 'sticker',
                type: 'sticker_convert',
                data: const {
                  'tag': '晚安',
                  'stickerId': 'hug_request',
                  'assetPath': 'assets/stickers/nahida/hug_request.png',
                },
              ),
            ],
          )
          .messages;
      final unmatched = chatMessageProcessor
          .buildAssistantMessages(
            replyText: '明天见啦～<sticker tag="未匹配标签"/>',
            processedText: '',
            pluginEvents: const [],
          )
          .messages;
      final key = GlobalKey();
      final colors = MoeColors.light();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appSettingsProvider.overrideWith(
              () => FakeChatInterfaceSettingsNotifier(
                chatInterfaceTestSettings(),
              ),
            ),
          ],
          child: SkinScope(
            skin: const MoeTalkSkin(),
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: ThemeData(
                fontFamily: captureReleaseSourcePreview
                    ? 'ReleasePreview'
                    : null,
                extensions: [colors],
              ),
              home: RepaintBoundary(
                key: key,
                child: Scaffold(
                  backgroundColor: colors.bgMain,
                  body: Center(
                    child: SizedBox(
                      width: 390,
                      child: ListView(
                        padding: const EdgeInsets.symmetric(vertical: 32),
                        children: [
                          MessageBubble(
                            isMe: true,
                            message: Message.text(
                              id: 'question',
                              role: 'user',
                              content: '晚安，明天见～',
                              createdAt: DateTime(2026, 10, 22),
                            ),
                          ),
                          for (final message in [...converted, ...unmatched])
                            MessageBubble(isMe: false, message: message),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.runAsync(() => precacheImage(
        const AssetImage('assets/stickers/nahida/hug_request.png'),
        tester.element(find.byType(Scaffold)),
      ));
      await tester.pumpAndSettle();
      expect(find.text('晚安呀，做个好梦～'), findsOneWidget);
      expect(find.text('明天见啦～'), findsOneWidget);
      expect(find.textContaining('<sticker'), findsNothing);
      expect(tester.takeException(), isNull);
      await saveReleaseSourcePreview(
        tester,
        key,
        'sticker-markup-${width.toInt()}',
      );
    });
  }
}
