import 'package:aicove_flutter/src/ui/shared/widgets/moe_scroll_behavior.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _app({ScrollBehavior? behavior}) => MaterialApp(
  scrollBehavior: behavior,
  theme: ThemeData(platform: TargetPlatform.android),
  home: Scaffold(
    body: ListView(
      children: [for (var i = 0; i < 40; i++) SizedBox(height: 60, child: Text('$i'))],
    ),
  ),
);

Future<void> _overscrollTop(WidgetTester tester) async {
  final gesture = await tester.startGesture(tester.getCenter(find.byType(ListView)));
  await gesture.moveBy(const Offset(0, 200));
  await tester.pump();
}

void main() {
  testWidgets('default Android stretch filters the scroll view on overscroll', (
    tester,
  ) async {
    await tester.pumpWidget(_app());
    await _overscrollTop(tester);
    expect(find.byType(StretchingOverscrollIndicator), findsOneWidget);
    // On devices with shader filters StretchEffect wraps the viewport in
    // ImageFiltered(ImageFilter.shader); the test renderer uses a transform.
    expect(find.byType(StretchEffect), findsOneWidget);
  });

  testWidgets('MoeScrollBehavior bounces without a filter layer', (tester) async {
    await tester.pumpWidget(_app(behavior: const MoeScrollBehavior()));
    await _overscrollTop(tester);
    expect(find.byType(StretchingOverscrollIndicator), findsNothing);
    expect(find.byType(GlowingOverscrollIndicator), findsNothing);
    expect(find.byType(StretchEffect), findsNothing);
    final position = tester.state<ScrollableState>(find.byType(Scrollable)).position;
    // Bouncing lets the content itself move past the edge.
    expect(position.pixels, lessThan(0));
  });
}
