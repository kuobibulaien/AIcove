import 'package:aicove_flutter/src/ui/shared/animations/parallax_slide_page_route.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('ParallaxSlidePageRoute delegates to CupertinoPageRoute', () {
    final route = ParallaxSlidePageRoute<void>(
      page: const SizedBox.shrink(),
    );

    expect(route, isA<CupertinoPageRoute<void>>());
    expect(
      route.transitionDuration,
      CupertinoRouteTransitionMixin.kTransitionDuration,
    );
    expect(route.reverseTransitionDuration, route.transitionDuration);
  });

  testWidgets('secondary transition follows Cupertino one-third parallax', (
    tester,
  ) async {
    final childKey = UniqueKey();
    Future<void> pumpWithSecondaryValue(double value) {
      return tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: SizedBox(
              width: 300,
              height: 100,
              child: Builder(
                builder: (context) {
                  return buildSecondaryParallaxTransition()(
                    context,
                    const AlwaysStoppedAnimation<double>(0),
                    AlwaysStoppedAnimation<double>(value),
                    Container(key: childKey, color: Colors.red),
                  );
                },
              ),
            ),
          ),
        ),
      );
    }

    await pumpWithSecondaryValue(0);
    final startDx = tester.getTopLeft(find.byKey(childKey)).dx;

    await pumpWithSecondaryValue(1);
    final endDx = tester.getTopLeft(find.byKey(childKey)).dx;

    expect(endDx - startDx, closeTo(-100, 0.1));
  });
}
