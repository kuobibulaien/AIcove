import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/ui/shared/animations/parallax_slide_page_route.dart';

void main() {
  testWidgets('declarative page updates child and respects canPop', (
    tester,
  ) async {
    final navigator = GlobalKey<NavigatorState>();
    late StateSetter update;
    var label = 'before';
    var canPop = false;
    var showDetail = true;
    await tester.pumpWidget(
      CupertinoApp(
        home: StatefulBuilder(
          builder: (_, setState) {
            update = setState;
            return Navigator(
              key: navigator,
              pages: [
                const ParallaxSlidePage(
                  key: ValueKey('root'),
                  child: SizedBox(),
                ),
                if (showDetail)
                  ParallaxSlidePage(
                    key: const ValueKey('detail'),
                    canPop: canPop,
                    child: Text(label),
                  ),
              ],
              onDidRemovePage: (_) => update(() => showDetail = false),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await navigator.currentState!.maybePop();
    await tester.pumpAndSettle();
    expect(find.text('before'), findsOneWidget);
    update(() {
      label = 'after';
      canPop = true;
    });
    await tester.pumpAndSettle();
    expect(find.text('after'), findsOneWidget);
    expect(find.text('before'), findsNothing);
    await navigator.currentState!.maybePop();
    await tester.pumpAndSettle();
    expect(find.text('after'), findsNothing);
  });

  testWidgets(
    'completed push keeps official return geometry and gesture cancellation',
    (tester) async {
      Future<List<double>> sample(bool fixed) async {
        final navigator = GlobalKey<NavigatorState>();
        const key = ValueKey('page');
        await tester.pumpWidget(
          CupertinoApp(
            key: UniqueKey(),
            navigatorKey: navigator,
            home: const CupertinoPageScaffold(child: SizedBox.expand()),
          ),
        );
        const child = CupertinoPageScaffold(child: SizedBox.expand(key: key));
        unawaited(
          navigator.currentState!.push(
            fixed
                ? ParallaxSlidePageRoute<void>(page: child)
                : CupertinoPageRoute<void>(builder: (_) => child),
          ),
        );
        await tester.pumpAndSettle();
        if (fixed) {
          final gesture = await tester.startGesture(const Offset(1, 200));
          await gesture.moveBy(const Offset(80, 0));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 200));
          await gesture.up();
          await tester.pumpAndSettle();
          expect(find.byKey(key), findsOneWidget, reason: '短距离边缘返回可取消');
        }
        navigator.currentState!.pop();
        await tester.pump();
        final positions = <double>[];
        for (var i = 0; i < 4; i++) {
          await tester.pump(const Duration(milliseconds: 40));
          positions.add(tester.getTopLeft(find.byKey(key)).dx);
        }
        await tester.pumpAndSettle();
        return positions;
      }

      final official = await sample(false);
      final fixed = await sample(true);
      for (var i = 0; i < official.length; i++) {
        expect(fixed[i], closeTo(official[i], .01));
      }
    },
  );
}
