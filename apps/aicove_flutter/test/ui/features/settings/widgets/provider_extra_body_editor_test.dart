import 'dart:io';
import 'dart:ui' as ui;

import 'package:aicove_flutter/src/ui/features/settings/widgets/provider_extra_body_editor.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/index.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const capture = bool.fromEnvironment('WRITE_EXTRA_BODY_PREVIEW');
  setUpAll(() async {
    if (!capture) return;
    final font = FontLoader('ExtraBodyPreview')
      ..addFont(
        File(
          '/System/Library/Fonts/STHeiti Medium.ttc',
        ).readAsBytes().then(ByteData.sublistView),
      );
    await font.load();
    final icons = FontLoader('MaterialIcons')
      ..addFont(
        File(
          '${Platform.environment['FLUTTER_ROOT']}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
        ).readAsBytes().then(ByteData.sublistView),
      );
    await icons.load();
    final mono = FontLoader('monospace')
      ..addFont(
        File(
          '/System/Library/Fonts/Menlo.ttc',
        ).readAsBytes().then(ByteData.sublistView),
      );
    await mono.load();
  });

  testWidgets('validates JSON and returns the parsed object', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(420, 820);
    addTearDown(tester.view.reset);
    final boundaryKey = GlobalKey();
    Map<String, dynamic>? result;

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFFFC96AA),
            primary: const Color(0xFFFC96AA),
            surface: moeSurface,
            onSurface: moeText,
          ),
          scaffoldBackgroundColor: moeSurface,
          fontFamily: capture ? 'ExtraBodyPreview' : null,
          extensions: [MoeColors.light()],
        ),
        builder: (context, child) =>
            RepaintBoundary(key: boundaryKey, child: child!),
        home: Scaffold(
          body: Builder(
            builder: (context) => Column(
              children: [
                const SizedBox(height: 24),
                MoeSettingsGroup(
                  margin: const EdgeInsets.symmetric(horizontal: 16),
                  title: '高级信息',
                  children: [
                    MoeSettingsRow(
                      label: '额外请求参数',
                      detailText: 'persona',
                      trailingType: MoeSettingsRowTrailing.text,
                      onTap: () async {
                        result = await showProviderExtraBodyEditor(context, {
                          'extraBody': {'persona': 'Emily Dickinson'},
                        });
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('额外请求参数'));
    await tester.pumpAndSettle();
    final field = find.byKey(const ValueKey('provider-extra-body-json'));
    expect(
      tester.widget<TextField>(field).controller!.text,
      contains('"persona": "Emily Dickinson"'),
    );
    if (capture) await _capture(tester, boundaryKey, 'editor');

    await tester.enterText(field, '[1]');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.textContaining('需要填写 JSON 对象'), findsOneWidget);
    expect(result, isNull);

    await tester.enterText(field, '{"persona": "鲁迅"}');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(result, {'persona': '鲁迅'});
    expect(tester.takeException(), isNull);
  });
}

Future<void> _capture(WidgetTester tester, GlobalKey key, String name) =>
    tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 1.5);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('../../.codex-temp/extra-body/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
