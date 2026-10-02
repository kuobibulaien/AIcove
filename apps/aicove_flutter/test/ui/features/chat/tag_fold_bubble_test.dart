import 'package:aicove_flutter/src/core/models/message_block.dart';
import 'package:aicove_flutter/src/core/utils/message_formatter.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/presentation/widgets/message_bubble.dart';
import 'package:aicove_flutter/src/features/content_tags/domain/tag_presentation.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/ui/features/chat/widgets/chat_message_list_items.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/moe_collapsible_bubble.dart';
import 'package:aicove_flutter/src/ui/theme/skin_provider.dart';
import 'package:aicove_flutter/src/ui/theme/skins/moetalk_skin.dart';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const TagPresentationMap _map = {
  'think_nya~': TagPresentationEntry(TagPresentation.fold, '思考'),
  'zw': TagPresentationEntry(TagPresentation.body, '正文'),
};

Message _assistant(String id, String text, {String? status}) => Message.text(
      id: id,
      role: 'assistant',
      content: text,
      createdAt: DateTime(2026, 9, 29),
    ).copyWith(status: status);

class _FakeAppSettingsNotifier extends AppSettingsNotifier {
  @override
  Future<AppSettings> build() async => AppSettings(
        ttsEnabled: false,
        defaultModelName: 'm',
        defaultPersonaPrompt: '',
        modelList: const ['m'],
        allKnownModels: const ['m'],
        modelDisplayNames: const {},
        modelTypes: const {},
        modelConfigs: const {},
        apiKey: '',
        apiBaseUrl: '',
        imageGenerationEnabled: false,
        maxFileUploadMB: 10,
        contextWindowTokens: 1000,
        customModels: const [],
        providers: const [],
        modelProviderMap: const {},
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
        hideUserAvatar: false,
      );
}

void main() {
  test('mapped fold tags become fold chunks and body tags are unwrapped', () {
    final items = buildChatMessageListItems(
      messages: [
        _assistant('a1', '<think_nya~>想一想</think_nya~>\n<zw>她笑了。</zw>'),
        _assistant('a2', '没有标签的回复'),
      ],
      tagPresentation: _map,
    );
    final chunks = items.whereType<ChatChunkedMessageItem>().toList();
    expect(chunks, hasLength(2));
    expect(chunks[0].fold?.title, '思考');
    expect(chunks[0].fold?.content, '想一想');
    expect(chunks[0].showAvatar, isTrue);
    expect(chunks[1].fold, isNull);
    expect(chunks[1].chunkText, '她笑了。');
    expect(chunks[1].showAvatar, isFalse);
    expect(
      items.whereType<ChatMessageItem>().single.message.id,
      'a2',
    );
  });

  test('streaming reply shows an unfinished fold', () {
    final items = buildChatMessageListItems(
      messages: [_assistant('a1', '<think_nya~>还在想', status: 'sending')],
      tagPresentation: _map,
    );
    final fold = items.whereType<ChatChunkedMessageItem>().single.fold!;
    expect(fold.closed, isFalse);
    expect(fold.content, '还在想');
  });

  test('finished replies unwrap a sole unknown body wrapper, streaming does not',
      () {
    const text = '<think_nya~>想</think_nya~><game>她笑了，推开门走进雨里。</game>';
    final done = buildChatMessageListItems(
      messages: [_assistant('a1', text)],
      tagPresentation: _map,
    ).whereType<ChatChunkedMessageItem>().toList();
    expect(done.map((c) => c.fold == null ? c.chunkText : 'fold'),
        ['fold', '她笑了，推开门走进雨里。']);

    final streaming = buildChatMessageListItems(
      messages: [_assistant('a1', text, status: 'sending')],
      tagPresentation: _map,
    ).whereType<ChatChunkedMessageItem>().toList();
    expect(streaming.last.chunkText, '<game>她笑了，推开门走进雨里。</game>');
  });

  test('unknown reply tags are collected for the tag page, role echoes are not',
      () {
    expect(
      collectUnknownReplyTags([
        _assistant('a1', '<game>正文</game><user>回显</user>'),
        _assistant('a2', '<think_nya~>想</think_nya~>\n```\n<code1>x</code1>\n```'),
        _assistant('a3', '<ztl>状态</ztl>', status: 'sending'),
      ], _map),
      {'game'},
    );
  });

  testWidgets('a thinking block renders as a standalone collapsible bubble',
      (tester) async {
    final message = Message(
      id: 'c1',
      role: 'assistant',
      content: '想一想',
      blocks: [
        ThinkingBlock(messageId: 'c1', content: '想一想', title: '思考'),
      ],
      createdAt: DateTime(2026, 9, 29),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appSettingsProvider.overrideWith(_FakeAppSettingsNotifier.new),
        ],
        child: SkinScope(
          skin: const MoeTalkSkin(),
          child: MaterialApp(
            home: Scaffold(
              body: MessageBubble(isMe: false, message: message),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(MoeCollapsibleBubble), findsOneWidget);
    expect(find.byKey(const ValueKey('message_bubble_c1')), findsNothing);
    expect(find.text('思考'), findsOneWidget);
    expect(find.text('想一想'), findsNothing);

    await tester.tap(find.byType(MoeCollapsibleBubble));
    await tester.pumpAndSettle();
    expect(find.text('想一想'), findsOneWidget);
  });

  // 源码渲染预览：--dart-define=WRITE_TAG_FOLD_PREVIEW=true 时写到 scratch/tag-fold/。
  const capture = bool.fromEnvironment('WRITE_TAG_FOLD_PREVIEW');
  for (final width in [360.0, 1000.0]) {
    testWidgets('fold bubble preview $width', (tester) async {
      if (!capture) return;
      tester.view.physicalSize = Size(width * 2, 1240);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.runAsync(() async {
        final loader = FontLoader('Preview');
        loader.addFont(
          File('/System/Library/Fonts/STHeiti Medium.ttc')
              .readAsBytes()
              .then(ByteData.sublistView),
        );
        await loader.load();
        final icons = FontLoader('MaterialIcons');
        icons.addFont(
          File(
            '${Platform.environment['HOME']}/dev-sdks/flutter-3.44.6/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
          ).readAsBytes().then(ByteData.sublistView),
        );
        await icons.load();
      });
      final items = buildChatMessageListItems(
        messages: [
          Message.text(
            id: 'u1',
            role: 'user',
            content: '早上好，今天去哪玩？',
            createdAt: DateTime(2026, 9, 29, 9),
          ),
          _assistant(
            'a1',
            '<think_nya~>她刚睡醒，语气要软一点；先回应问候，再给两个出门的提议。</think_nya~>\n'
                '<zw>“早呀～”她揉了揉眼睛，把窗帘拉开一条缝。\n“去河边走走好不好？”</zw>\n'
                '<details><summary>状态栏</summary>心情：愉快\n体力：80%</details>',
          ),
        ],
        tagPresentation: {
          ..._map,
          'details': const TagPresentationEntry(TagPresentation.fold, '详情'),
        },
      );
      final key = GlobalKey();
      Widget bubbleFor(ChatMessageListItem item) {
        if (item is ChatMessageItem) {
          return MessageBubble(
            isMe: item.message.role == 'user',
            message: item.message,
            showAvatar: item.showAvatar,
          );
        }
        final chunk = item as ChatChunkedMessageItem;
        final id = '${chunk.originalMessage.id}_chunk_${chunk.chunkIndex}';
        final fold = chunk.fold;
        return MessageBubble(
          isMe: false,
          showAvatar: chunk.showAvatar,
          showCorner: chunk.showCorner,
          message: Message(
            id: id,
            role: 'assistant',
            content: chunk.chunkText,
            blocks: fold == null
                ? null
                : [
                    ThinkingBlock(
                      messageId: id,
                      content: fold.content,
                      title: fold.title,
                    ),
                  ],
            createdAt: DateTime(2026, 9, 29, 9),
          ),
        );
      }

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appSettingsProvider.overrideWith(_FakeAppSettingsNotifier.new),
          ],
          child: SkinScope(
            skin: const MoeTalkSkin(),
            child: MaterialApp(
              theme: ThemeData(fontFamily: 'Preview'),
              home: RepaintBoundary(
                key: key,
                child: Scaffold(
                  body: ListView(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    children: [
                      for (final item in items.where(
                        (item) =>
                            item is ChatMessageItem ||
                            item is ChatChunkedMessageItem,
                      ))
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 3),
                          child: bubbleFor(item),
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
      // 展开最后一个折叠气泡（状态栏），另一个保持收起。
      await tester.tap(find.byType(MoeCollapsibleBubble).last);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final dir = Directory('../../scratch/tag-fold')
          ..createSync(recursive: true);
        await File('${dir.path}/fold-bubbles-${width.toInt()}.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    });
  }
}
