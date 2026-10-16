import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/ui/features/settings/pages/ui_settings_page.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/index.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';

void main() {
  testWidgets('three material choices persist and preserve blur strength', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(420, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    SharedPreferences.setMockInitialValues({
      'aicove.ui_models.v1': jsonEncode({
        'glass_effect_enabled': true,
        'use_liquid_glass': false,
        'glass_blur_sigma': 16.0,
      }),
    });
    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: UiSettingsPage())),
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(UiSettingsPage)),
    );
    await container.read(appSettingsProvider.future);
    await tester.pumpAndSettle();
    for (final choice in ['纯色', '模糊', '玻璃', '纯色']) {
      await Scrollable.ensureVisible(
        tester.element(find.text(choice)),
        alignment: 0.5,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(choice));
      await tester.pumpAndSettle();
      final state = container.read(appSettingsProvider).requireValue;
      expect(state.glassEffectEnabled, choice != '纯色');
      expect(state.useLiquidGlass, choice == '玻璃');
      expect(state.glassBlurSigma, 16);
      for (final key in ['material-blur-slider', 'material-tint-slider']) {
        expect(
          find.byKey(ValueKey(key)),
          choice == '纯色' ? findsNothing : findsOneWidget,
        );
      }
      expect(
        find.text('此项极耗费性能，容易引起发热和卡顿。手机端日用推荐模糊或纯色。'),
        choice == '玻璃' ? findsOneWidget : findsNothing,
      );
      expect(tester.takeException(), isNull);
    }
    final fresh = ProviderContainer();
    addTearDown(fresh.dispose);
    final restored = await fresh.read(appSettingsProvider.future);
    expect(restored.glassEffectEnabled, isFalse);
    expect(restored.glassBlurSigma, 16);
    await Scrollable.ensureVisible(
      tester.element(find.text('玻璃')),
      alignment: 0.5,
    );
    await tester.tap(find.text('玻璃'));
    await tester.pumpAndSettle();
    final slider = find.byKey(const ValueKey('material-blur-slider'));
    expect(slider, findsOneWidget);
    expect(tester.widget<MoeSlider>(slider).min, 0);
    for (final value in [0.0, 60.0, 100.0]) {
      tester.widget<MoeSlider>(slider).onChanged!(value);
      await tester.pumpAndSettle();
      expect(
        container.read(appSettingsProvider).requireValue.glassBlurSigma,
        moreOrLessEquals(value / 100 * kMaxGlassBlurSigma, epsilon: 1e-9),
      );
      expect(tester.widget<MoeSlider>(slider).value, value);
    }
    final thicknessRestored = ProviderContainer();
    addTearDown(thicknessRestored.dispose);
    expect(
      (await thicknessRestored.read(appSettingsProvider.future)).glassBlurSigma,
      32,
    );
    final notifier = container.read(appSettingsProvider.notifier);
    await Future.wait([
      notifier.setSurfaceMaterial(MoeSurfaceMaterial.solid),
      notifier.setSurfaceMaterial(MoeSurfaceMaterial.liquid),
      notifier.setSurfaceMaterial(MoeSurfaceMaterial.frosted),
    ]);
    final finalContainer = ProviderContainer();
    addTearDown(finalContainer.dispose);
    final finalSettings = await finalContainer.read(appSettingsProvider.future);
    expect(finalSettings.surfaceMaterial, MoeSurfaceMaterial.frosted);
  });

  testWidgets('blur and tint sliders are independent under frosted', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(420, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    SharedPreferences.setMockInitialValues({
      'aicove.ui_models.v1': jsonEncode({
        'glass_effect_enabled': true,
        'use_liquid_glass': false,
        'glass_blur_sigma': 16.0,
      }),
    });
    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: UiSettingsPage())),
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(UiSettingsPage)),
    );
    await container.read(appSettingsProvider.future);
    await tester.pumpAndSettle();
    final slider = find.byKey(const ValueKey('material-blur-slider'));
    final tint = find.byKey(const ValueKey('material-tint-slider'));
    expect(slider, findsOneWidget);
    final widget = tester.widget<MoeSlider>(slider);
    expect(widget.min, 0, reason: '模糊度可拉到零');
    expect(widget.max, 100);
    expect(widget.divisions, isNull);
    expect(widget.value, 50);
    expect(widget.label, '50%');
    expect(widget.semanticFormatterCallback!(42), '模糊度 42%');
    expect(find.text('模糊度'), findsOneWidget);
    expect(find.text('底色填充'), findsOneWidget);
    // Without a stored fill, the tint keeps the value the blur implied.
    expect(tester.widget<MoeSlider>(tint).value, 50);
    expect(tester.widget<MoeSlider>(tint).min, 0, reason: '模糊底色可拉到零');
    expect(
      tester.widget<MoeSlider>(tint).semanticFormatterCallback!(30),
      '底色填充 30%',
    );
    for (final entry in {10.0: 3.2, 55.0: 17.6, 100.0: 32.0}.entries) {
      tester.widget<MoeSlider>(slider).onChanged!(entry.key);
      await tester.pumpAndSettle();
      expect(
        container.read(appSettingsProvider).requireValue.frostedBlurSigma,
        moreOrLessEquals(entry.value, epsilon: 1e-9),
      );
      expect(
        tester.widget<MoeSlider>(slider).value,
        moreOrLessEquals(entry.key, epsilon: 1e-9),
      );
    }
    final persisted = ProviderContainer();
    addTearDown(persisted.dispose);
    expect(
      (await persisted.read(appSettingsProvider.future)).frostedBlurSigma,
      32,
    );
    expect(tester.widget<MoeSlider>(tint).value, 50, reason: '模糊不带动底色');
    tester.widget<MoeSlider>(tint).onChanged!(20);
    await tester.pumpAndSettle();
    final afterTint = container.read(appSettingsProvider).requireValue;
    expect(afterTint.frostedTintFill, moreOrLessEquals(0.2, epsilon: 1e-9));
    expect(afterTint.glassTintFill, 0.5, reason: '模糊材质底色不带动玻璃');
    expect(afterTint.frostedBlurSigma, 32, reason: '底色不带动模糊');
    expect(afterTint.glassBlurSigma, 16, reason: '模糊材质不带动玻璃');
    final tintPersisted = ProviderContainer();
    addTearDown(tintPersisted.dispose);
    expect(
      (await tintPersisted.read(appSettingsProvider.future)).frostedTintFill,
      moreOrLessEquals(0.2, epsilon: 1e-9),
    );
    await tester.drag(slider, const Offset(-1000, 0));
    await tester.pumpAndSettle();
    expect(tester.widget<MoeSlider>(slider).value, 0);
    expect(
      container.read(appSettingsProvider).requireValue.frostedBlurSigma,
      0,
    );
    await tester.drag(slider, const Offset(2000, 0));
    await tester.pumpAndSettle();
    expect(tester.widget<MoeSlider>(slider).value, 100);
    expect(
      container.read(appSettingsProvider).requireValue.frostedBlurSigma,
      32,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('frosted and glass keep separate blur and fill settings', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(420, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    SharedPreferences.setMockInitialValues({
      'aicove.ui_models.v1': jsonEncode({
        'glass_effect_enabled': true,
        'use_liquid_glass': true,
        'glass_blur_sigma': 0.0,
      }),
    });
    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: UiSettingsPage())),
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(UiSettingsPage)),
    );
    AppSettings read() => container.read(appSettingsProvider).requireValue;
    await container.read(appSettingsProvider.future);
    await tester.pumpAndSettle();
    final slider = find.byKey(const ValueKey('material-blur-slider'));
    final tint = find.byKey(const ValueKey('material-tint-slider'));
    expect(tester.widget<MoeSlider>(slider).value, 0);
    expect(tester.widget<MoeSlider>(slider).min, 0);
    // The legacy fill follows the old shared blur: zero.
    expect(tester.widget<MoeSlider>(tint).value, 0);
    await Scrollable.ensureVisible(
      tester.element(find.text('模糊')),
      alignment: 0.5,
    );
    await tester.tap(find.text('模糊'));
    await tester.pumpAndSettle();
    // A store from before the split inherits the shared value, zero included.
    expect(tester.widget<MoeSlider>(slider).value, 0);
    expect(tester.widget<MoeSlider>(slider).min, 0);
    tester.widget<MoeSlider>(slider).onChanged!(75);
    await tester.pumpAndSettle();
    expect(read().frostedBlurSigma, 24);
    expect(read().glassBlurSigma, 0, reason: '模糊材质不带动玻璃');
    tester.widget<MoeSlider>(tint).onChanged!(60);
    await tester.pumpAndSettle();
    expect(read().frostedTintFill, moreOrLessEquals(0.6, epsilon: 1e-9));
    expect(read().glassTintFill, 0, reason: '模糊材质底色不带动玻璃');
    await tester.tap(find.text('玻璃'));
    await tester.pumpAndSettle();
    expect(tester.widget<MoeSlider>(slider).value, 0);
    expect(tester.widget<MoeSlider>(tint).value, 0);
    tester.widget<MoeSlider>(slider).onChanged!(25);
    await tester.pumpAndSettle();
    expect(read().glassBlurSigma, 8);
    expect(read().frostedBlurSigma, 24, reason: '玻璃不带动模糊材质');
    tester.widget<MoeSlider>(tint).onChanged!(30);
    await tester.pumpAndSettle();
    expect(read().glassTintFill, moreOrLessEquals(0.3, epsilon: 1e-9));
    expect(
      read().frostedTintFill,
      moreOrLessEquals(0.6, epsilon: 1e-9),
      reason: '玻璃底色不带动模糊材质',
    );
    await tester.tap(find.text('模糊'));
    await tester.pumpAndSettle();
    expect(tester.widget<MoeSlider>(slider).value, 75);
    expect(
      tester.widget<MoeSlider>(tint).value,
      moreOrLessEquals(60, epsilon: 1e-9),
    );
    final fresh = ProviderContainer();
    addTearDown(fresh.dispose);
    final restored = await fresh.read(appSettingsProvider.future);
    expect(restored.frostedBlurSigma, 24);
    expect(restored.glassBlurSigma, 8);
    expect(restored.frostedTintFill, moreOrLessEquals(0.6, epsilon: 1e-9));
    expect(restored.glassTintFill, moreOrLessEquals(0.3, epsilon: 1e-9));
    expect(tester.takeException(), isNull);
  });
}
