import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/ui/theme/accent_color_provider.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('默认强调色日间为粉色，用户自定义强调色跨启动保留', () async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer();
    await container.read(appSettingsProvider.future);
    expect(container.read(accentColorProvider), const Color(0xFFFC96AA));
    await container.read(appSettingsProvider.notifier).setAccentColor('3390EC');
    expect(container.read(accentColorProvider), const Color(0xFF3390EC));
    container.dispose();
    final reopened = ProviderContainer();
    addTearDown(reopened.dispose);
    await reopened.read(appSettingsProvider.future);
    expect(reopened.read(accentColorProvider), const Color(0xFF3390EC));
  });

  test('默认粉色强调色在暗色模式下转为薰衣草紫', () {
    const defaultAccent = Color(0xFFFC96AA);
    final darkAccent = defaultAccent == const Color(0xFFFC96AA)
        ? moeAccentDark
        : defaultAccent;
    expect(darkAccent, const Color(0xFFB39DDB));

    final lightColors = MoeColors.light();
    expect(lightColors.accentColor, const Color(0xFFFC96AA));

    final darkColors = MoeColors.dark();
    expect(darkColors.accent, moeAccentDark);
    expect(darkColors.accent, const Color(0xFFB39DDB));
  });
}
