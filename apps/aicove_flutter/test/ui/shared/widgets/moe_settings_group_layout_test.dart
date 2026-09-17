import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/index.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';

double _expectedContentWidth(double panelWidth) {
  final inset = (panelWidth * 0.04).clamp(12.0, 32.0);
  return math.min(760.0, math.max(0.0, panelWidth - 2 * inset));
}

Widget _wrap({
  required Widget child,
  bool dark = false,
  bool glassEnabled = false,
  bool liquid = false,
  double scale = 1.0,
}) {
  return MaterialApp(
    theme: ThemeData(
      brightness: dark ? Brightness.dark : Brightness.light,
      extensions: [dark ? MoeColors.dark() : MoeColors.light()],
    ),
    builder: (context, child) => MoeGlassTheme(
      enabled: glassEnabled,
      blurSigma: 16,
      useLiquidGlass: liquid,
      child: MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
    ),
    home: Scaffold(body: child),
  );
}

void main() {
  for (final width in <double>[320, 360, 420, 460, 616, 896, 1000, 1280]) {
    testWidgets('content column follows panel width $width', (tester) async {
      await tester.binding.setSurfaceSize(Size(width, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        _wrap(
          child: SizedBox(
            width: width,
            child: const MoeSettingsContent(
              child: Column(
                children: [
                  MoeSettingsGroup(children: [Text('短')]),
                  MoeSettingsGroup(
                    title: '分组',
                    children: [MoeSettingsRow(label: '标签')],
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      final expected = _expectedContentWidth(width);
      final surfaces = tester
          .widgetList<MoeContentSurface>(find.byType(MoeContentSurface))
          .map((w) => tester.getRect(find.byWidget(w)))
          .toList();
      expect(surfaces, hasLength(2));
      for (final rect in surfaces) {
        expect(rect.width, closeTo(expected, 0.01), reason: 'width=$width');
        expect(rect.left, closeTo((width - expected) / 2, 0.01));
        expect(rect.right, closeTo((width + expected) / 2, 0.01));
      }

      final shortText = tester.getRect(find.text('短'));
      expect(shortText.width, closeTo(expected, 0.01));
      final title = tester.getRect(find.text('分组'));
      expect(title.left, closeTo(surfaces.last.left + 12, 0.01));
    });
  }

  testWidgets('half-width nested content uses local panel, not MediaQuery', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _wrap(
        child: const Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 460,
            child: MoeSettingsContent(
              child: MoeSettingsGroup(children: [Text('嵌套')]),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final expected = _expectedContentWidth(460);
    final card = tester.getRect(find.byType(MoeContentSurface));
    expect(card.width, closeTo(expected, 0.01));
    expect(tester.takeException(), isNull);
  });

  testWidgets('unbounded horizontal constraints fall back to max width', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        child: const SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: MoeSettingsContent(
            child: MoeSettingsGroup(children: [Text('无界')]),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final card = tester.getRect(find.byType(MoeContentSurface));
    expect(card.width, closeTo(760, 0.01));
    expect(tester.takeException(), isNull);
  });

  for (final dark in [false, true]) {
    for (final (enabled, liquid) in [
      (false, false),
      (true, false),
      (true, true),
    ]) {
      testWidgets(
        'material props stay delegated dark=$dark glass=$enabled liquid=$liquid',
        (tester) async {
          MoeLiquidGlassService.setMockState(
            initialized: true,
            available: true,
          );
          addTearDown(
            () => MoeLiquidGlassService.setMockState(
              initialized: false,
              available: false,
            ),
          );
          await tester.pumpWidget(
            _wrap(
              dark: dark,
              glassEnabled: enabled,
              liquid: liquid,
              child: const SizedBox(
                width: 360,
                child: MoeSettingsContent(
                  child: MoeSettingsGroup(children: [Text('材质')]),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final surface = tester.widget<MoeContentSurface>(
            find.byType(MoeContentSurface),
          );
          final group = find.byType(MoeSettingsGroup);
          expect(surface.color, isNotNull);
          expect(surface.blurSigma, 0);
          expect(surface.borderRadius, BorderRadius.circular(20));
          expect(
            find.descendant(of: group, matching: find.byType(MoeLiquidGlass)),
            findsNothing,
          );
          expect(
            find.descendant(of: group, matching: find.byType(AdaptiveGlass)),
            findsNothing,
          );
          expect(
            find.descendant(of: group, matching: find.byType(BackdropFilter)),
            findsNothing,
          );
          expect(
            find.descendant(
              of: group,
              matching: find.byType(MoeFloatingSurface),
            ),
            findsNothing,
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('default group has zero margin and radius 20', (tester) async {
    await tester.pumpWidget(
      _wrap(
        child: const SizedBox(
          width: 360,
          child: MoeSettingsContent(
            child: MoeSettingsGroup(children: [MoeSettingsRow(label: '行')]),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final group = tester.widget<MoeSettingsGroup>(
      find.byType(MoeSettingsGroup),
    );
    expect(group.margin, isNull);
    final card = tester.getRect(find.byType(MoeContentSurface));
    final content = tester.getRect(find.byType(MoeSettingsContent));
    expect(
      card.left,
      closeTo(content.left + (content.width - card.width) / 2, 0.01),
    );
  });
}
