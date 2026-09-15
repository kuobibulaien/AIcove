import 'package:aicove_flutter/src/ui/shared/animations/parallax_slide_page_route.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

void main() {
  for (final imperative in [false, true]) {
    for (final width in [360.0, 1000.0]) {
      testWidgets(
        'normal push is coupled; interrupted pop retains old clock at $width (imperative=$imperative)',
        (tester) async {
          tester.view.physicalSize = Size(width, 800);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          const base = ValueKey('base'), front = ValueKey('front');
          late ModalRoute<dynamic> b, f;
          final router = GoRouter(
            routes: [
              GoRoute(
                path: '/',
                pageBuilder: (c, s) => CupertinoPage(
                  key: s.pageKey,
                  child: Builder(
                    builder: (c) {
                      b = ModalRoute.of(c)!;
                      return const ColoredBox(
                        key: base,
                        color: Color(0xFFFF0000),
                      );
                    },
                  ),
                ),
                routes: [
                  GoRoute(
                    path: 'detail',
                    pageBuilder: (c, s) => CupertinoPage(
                      key: s.pageKey,
                      child: Builder(
                        builder: (c) {
                          f = ModalRoute.of(c)!;
                          return const ColoredBox(
                            key: front,
                            color: Color(0xFF0000FF),
                          );
                        },
                      ),
                    ),
                  ),
                ],
              ),
            ],
          );
          addTearDown(router.dispose);
          await tester.pumpWidget(CupertinoApp.router(routerConfig: router));
          await tester.pumpAndSettle();
          for (var pass = 0; pass < 2; pass++) {
            if (imperative) {
              final route = ParallaxSlidePageRoute<void>(
                page: const ColoredBox(key: front, color: Color(0xFF0000FF)),
              );
              f = route;
              router.routerDelegate.navigatorKey.currentState!.push(route);
            } else {
              router.push('/detail');
            }
            await tester.pump();
            double? previousBaseDx;
            for (var frame = 1; frame <= 20; frame++) {
              await tester.pump(const Duration(milliseconds: 16));
              final p = f.animation!.value, s = b.secondaryAnimation!.value;
              if (frame <= 4 || frame >= 12) {
                debugPrint(
                  'width=$width pass=$pass ms=${frame * 16} primary=$p secondary=$s baseDx=${tester.getTopLeft(find.byKey(base)).dx} frontDx=${tester.getTopLeft(find.byKey(front).last).dx}',
                );
              }
              if (pass == 0) {
                expect(s, closeTo(p, 0.000001));
              } else if (frame == 1) {
                expect(s, greaterThan(p));
              }
              final baseDx = tester.getTopLeft(find.byKey(base)).dx;
              expect(baseDx, lessThan(0));
              if (pass == 1 && frame == 15) {
                expect(
                  baseDx,
                  greaterThan(previousBaseDx!),
                  reason: 'The background is still completing the old return.',
                );
                expect(
                  tester.getTopLeft(find.byKey(front).last).dx,
                  lessThan(width * 0.07),
                );
              }
              if (pass == 1 && frame == 16) {
                expect(
                  baseDx,
                  lessThan(previousBaseDx!),
                  reason: 'The background only now resumes moving left.',
                );
              }
              previousBaseDx = baseDx;
            }
            await tester.pumpAndSettle();
            router.pop();
            await tester.pump();
            if (pass == 0) {
              await tester.pump(const Duration(milliseconds: 32));
            } else {
              await tester.pumpAndSettle();
            }
          }
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  }
}
