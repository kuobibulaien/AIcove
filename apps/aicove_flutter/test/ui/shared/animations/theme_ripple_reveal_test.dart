import 'dart:io';
import 'dart:ui' as ui;

import 'package:aicove_flutter/src/ui/shared/animations/theme_ripple_reveal.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

class _Demo extends StatefulWidget {
  const _Demo();

  @override
  State<_Demo> createState() => _DemoState();
}

class _DemoState extends State<_Demo> {
  ThemeMode mode = ThemeMode.system;

  @override
  Widget build(BuildContext context) {
    return ThemeRippleReveal(
      themeMode: mode,
      builder: (context, effectiveMode) => MaterialApp(
        themeMode: effectiveMode,
        theme: ThemeData.light(),
        darkTheme: ThemeData.dark(),
        themeAnimationDuration: Duration.zero,
        home: Scaffold(
          body: Column(
            children: [
              const SizedBox(height: 120),
              ListTile(
                title: const Text('dark'),
                trailing: Switch(
                  key: const Key('dark-switch'),
                  value: effectiveMode == ThemeMode.dark,
                  onChanged: (value) => setState(
                    () => mode = value ? ThemeMode.dark : ThemeMode.light,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Brightness _shownBrightness(WidgetTester tester) =>
    Theme.of(tester.element(find.byType(Scaffold))).brightness;

Future<void> _savePreview(WidgetTester tester, GlobalKey key, String name) =>
    tester.runAsync(() async {
      final dir = Platform.environment['RIPPLE_PREVIEW_DIR'];
      if (dir == null) return;
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      File('$dir/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
    });

/// Lets the snapshot (real async) finish, then plays the ripple to the end.
Future<void> _finish(WidgetTester tester) async {
  await tester.pumpAndSettle();
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pump();
}

Future<void> _settleSnapshot(WidgetTester tester) async {
  await tester.runAsync(() => Future<void>.delayed(
        const Duration(milliseconds: 50),
      ));
  await tester.pump();
}

void main() {
  late GlobalKey previewKey;
  int overlays(WidgetTester tester) =>
      tester.widgetList(find.byType(IgnorePointer)).length;

  setUp(() => previewKey = GlobalKey());

  testWidgets('manual toggle ripples and switches theme', (tester) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    await tester.pumpWidget(
      RepaintBoundary(key: previewKey, child: const _Demo()),
    );
    final idle = overlays(tester);

    await tester.tap(find.byKey(const Key('dark-switch')));
    await tester.pump();
    await _settleSnapshot(tester);
    expect(overlays(tester), idle + 1);
    await tester.pump(ThemeRippleReveal.duration * 0.45);
    await _savePreview(tester, previewKey, 'ripple_tap');

    await _finish(tester);
    expect(_shownBrightness(tester), Brightness.dark);
    expect(overlays(tester), idle);
  });

  testWidgets('system brightness change ripples without a tap',
      (tester) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    await tester.pumpWidget(
      RepaintBoundary(key: previewKey, child: const _Demo()),
    );
    final idle = overlays(tester);
    expect(_shownBrightness(tester), Brightness.light);

    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    await tester.pump();
    await _settleSnapshot(tester);
    expect(overlays(tester), idle + 1);
    await tester.pump(ThemeRippleReveal.duration * 0.45);
    await _savePreview(tester, previewKey, 'ripple_system');

    await _finish(tester);
    expect(_shownBrightness(tester), Brightness.dark);
    expect(overlays(tester), idle);
  });
}
