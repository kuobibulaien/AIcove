import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/features/chat/presentation/widgets/composer_more_panel.dart';

void main() {
  for (final width in [320.0, 1000.0]) {
    for (final scale in [1.2, 1.8]) {
      testWidgets('more panel labels fit width=$width scale=$scale',
          (tester) async {
        await tester.binding.setSurfaceSize(Size(width, 568));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        ComposerAction? selected;
        await tester.pumpWidget(MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: Scaffold(
              body: SizedBox(
                  height: 240,
                  child: ComposerMorePanel(
                    onAction: (action) => selected = action,
                  ))),
        ));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final label = find.text('视频');
        await tester.ensureVisible(label);
        await tester.pumpAndSettle();
        await tester.tap(label);
        expect(selected, ComposerAction.video);
        final paragraph = tester.renderObject<RenderParagraph>(label);
        final fullHeight =
            paragraph.getMaxIntrinsicHeight(paragraph.size.width);
        expect(paragraph.size.height, greaterThanOrEqualTo(fullHeight),
            reason:
                'action label line must fit its allocated height at the app text scale');
      });
    }
  }
}
