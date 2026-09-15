import 'package:aicove_flutter/src/ui/shared/widgets/index.dart';
import 'package:aicove_flutter/src/ui/theme/moe_interaction_theme.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

void main() {
  for (final dark in [false, true]) {
    for (final width in [320.0, 1100.0]) {
      for (final scale in [1.0, 1.8]) {
        testWidgets(
          'button actions survive material changes $dark/$width/$scale',
          (tester) async {
            tester.view.devicePixelRatio = 1;
            tester.view.physicalSize = Size(width, 1000);
            addTearDown(tester.view.reset);
            MoeLiquidGlassService.setMockState(available: true);
            addTearDown(
              () => MoeLiquidGlassService.setMockState(available: false),
            );
            final colors = dark ? MoeColors.dark() : MoeColors.light();
            final focus = FocusNode();
            addTearDown(focus.dispose);
            late StateSetter rebuild;
            var material = MoeSurfaceMaterial.frosted;
            var loading = false;
            var selected = 0;
            var primaryTaps = 0;
            var keyTaps = 0;
            await tester.pumpWidget(
              MaterialApp(
                theme: withMoeInteractionTheme(
                  ThemeData(
                    brightness: dark ? Brightness.dark : Brightness.light,
                    extensions: [colors],
                  ),
                ),
                home: StatefulBuilder(
                  builder: (context, setState) {
                    rebuild = setState;
                    return MediaQuery(
                      data: MediaQuery.of(
                        context,
                      ).copyWith(textScaler: TextScaler.linear(scale)),
                      child: MoeGlassTheme(
                        enabled: material != MoeSurfaceMaterial.solid,
                        useLiquidGlass: material == MoeSurfaceMaterial.liquid,
                        blurSigma: 16,
                        child: Scaffold(
                          body: Center(
                            child: SizedBox(
                              width: 360,
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  MoePrimaryButton(
                                    label: '发送',
                                    isLoading: loading,
                                    onPressed: () => primaryTaps++,
                                  ),
                                  const SizedBox(height: 12),
                                  FilledButton(
                                    focusNode: focus,
                                    onPressed: () => keyTaps++,
                                    child: const Text('确认'),
                                  ),
                                  const SizedBox(height: 12),
                                  MoeToggleBar<int>(
                                    value: selected,
                                    items: const [
                                      MoeToggleItem(value: 0, label: '左'),
                                      MoeToggleItem(value: 1, label: '右'),
                                    ],
                                    onChanged: (value) =>
                                        rebuild(() => selected = value),
                                  ),
                                  const SizedBox(height: 12),
                                  MoeSegTabBar(
                                    currentIndex: selected,
                                    tabs: const ['一', '二'],
                                    onTap: (value) =>
                                        rebuild(() => selected = value),
                                  ),
                                  const SizedBox(height: 12),
                                  MoeTileButton(
                                    label: '设置',
                                    subtitle: '按钮材质',
                                    icon: Icons.settings,
                                    onTap: () {},
                                  ),
                                  const SizedBox(height: 12),
                                  SegmentedButton<int>(
                                    segments: const [
                                      ButtonSegment(value: 0, label: Text('关')),
                                      ButtonSegment(value: 1, label: Text('开')),
                                    ],
                                    selected: {selected},
                                    onSelectionChanged: (values) =>
                                        rebuild(() => selected = values.single),
                                  ),
                                  const SizedBox(height: 12),
                                  MoeButtonSurface(
                                    radius: 999,
                                    child: ChoiceChip(
                                      label: const Text('选择'),
                                      selected: selected == 1,
                                      onSelected: (value) => rebuild(
                                        () => selected = value ? 1 : 0,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            );
            await tester.pumpAndSettle();
            await tester.tap(find.text('右'));
            expect(selected, 1);
            await tester.tap(find.text('发送'));
            expect(primaryTaps, 1);
            focus.requestFocus();
            await tester.pumpAndSettle();
            for (final mode in MoeSurfaceMaterial.values) {
              rebuild(() => material = mode);
              await tester.pumpAndSettle();
              expect(focus.hasFocus, isTrue);
              expect(selected, 1);
              await tester.sendKeyEvent(LogicalKeyboardKey.enter);
              await tester.pumpAndSettle();
              expect(tester.takeException(), isNull);
            }
            expect(keyTaps, 3);
            rebuild(() => loading = true);
            await tester.pump();
            await tester.tap(find.byType(MoePrimaryButton));
            expect(primaryTaps, 1);
            expect(find.byType(CircularProgressIndicator), findsOneWidget);
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }

  testWidgets(
    'button material respects high contrast and reduced transparency',
    (tester) async {
      MoeLiquidGlassService.setMockState(available: true);
      addTearDown(() => MoeLiquidGlassService.setMockState(available: false));
      for (final highContrast in [false, true]) {
        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(highContrast: highContrast),
              child: GlassAccessibilityScope(
                reduceTransparency: !highContrast,
                child: MoeGlassTheme(
                  enabled: true,
                  useLiquidGlass: true,
                  blurSigma: 16,
                  child: Center(
                    child: MoeSecondaryButton(label: '取消', onPressed: () {}),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(BackdropFilter), findsNothing);
        expect(find.byType(AdaptiveGlass), findsNothing);
        expect(tester.takeException(), isNull);
      }
    },
  );
}
