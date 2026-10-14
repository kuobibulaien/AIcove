import 'dart:convert';
import 'dart:ui' as ui;

import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/ui/features/wallpaper/pages/wallpaper_editor_page.dart';
import 'package:aicove_flutter/src/ui/features/wallpaper/widgets/wallpaper_preview_samples.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/index.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../chat/pages/chat_interface_test_support.dart';

/// A 200x100 PNG as a data URI, so the editor can resolve the image size.
Future<String> _landscapeImage() async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(
    const Rect.fromLTWH(0, 0, 200, 100),
    Paint()..color = const Color(0xFF88AACC),
  );
  final image = await recorder.endRecording().toImage(200, 100);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  return 'data:image/png;base64,${base64Encode(bytes!.buffer.asUint8List())}';
}

void main() {
  late String source;
  setUpAll(() async => source = await _landscapeImage());

  Future<List<WallpaperStyle>> pumpEditor(
    WidgetTester tester,
    Size size,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
    final saved = <WallpaperStyle>[];
    await tester.pumpWidget(
      chatInterfaceTestScope(
        conversation: Conversation(
          id: 'wallpaper_editor',
          title: 'Test',
          displayName: 'Test',
          createdAt: DateTime(2026, 10, 14),
          updatedAt: DateTime(2026, 10, 14),
        ),
        child: MaterialApp(
          theme: ThemeData(extensions: [MoeColors.light()]),
          home: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => WallpaperEditorPage(
                      source: source,
                      style: const WallpaperStyle(),
                      defaultStyle: const WallpaperStyle(),
                      kind: WallpaperPreviewKind.home,
                      onSave: (_, style) async => saved.add(style),
                    ),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    // Decoding the image and reading its size runs on real async work.
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    return saved;
  }

  Future<void> drag(
    WidgetTester tester,
    WallpaperLayout layout,
    Offset by,
  ) async {
    await tester.drag(
      find.byKey(ValueKey('wallpaper_preview_${layout.name}')),
      by,
      touchSlopX: 0,
      touchSlopY: 0,
    );
    await tester.pumpAndSettle();
  }

  testWidgets('wide window: framing is saved for the current layout only, '
      'the other follows until adjusted on its own', (tester) async {
    final saved = await pumpEditor(tester, const Size(1200, 900));
    expect(
      find.byKey(const ValueKey('wallpaper_preview_narrow')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('wallpaper_preview_wide')),
      findsOneWidget,
    );
    expect(find.text('宽屏（当前）'), findsOneWidget);
    expect(find.text('沿用宽屏'), findsOneWidget);

    await drag(tester, WallpaperLayout.wide, const Offset(-60, 0));
    // The narrow preview still follows the wide framing.
    expect(find.text('沿用宽屏'), findsOneWidget);

    await drag(tester, WallpaperLayout.narrow, const Offset(60, 0));
    final follow = find.byKey(const ValueKey('wallpaper_follow_narrow'));
    expect(follow, findsOneWidget);

    await tester.tap(follow);
    await tester.pumpAndSettle();
    expect(find.text('沿用宽屏'), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(saved, hasLength(1));
    final style = saved.single;
    expect(style.ownFraming(WallpaperLayout.narrow), isNull);
    final wide = style.ownFraming(WallpaperLayout.wide)!;
    // Dragging left moves the focus towards the image's right side.
    expect(wide.x, greaterThan(0));
    expect(style.framingFor(WallpaperLayout.narrow), wide);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'narrow window: tabs switch previews and zoom edits the shown one',
    (tester) async {
      final saved = await pumpEditor(tester, const Size(400, 860));
      expect(
        find.byKey(const ValueKey('wallpaper_editor_layout_tabs')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('wallpaper_preview_narrow')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('wallpaper_preview_wide')),
        findsNothing,
      );

      tester
          .widget<MoeSlider>(
            find.descendant(
              of: find.byKey(const ValueKey('wallpaper_scale_slider')),
              matching: find.byType(MoeSlider),
            ),
          )
          .onChanged!(2);
      await tester.pump();
      expect(find.text('2.0×'), findsOneWidget);

      await tester.tap(find.text('宽屏'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('wallpaper_preview_wide')),
        findsOneWidget,
      );
      // The wide layout follows the narrow zoom until changed.
      expect(find.text('2.0×'), findsOneWidget);

      await tester.pageBack();
      await tester.pumpAndSettle();
      final style = saved.single;
      expect(style.ownFraming(WallpaperLayout.narrow)?.scale, 2);
      expect(style.ownFraming(WallpaperLayout.wide), isNull);
      expect(tester.takeException(), isNull);
    },
  );
}
