import 'package:aicove_flutter/src/ui/shared/animations/moe_menu_transition.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/menus/moe_popup_menu.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/moe_floating_surface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final upward in [false, true]) {
    testWidgets('menu grows and retracts at pointer, upward=$upward', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(480, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final anchor = Offset(100, upward ? 680 : 100);
      final key = GlobalKey();
      var selected = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  key: key,
                  onPressed: () => MoePopupMenu.show(
                    context,
                    targetBox:
                        key.currentContext!.findRenderObject() as RenderBox,
                    globalPosition: anchor,
                    items: List.generate(
                      4,
                      (i) => MoePopupMenuItem(
                        label: 'action $i',
                        onTap: () => selected = true,
                      ),
                    ),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pump();
      final surface = find.byType(MoeFloatingSurface);
      final initial = tester.getRect(surface);
      expect(initial.width, closeTo(180 * 0.08, 0.01));
      await tester.pump(const Duration(milliseconds: 70));
      final during = tester.getRect(surface);
      expect(during.width, greaterThan(initial.width));
      expect(
        find.ancestor(of: surface, matching: find.byType(Opacity)),
        findsNothing,
        reason:
            'A live glass backdrop must sample the page, not an opacity buffer',
      );
      expect(during.left, closeTo(anchor.dx, 0.01));
      expect(upward ? during.bottom : during.top, closeTo(anchor.dy, 0.01));
      await tester.pumpAndSettle();
      final complete = tester.getRect(surface);
      expect(complete.width, greaterThan(during.width));
      await tester.tap(find.text('action 0'));
      await tester.pump();
      expect(selected, isFalse, reason: 'wait for visual exit before action');
      await tester.pump(const Duration(milliseconds: 70));
      final closing = tester.getRect(surface);
      expect(closing.width, lessThan(complete.width));
      expect(closing.left, closeTo(anchor.dx, 0.01));
      expect(upward ? closing.bottom : closing.top, closeTo(anchor.dy, 0.01));
      await tester.pumpAndSettle();
      expect(selected, isTrue);
      expect(surface, findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('reduced motion renders menu without scaling or fading', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: true),
          child: MoeMenuTransition(
            animation: const AlwaysStoppedAnimation(0),
            child: const Text('menu'),
          ),
        ),
      ),
    );
    expect(find.text('menu'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(MoeMenuTransition),
        matching: find.byType(Transform),
      ),
      findsNothing,
    );
    expect(
      find.descendant(
        of: find.byType(MoeMenuTransition),
        matching: find.byType(Opacity),
      ),
      findsNothing,
    );
  });
}
