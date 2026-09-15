import 'dart:io';
import 'dart:ui' as ui;

import 'package:aicove_flutter/src/ui/shared/widgets/moe_search_field.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUpAll(() async {
    if (!const bool.fromEnvironment('WRITE_SEARCH_QA')) return;
    final font = FontLoader('SearchCapture');
    font.addFont(
      File(
        '/System/Library/Fonts/STHeiti Medium.ttc',
      ).readAsBytes().then(ByteData.sublistView),
    );
    await font.load();
    final icons = FontLoader('MaterialIcons');
    icons.addFont(
      File(
        "${Platform.environment['FLUTTER_ROOT']}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf",
      ).readAsBytes().then(ByteData.sublistView),
    );
    await icons.load();
  });
  for (final width in [320.0, 360.0, 440.0, 1000.0]) {
    for (final dark in [false, true]) {
      for (final scale in [1.0, 1.8]) {
        testWidgets('search motion and clear $width dark=$dark scale=$scale', (
          tester,
        ) async {
          await tester.binding.setSurfaceSize(Size(width, 200));
          addTearDown(() => tester.binding.setSurfaceSize(null));
          final controller = TextEditingController();
          addTearDown(controller.dispose);
          final changes = <String>[];
          final capture = GlobalKey();
          await tester.pumpWidget(
            MaterialApp(
              theme: ThemeData(
                fontFamily: const bool.fromEnvironment('WRITE_SEARCH_QA')
                    ? 'SearchCapture'
                    : null,
                brightness: dark ? Brightness.dark : Brightness.light,
                extensions: [dark ? MoeColors.dark() : MoeColors.light()],
              ),
              home: MediaQuery(
                data: MediaQueryData(textScaler: TextScaler.linear(scale)),
                child: Scaffold(
                  body: RepaintBoundary(
                    key: capture,
                    child: MoeSearchField(
                      controller: controller,
                      onChanged: changes.add,
                    ),
                  ),
                ),
              ),
            ),
          );
          final icon = find.byIcon(Icons.search_rounded);
          final idleX = tester.getTopLeft(icon).dx;
          Future<void> snapshot(String state) async {
            if (!const bool.fromEnvironment('WRITE_SEARCH_QA') ||
                width != 360 ||
                scale != 1) {
              return;
            }
            final boundary =
                capture.currentContext!.findRenderObject()
                    as RenderRepaintBoundary;
            await tester.runAsync(() async {
              final image = await boundary.toImage(pixelRatio: 2);
              final bytes = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              final file = File(
                '../../scratch/search-unification/qa/${dark ? 'dark' : 'light'}-$state.png',
              );
              await file.parent.create(recursive: true);
              await file.writeAsBytes(bytes!.buffer.asUint8List());
              image.dispose();
            });
          }

          await snapshot('idle');
          await tester.tap(find.byType(TextField));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 110));
          final middleX = tester.getTopLeft(icon).dx;
          expect(middleX, lessThan(idleX));
          expect(middleX, greaterThan(26));
          await snapshot('moving');
          await tester.pumpAndSettle();
          expect(tester.getTopLeft(icon).dx, closeTo(26, 0.1));
          final nativeHint = find.descendant(
            of: find.byType(InputDecorator),
            matching: find.text('搜索'),
          );
          final hint = tester.widget<Text>(nativeHint);
          expect(
            hint.style!.color!.a,
            greaterThan(0),
            reason:
                'The input must paint its own hint so caret and hint share layout.',
          );
          final editable = tester
              .state<EditableTextState>(find.byType(EditableText))
              .renderEditable;
          final hintOrigin = tester.getTopLeft(nativeHint);
          expect(
            hintOrigin.dx,
            closeTo(editable.localToGlobal(Offset.zero).dx, 0.1),
          );
          await snapshot('focused');
          await tester.enterText(find.byType(TextField), '角色');
          await tester.pump();
          expect(changes.last, '角色');
          await tester.tap(find.byTooltip('清除搜索'));
          await tester.pumpAndSettle();
          expect(controller.text, isEmpty);
          expect(changes.last, '');
          expect(
            tester
                .widget<TextField>(find.byType(TextField))
                .focusNode!
                .hasFocus,
            isTrue,
          );
          await tester.tap(find.byTooltip('取消搜索'));
          await tester.pumpAndSettle();
          expect(tester.getTopLeft(icon).dx, closeTo(idleX, 0.1));
          controller.text = '外部搜索';
          await tester.pumpAndSettle();
          expect(tester.getTopLeft(icon).dx, closeTo(26, 0.1));
          expect(tester.takeException(), isNull);
        });
      }
    }
  }
}
