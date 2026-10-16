import 'dart:io';
import 'dart:ui' as ui;

import 'package:aicove_flutter/src/ui/features/settings/widgets/fish_audio_provider_notice.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/index.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const capture = bool.fromEnvironment('WRITE_FISH_NOTICE_PREVIEW');
  setUpAll(() async {
    if (!capture) return;
    final font = FontLoader('FishNoticePreview')
      ..addFont(
        File(
          '/System/Library/Fonts/STHeiti Medium.ttc',
        ).readAsBytes().then(ByteData.sublistView),
      );
    await font.load();
  });

  Future<GlobalKey> pump(
    WidgetTester tester, {
    required TextEditingController controller,
    required DateTime now,
    bool showKeyLink = true,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 420);
    addTearDown(tester.view.reset);
    final boundaryKey = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          scaffoldBackgroundColor: moeSurface,
          fontFamily: capture ? 'FishNoticePreview' : null,
          extensions: [MoeColors.light()],
        ),
        builder: (context, child) =>
            RepaintBoundary(key: boundaryKey, child: child!),
        home: Scaffold(
          body: Column(
            children: [
              const SizedBox(height: 24),
              MoeSettingsGroup(
                margin: const EdgeInsets.symmetric(horizontal: 16),
                title: '基础配置',
                children: [
                  MoeSettingsRow(
                    label: 'API Key',
                    trailingType: MoeSettingsRowTrailing.custom,
                    expandTrailing: true,
                    trailing: TextField(
                      controller: controller,
                      textAlign: TextAlign.end,
                    ),
                  ),
                  FishAudioProviderNotice(
                    keyController: controller,
                    showKeyLink: showKeyLink,
                    now: now,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    return boundaryKey;
  }

  testWidgets('empty key shows the link, typing a key hides it', (
    tester,
  ) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    final key = await pump(
      tester,
      controller: controller,
      now: DateTime(2026, 10, 14),
    );
    expect(find.text('获取 API key'), findsOneWidget);
    expect(find.text(kFishAudioFreeNoticeText), findsOneWidget);
    if (capture) await _capture(tester, key, 'empty_key');

    controller.text = 'sk-test';
    await tester.pump();
    expect(find.text('获取 API key'), findsNothing);
    expect(find.text(kFishAudioFreeNoticeText), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('free notice disappears from 2026-12-01', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await pump(
      tester,
      controller: controller,
      now: DateTime(2026, 11, 30, 23, 59),
    );
    expect(find.text(kFishAudioFreeNoticeText), findsOneWidget);

    await pump(tester, controller: controller, now: DateTime(2026, 12, 1));
    expect(find.text(kFishAudioFreeNoticeText), findsNothing);
    expect(find.text('获取 API key'), findsOneWidget);
  });

  testWidgets('multi-key mode hides the link', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await pump(
      tester,
      controller: controller,
      now: DateTime(2026, 10, 14),
      showKeyLink: false,
    );
    expect(find.text('获取 API key'), findsNothing);
  });
}

Future<void> _capture(WidgetTester tester, GlobalKey key, String name) =>
    tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('../../scratch/fish-notice-20261014/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
