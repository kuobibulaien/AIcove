import 'dart:io';
import 'dart:ui' as ui;

import 'package:aicove_flutter/src/ui/features/debug/pages/spring_transition_demo.dart';
import 'package:aicove_flutter/src/ui/features/debug/pages/ui_gallery_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const backKey = ValueKey('spring-demo-back');
const reenterKey = ValueKey('spring-demo-reenter');
const translationKey = ValueKey('spring-demo-translation');

double offset(WidgetTester tester) =>
    tester.widget<Transform>(find.byKey(translationKey)).transform.storage[12];

void main() {
  for (final width in [360.0, 1000.0]) {
    for (final demo in SpringTransitionDemo.values) {
      testWidgets(
        '${demo.name} gallery entry, 30 interruptions and cleanup $width',
        (tester) async {
          tester.view.physicalSize = Size(width, 1000);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          await tester.pumpWidget(const MaterialApp(home: UiGalleryPage()));
          await tester.tap(find.byKey(ValueKey('spring-demo-${demo.name}')));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 100));
          expect(offset(tester), inExclusiveRange(0, width));
          final page = tester.element(
            find.byKey(const ValueKey('spring-demo-drag')),
          );
          for (var i = 0; i < 30; i++) {
            final before = offset(tester);
            await tester.tap(find.byKey(i.isEven ? backKey : reenterKey));
            await tester.pump();
            expect(offset(tester), closeTo(before, .001));
            await tester.pump(const Duration(milliseconds: 32));
            expect(
              tester.element(find.byKey(const ValueKey('spring-demo-drag'))),
              same(page),
            );
          }
          await tester.tap(find.byKey(reenterKey));
          await tester.pump();
          await tester.pump(const Duration(seconds: 2));
          expect(offset(tester).abs(), lessThan(.5));
          await tester.binding.handlePopRoute();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 100));
          expect(offset(tester), inExclusiveRange(0, width));
          await tester.tap(find.byKey(reenterKey));
          await tester.pump();
          await tester.pump(const Duration(seconds: 2));
          expect(find.byKey(translationKey), findsOneWidget);
          await tester.tap(find.byKey(backKey));
          await tester.pump();
          await tester.pump(const Duration(seconds: 2));
          await tester.pump();
          expect(find.byKey(translationKey), findsNothing);
          expect(find.text('组件库 (UI Kit)'), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  for (final demo in SpringTransitionDemo.values) {
    testWidgets(
      '${demo.name} drag cancellation, large text and reduced motion',
      (tester) async {
        tester.view.physicalSize = const Size(320, 760);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        Widget app({bool reduced = false}) => MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: const TextScaler.linear(1.8),
              disableAnimations: reduced,
            ),
            child: child!,
          ),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => openSpringTransitionDemo(context, demo),
                child: const Text('打开'),
              ),
            ),
          ),
        );
        await tester.pumpWidget(app());
        await tester.tap(find.text('打开'));
        await tester.pumpAndSettle();
        final gesture = await tester.startGesture(const Offset(40, 350));
        await gesture.moveBy(const Offset(70, 0));
        await tester.pump();
        await gesture.moveBy(const Offset(40, 0));
        await tester.pump();
        expect(offset(tester), greaterThan(20));
        await gesture.cancel();
        await tester.pumpAndSettle();
        expect(offset(tester).abs(), lessThan(.5));
        expect(tester.takeException(), isNull);
        await tester.tap(find.byKey(backKey));
        await tester.pumpAndSettle();
        await tester.pumpWidget(app(reduced: true));
        await tester.tap(find.text('打开'));
        await tester.pumpAndSettle();
        expect(offset(tester), 0);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.byKey(translationKey), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('source rendered gallery and spring demo preview', (
    tester,
  ) async {
    if (!const bool.fromEnvironment('WRITE_SPRING_PREVIEW')) return;
    final font = FontLoader('Preview');
    await tester.runAsync(() async {
      font.addFont(
        File(
          '/System/Library/Fonts/STHeiti Medium.ttc',
        ).readAsBytes().then(ByteData.sublistView),
      );
      await font.load();
      final icons = FontLoader('MaterialIcons');
      icons.addFont(
        File(
          '/tmp/flutter-3.44.6/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
        ).readAsBytes().then(ByteData.sublistView),
      );
      await icons.load();
    });
    tester.view.physicalSize = const Size(420, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final boundary = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(fontFamily: 'Preview'),
          home: const UiGalleryPage(),
        ),
      ),
    );
    await tester.pump();
    Future<void> capture(String name) async {
      final render =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await render.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File('../../.codex-temp/spring-gallery/$name.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }

    await capture('gallery');
    await tester.tap(find.byKey(const ValueKey('spring-demo-motor')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    await capture('demo');
    await tester.tap(find.byKey(backKey));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
  });
}
