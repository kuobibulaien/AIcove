import 'package:aicove_flutter/src/ui/features/settings/pages/settings_page.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/moe_adaptive_shell.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/moe_avatar.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/list/moe_settings_row.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _profileCard = ValueKey('settings-profile-card');
const _entryContainer = ValueKey('settings-entry-container');

const _entryStyles = <String, (IconData, int)>{
  '账号': (Icons.person_rounded, 0xFF007AFF),
  '模型': (Icons.layers_rounded, 0xFF5856D6),
  '界面': (Icons.tune_rounded, 0xFF32ADE6),
  '插件': (Icons.extension_rounded, 0xFFAF52DE),
  '调试': (Icons.terminal_rounded, 0xFFFF9500),
};

void main() {
  for (final width in [320.0, 360.0, 420.0, 440.0]) {
    for (final scale in [1.0, 1.8]) {
      testWidgets('settings local width $width text scale $scale', (
        tester,
      ) async {
        SharedPreferences.setMockInitialValues({});
        await tester.binding.setSurfaceSize(Size(width, 780));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          ProviderScope(
            child: MaterialApp(
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: const SettingsPage(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final card = find.byKey(_profileCard);
        final cardRect = tester.getRect(card);
        final search = find.byType(TextField);
        expect(cardRect.left, tester.getRect(search).left);
        expect(cardRect.right, tester.getRect(search).right);
        if (scale == 1) expect(cardRect.height, 88);
        final container = find.byKey(_entryContainer);
        expect(container, findsOneWidget);
        final containerRect = tester.getRect(container);
        expect(containerRect.left, cardRect.left);
        expect(containerRect.right, cardRect.right);
        final cardMaterial = tester.widget<Material>(card);
        final containerMaterial = tester.widget<Material>(container);
        expect(containerMaterial.color, cardMaterial.color);
        expect(
          cardMaterial.color,
          MoeColors.light().surface.withValues(alpha: 0.88),
        );
        expect(containerMaterial.borderRadius, BorderRadius.circular(20));
        final avatar = tester.getRect(find.byType(MoeAvatar));
        final rows = tester
            .widgetList<MoeSettingsRow>(find.byType(MoeSettingsRow))
            .toList();
        expect(rows.map((e) => e.label), ['账号', '模型', '界面', '插件', '调试']);
        for (final row in rows) {
          expect(
            tester.getRect(find.byWidget(row.iconWidget!)).left,
            avatar.left,
          );
          expect(
            tester.getSize(find.byWidget(row.iconWidget!)),
            const Size(30, 30),
          );
          expect(
            tester.getSize(find.byWidget(row)).height,
            greaterThanOrEqualTo(52),
          );
          final tile = row.iconWidget! as Container;
          final decoration = tile.decoration! as BoxDecoration;
          final (iconData, colorValue) = _entryStyles[row.label]!;
          expect(decoration.color, Color(colorValue));
          expect(decoration.borderRadius, BorderRadius.circular(7));
          expect(decoration.shape, BoxShape.rectangle);
          final glyph = tile.child! as Icon;
          expect(glyph.icon, iconData);
          expect(glyph.color, Colors.white);
          expect(glyph.size, 19);
          expect(row.labelStyle!.fontSize, 16);
          expect(row.labelStyle!.fontWeight, FontWeight.normal);
          expect(
            row.contentPadding,
            const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
          );
          final chevron = row.trailing! as Icon;
          expect(chevron.size, 20);
          expect(
            find.ancestor(of: find.byWidget(row), matching: container),
            findsOneWidget,
          );
        }
        final arrows = find.byIcon(Icons.chevron_right);
        final right = tester.getRect(arrows.first).right;
        for (var i = 1; i < arrows.evaluate().length; i++) {
          expect(tester.getRect(arrows.at(i)).right, right);
        }
        expect(tester.takeException(), isNull);
        await tester.enterText(search, '深色');
        await tester.pumpAndSettle();
        expect(find.byType(MoeAvatar), findsNothing);
        expect(card, findsNothing);
        expect(find.byType(MoeSettingsRow), findsOneWidget);
        expect(find.text('界面'), findsOneWidget);
        expect(container, findsOneWidget);
        expect(
          find.descendant(
            of: container,
            matching: find.byType(MoeSettingsRow),
          ),
          findsOneWidget,
        );
        final searchCardRect = tester.getRect(container);
        expect(searchCardRect.left, cardRect.left);
        expect(searchCardRect.right, cardRect.right);
        await tester.tap(find.byTooltip('清除搜索'));
        await tester.pumpAndSettle();
        expect(find.byType(MoeAvatar), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('settings entry container dark theme', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.binding.setSurfaceSize(const Size(360, 780));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: ThemeData(
            brightness: Brightness.dark,
            extensions: [MoeColors.dark()],
          ),
          home: const SettingsPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final expected = MoeColors.dark().text.withValues(alpha: 0.06);
    final cardMaterial = tester.widget<Material>(find.byKey(_profileCard));
    final containerMaterial = tester.widget<Material>(
      find.byKey(_entryContainer),
    );
    expect(cardMaterial.color, expected);
    expect(containerMaterial.color, expected);
    final rows = tester
        .widgetList<MoeSettingsRow>(find.byType(MoeSettingsRow))
        .toList();
    expect(rows.length, 5);
    for (final row in rows) {
      final tile = row.iconWidget! as Container;
      final decoration = tile.decoration! as BoxDecoration;
      final (_, colorValue) = _entryStyles[row.label]!;
      expect(decoration.color, Color(colorValue));
      expect(decoration.shape, BoxShape.rectangle);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('settings wide shell 1000 keeps local 360', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.binding.setSurfaceSize(const Size(1000, 760));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final nav = GlobalKey<NavigatorState>();
    final observer = MoeDetailStackObserver();
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: MoeAdaptiveShell(
            navigatorKey: nav,
            observer: observer,
            primary: const SettingsPage(),
            detail: const SizedBox.expand(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final cardRect = tester.getRect(find.byKey(_profileCard));
    final containerRect = tester.getRect(find.byKey(_entryContainer));
    expect(containerRect.left, cardRect.left);
    expect(containerRect.right, cardRect.right);
    expect(cardRect.left, 24);
    expect(cardRect.right, 360);
    expect(find.byType(MoeSettingsRow), findsNWidgets(5));
    expect(tester.takeException(), isNull);
  });
}
