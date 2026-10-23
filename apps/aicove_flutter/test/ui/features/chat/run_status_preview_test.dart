import 'dart:io';
import 'dart:ui' as ui;

import 'package:aicove_flutter/src/core/models/message_block.dart';
import 'package:aicove_flutter/src/core/utils/message_formatter.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/presentation/widgets/message_bubble.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/ui/features/chat/widgets/chat_message_list_items.dart';
import 'package:aicove_flutter/src/ui/features/chat/widgets/chat_reply_action_bar.dart';
import 'package:aicove_flutter/src/ui/features/chat/widgets/chat_run_status_line.dart';
import 'package:aicove_flutter/src/ui/theme/skin_provider.dart';
import 'package:aicove_flutter/src/ui/theme/skins/moetalk_skin.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'pages/chat_interface_test_support.dart';

/// A tool-mode reply whose codemode script made nested calls and whose last
/// round was cut off by the output limit.
/// --dart-define=WRITE_RUN_STATUS_PREVIEW=true writes the source-rendered
/// preview to scratch/run-status/.
void main() {
  const capture = bool.fromEnvironment('WRITE_RUN_STATUS_PREVIEW');

  List<Widget> replyWidgets(MoeColors colors) {
    final reply = Message.fromBlocks(
      id: 'a1',
      role: 'assistant',
      createdAt: DateTime(2026, 10, 22, 5, 3),
      rawPayload: const {'runStatus': 'truncated', 'stopReason': 'length'},
      blocks: [
        TextBlock(
          messageId: 'a1',
          content: '下好了，游戏在工作区的 `games/myraidrealm/` 里。接下来要在浏览器里打开',
        ),
        ToolBlock(
          messageId: 'a1',
          toolCallId: 'call_1',
          toolName: 'codemode',
          arguments: const {
            'code':
                'const rel = await tools.bash({ command: "curl -sL https://api.github.com/repos/0xSynt4x/MyRaidRealmWEB/releases/latest" });\n'
                'const url = JSON.parse(rel.output).assets[0].browser_download_url;\n'
                'await tools.bash({ command: `mkdir -p games/myraidrealm && curl -sLo games/myraidrealm/index.html \${url}` });\n'
                'return await tools.workspace_list({ path: "games/myraidrealm" });',
          },
          result: const {
            'content':
                'Script completed\nWall time 4.1 seconds\nOutput:\nindex.html  2.3 MB',
            'codemodeCalls': [
              {
                'id': 'call_1/1',
                'name': 'bash',
                'args': '{"command":"curl -sL https://api.github.com/…"}',
                'status': 'ok',
                'durationMs': 1800,
              },
              {
                'id': 'call_1/2',
                'name': 'bash',
                'args': '{"command":"mkdir -p games/myraidrealm && …"}',
                'status': 'ok',
                'durationMs': 2200,
              },
              {
                'id': 'call_1/3',
                'name': 'workspace_list',
                'args': '{"path":"games/myraidrealm"}',
                'status': 'ok',
                'durationMs': 40,
              },
            ],
          },
        ),
      ],
    );
    final items = buildChatMessageListItems(
      messages: [reply],
      config: const MessageFormatConfig(enableChunking: false),
      showToolCallFolds: true,
      showReplyActions: true,
    );
    return [
      for (final item in items)
        if (item is ChatChunkedMessageItem)
          MessageBubble(
            isMe: false,
            message: chatChunkDisplayMessage(item),
            documentStyle: true,
          )
        else if (item is ChatMessageItem)
          MessageBubble(isMe: false, message: item.message, documentStyle: true)
        else if (item is ChatRunStatusItem)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Align(
              alignment: Alignment.centerLeft,
              child: ChatRunStatusLine(
                status: item.status,
                textColor: colors.muted,
              ),
            ),
          )
        else if (item is ChatReplyActionsItem)
          Padding(
            padding: const EdgeInsets.only(left: 10, right: 16),
            child: Align(
              alignment: Alignment.centerLeft,
              child: ChatReplyActionBar(
                timeLabel: '8分钟前',
                color: colors.muted,
                visible: true,
                onCopy: () {},
                onQuote: () {},
                onRetry: () {},
              ),
            ),
          ),
    ];
  }

  for (final dark in [false, true]) {
    testWidgets('run status preview dark=$dark', (tester) async {
      tester.view.physicalSize = const Size(390 * 2, 1100 * 2);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      if (capture) {
        await tester.runAsync(() async {
          Future<void> load(String family, String path) async {
            final loader = FontLoader(family)
              ..addFont(File(path).readAsBytes().then(ByteData.sublistView));
            await loader.load();
          }

          await load('Preview', '/System/Library/Fonts/STHeiti Medium.ttc');
          await load('Menlo', '/System/Library/Fonts/Menlo.ttc');
          await load('packages/gpt_markdown/JetBrainsMono',
              '${Platform.environment['HOME']}/.pub-cache/hosted/pub.dev/gpt_markdown-1.3.0/lib/fonts/JetBrainsMono-Regular.ttf');
          await load('MaterialIcons',
              '${Platform.environment['HOME']}/dev-sdks/flutter-3.44.6/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
        });
      }
      final key = GlobalKey();
      final colors = dark ? MoeColors.dark() : MoeColors.light();
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
              theme: ThemeData(
                brightness: dark ? Brightness.dark : Brightness.light,
                fontFamily: capture ? 'Preview' : null,
                extensions: [colors],
              ),
              home: RepaintBoundary(
                key: key,
                child: Scaffold(
                  backgroundColor: colors.bgMain,
                  body: ListView(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    children: [
                      MessageBubble(
                        isMe: true,
                        message: Message.text(
                          id: 'u1',
                          role: 'user',
                          content:
                              'https://github.com/0xSynt4x/MyRaidRealmWEB/ 我想玩这个',
                          createdAt: DateTime(2026, 10, 22, 5, 2),
                        ),
                        documentStyle: true,
                      ),
                      ...replyWidgets(colors),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('回复达到长度上限，被截断了'), findsOneWidget);
      expect(find.byTooltip('重试'), findsOneWidget);
      expect(find.text('8分钟前'), findsOneWidget);
      await tester.tap(find.text('bash、workspace_list · 3 次'));
      await tester.pumpAndSettle();
      expect(find.textContaining('脚本里调用了 3 个工具'), findsOneWidget);
      expect(tester.takeException(), isNull);
      if (!capture) return;
      await tester.runAsync(() async {
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final dir = Directory('../../scratch/run-status')
          ..createSync(recursive: true);
        await File('${dir.path}/run-status-${dark ? 'dark' : 'light'}.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    });
  }
}
