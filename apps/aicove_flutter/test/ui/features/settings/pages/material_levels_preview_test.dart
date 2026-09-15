import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/ui/features/settings/pages/ui_settings_page.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/form/moe_slider.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const capture = bool.fromEnvironment('WRITE_MATERIAL_QA');
  setUpAll(() async {
    if (!capture) return;
    final font = FontLoader('MaterialPreview')
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
  });

  testWidgets('material settings widths, themes and large text', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    for (final width in [360.0, 420.0, 1000.0, 1280.0]) {
      for (final dark in [false, true]) {
        for (final scale in [1.0, 1.8]) {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = Size(width, 820);
          SharedPreferences.setMockInitialValues({
            'aicove.ui_models.v1': jsonEncode({
              'glass_effect_enabled': true,
              'use_liquid_glass': true,
              'glass_blur_sigma': 19.0,
            }),
          });
          final key = GlobalKey();
          await tester.pumpWidget(
            ProviderScope(
              key: UniqueKey(),
              child: MaterialApp(
                theme: ThemeData(
                  colorScheme: ColorScheme.fromSeed(
                    seedColor: dark ? moeAccentDark : const Color(0xFFFC96AA),
                    primary: dark ? moeAccentDark : const Color(0xFFFC96AA),
                    brightness: dark ? Brightness.dark : Brightness.light,
                    surface: dark ? moeSurfaceDark : moeSurface,
                    onSurface: dark ? moeTextDark : moeText,
                  ),
                  scaffoldBackgroundColor: dark ? moeSurfaceDark : moeSurface,
                  fontFamily: capture ? 'MaterialPreview' : null,
                  extensions: [dark ? MoeColors.dark() : MoeColors.light()],
                ),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(scale)),
                  child: RepaintBoundary(key: key, child: child!),
                ),
                home: const _ThemedSettings(),
              ),
            ),
          );
          final container = ProviderScope.containerOf(
            tester.element(find.byType(UiSettingsPage)),
          );
          await container.read(appSettingsProvider.future);
          await tester.pumpAndSettle();
          await Scrollable.ensureVisible(
            tester.element(find.text('材质等级')),
            alignment: 0.03,
          );
          await tester.pumpAndSettle();
          final slider = find.byKey(const ValueKey('glass-thickness-slider'));
          expect(tester.widget<MoeSlider>(slider).value, 19);
          expect(
            container.read(appSettingsProvider).requireValue.glassBlurSigma,
            19,
            reason: 'Reading old settings must not rewrite persisted data',
          );
          for (final label in ['纯色', '模糊', '玻璃', '通透', '中等', '厚重']) {
            expect(find.text(label), findsOneWidget);
          }
          expect(tester.takeException(), isNull);
          if (capture && scale == 1 && width == 420) {
            await tester.runAsync(() async {
              final boundary = key.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
              final image = await boundary.toImage(pixelRatio: 1.5);
              final bytes = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              final file = File(
                '../../.codex-temp/material-levels/${dark ? 'dark' : 'light'}-settings.png',
              );
              await file.parent.create(recursive: true);
              await file.writeAsBytes(bytes!.buffer.asUint8List());
              image.dispose();
            });
          }
        }
      }
    }
  });

  testWidgets('frosted blur settings widths, themes and large text', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    for (final width in [360.0, 420.0, 1000.0, 1280.0]) {
      for (final dark in [false, true]) {
        for (final scale in [1.0, 1.8]) {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = Size(width, 820);
          SharedPreferences.setMockInitialValues({
            'aicove.ui_models.v1': jsonEncode({
              'glass_effect_enabled': true,
              'use_liquid_glass': false,
              'glass_blur_sigma': 19.0,
            }),
          });
          final key = GlobalKey();
          await tester.pumpWidget(
            ProviderScope(
              key: UniqueKey(),
              child: MaterialApp(
                theme: ThemeData(
                  colorScheme: ColorScheme.fromSeed(
                    seedColor: dark ? moeAccentDark : const Color(0xFFFC96AA),
                    primary: dark ? moeAccentDark : const Color(0xFFFC96AA),
                    brightness: dark ? Brightness.dark : Brightness.light,
                    surface: dark ? moeSurfaceDark : moeSurface,
                    onSurface: dark ? moeTextDark : moeText,
                  ),
                  scaffoldBackgroundColor: dark ? moeSurfaceDark : moeSurface,
                  fontFamily: capture ? 'MaterialPreview' : null,
                  extensions: [dark ? MoeColors.dark() : MoeColors.light()],
                ),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(scale)),
                  child: RepaintBoundary(key: key, child: child!),
                ),
                home: const _ThemedSettings(),
              ),
            ),
          );
          final container = ProviderScope.containerOf(
            tester.element(find.byType(UiSettingsPage)),
          );
          await container.read(appSettingsProvider.future);
          await tester.pumpAndSettle();
          await Scrollable.ensureVisible(
            tester.element(find.text('材质等级')),
            alignment: 0.03,
          );
          await tester.pumpAndSettle();
          final slider = find.byKey(const ValueKey('frosted-blur-slider'));
          expect(slider, findsOneWidget);
          expect(
            find.byKey(const ValueKey('glass-thickness-slider')),
            findsNothing,
          );
          final widget = tester.widget<MoeSlider>(slider);
          expect(widget.min, 10);
          expect(widget.max, 100);
          expect(widget.divisions, isNull, reason: '模糊度为 10..100 连续滑条');
          expect(widget.value, moreOrLessEquals(59.375, epsilon: 1e-6));
          for (final label in ['纯色', '模糊', '玻璃', '模糊度', '59%', '10%', '100%']) {
            expect(find.text(label), findsOneWidget);
          }
          for (final label in ['通透', '中等', '厚重']) {
            expect(find.text(label), findsNothing);
          }
          expect(
            container.read(appSettingsProvider).requireValue.glassBlurSigma,
            19,
            reason: '模糊显示沿用旧强度存储，读取不回写',
          );
          expect(tester.takeException(), isNull);
          if (capture && scale == 1 && width == 420) {
            await tester.runAsync(() async {
              final boundary = key.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
              final image = await boundary.toImage(pixelRatio: 1.5);
              final bytes = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              final file = File(
                '../../.codex-temp/material-levels/frosted-${dark ? 'dark' : 'light'}-settings.png',
              );
              await file.parent.create(recursive: true);
              await file.writeAsBytes(bytes!.buffer.asUint8List());
              image.dispose();
            });
          }
        }
      }
    }
  });
}

class _ThemedSettings extends ConsumerWidget {
  const _ThemedSettings();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(appSettingsProvider).value;
    return MoeGlassTheme(
      enabled: settings?.glassEffectEnabled ?? true,
      useLiquidGlass: settings?.useLiquidGlass ?? true,
      blurSigma: settings?.glassBlurSigma ?? 16,
      child: const UiSettingsPage(),
    );
  }
}
