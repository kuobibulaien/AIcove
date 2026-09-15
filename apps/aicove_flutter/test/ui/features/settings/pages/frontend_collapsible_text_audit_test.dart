import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/ui/features/settings/pages/collapsible_selectable_text.dart';

void main() {
  for (final scale in [1.2, 1.8]) {
    testWidgets(
        'collapsed text offers expansion when scaled line exceeds width scale=$scale',
        (tester) async {
      const content = 'abcdefghij';
      const style = TextStyle(fontSize: 14);
      await tester.pumpWidget(MaterialApp(
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
                    toggleColor: Colors.blue),
              )),
        )),
      ));
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
    });
  }
}
