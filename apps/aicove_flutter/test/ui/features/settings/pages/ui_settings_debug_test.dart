import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/ui/features/settings/pages/ui_settings_page.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 界面设置重排：源码渲染预览生成器。
/// `flutter test --dart-define=WRITE_UI_SETTINGS_QA=true` 时输出 PNG 到
/// .codex-temp/ui-settings-redesign/。
void main() {
  const capture = bool.fromEnvironment('WRITE_UI_SETTINGS_QA');
  setUpAll(() async {
    if (!capture) return;
    final font = FontLoader('UiSettingsPreview')
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

  for (final dark in [false, true]) {
    for (final liquid in [true, false]) {
      testWidgets('render dark=$dark liquid=$liquid', (tester) async {
        addTearDown(tester.view.reset);
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(420, 1750);
        SharedPreferences.setMockInitialValues({
          'aicove.ui_models.v1': jsonEncode({
            'glass_effect_enabled': liquid,
            'use_liquid_glass': liquid,
            'glass_blur_sigma': 16.0,
          }),
        });
        final key = GlobalKey();
        await tester.pumpWidget(
          ProviderScope(
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
                fontFamily: capture ? 'UiSettingsPreview' : null,
                extensions: [dark ? MoeColors.dark() : MoeColors.light()],
              ),
              home: RepaintBoundary(key: key, child: const _ThemedSettings()),
            ),
          ),
        );
        final container = ProviderScope.containerOf(
          tester.element(find.byType(UiSettingsPage)),
        );
        // 存储链含全局串行写队列，其完成依赖真实事件循环，需 runAsync 等待。
        await tester.runAsync(
          () => container.read(appSettingsProvider.future),
        );
        // 有界 settle：帧被持续调度时尽快暴露而不是等 10 分钟超时。
        var frames = 0;
        while (tester.binding.hasScheduledFrame && frames < 600) {
          await tester.pump(const Duration(milliseconds: 16));
          frames++;
        }
        expect(frames, lessThan(600), reason: 'frames keep being scheduled');
        expect(tester.takeException(), isNull);
        if (capture) {
          await tester.runAsync(() async {
            final boundary =
                key.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            final image = await boundary.toImage(pixelRatio: 1.5);
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final file = File(
              '../../.codex-temp/ui-settings-redesign/'
              '${dark ? 'dark' : 'light'}-${liquid ? 'liquid' : 'solid'}.png',
            );
            await file.parent.create(recursive: true);
            await file.writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
      });
    }
  }
}

class _ThemedSettings extends ConsumerWidget {
  const _ThemedSettings();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(appSettingsProvider).value;
    return MoeGlassTheme(
      enabled: settings?.glassEffectEnabled ?? false,
      useLiquidGlass: settings?.useLiquidGlass ?? false,
      blurSigma: MoeGlassThickness.fromSigma(
        settings?.glassBlurSigma ?? 16,
      ).sigma,
      child: const UiSettingsPage(),
    );
  }
}
