import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/cupertino.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/ui/shared/animations/parallax_slide_page_route.dart';

void main() {
  for (final width in [360.0, 1000.0]) {
    for (final rtl in [false, true]) {
      for (final declarative in [false, true]) {
        testWidgets(
          'matches SDK through interrupted pop and reentry $width/$rtl/$declarative',
          (tester) async {
            tester.view.physicalSize = Size(width, 800);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.reset);
            Future<List<double>> sample(bool adapted) async {
              final nav = GlobalKey<NavigatorState>();
              const back = ValueKey('back'), front = ValueKey('front');
              const home = CupertinoPageScaffold(
                child: SizedBox.expand(key: back),
              );
              const detail = CupertinoPageScaffold(
                child: SizedBox.expand(key: front),
              );
              PageRoute<void> route(Widget child) {
                if (declarative) {
                  final Page<void> page = adapted
                      ? ParallaxSlidePage<void>(child: child)
                      : CupertinoPage<void>(child: child);
                  return page.createRoute(nav.currentContext!)
                      as PageRoute<void>;
                }
                return adapted
                    ? ParallaxSlidePageRoute<void>(page: child)
                    : CupertinoPageRoute<void>(builder: (_) => child);
              }

              await tester.pumpWidget(
                CupertinoApp(
                  key: UniqueKey(),
                  navigatorKey: nav,
                  builder: (_, child) => Directionality(
                    textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
                    child: child!,
                  ),
                  home: const SizedBox(),
                ),
              );
              unawaited(nav.currentState!.push(route(home)));
              await tester.pumpAndSettle();
              final positions = <double>[];
              void record() {
                positions.add(tester.getTopLeft(find.byKey(back)).dx);
                positions.add(tester.getTopLeft(find.byKey(front).last).dx);
              }

              for (final ms in [80, 180, 300, 380]) {
                unawaited(nav.currentState!.push(route(detail)));
                await tester.pump();
                await tester.pump(Duration(milliseconds: ms));
                record();
                nav.currentState!.pop();
                await tester.pump();
                await tester.pump(const Duration(milliseconds: 16));
                record();
                unawaited(nav.currentState!.push(route(detail)));
                await tester.pump();
                for (var frame = 0; frame < 6; frame++) {
                  await tester.pump(const Duration(milliseconds: 16));
                  record();
                }
                await tester.pumpAndSettle();
                nav.currentState!.pop();
                await tester.pumpAndSettle();
                expect(find.byKey(front), findsNothing);
              }
              await tester.pumpWidget(const SizedBox());
              return positions;
            }

            final official = await sample(false);
            final adapted = await sample(true);
            expect(adapted.length, official.length);
            for (var i = 0; i < official.length; i++) {
              expect(
                adapted[i],
                closeTo(official[i], .001),
                reason: 'sample $i',
              );
            }
          },
        );
      }
    }
  }
  testWidgets('source-rendered Cupertino transition preview', (tester) async {
    if (!const bool.fromEnvironment('WRITE_CUPERTINO_PREVIEW')) return;
    final font = FontLoader('Preview');
    await tester.runAsync(() async {
      font.addFont(
        File(
          '/System/Library/Fonts/STHeiti Medium.ttc',
        ).readAsBytes().then(ByteData.sublistView),
      );
      await font.load();
    });
    tester.view.physicalSize = const Size(420, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final boundary = GlobalKey();
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: CupertinoApp(
          debugShowCheckedModeBanner: false,
          theme: const CupertinoThemeData(
            textTheme: CupertinoTextThemeData(
              textStyle: TextStyle(
                fontFamily: 'Preview',
                color: CupertinoColors.black,
                fontSize: 18,
              ),
            ),
          ),
          navigatorKey: nav,
          home: const CupertinoPageScaffold(
            navigationBar: CupertinoNavigationBar(
              automaticallyImplyLeading: false,
              middle: Text(
                '设置',
                style: TextStyle(
                  fontFamily: 'Preview',
                  color: CupertinoColors.black,
                  fontSize: 18,
                ),
              ),
            ),
            child: Center(child: Text('底层页面')),
          ),
        ),
      ),
    );
    unawaited(
      nav.currentState!.push(
        ParallaxSlidePageRoute<void>(
          page: const CupertinoPageScaffold(
            navigationBar: CupertinoNavigationBar(
              automaticallyImplyLeading: false,
              middle: Text(
                '界面',
                style: TextStyle(
                  fontFamily: 'Preview',
                  color: CupertinoColors.black,
                  fontSize: 18,
                ),
              ),
            ),
            child: Center(child: Text('官方 Cupertino 转场')),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 160));
    final render =
        boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final image = await render.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('build/cupertino-transition-preview.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
    await tester.pumpAndSettle();
  });
}
