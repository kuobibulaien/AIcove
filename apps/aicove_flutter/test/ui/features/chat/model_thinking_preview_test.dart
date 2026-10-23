@Tags(['preview'])
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:aicove_flutter/src/core/api/providers/provider_adapter.dart'
    show ToolCall, ToolResult;
import 'package:aicove_flutter/src/core/utils/message_formatter.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/presentation/widgets/message_bubble.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_message_processor.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_types.dart'
    show ReplyRound;
import 'package:aicove_flutter/src/features/content_tags/domain/tag_presentation.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/ui/features/chat/widgets/chat_message_list_items.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/moe_fold_section.dart';
import 'package:aicove_flutter/src/ui/theme/skin_provider.dart';
import 'package:aicove_flutter/src/ui/theme/skins/moetalk_skin.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'pages/chat_interface_test_support.dart';

/// 文档模式里一条调过两轮工具的回复：每轮思考、话术、工具调用按先后交替，
/// 最后是正文轮的思考、标签思考与正文。
/// --dart-define=WRITE_MODEL_THINKING_PREVIEW=true 时把源码渲染预览写到
/// scratch/model-thinking/。
void main() {
  const capture = bool.fromEnvironment('WRITE_MODEL_THINKING_PREVIEW');

  List<Message> displayMessages() {
    const answer = '<think>她问天气，语气要轻快，顺便提醒带伞。</think>\n'
        '明天上海多云转小雨，**白天 22 度**左右，出门记得带把伞～';
    final reply = const ChatMessageProcessor().buildAssistantMessages(
      replyText: answer,
      processedText: answer,
      pluginEvents: const [],
      toolCalls: const [
        ToolCall(
          id: 'call_1',
          name: 'web_search',
          arguments: {'query': '上海 明天 天气'},
        ),
        ToolCall(
          id: 'call_2',
          name: 'web_search',
          arguments: {'query': '上海 明天 降雨概率'},
        ),
      ],
      rawToolResults: const [
        ToolResult(
          toolCallId: 'call_1',
          name: 'web_search',
          result: '多云转小雨，17～22℃，东南风 3 级',
        ),
        ToolResult(
          toolCallId: 'call_2',
          name: 'web_search',
          result: '午后降雨概率 70%',
        ),
      ],
      replyRounds: const [
        ReplyRound(
          replyText: '我先帮你查一下明天的天气～',
          processedText: '我先帮你查一下明天的天气～',
          reasoning: 'The user asks about tomorrow\'s weather in Shanghai. '
              'I should call web_search first.',
          toolCallIds: ['call_1'],
        ),
        ReplyRound(
          replyText: '有小雨，再看看几点下。',
          processedText: '有小雨，再看看几点下。',
          toolCallIds: ['call_2'],
        ),
        ReplyRound(
          replyText: answer,
          processedText: answer,
          reasoning: '搜索结果显示午后有雨，回复时提醒带伞。',
        ),
      ],
    ).messages;
    final items = buildChatMessageListItems(
      messages: reply,
      config: const MessageFormatConfig(enableChunking: false),
      tagPresentation: const {
        'think': TagPresentationEntry(TagPresentation.fold, '思考'),
      },
      showToolCallFolds: true,
    );
    return [
      for (final item in items)
        if (item is ChatChunkedMessageItem)
          chatChunkDisplayMessage(item)
        else if (item is ChatMessageItem)
          item.message,
    ];
  }

  for (final dark in [false, true]) {
    testWidgets('model thinking preview dark=$dark', (tester) async {
      tester.view.physicalSize = const Size(390 * 2, 900 * 2);
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
                          content: '明天上海天气怎么样？',
                          createdAt: DateTime(2026, 10, 21),
                        ),
                        documentStyle: true,
                      ),
                      for (final message in displayMessages())
                        MessageBubble(
                          isMe: false,
                          message: message,
                          documentStyle: true,
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // 两轮工具：思考 → 话术 → 工具 → 话术 → 工具 → 思考 → 标签思考 → 正文。
      expect(find.byType(MoeFoldSection), findsNWidgets(5));
      expect(find.text('模型思考'), findsNWidgets(2));
      await tester.tap(find.text('模型思考').first);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      if (!capture) return;
      await tester.runAsync(() async {
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final dir = Directory('../../scratch/model-thinking')
          ..createSync(recursive: true);
        await File('${dir.path}/model-thinking-${dark ? 'dark' : 'light'}.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    });
  }
}
