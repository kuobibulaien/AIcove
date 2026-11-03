import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/ui/features/settings/pages/provider_detail_page.dart';
import 'package:aicove_flutter/src/ui/features/settings/widgets/model_row_tile.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';

void main() {
  setUpAll(() async {
    if (!const bool.fromEnvironment('WRITE_MODEL_REMARK_PREVIEW')) return;
    for (final entry in {
      'Preview': '/System/Library/Fonts/STHeiti Medium.ttc',
      'monospace': '/System/Library/Fonts/STHeiti Medium.ttc',
      'packages/cupertino_icons/CupertinoIcons':
          'build/unit_test_assets/packages/cupertino_icons/assets/CupertinoIcons.ttf',
      'MaterialIcons':
          '${Platform.environment['FLUTTER_ROOT']}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    }.entries) {
      final file = File(entry.value);
      if (!file.existsSync()) continue;
      final loader = FontLoader(entry.key);
      loader.addFont(file.readAsBytes().then(ByteData.sublistView));
      await loader.load();
    }
  });

  for (final width in [360.0, 1000.0]) {
    testWidgets(
        'model form saves while open and closing flushes the latest alias $width',
        (tester) async {
      SharedPreferences.setMockInitialValues({
        'aicove.ui_models.v1': jsonEncode({
          'providers': [
            {
              'id': 'openai',
              'displayName': 'Test',
              'enabled': true,
              'apiKeys': <String>[],
              'apiBaseUrl': 'https://example.invalid/v1',
              'models': ['test-model'],
              'visible_models': ['test-model'],
              'capabilities': ['chat']
            }
          ],
        })
      });
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(const ProviderScope(
          child: MaterialApp(
              home: Scaffold(
                  body: ModelRowTile(
                      providerId: 'openai',
                      model: 'test-model',
                      displayName: null)))));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.edit_outlined));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'first alias');
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      expect(find.text('编辑模型'), findsOneWidget);
      final first = ProviderContainer();
      addTearDown(first.dispose);
      expect(
          (await first.read(appSettingsProvider.future))
              .getModelDisplayName('openai:test-model'),
          'first alias');
      await tester.enterText(find.byType(TextField).first, 'final alias');
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
      final fresh = ProviderContainer();
      addTearDown(fresh.dispose);
      expect(
          (await fresh.read(appSettingsProvider.future))
              .getModelDisplayName('openai:test-model'),
          'final alias');
      expect(find.text('编辑模型'), findsNothing);

      // Reopening the edit dialog must prefill the saved remark name.
      await tester.tap(find.byIcon(Icons.edit_outlined));
      await tester.pumpAndSettle();
      final remarkField = tester.widget<TextField>(find.byType(TextField).first);
      expect(remarkField.controller?.text, 'final alias');
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
      'ProviderDetailPage displays saved model remark name and prefills edit dialog',
      (tester) async {
    debugClearProviderDetailWarmCache();
    SharedPreferences.setMockInitialValues({
      'aicove.ui_models.v1': jsonEncode({
        'providers': [
          {
            'id': 'openai',
            'displayName': 'OpenAI',
            'enabled': true,
            'apiKeys': <String>['sk-test'],
            'apiBaseUrl': 'https://example.invalid/v1',
            'models': ['gpt-4o'],
            'visible_models': ['gpt-4o'],
            'capabilities': ['chat']
          }
        ],
        'model_display_names': {
          'openai:gpt-4o': '主力写作模型',
        },
      })
    });
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final boundaryKey = GlobalKey();
    final theme = ThemeData(
      brightness: Brightness.light,
      fontFamily: const bool.fromEnvironment('WRITE_MODEL_REMARK_PREVIEW')
          ? 'Preview'
          : null,
      extensions: [MoeColors.light()],
    );

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme,
          builder: (context, child) =>
              RepaintBoundary(key: boundaryKey, child: child!),
          home: const ProviderDetailPage(providerId: 'openai'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Switch to the models tab on ProviderDetailPage.
    await tester.tap(find.text('模型'));
    await tester.pumpAndSettle();

    expect(find.text('主力写作模型'), findsOneWidget);
    expect(find.text('gpt-4o'), findsNothing);

    if (const bool.fromEnvironment('WRITE_MODEL_REMARK_PREVIEW')) {
      await tester.runAsync(() async {
        final boundary = boundaryKey.currentContext!.findRenderObject()!
            as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 2);
        final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
        final outFile = File('../../scratch/model-remark-preview/model_list.png');
        await outFile.parent.create(recursive: true);
        await outFile.writeAsBytes(byteData!.buffer.asUint8List());
        image.dispose();
      });
    }

    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();

    final remarkField = tester.widget<TextField>(find.byType(TextField).first);
    expect(remarkField.controller?.text, '主力写作模型');

    if (const bool.fromEnvironment('WRITE_MODEL_REMARK_PREVIEW')) {
      await tester.runAsync(() async {
        final boundary = boundaryKey.currentContext!.findRenderObject()!
            as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 2);
        final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
        final outFile = File('../../scratch/model-remark-preview/edit_sheet.png');
        await outFile.parent.create(recursive: true);
        await outFile.writeAsBytes(byteData!.buffer.asUint8List());
        image.dispose();
      });
    }
  });
}
