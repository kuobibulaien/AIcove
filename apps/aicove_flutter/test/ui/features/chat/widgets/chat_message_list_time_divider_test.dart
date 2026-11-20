import 'dart:io';
import 'dart:ui' as ui;

import 'package:aicove_flutter/src/core/utils/message_formatter.dart';
import 'package:aicove_flutter/src/features/chat/domain/chat_display_policy.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/presentation/widgets/message_bubble.dart';
import 'package:aicove_flutter/src/ui/features/chat/widgets/chat_message_list.dart';
import 'package:aicove_flutter/src/ui/features/chat/widgets/chat_message_list_items.dart';
import 'package:aicove_flutter/src/ui/features/chat/widgets/chat_viewport_controller.dart';
import 'package:aicove_flutter/src/ui/theme/skin_provider.dart';
import 'package:aicove_flutter/src/ui/theme/skins/moetalk_skin.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../../tool/chat_segmented_fixture.dart';

Message _message(String id, DateTime createdAt) => Message.text(
  id: id,
  role: 'assistant',
  content: '你好',
  createdAt: createdAt,
);

void main() {
  final messages = [
    _message('a', DateTime(2026, 10, 21, 9)),
    _message('b', DateTime(2026, 10, 21, 9, 3)),
    _message('c', DateTime(2026, 10, 21, 10)),
  ];
  const config = MessageFormatConfig(enableChunking: false);

  test('time dividers follow the time awareness plugin switch', () {
    final shown = buildChatMessageListItems(messages: messages, config: config);
    expect(shown.whereType<ChatTimeDividerItem>(), hasLength(2));

    final hidden = buildChatMessageListItems(
      messages: messages,
      config: config,
      showTimeDividers: false,
    );
    expect(hidden.whereType<ChatTimeDividerItem>(), isEmpty);
  });

  test('a long gap still shows the avatar when dividers are hidden', () {
    final hidden = buildChatMessageListItems(
      messages: messages,
      config: config,
      showTimeDividers: false,
    );
    final avatars = {
      for (final item in hidden.whereType<ChatMessageItem>())
        item.message.id: item.showAvatar,
    };
    expect(avatars, {'a': true, 'b': false, 'c': true});
  });

  for (final showTimeDividers in [true, false]) {
    test('a 4m59s gap stays grouped: dividers=$showTimeDividers', () {
      final first = _message('a', DateTime(2026, 10, 21, 9));
      final second = _message(
        'b',
        first.createdAt.add(const Duration(minutes: 4, seconds: 59)),
      );
      final items = buildChatMessageListItems(
        messages: [first, second],
        config: config,
        showTimeDividers: showTimeDividers,
      );
      final dividers = items.whereType<ChatTimeDividerItem>().toList();
      expect(dividers, hasLength(showTimeDividers ? 1 : 0));
      if (showTimeDividers) {
        expect(items.first, same(dividers.single));
        expect(dividers.single.associatedMessageId, first.id);
        expect(dividers.single.time, first.createdAt);
      }
      expect(
        items.whereType<ChatMessageItem>().map((item) => item.showAvatar),
        [true, false],
      );
    });

    test('an exact 5m gap starts a group: dividers=$showTimeDividers', () {
      final first = _message('a', DateTime(2026, 10, 21, 9));
      final second = _message(
        'b',
        first.createdAt.add(const Duration(minutes: 5)),
      );
      final items = buildChatMessageListItems(
        messages: [first, second],
        config: config,
        showTimeDividers: showTimeDividers,
      );
      final dividers = items.whereType<ChatTimeDividerItem>().toList();
      expect(dividers, hasLength(showTimeDividers ? 2 : 0));
      if (showTimeDividers) {
        expect(dividers.map((item) => item.associatedMessageId), ['a', 'b']);
        expect(dividers.map((item) => item.time), [
          first.createdAt,
          second.createdAt,
        ]);
        expect(items[0], same(dividers[0]));
        expect((items[1] as ChatMessageItem).message.id, 'a');
        expect(items[2], same(dividers[1]));
        expect((items[3] as ChatMessageItem).message.id, 'b');
      }
      expect(
        items.whereType<ChatMessageItem>().map((item) => item.showAvatar),
        [true, true],
      );
    });
  }

  testWidgets('5 minute time divider source preview', (tester) async {
    const capture = bool.fromEnvironment('WRITE_TIME_DIVIDER_PREVIEW');
    tester.view.physicalSize = const Size(390 * 2, 640 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    if (capture) {
      await tester.runAsync(() async {
        final font = FontLoader('Preview')
          ..addFont(
            File(
              '/System/Library/Fonts/STHeiti Medium.ttc',
            ).readAsBytes().then(ByteData.sublistView),
          );
        await font.load();
        final icons = FontLoader('MaterialIcons')
          ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
        await icons.load();
      });
    }

    final now = DateTime.now();
    final start = DateTime(now.year, now.month, now.day, 16);
    final previewMessages = [
      Message.text(
        id: 'preview_1600',
        role: 'assistant',
        content: '下午好，刚泡了一杯茶。',
        createdAt: start,
      ),
      Message.text(
        id: 'preview_1602',
        role: 'assistant',
        content: '16:02，才过两分钟，接着聊。',
        createdAt: start.add(const Duration(minutes: 2)),
      ),
      Message.text(
        id: 'preview_1607',
        role: 'assistant',
        content: '16:07，隔了五分钟，我又回来啦。',
        createdAt: start.add(const Duration(minutes: 7)),
      ),
    ];
    final fixture = (await tester.runAsync(
      () => SegmentedChatFixture.create(
        historyMessages: previewMessages,
        settings: segmentedProbeSettings.copyWith(
          messageChunkingEnabled: false,
          messageFormatConfig: config,
          singleAvatarPerTurn: true,
        ),
      ),
    ))!;
    final viewport = ChatViewportController();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(fixture.dispose);
      viewport.dispose();
    });
    final key = GlobalKey();
    final colors = MoeColors.light();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: fixture.container,
        child: SkinScope(
          skin: const MoeTalkSkin(),
          child: MaterialApp(
            theme: ThemeData(
              fontFamily: capture ? 'Preview' : null,
              extensions: [colors],
            ),
            home: RepaintBoundary(
              key: key,
              child: Scaffold(
                backgroundColor: colors.bgMain,
                appBar: AppBar(
                  title: const Text('聊天'),
                  centerTitle: true,
                  backgroundColor: colors.bgMain,
                  surfaceTintColor: Colors.transparent,
                ),
                body: ChatMessageList(
                  conversationId: fixture.conversation.id,
                  messages: previewMessages,
                  displayName: 'AIcove酱',
                  avatarUrl: 'assets/characters/images/aicove_assistant.png',
                  viewportController: viewport,
                  chatDisplayStyle: ChatDisplayStyle.bubble,
                  hasMoreMessages: false,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      final context = tester.element(find.byType(ChatMessageList));
      for (final image in tester.widgetList<Image>(find.byType(Image))) {
        await precacheImage(image.image, context);
      }
    });
    await tester.pumpAndSettle();
    expect(find.text('16:00'), findsOneWidget);
    expect(find.text('16:02'), findsNothing);
    expect(find.text('16:07'), findsOneWidget);
    final bubbles = tester.widgetList<MessageBubble>(
      find.byType(MessageBubble),
    );
    expect(
      {for (final bubble in bubbles) bubble.message.id: bubble.showAvatar},
      {'preview_1600': true, 'preview_1602': false, 'preview_1607': true},
    );
    expect(find.byType(Image), findsNWidgets(2));
    expect(
      tester
          .widgetList<RawImage>(find.byType(RawImage))
          .map((image) => image.image),
      everyElement(isNotNull),
    );
    expect(tester.takeException(), isNull);
    if (!capture) return;
    await tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 2);
      try {
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File('../../scratch/time-divider-5min/preview.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes!.buffer.asUint8List());
      } finally {
        image.dispose();
      }
    });
  });
}
