// ignore_for_file: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/ui/features/settings/pages/default_model_settings_page.dart';
import 'package:aicove_flutter/src/ui/features/debug/pages/enhanced_dialogue_page.dart';
import 'package:aicove_flutter/src/ui/features/debug/pages/message_segmentation_debug_page.dart';

class _RejectingStore extends InMemorySharedPreferencesStore {
  _RejectingStore(super.data) : super.withData();
  @override
  Future<bool> setValue(String valueType, String key, Object value) async =>
      false;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test('a rejected settings write fails and does not publish the new value',
      () async {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final initial = await c.read(appSettingsProvider.future);
    final previous = SharedPreferencesStorePlatform.instance;
    final backend = _RejectingStore(await previous.getAll());
    SharedPreferencesStorePlatform.instance = backend;
    addTearDown(() => SharedPreferencesStorePlatform.instance = previous);
    await expectLater(
        c
            .read(appSettingsProvider.notifier)
            .setContextWindowTokens(initial.contextWindowTokens + 5),
        throwsStateError);
    expect(c.read(appSettingsProvider).requireValue.contextWindowTokens,
        initial.contextWindowTokens);
  });
  for (final width in [360.0, 1000.0]) {
    testWidgets(
        'context window persists without save and invalid text stays editable $width',
        (tester) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(const ProviderScope(
          child: MaterialApp(home: DefaultModelSettingsPage())));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byType(TextField));
      await tester.enterText(find.byType(TextField), '123');
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      final fresh = ProviderContainer();
      addTearDown(fresh.dispose);
      expect((await fresh.read(appSettingsProvider.future)).contextWindowTokens,
          123000);
      await tester.enterText(find.byType(TextField), '');
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      expect(find.textContaining('请输入大于 0'), findsOneWidget);
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
          '');
      expect(find.text('保存'), findsNothing);
      expect(tester.takeException(), isNull);
    });
    testWidgets(
        'enhanced prompt and segment delay persist without confirmation $width',
        (tester) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(const ProviderScope(
          child: MaterialApp(home: EnhancedDialoguePage())));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byType(TextField).first, 'new enhanced prompt');
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      final fresh = ProviderContainer();
      addTearDown(fresh.dispose);
      expect(
          (await fresh.read(appSettingsProvider.future))
              .enhancedDialogueSettings
              .systemPrompt,
          'new enhanced prompt');
      await tester.pumpWidget(const ProviderScope(
          child: MaterialApp(home: MessageSegmentationDebugPage())));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('0.5s'));
      await tester.tap(find.text('0.5s'));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      final latest = ProviderContainer();
      addTearDown(latest.dispose);
      expect(
          (await latest.read(appSettingsProvider.future))
              .streamSegmentDelaySeconds,
          .5);
      expect(find.text('保存配置'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}
