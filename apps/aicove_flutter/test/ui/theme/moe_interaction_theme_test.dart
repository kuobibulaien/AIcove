import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:aicove_flutter/src/ui/shared/widgets/buttons/moe_icon_button.dart';
import 'package:aicove_flutter/src/ui/theme/moe_interaction_theme.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final brightness in Brightness.values) {
    for (final width in [420.0, 1280.0]) {
      testWidgets('hover leaves pixels unchanged: $brightness / $width', (
        tester,
      ) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        var taps = 0;
        var holds = 0;
        final controls = <Widget>[
          InkWell(onTap: () => taps++, child: const Text('Profile')),
          IconButton(
            tooltip: 'Details',
            onPressed: () => taps++,
            icon: const Icon(Icons.more_horiz),
          ),
          TextButton(onPressed: () {}, child: const Text('Text')),
          FilledButton(onPressed: () {}, child: const Text('Filled')),
          OutlinedButton(onPressed: () {}, child: const Text('Outlined')),
          ElevatedButton(onPressed: () {}, child: const Text('Elevated')),
          ElevatedButton(
            style: withoutHoverFeedback(
              ElevatedButton.styleFrom(
                foregroundColor: Colors.red,
                elevation: 3,
              ),
            ),
            onPressed: () {},
            child: const Text('Styled'),
          ),
          MoeIconButton(
            icon: Icons.add,
            onTap: () => taps++,
            onLongPress: () => holds++,
          ),
          Switch(value: true, onChanged: (_) {}),
          Checkbox(value: true, onChanged: (_) {}),
          Slider(
            value: 0.5,
            activeColor: Colors.red,
            overlayColor: moeInteractionOverlay,
            onChanged: (_) {},
          ),
          ActionChip(label: const Text('Chip'), onPressed: () {}),
          FloatingActionButton(onPressed: () {}, child: const Icon(Icons.add)),
        ];
        final boundary = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            theme: withMoeInteractionTheme(
              ThemeData(
                brightness: brightness,
                extensions: [
                  brightness == Brightness.dark
                      ? MoeColors.dark()
                      : MoeColors.light(),
                ],
              ),
            ),
            builder: (_, child) =>
                TooltipVisibility(visible: false, child: child!),
            home: Scaffold(
              body: RepaintBoundary(
                key: boundary,
                child: Column(
                  children: [
                    for (var i = 0; i < controls.length; i++)
                      SizedBox(
                        key: ValueKey(i),
                        height: 60,
                        child: controls[i],
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        Future<Uint8List> pixels() async => (await tester.runAsync(() async {
          final image =
              await (boundary.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary)
                  .toImage();
          final data = await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          );
          image.dispose();
          return Uint8List.fromList(data!.buffer.asUint8List());
        }))!;
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: const Offset(1, 899));
        await tester.pumpAndSettle();
        final before = await pixels();
        for (var i = 0; i < controls.length; i++) {
          await mouse.moveTo(tester.getCenter(find.byKey(ValueKey(i))));
          await tester.pumpAndSettle(const Duration(milliseconds: 100));
          expect(
            await pixels(),
            orderedEquals(before),
            reason: '${controls[i].runtimeType} changed on hover',
          );
        }
        await mouse.removePointer();
        await tester.longPress(find.byType(IconButton));
        await tester.pumpAndSettle();
        expect(find.text('Details'), findsNothing);
        taps = 0;
        await tester.tap(find.byType(IconButton));
        await tester.longPress(find.byType(MoeIconButton));
        expect(taps, 1);
        expect(holds, 1);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
