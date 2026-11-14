import 'dart:convert';

import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/features/settings/data/support/ui_models_store_support.dart';
import 'package:aicove_flutter/src/ui/theme/accent_color_provider.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<ProviderContainer> open() async {
    final container = ProviderContainer();
    await container.read(appSettingsProvider.future);
    return container;
  }

  test('默认皮肤：浅色粉色强调，暗色金色强调、纯黑背景', () async {
    SharedPreferences.setMockInitialValues({});
    final container = await open();
    addTearDown(container.dispose);

    final settings = container.read(appSettingsProvider).requireValue;
    expect(settings.interfaceSkin, InterfaceSkin.classic);
    expect(container.read(accentColorProvider), const Color(0xFFFC96AA));
    expect(container.read(darkAccentColorProvider), const Color(0xFFD4AF37));

    final dark = MoeColors.dark(accentColor: settings.darkAccentColor);
    expect(dark.primary, const Color(0xFFD4AF37));
    expect(dark.surface, const Color(0xFF000000));
    expect(dark.bgMain, const Color(0xFF000000));
  });

  test('切换内置主题色与自定义浅色／深色主题色跨启动保留', () async {
    SharedPreferences.setMockInitialValues({});
    final container = await open();
    final notifier = container.read(appSettingsProvider.notifier);

    await notifier.setInterfaceSkin(InterfaceSkin.sky);
    expect(container.read(accentColorProvider), const Color(0xFF3390EC));

    await notifier.setCustomSkin(accentColor: '4ECDC4');
    var settings = container.read(appSettingsProvider).requireValue;
    expect(settings.interfaceSkin, InterfaceSkin.custom);
    expect(container.read(accentColorProvider), const Color(0xFF4ECDC4));
    // 没单独选深色时由浅色推算。
    expect(settings.darkAccentColor, isNot(const Color(0xFF4ECDC4)));

    await notifier.setCustomSkin(darkAccentColor: 'B39DDB');
    settings = container.read(appSettingsProvider).requireValue;
    expect(container.read(darkAccentColorProvider), const Color(0xFFB39DDB));
    expect(container.read(accentColorProvider), const Color(0xFF4ECDC4));
    container.dispose();

    final reopened = await open();
    addTearDown(reopened.dispose);
    expect(
      reopened.read(appSettingsProvider).requireValue.interfaceSkin,
      InterfaceSkin.custom,
    );
    expect(reopened.read(accentColorProvider), const Color(0xFF4ECDC4));
    expect(reopened.read(darkAccentColorProvider), const Color(0xFFB39DDB));
  });

  for (final removed in ['momotalk', 'warm']) {
    test('已下架的皮肤 $removed 读成默认', () async {
      SharedPreferences.setMockInitialValues({
        kUiModelsStoreKey: jsonEncode({'interface_skin': removed}),
      });
      final container = await open();
      addTearDown(container.dispose);
      expect(
        container.read(appSettingsProvider).requireValue.interfaceSkin,
        InterfaceSkin.classic,
      );
    });
  }

  for (final (accent, background, expected) in [
    ('FC96AA', 'default', InterfaceSkin.classic),
    ('pink', 'white', InterfaceSkin.classic),
    ('FC96AA', 'momotalk', InterfaceSkin.classic),
    ('FC96AA', 'warm', InterfaceSkin.custom),
    ('3390EC', 'default', InterfaceSkin.custom),
  ]) {
    test('旧版本无皮肤字段 accent=$accent bg=$background 迁为 ${expected.value}',
        () async {
      SharedPreferences.setMockInitialValues({
        kUiModelsStoreKey: jsonEncode({
          'accent_color': accent,
          'chat_background_color': background,
        }),
      });
      final container = await open();
      addTearDown(container.dispose);
      expect(
        container.read(appSettingsProvider).requireValue.interfaceSkin,
        expected,
      );
    });
  }
}
