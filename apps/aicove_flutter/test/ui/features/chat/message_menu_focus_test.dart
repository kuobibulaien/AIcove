import 'package:aicove_flutter/src/features/chat/presentation/widgets/message_action_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final width in [360.0, 1000.0]) {
    for (final mediaType in [null, ...MediaType.values]) {
      for (final dismissal in ['outside', 'back', 'escape']) {
        testWidgets(
          'message menu keeps dismissed keyboard closed: $width $mediaType $dismissal',
          (tester) async {
            final focus = FocusNode();
            final controller = TextEditingController(text: '未发送的草稿');
            addTearDown(focus.dispose);
            addTearDown(controller.dispose);
            await tester.binding.setSurfaceSize(Size(width, 800));
            addTearDown(() => tester.binding.setSurfaceSize(null));
            await _pumpChat(tester, focus, controller, mediaType: mediaType);
            await tester.tap(find.byType(TextField));
            await tester.pump();
            expect(focus.hasFocus, isTrue);
            // Android back can hide the IME without clearing Flutter focus.
            tester.testTextInput.hide();
            expect(tester.testTextInput.isVisible, isFalse);
            tester.testTextInput.log.clear();

            await tester.longPress(find.text('消息'));
            await tester.pumpAndSettle();
            expect(find.text('多选'), findsOneWidget);
            expect(focus.hasFocus, isFalse);
            switch (dismissal) {
              case 'outside':
                // The barrier must consume a dismissal over the input too.
                await tester.tapAt(tester.getCenter(find.byType(TextField)));
              case 'back':
                await tester.binding.handlePopRoute();
              case 'escape':
                await tester.sendKeyEvent(LogicalKeyboardKey.escape);
            }
            await tester.pumpAndSettle();
            expect(find.text('多选'), findsNothing);
            expect(focus.hasFocus, isFalse);
            expect(tester.testTextInput.isVisible, isFalse);
            expect(
              tester.testTextInput.log.where(
                (call) => call.method == 'TextInput.show',
              ),
              isEmpty,
            );
            expect(controller.text, '未发送的草稿');
            await tester.tap(find.byType(TextField));
            await tester.pump();
            expect(focus.hasFocus, isTrue);
            expect(tester.testTextInput.isVisible, isTrue);
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox());
          },
        );
      }
    }
  }

  for (final allowSelect in [false, true]) {
    for (final mediaType in [null, ...MediaType.values]) {
      testWidgets('regenerate is second: $mediaType select=$allowSelect', (
        tester,
      ) async {
        final focus = FocusNode();
        final controller = TextEditingController();
        addTearDown(focus.dispose);
        addTearDown(controller.dispose);
        MessageAction? selected;
        await _pumpChat(
          tester,
          focus,
          controller,
          mediaType: mediaType,
          allowSelect: allowSelect,
          onAction: (action) => selected = action,
        );
        await tester.longPress(find.text('消息'));
        await tester.pumpAndSettle();
        final labels = tester
            .widgetList<Text>(
              find.descendant(
                of: find.byType(TextButton),
                matching: find.byType(Text),
              ),
            )
            .map((text) => text.data)
            .toList();
        final expectedLabel = switch (mediaType) {
          null => '重新生成',
          MediaType.image => '重新生成图片',
          MediaType.audio => '重新生成语音',
        };
        expect(labels[1], expectedLabel);
        await tester.tap(find.text(expectedLabel));
        await tester.pumpAndSettle();
        expect(
          selected,
          mediaType == null
              ? MessageAction.regenerate
              : MessageAction.regenerateMedia,
        );
        expect(focus.hasFocus, isFalse);
        await tester.pumpWidget(const SizedBox());
      });
    }
  }

  testWidgets('menu action can explicitly focus the editor after closing', (
    tester,
  ) async {
    final focus = FocusNode();
    final controller = TextEditingController(text: '草稿');
    addTearDown(focus.dispose);
    addTearDown(controller.dispose);
    await _pumpChat(
      tester,
      focus,
      controller,
      onAction: (action) {
        if (action == MessageAction.quote) focus.requestFocus();
      },
    );
    await tester.tap(find.byType(TextField));
    await tester.pump();
    await tester.longPress(find.text('消息'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('引用'));
    await tester.pumpAndSettle();
    expect(focus.hasFocus, isTrue);
    expect(tester.testTextInput.isVisible, isTrue);
    expect(controller.text, '草稿');
    await tester.pumpWidget(const SizedBox());
  });
}

Future<void> _pumpChat(
  WidgetTester tester,
  FocusNode focus,
  TextEditingController controller, {
  MediaType? mediaType,
  bool allowSelect = true,
  ValueChanged<MessageAction>? onAction,
}) => tester.pumpWidget(
  MaterialApp(
    theme: ThemeData(platform: TargetPlatform.android),
    home: Builder(
      builder: (context) => Scaffold(
        body: Column(
          children: [
            Expanded(
              child: Center(
                child: Builder(
                  builder: (context) => GestureDetector(
                    onLongPress: () {
                      final box = context.findRenderObject()! as RenderBox;
                      if (mediaType == null) {
                        showMessageActionMenu(
                          context,
                          targetBox: box,
                          isUserMessage: false,
                          messageText: '消息',
                          allowSelect: allowSelect,
                          onAction: onAction ?? (_) {},
                        );
                      } else {
                        showMediaActionMenu(
                          context,
                          targetBox: box,
                          mediaType: mediaType,
                          allowSelect: allowSelect,
                          allowRegenerate: true,
                          onAction: onAction ?? (_) {},
                        );
                      }
                    },
                    child: const Text('消息'),
                  ),
                ),
              ),
            ),
            TextField(focusNode: focus, controller: controller),
          ],
        ),
      ),
    ),
  ),
);
