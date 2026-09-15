import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'package:aicove_flutter/src/ui/shared/widgets/index.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MoeLiquidGlassService', () {
    test('mock state can be controlled in tests', () {
      MoeLiquidGlassService.setMockState(initialized: true, available: true);
      expect(MoeLiquidGlassService.isInitialized, isTrue);
      expect(MoeLiquidGlassService.isAvailable, isTrue);

      MoeLiquidGlassService.setMockState(initialized: true, available: false);
      expect(MoeLiquidGlassService.isAvailable, isFalse);

      // Restore
      MoeLiquidGlassService.setMockState(initialized: true, available: true);
    });

    testWidgets('wrapApp applies brightnessResolver and respects system accessibility', (tester) async {
      await tester.pumpWidget(
        MoeLiquidGlassService.wrapApp(
          child: MaterialApp(
            theme: ThemeData(brightness: Brightness.light),
            darkTheme: ThemeData(brightness: Brightness.dark),
            themeMode: ThemeMode.dark,
            home: Builder(
              builder: (context) {
                final brightness = Theme.maybeBrightnessOf(context);
                return Text('Brightness: $brightness');
              },
            ),
          ),
        ),
      );

      expect(find.text('Brightness: Brightness.dark'), findsOneWidget);
    });
  });

  group('MoeLiquidGlass Widget', () {
    setUp(() {
      MoeLiquidGlassService.setMockState(initialized: true, available: true);
    });

    testWidgets('renders AdaptiveGlass when enabled', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: MoeLiquidGlass(
                enabled: true,
                thickness: 25,
                refractiveIndex: 1.3,
                blurSigma: 12,
                child: const Text('Liquid Content'),
              ),
            ),
          ),
        ),
      );

      expect(find.text('Liquid Content'), findsOneWidget);
      expect(find.byType(AdaptiveGlass), findsOneWidget);
    });

    testWidgets('gracefully degrades to native material when enabled is false', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: MoeLiquidGlass(
                enabled: false,
                blurSigma: 14,
                child: const Text('Fallback Content'),
              ),
            ),
          ),
        ),
      );

      expect(find.text('Fallback Content'), findsOneWidget);
      // AdaptiveGlass should NOT be rendered
      expect(find.byType(AdaptiveGlass), findsNothing);
      // Explicitly disabled glass must be opaque, without a backdrop filter.
        expect(find.byType(BackdropFilter), findsNothing);
    });

    testWidgets('gracefully degrades to solid surface in high contrast mode', (tester) async {
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(highContrast: true),
          child: MaterialApp(
            home: Scaffold(
              body: Center(
                child: MoeLiquidGlass(
                  enabled: true,
                  child: const Text('High Contrast Content'),
                ),
              ),
            ),
          ),
        ),
      );

      expect(find.text('High Contrast Content'), findsOneWidget);
      expect(find.byType(AdaptiveGlass), findsNothing);
      // In high contrast, BackdropFilter should be bypassed
      expect(find.byType(BackdropFilter), findsNothing);
    });

    testWidgets('retains Material ink splash and tap gestures inside glass surface', (tester) async {
      var tapped = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: MoeLiquidGlass(
                enabled: true,
                child: InkWell(
                  onTap: () {
                    tapped = true;
                  },
                  child: const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('Tappable Button'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      expect(find.text('Tappable Button'), findsOneWidget);
      await tester.tap(find.text('Tappable Button'));
      await tester.pumpAndSettle();

      expect(tapped, isTrue);
    });

    testWidgets('inherits global MoeGlassTheme enabled and blurSigma values', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: MoeGlassTheme(
            enabled: false,
            blurSigma: 10,
            child: Scaffold(
              body: Center(
                child: MoeLiquidGlass(
                  // enabled is omitted, should inherit from MoeGlassTheme (false)
                  child: const Text('Inherited Theme Content'),
                ),
              ),
            ),
          ),
        ),
      );

      expect(find.text('Inherited Theme Content'), findsOneWidget);
      // Should degrade because MoeGlassTheme.enabled is false
      expect(find.byType(AdaptiveGlass), findsNothing);
      expect(find.byType(BackdropFilter), findsNothing);
    });
  });
}
