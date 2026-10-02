import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/ui/features/settings/pages/collapsible_selectable_text.dart';
import '../../../../helpers/release_source_preview.dart';

void main() {
  for (final scale in [1.2, 1.8]) {
    testWidgets(
      'collapsed text offers expansion when scaled line exceeds width scale=$scale',
      (tester) async {
        const content = 'abcdefghij';
        const style = TextStyle(fontSize: 14);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: MediaQuery(
                data: MediaQueryData(textScaler: TextScaler.linear(scale)),
                child: const Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    width: 200,
                    child: CollapsibleSelectableText(
                      content: content,
                      style: style,
                      collapsedLines: 1,
                      toggleColor: Colors.blue,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        final measure = TextPainter(
          text: const TextSpan(text: content, style: style),
          textDirection: TextDirection.ltr,
          textScaler: TextScaler.linear(scale),
          maxLines: 1,
        )..layout(maxWidth: 200);
        addTearDown(measure.dispose);
        expect(measure.didExceedMaxLines, scale == 1.8);
        expect(tester.takeException(), isNull);
        expect(find.text('展开更多'), scale == 1.8 ? findsOneWidget : findsNothing);
      },
    );
  }

  testWidgets('existing collapsed text reacts to text scaling changes', (
    tester,
  ) async {
    Future<void> render(double scale) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(scale)),
            child: const Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 200,
                child: CollapsibleSelectableText(
                  content: 'abcdefghij',
                  style: TextStyle(fontSize: 14),
                  collapsedLines: 1,
                  toggleColor: Colors.blue,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await render(1.2);
    expect(find.text('展开更多'), findsNothing);
    await render(1.8);
    expect(find.text('展开更多'), findsOneWidget);
    await tester.tap(find.text('展开更多'));
    await tester.pump();
    expect(find.text('收起'), findsOneWidget);
    expect(
      tester.widget<SelectableText>(find.byType(SelectableText)).maxLines,
      isNull,
    );
    await tester.tap(find.text('收起'));
    await tester.pump();
    expect(
      tester.widget<SelectableText>(find.byType(SelectableText)).maxLines,
      1,
    );
    await render(1.2);
    expect(find.text('展开更多'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final width in [360.0, 1000.0]) {
    testWidgets('scaled content can expand and collapse width=$width', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 560);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await loadReleasePreviewFonts(tester);
      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData(
              fontFamily: captureReleaseSourcePreview ? 'ReleasePreview' : null,
            ),
            home: Scaffold(
              appBar: AppBar(title: const Text('大字号文本展开')),
              body: MediaQuery(
                data: const MediaQueryData(textScaler: TextScaler.linear(1.8)),
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: SizedBox(
                      width: width < 900 ? 200 : 400,
                      child: const CollapsibleSelectableText(
                        content: '文字放大以后，完整内容仍然可以通过展开按钮阅读，收起后保留原来的显示位置。',
                        style: TextStyle(fontSize: 14),
                        collapsedLines: 1,
                        toggleColor: Colors.blue,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('展开更多'), findsOneWidget);
      await saveReleaseSourcePreview(
        tester,
        key,
        'collapsed-text-${width.toInt()}',
      );
      await tester.tap(find.text('展开更多'));
      await tester.pumpAndSettle();
      expect(find.text('收起'), findsOneWidget);
      expect(
        tester.widget<SelectableText>(find.byType(SelectableText)).maxLines,
        isNull,
      );
      await tester.tap(find.text('收起'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<SelectableText>(find.byType(SelectableText)).maxLines,
        1,
      );
      expect(tester.takeException(), isNull);
    });
  }
}
