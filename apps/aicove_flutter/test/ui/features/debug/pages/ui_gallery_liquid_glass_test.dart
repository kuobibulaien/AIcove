import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/ui/features/debug/pages/ui_gallery_page.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/index.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('UiGalleryPage liquid glass pilot demo renders and toggles correctly', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 3200));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MoeLiquidGlassService.wrapApp(
        child: const ProviderScope(
          child: MaterialApp(
            home: UiGalleryPage(),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    // Verify section header exists
    expect(find.text('液态玻璃材质 (Liquid Glass Pilot)'), findsOneWidget);

    // Verify liquid glass capsule exists
    expect(find.text('液态晶体胶囊'), findsOneWidget);
    expect(find.text('GPU Shader 透镜折射'), findsOneWidget);

    // Verify switch control exists
    final switchFinder = find.descendant(
      of: find.widgetWithText(MoeSettingsRow, '启用液态效果 (Shader)'),
      matching: find.byType(Switch),
    );
    expect(switchFinder, findsOneWidget);

    // Ensure visible and test button tap inside the crystal capsule
    final interactButtonFinder = find.widgetWithText(MoeSecondaryButton, '交互测试');
    expect(interactButtonFinder, findsOneWidget);
    await tester.ensureVisible(interactButtonFinder);
    await tester.tap(interactButtonFinder, warnIfMissed: false);
    await tester.pump();
    // Wait for the 2-second MoeToast to dismiss completely
    await tester.pump(const Duration(seconds: 3));

    // Toggle off the liquid shader effect to test graceful fallback
    await tester.ensureVisible(switchFinder);
    await tester.tap(switchFinder, warnIfMissed: false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('原生材质优雅降级'), findsOneWidget);
    expect(find.text('已降级为原生材质'), findsOneWidget);

    // Toggle it back on
    await tester.tap(switchFinder, warnIfMissed: false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('GPU Shader 透镜折射'), findsOneWidget);
    expect(find.text('已开启着色器物理折射'), findsOneWidget);
  });
}
