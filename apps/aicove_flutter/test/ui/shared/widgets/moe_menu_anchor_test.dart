import 'package:aicove_flutter/src/ui/shared/widgets/menus/moe_popup_menu.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/moe_floating_surface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final left in [0.0, 384.0]) {
    for (final nearBottom in [false, true]) {
      testWidgets(
        'pointer anchors in local navigator left=$left bottom=$nearBottom',
        (tester) async {
          await tester.binding.setSurfaceSize(Size(left + 360, 800));
          addTearDown(() => tester.binding.setSurfaceSize(null));
          final target = GlobalKey();
          final point = Offset(left + 110, nearBottom ? 590 : 100);
          await tester.pumpWidget(
            MaterialApp(
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  padding: const EdgeInsets.only(top: 24, bottom: 20),
                  viewInsets: const EdgeInsets.only(bottom: 160),
                  textScaler: const TextScaler.linear(1.8),
                ),
                child: child!,
              ),
              home: Row(
                children: [
                  SizedBox(width: left),
                  Expanded(
                    child: Navigator(
                      onGenerateRoute: (_) => MaterialPageRoute<void>(
                        builder: (context) => MediaQuery(
                          data: MediaQuery.of(context).copyWith(
                            padding: const EdgeInsets.only(top: 24, bottom: 20),
                            viewInsets: const EdgeInsets.only(bottom: 160),
                            textScaler: const TextScaler.linear(1.8),
                          ),
                          child: Builder(
                            builder: (context) => Scaffold(
                              resizeToAvoidBottomInset: false,
                              body: GestureDetector(
                                key: target,
                                behavior: HitTestBehavior.opaque,
                                onLongPressStart: (details) =>
                                    MoePopupMenu.show(
                                      context,
                                      targetBox:
                                          target.currentContext!
                                                  .findRenderObject()!
                                              as RenderBox,
                                      globalPosition: details.globalPosition,
                                      items: List.generate(
                                        8,
                                        (i) => MoePopupMenuItem(
                                          icon: Icons.copy,
                                          label: 'item $i',
                                          onTap: () {},
                                        ),
                                      ),
                                    ),
                                child: const SizedBox.expand(),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
          await tester.longPressAt(point);
          await tester.pumpAndSettle();
          final rect = tester.getRect(find.byType(MoeFloatingSurface));
          expect(rect.left, greaterThanOrEqualTo(left + 8));
          expect(rect.right, lessThanOrEqualTo(left + 352));
          expect(rect.top, greaterThanOrEqualTo(32));
          expect(rect.bottom, lessThanOrEqualTo(632));
          expect(nearBottom ? rect.bottom : rect.top, closeTo(point.dy, 0.01));
          await tester.ensureVisible(find.text('item 7'));
          await tester.tap(find.text('item 7'));
          await tester.pumpAndSettle();
          expect(find.byType(MoeFloatingSurface), findsNothing);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
