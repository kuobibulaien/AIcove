import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/features/chat/presentation/widgets/incremental_message_text.dart';

void main() {
  const style = TextStyle(fontSize: 14, height: 1.42);
  for (final width in <double>[200, 880]) {
    for (final scale in <double>[1, 1.4]) {
      testWidgets('分段缓存与原 Text 尺寸相同：width=$width scale=$scale', (tester) async {
        tester.view.physicalSize = const Size(2000, 2400);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        for (final text in [
          '第一段\n第二段',
          '\n第一段\n\n第二段\n',
          'Windows\r\n换行\r\n',
          '中文混合 English שלום العربية\n继续下一段',
          '${List.filled(70, '长段落自动折行。').join()}\n短尾段',
        ]) {
          await tester.pumpWidget(MaterialApp(
              home: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(scale)),
            child: SingleChildScrollView(
                child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                    width: width,
                    child: Align(
                        alignment: Alignment.topLeft,
                        child: Text(text,
                            key: const ValueKey('original'), style: style))),
                SizedBox(
                    width: width,
                    child: Align(
                        alignment: Alignment.topLeft,
                        child: IncrementalMessageText(text,
                            key: const ValueKey('incremental'), style: style))),
              ],
            )),
          )));
          final original =
              tester.getSize(find.byKey(const ValueKey('original')));
          final incremental =
              tester.getSize(find.byKey(const ValueKey('incremental')));
          expect(incremental.height, closeTo(original.height, 0.5),
              reason: text);
          expect(incremental.width, closeTo(original.width, 0.5), reason: text);
        }
      });
    }
  }

  testWidgets('追加末段复用已完成段落，样式和替换文本仍正常刷新', (tester) async {
    Future<void> pump(String text, [TextStyle value = style]) =>
        tester.pumpWidget(
            MaterialApp(home: IncrementalMessageText(text, style: value)));
    await pump('已完成段落\n尾');
    final prefix = tester.widget<Text>(find.text('已完成段落'));
    final render = tester.renderObject<RenderParagraph>(find.text('已完成段落'));
    await pump('已完成段落\n尾段继续增长');
    expect(identical(tester.widget(find.text('已完成段落')), prefix), isTrue);
    expect(identical(tester.renderObject(find.text('已完成段落')), render), isTrue);
    await pump('已完成段落\n尾段继续增长', style.copyWith(fontSize: 18));
    expect(tester.widget<Text>(find.text('已完成段落')).style!.fontSize, 18);
    await pump('替换后的内容');
    expect(find.text('已完成段落'), findsNothing);
    expect(find.text('替换后的内容'), findsOneWidget);
  });

  testWidgets('读屏仍按一整条消息读取，不拆成多个语义节点', (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(const MaterialApp(
        home: IncrementalMessageText('第一段\n第二段', style: style)));
    expect(find.bySemanticsLabel('第一段\n第二段'), findsOneWidget);
    expect(find.bySemanticsLabel('第一段'), findsNothing);
    semantics.dispose();
  });
}
