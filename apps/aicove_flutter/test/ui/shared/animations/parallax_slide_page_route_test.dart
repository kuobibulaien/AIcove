import 'package:aicove_flutter/src/ui/shared/animations/parallax_slide_page_route.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('ParallaxSlidePageRoute delegates to CupertinoPageRoute', () {
    final route = ParallaxSlidePageRoute<void>(page: const SizedBox.shrink());

    expect(route, isA<CupertinoPageRoute<void>>());
    expect(
      route.transitionDuration,
      CupertinoRouteTransitionMixin.kTransitionDuration,
    );
    expect(route.reverseTransitionDuration, route.transitionDuration);
  });
}
