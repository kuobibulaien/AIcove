import 'dart:ui' as ui;

import 'package:aicove_flutter/src/ui/shared/animations/parallax_slide_page_route.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/moe_adaptive_shell.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

const _red = Color(0xFFFF0000);

// The Cupertino edge shadow tints the covered page slightly.
final _isRed = predicate<Color>((c) => c.r > 0.8 && c.g < 0.2 && c.b < 0.2);

Future<Color> _pixel(WidgetTester tester, Offset at) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('capture')),
  );
  final bytes = await tester.runAsync(() async {
    final image = await boundary.toImage();
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    image.dispose();
    return data!;
  });
  final width = boundary.size.width.toInt();
  final i = (at.dy.toInt() * width + at.dx.toInt()) * 4;
  return Color.fromARGB(
    bytes!.getUint8(i + 3),
    bytes.getUint8(i),
    bytes.getUint8(i + 1),
    bytes.getUint8(i + 2),
  );
}

void main() {
  testWidgets('宽屏透明详情进下级时，被盖住的上级页只在新页左侧露出', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final navigator = GlobalKey<NavigatorState>();
    final observer = MoeDetailStackObserver();
    final router = GoRouter(
      routes: [
        ShellRoute(
          navigatorKey: navigator,
          observers: [observer],
          builder: (_, __, child) => MoeAdaptiveShell(
            primary: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => MoeWorkspace.open(
                    context,
                    const Scaffold(
                      backgroundColor: Colors.transparent,
                      body: ColoredBox(color: _red, child: SizedBox.expand()),
                    ),
                  ),
                  child: const Text('打开二级'),
                ),
              ),
            ),
            detail: child,
            navigatorKey: navigator,
            observer: observer,
          ),
          routes: [
            GoRoute(
              path: '/',
              builder: (_, __) => const MoeWorkspacePlaceholder(),
            ),
          ],
        ),
      ],
    );
    await tester.pumpWidget(
      RepaintBoundary(
        key: const ValueKey('capture'),
        child: MaterialApp.router(
          routerConfig: router,
          theme: ThemeData(extensions: [MoeColors.light()]),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('打开二级'));
    await tester.pumpAndSettle();

    navigator.currentState!.push(
      ParallaxSlidePageRoute<void>(
        page: const Scaffold(
          backgroundColor: Colors.transparent,
          body: SizedBox.expand(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    const detailLeft = telegramPrimaryWidth + telegramWorkspaceInset * 2;
    const detailWidth = 1000 - detailLeft;
    final progress = Curves.fastEaseInToSlowEaseOut.transform(200 / 500);
    final incomingLeft = detailLeft + detailWidth * (1 - progress);
    final previousRight = 1000 - detailWidth * progress / 3;
    expect(incomingLeft + 20, lessThan(previousRight - 20));

    expect(
      await _pixel(tester, Offset(incomingLeft - 20, 350)),
      _isRed,
      reason: '新页左边缘之外，上级页仍按官方视差可见',
    );
    expect(
      await _pixel(tester, Offset(incomingLeft + 20, 350)),
      isNot(_isRed),
      reason: '透明新页下方不能透出上级页，否则动画结束时上级页会半路整块消失',
    );

    await tester.pumpAndSettle();
    navigator.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    final returning = Curves.fastEaseInToSlowEaseOut.flipped.transform(
      1 - 200 / 500,
    );
    final leavingLeft = detailLeft + detailWidth * (1 - returning);
    expect(await _pixel(tester, Offset(leavingLeft - 20, 350)), _isRed);
    expect(await _pixel(tester, Offset(leavingLeft + 20, 350)), isNot(_isRed));
  });
}
