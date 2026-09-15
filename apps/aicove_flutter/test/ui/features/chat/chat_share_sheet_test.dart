import 'dart:io';
import 'dart:ui' as ui;

import 'package:aicove_flutter/src/core/models/message_block.dart';
import 'package:aicove_flutter/src/features/chat/application/chat_forward_messages.dart';
import 'package:aicove_flutter/src/features/chat/conversation_providers.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/presentation/widgets/message_bubble.dart';
import 'package:aicove_flutter/src/features/chat/presentation/widgets/chat_record_bubble.dart';
import 'package:aicove_flutter/src/ui/features/chat/widgets/chat_share_sheet.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/index.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../tool/chat_segmented_fixture.dart';

class _Contacts extends ConversationsNotifier {
  _Contacts({this.count = 4});
  final int count;
  @override
  Future<List<Conversation>> build() async => [
    for (final name in List.generate(
      count,
      (i) => i < 4 ? ['小林', '小夏', '阿宁', '小白'][i] : '联系人$i',
    ))
      Conversation(
        id: name,
        title: name,
        displayName: name,
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      ),
  ];
}

const previewDir = String.fromEnvironment('SHARE_PREVIEW_DIR');
Future<void> capture(WidgetTester tester, String name) async {
  if (previewDir.isEmpty) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('capture')),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    await File(
      '$previewDir/$name.png',
    ).writeAsBytes(data!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  setUpAll(() async {
    if (previewDir.isEmpty) return;
    for (final entry in {
      'SharePreview': '/System/Library/Fonts/STHeiti Medium.ttc',
      'MaterialIcons':
          '${Platform.environment['FLUTTER_ROOT']}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    }.entries) {
      final loader = FontLoader(entry.key);
      loader.addFont(
        File(entry.value).readAsBytes().then(ByteData.sublistView),
      );
      await loader.load();
    }
  });

  for (final width in [390.0, 1000.0]) {
    testWidgets('分享随联系人收缩、多选、留言与空留言、键盘 $width', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 800);
      addTearDown(tester.view.reset);
      final sends = <String, String>{};
      var export = false;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [conversationsProvider.overrideWith(_Contacts.new)],
          child: RepaintBoundary(
            key: const ValueKey('capture'),
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: ThemeData(
                fontFamily: previewDir.isEmpty ? null : 'SharePreview',
                extensions: [MoeColors.light()],
              ),
              home: Scaffold(
                body: Builder(
                  builder: (context) => Center(
                    child: TextButton(
                      onPressed: () => showMoeBottomSheet<String>(
                        context: context,
                        title: '分享',
                        maxHeight: 680,
                        builder: (context) => ChatShareSheet(
                          onExport: () {
                            export = true;
                            Navigator.pop(context);
                          },
                          onSend: (id, note) async => sends[id] = note,
                        ),
                      ),
                      child: const Text('打开分享'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开分享'));
      await tester.pumpAndSettle();
      expect(tester.getRect(find.byType(MoeBottomSheet)).height, lessThan(260));
      await tester.tap(find.byKey(const ValueKey('share-contact-小林')));
      await tester.tap(find.byKey(const ValueKey('share-contact-小夏')));
      await tester.pumpAndSettle();
      await capture(tester, 'share-${width.toInt()}');
      expect(find.byType(TextField), findsNothing);
      final exportRect = tester.getRect(find.text('导出为图片'));
      final shareRect = tester.getRect(find.text('直接分享'));
      expect(exportRect.top, shareRect.top);
      expect(exportRect.left, lessThan(shareRect.left));
      expect(exportRect.bottom, greaterThan(720));
      final lastContact = tester.getRect(find.text('小白'));
      expect(exportRect.top - lastContact.bottom, lessThan(32));
      expect(sends, isEmpty);
      await tester.tap(find.text('直接分享'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('share-note-dialog')), findsOneWidget);
      await tester.enterText(find.byType(TextField), '暂时不发送');
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(sends, isEmpty);
      expect(find.byType(ChatShareSheet), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      await tester.tap(find.text('直接分享'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '');
      await tester.tap(find.text('发送'));
      await tester.pumpAndSettle();
      expect(sends, {'小林': '', '小夏': ''});
      await tester.tap(find.text('打开分享'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('share-contact-阿宁')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('直接分享'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).textAlign,
        TextAlign.center,
      );
      expect(
        tester.widget<TextField>(find.byType(TextField)).textAlignVertical,
        TextAlignVertical.center,
      );
      await tester.enterText(find.byType(TextField), '你怎么看？');
      await tester.pumpAndSettle();
      final editable = tester
          .state<EditableTextState>(find.byType(EditableText))
          .renderEditable;
      final caret = editable.getLocalRectForCaret(
        const TextPosition(offset: 5),
      );
      final caretBottom = editable.localToGlobal(caret.bottomCenter).dy;
      final inputRect = tester.getRect(find.byType(InputDecorator));
      expect(
        inputRect.bottom - caretBottom,
        inInclusiveRange(0, 12),
        reason: '文字下方紧贴输入横线，不能保留空白行',
      );
      expect(inputRect.height, lessThan(50));
      await capture(tester, 'note-${width.toInt()}');
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('发送'));
      await tester.tap(find.text('发送'));
      await tester.pumpAndSettle();
      expect(sends['阿宁'], '你怎么看？');
      tester.view.viewInsets = const FakeViewPadding();
      await tester.tap(find.text('打开分享'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('导出为图片'));
      await tester.pumpAndSettle();
      expect(export, isTrue);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('联系人按实际行数增高，空列表收缩，超高仅滚动联系人', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 800);
    addTearDown(tester.view.reset);
    final heights = <int, double>{};
    for (final count in [0, 1, 4, 5, 8, 9, 40]) {
      await tester.pumpWidget(
        ProviderScope(
          key: ValueKey(count),
          overrides: [
            conversationsProvider.overrideWith(() => _Contacts(count: count)),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  child: const Text('打开'),
                  onPressed: () => showMoeBottomSheet<String>(
                    context: context,
                    title: '分享',
                    maxHeight: 680,
                    builder: (_) => ChatShareSheet(
                      onExport: () {},
                      onSend: (_, __) async {},
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      heights[count] = tester.getSize(find.byType(MoeBottomSheet)).height;
      if (count == 40) {
        final buttonBefore = tester.getRect(find.text('直接分享'));
        await tester.drag(find.byType(GridView), const Offset(0, -600));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('share-contact-联系人39')).hitTestable(),
          findsOneWidget,
        );
        expect(tester.getRect(find.text('直接分享')), buttonBefore);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    }
    expect(heights[0], lessThan(heights[1]!));
    expect(heights[1], heights[4]);
    expect(heights[5], heights[8]);
    expect(heights[5]! - heights[4]!, closeTo(95, 0.1));
    expect(heights[9]! - heights[8]!, closeTo(95, 0.1));
    expect(heights[40], 680);
  });

  testWidgets('聊天记录集合以单个卡片显示，点击可查看原记录', (tester) async {
    final fixture = (await tester.runAsync(
      () => SegmentedChatFixture.create(historyCount: 0),
    ))!;
    final message = buildForwardedChatMessage(
      sourceTitle: '小林',
      note: '你怎么看？',
      messages: [
        Message(
          id: 'one',
          role: 'user',
          content: '今天有点累。',
          createdAt: DateTime(2026),
        ),
        Message(
          id: 'two',
          role: 'assistant',
          content: '一起出去走走吧。',
          createdAt: DateTime(2026),
        ),
      ],
    ).copyWith(status: 'sent');
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: fixture.container,
        child: RepaintBoundary(
          key: const ValueKey('capture'),
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData(
              fontFamily: previewDir.isEmpty ? null : 'SharePreview',
              extensions: [MoeColors.light()],
            ),
            home: Scaffold(
              body: Center(child: MessageBubble(isMe: true, message: message)),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(ChatRecordBubble), findsOneWidget);
    expect(find.text('你怎么看？'), findsOneWidget);
    await capture(tester, 'record-bubble');
    await tester.tap(
      find.byKey(ValueKey('chat-record-${message.blocks!.first.id}')),
    );
    await tester.pumpAndSettle();
    expect(find.byType(ChatRecordPage), findsOneWidget);
    expect(find.text('一起出去走走吧。'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(fixture.dispose);
  });

  test('集合序列化保留原消息，所有文本上下文带来源，留言可空', () {
    final message = buildForwardedChatMessage(
      sourceTitle: '小林',
      note: '',
      messages: [
        Message(
          id: 'one',
          role: 'assistant',
          content: '原始内容',
          createdAt: DateTime(2026),
          blocks: [TextBlock(messageId: 'one', content: '原始内容')],
        ),
      ],
    );
    final restored =
        MessageBlock.fromJson(message.blocks!.single.toJson())
            as ChatRecordBlock;
    expect(restored.entries.single.blocks.single.id, isNot('one'));
    expect(restored.entries.single.text, '原始内容');
    expect(restored.content, contains('用户与「小林」的聊天记录'));
    expect(message.toHistoryJsonList().toString(), contains('原始内容'));
    final legacy = Map<String, dynamic>.of(restored.toJson())
      ..remove('chatRecord');
    expect(MessageBlock.fromJson(legacy), isA<TextBlock>());
    expect(
      (MessageBlock.fromJson(legacy) as TextBlock).content,
      restored.content,
    );
  });
}
