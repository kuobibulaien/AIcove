import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:aicove_flutter/src/features/agent_context/providers/preset_recipe_provider.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/ui/features/character/pages/contact_edit_page.dart';
import 'package:aicove_flutter/src/ui/features/character/services/contact_edit_snapshot_store.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/index.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';

/// 需求（2026-09-12）：联系人设置界面在亮色／暗色模式下背景色必须统一，
/// 全部按下方的 `MoeSettingsGroup` 分组容器色（`componentBackground`）设置。
///
/// 重做后（2026-09）：壁纸、插件、背景信息补充三段均为 `MoeSettingsGroup`，
/// 本测试直接比较页面内所有分组容器的实际背景色。
void main() {
  final themes = <String, ({bool dark, MoeColors colors})>{
    'light': (dark: false, colors: MoeColors.light()),
    'dark': (dark: true, colors: MoeColors.dark()),
  };
  final carriers = <String, Size>{
    'narrow': const Size(390, 844),
    'wide': const Size(1180, 820),
  };

  themes.forEach((themeName, scenario) {
    carriers.forEach((carrierName, size) {
      testWidgets(
          'contact edit card backgrounds are unified '
          '($themeName/$carrierName)', (tester) async {
        SharedPreferences.setMockInitialValues({});
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final conversation = Conversation(
          id: 'background-unify',
          title: 'Synthetic',
          displayName: 'Synthetic',
          createdAt: DateTime(2026, 9, 12),
          updatedAt: DateTime(2026, 9, 12),
        );

        await tester.pumpWidget(ProviderScope(
          overrides: [
            presetRecipeListProvider
                .overrideWith((ref) async => const <PresetRecipeSummary>[]),
          ],
          child: MaterialApp(
            builder: (context, child) => MoeGlassTheme(
              enabled: false, blurSigma: 16, child: child!),
            theme: ThemeData(
              brightness: scenario.dark ? Brightness.dark : Brightness.light,
              extensions: <ThemeExtension<dynamic>>[scenario.colors],
            ),
            home: ContactEditPage(
              conversation: conversation,
              initialSnapshot:
                  ContactEditSnapshot.fromConversation(conversation),
            ),
          ),
        ));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);

        final settingsGroups = find.byType(MoeSettingsGroup);
        expect(settingsGroups, findsAtLeastNWidgets(3),
            reason: '壁纸、插件、背景信息补充三段都应使用 MoeSettingsGroup');

        final cardColors = <Color>{
          for (var i = 0; i < settingsGroups.evaluate().length; i++)
            _decorationColor(tester, settingsGroups.at(i)),
        };

        expect(cardColors, {scenario.colors.componentBackground},
            reason: '页面内所有卡片背景色必须统一为分组容器色 componentBackground');
        expect(scenario.colors.componentBackground,
            scenario.dark ? moePanelDark : moePanel);
      });
    });
  });
}

Color _decorationColor(WidgetTester tester, Finder card) {
  final surface = find.descendant(of: card, matching: find.byType(MoeFloatingSurface)).first;
  final material = tester.widgetList<Material>(
      find.descendant(of: surface, matching: find.byType(Material)))
      .firstWhere((material) => material.color != null);
  return material.color!;
}
