import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/features/chat/presentation/widgets/message_action_sheet.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';

void main() {
  for (final type in MediaType.values) {
    final label = type == MediaType.image ? '重新生成图片' : '重新生成语音';
    for (final width in [360.0, 1000.0]) {
      for (final scale in [1.0, 1.8]) {
        testWidgets('$label 菜单 ${width}px ${scale}x', (tester) async {
          tester.view.physicalSize = Size(width, 800);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          MessageAction? selected;
          await tester.pumpWidget(MaterialApp(
              theme: ThemeData(extensions: [MoeColors.light()]),
              builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(textScaler: TextScaler.linear(scale)),
                  child: child!),
              home: Scaffold(
                  body: Center(
                      child: Builder(
                          builder: (context) => GestureDetector(
                              onLongPress: () => showMediaActionMenu(context,
                                      targetBox: context.findRenderObject()!
                                          as RenderBox,
                                      mediaType: type,
                                      allowDelete: true,
                                      allowRegenerate: true,
                                      onAction: (action) {
                                    selected = action;
                                  }),
                              child: const SizedBox(
                                  width: 160,
                                  height: 160,
                                  child: ColoredBox(
                                      color: Colors.pink,
                                      child: Text('图片')))))))));
          await tester.longPress(find.text('图片'));
          await tester.pumpAndSettle();
          expect(find.text(label), findsOneWidget);
          expect(tester.takeException(), isNull);
          final paragraph =
              tester.renderObject<RenderParagraph>(find.text(label));
          // Both the horizontal menu and the desktop menu must keep one line
          // at large text scale; absolute font height is not the line count.
          final lines = paragraph.getBoxesForSelection(
              TextSelection(baseOffset: 0, extentOffset: label.length));
          expect(lines.map((box) => box.top).toSet(), hasLength(1));
          expect(find.text(label).hitTestable(), findsOneWidget);
          await tester.tap(find.text(label));
          await tester.pumpAndSettle();
          expect(selected, MessageAction.regenerateMedia);
        });
      }
    }
  }
  for (final type in MediaType.values) {
    testWidgets('普通媒体不显示重画 $type', (tester) async {
      await tester.pumpWidget(MaterialApp(
          theme: ThemeData(extensions: [MoeColors.light()]),
          home: Scaffold(
              body: Center(
                  child: Builder(
                      builder: (context) => TextButton(
                          onPressed: () => showMediaActionMenu(context,
                              targetBox:
                                  context.findRenderObject()! as RenderBox,
                              mediaType: type,
                              allowRegenerate: false,
                              onAction: (_) {}),
                          child: const Text('菜单')))))));
      await tester.tap(find.text('菜单'));
      await tester.pumpAndSettle();
      expect(find.text('重新生成图片'), findsNothing);
      expect(find.text('重新生成语音'), findsNothing);
      await tester.tapAt(const Offset(1, 1));
      await tester.pumpAndSettle();
    });
  }
}
