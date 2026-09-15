import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/form/moe_text_field.dart';
import 'package:flutter/material.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/form/moe_input_decoration.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final brightness in Brightness.values) {
    testWidgets('custom field does not inherit a second fill $brightness', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            brightness: brightness,
            inputDecorationTheme: const InputDecorationTheme(
              filled: true,
              fillColor: Colors.red,
            ),
          ),
          home: const Scaffold(
            body: RepaintBoundary(
              key: ValueKey('capture'),
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    MoeTextField(hint: 'Name'),
                    TextField(
                      decoration: MoeInputDecoration(hintText: 'Inline field'),
                    ),
                    TextField(
                      decoration: InputDecoration(
                        hintText: 'Standard filled field',
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      final decoration = tester
          .widget<InputDecorator>(find.byType(InputDecorator).first)
          .decoration;
      expect(decoration.filled, isFalse);
      await tester.enterText(find.byType(TextField).first, 'Edited');
      await tester.pump();
      expect(find.text('Edited'), findsOneWidget);
      expect(
        tester
            .widget<InputDecorator>(find.byType(InputDecorator).at(1))
            .decoration
            .filled,
        isFalse,
      );
      expect(
        tester
            .widget<InputDecorator>(find.byType(InputDecorator).at(2))
            .decoration
            .filled,
        isTrue,
      );
      await tester.pumpAndSettle();
      if (const bool.fromEnvironment('WRITE_INPUT_QA')) {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const ValueKey('capture')),
        );
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 2);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File(
            '../../scratch/input-fill-fix/${brightness.name}.png',
          );
          await file.writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      expect(tester.takeException(), isNull);
    });
  }
}
