import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/ui/features/settings/widgets/model_row_tile.dart';

void main() {
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
      expect(tester.takeException(), isNull);
    });
  }
}
