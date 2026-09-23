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
    expect(settings.lightChatBackground, isNull);

    final dark = MoeColors.dark(accentColor: settings.darkAccentColor);
    expect(dark.primary, const Color(0xFFD4AF37));
    expect(dark.surface, const Color(0xFF000000));
    expect(dark.bgMain, const Color(0xFF000000));
  });

  test('切换内置皮肤与自定义皮肤跨启动保留', () async {
    SharedPreferences.setMockInitialValues({});
    final container = await open();
    final notifier = container.read(appSettingsProvider.notifier);

    await notifier.setInterfaceSkin(InterfaceSkin.momotalk);
    var settings = container.read(appSettingsProvider).requireValue;
    expect(settings.lightChatBackground, const Color(0xFFF3F6F8));

    await notifier.setCustomSkin(accentColor: '3390EC');
    settings = container.read(appSettingsProvider).requireValue;
    expect(settings.interfaceSkin, InterfaceSkin.custom);
    expect(container.read(accentColorProvider), const Color(0xFF3390EC));
    container.dispose();

    final reopened = await open();
    addTearDown(reopened.dispose);
    expect(
      reopened.read(appSettingsProvider).requireValue.interfaceSkin,
      InterfaceSkin.custom,
    );
    expect(reopened.read(accentColorProvider), const Color(0xFF3390EC));
  });

  for (final (accent, background, expected) in [
    ('FC96AA', 'default', InterfaceSkin.classic),
    ('pink', 'white', InterfaceSkin.classic),
    ('FC96AA', 'momotalk', InterfaceSkin.momotalk),
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
