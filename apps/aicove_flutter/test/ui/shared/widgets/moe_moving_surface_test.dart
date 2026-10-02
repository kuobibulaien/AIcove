import 'dart:io';
import 'dart:ui' as ui;

import 'package:aicove_flutter/src/ui/shared/widgets/index.dart';
import 'package:aicove_flutter/src/ui/shared/effects/frosted_glass_card.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

const _capture = bool.fromEnvironment('WRITE_MOVING_SURFACE_QA');

Widget _app(Widget child, {bool dark = false, bool liquid = true}) =>
    MaterialApp(
      theme: ThemeData(
        brightness: dark ? Brightness.dark : Brightness.light,
        fontFamily: _capture ? 'MovingSurfacePreview' : null,
        extensions: [dark ? MoeColors.dark() : MoeColors.light()],
      ),
      builder: (context, child) => MoeGlassTheme(
        enabled: true,
        useLiquidGlass: liquid,
        blurSigma: 16,
        child: child!,
      ),
      home: Scaffold(body: child),
    );

void _expectSolid(Finder root) {
  expect(
    find.descendant(of: root, matching: find.byType(AdaptiveGlass)),
    findsNothing,
  );
  expect(
    find.descendant(of: root, matching: find.byType(BackdropFilter)),
    findsNothing,
  );
}

void main() {
  setUp(() => MoeLiquidGlassService.setMockState(available: true));
  tearDown(() => MoeLiquidGlassService.setMockState());
  setUpAll(() async {
    if (!_capture) return;
    final font = FontLoader('MovingSurfacePreview')
      ..addFont(
        File(
          '/System/Library/Fonts/STHeiti Medium.ttc',
        ).readAsBytes().then(ByteData.sublistView),
      );
    await font.load();
    final icons = FontLoader('MaterialIcons')
      ..addFont(
        File(
          '${Platform.environment['FLUTTER_ROOT']}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
        ).readAsBytes().then(ByteData.sublistView),
      );
    await icons.load();
  });

  for (final width in [360.0, 1000.0]) {
    for (final dark in [false, true]) {
      for (final liquid in [false, true]) {
        testWidgets(
          'moving controls are solid before and during scroll $width $dark $liquid',
          (tester) async {
            tester.view.devicePixelRatio = 1;
            tester.view.physicalSize = Size(width, 640);
            addTearDown(tester.view.reset);
            final capture = GlobalKey();
            final list = GlobalKey();
            var selected = 0;
            var taps = 0;
            await tester.pumpWidget(
              _app(
                RepaintBoundary(
                  key: capture,
                  child: ColoredBox(
                    color: dark
                        ? const Color(0xff34444e)
                        : const Color(0xffdbe8ee),
                    child: Center(
                      child: SizedBox(
                        width: 420,
                        child: ListView(
                          key: list,
                          padding: const EdgeInsets.all(16),
                          children: [
                            const Text(
                              '滚动内容 · 实色背景',
                              style: TextStyle(fontSize: 20),
                            ),
                            const SizedBox(height: 16),
                            const MoeTextField(hint: '输入草稿'),
                            const SizedBox(height: 16),
                            const MoeSearchField(hintText: '搜索设置'),
                            const SizedBox(height: 16),
                            MoeToggleBar<int>(
                              value: selected,
                              items: const [
                                MoeToggleItem(value: 0, label: '全部'),
                                MoeToggleItem(value: 1, label: '收藏'),
                              ],
                              onChanged: (value) => selected = value,
                            ),
                            const SizedBox(height: 16),
                            FrostedGlassContainer(
                              padding: const EdgeInsets.all(16),
                              child: Column(
                                children: [
                                  const Text('旧内容卡片同样使用实色背景'),
                                  TextButton(
                                    onPressed: () => taps++,
                                    child: const Text('操作'),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 16),
                            const MoeLiquidGlass(
                              height: 64,
                              child: Center(child: Text('直接材质入口也受保护')),
                            ),
                            const SizedBox(height: 16),
                            MoeSlider(value: 0.5, onChanged: (_) {}),
                            const SizedBox(height: 800),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                dark: dark,
                liquid: liquid,
              ),
            );
            await tester.pumpAndSettle();
            _expectSolid(find.byKey(list));
            await tester.tap(find.text('收藏'));
            expect(selected, 1);
            await tester.tap(find.text('操作'));
            expect(taps, 1);
            await tester.enterText(
              find.descendant(
                of: find.byType(MoeTextField),
                matching: find.byType(TextField),
              ),
              '保留草稿',
            );
            final fieldState = tester.state(find.byType(MoeTextField));
            final before = tester.getTopLeft(find.byType(MoeToggleBar<int>));
            final gesture = await tester.startGesture(Offset(width / 2, 510));
            await gesture.moveBy(const Offset(0, -20));
            await tester.pump();
            await gesture.moveBy(const Offset(0, -70));
            await tester.pump();
            expect(
              tester.getTopLeft(find.byType(MoeToggleBar<int>)).dy,
              lessThan(before.dy),
            );
            _expectSolid(find.byKey(list));
            expect(tester.state(find.byType(MoeTextField)), same(fieldState));
            expect(find.text('保留草稿'), findsOneWidget);
            expect(
              tester
                  .widget<EditableText>(find.byType(EditableText).first)
                  .focusNode
                  .hasFocus,
              isTrue,
            );
            if (_capture && liquid) {
              tester
                  .state<ScrollableState>(
                    find
                        .descendant(
                          of: find.byKey(list),
                          matching: find.byType(Scrollable),
                        )
                        .first,
                  )
                  .position
                  .jumpTo(0);
              await tester.pump();
              await tester.runAsync(() async {
                final image =
                    await (capture.currentContext!.findRenderObject()
                            as RenderRepaintBoundary)
                        .toImage();
                final bytes = await image.toByteData(
                  format: ui.ImageByteFormat.png,
                );
                final file = File(
                  '../../.codex-temp/moving-surfaces/${width.toInt()}-${dark ? 'dark' : 'light'}.png',
                );
                await file.parent.create(recursive: true);
                await file.writeAsBytes(bytes!.buffer.asUint8List());
                image.dispose();
              });
            }
            await gesture.up();
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }

  testWidgets('fixed surface keeps glass while its own content scrolls', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        MoeFloatingSurface(
          child: ListView(
            children: const [Text('固定外框'), SizedBox(height: 1000)],
          ),
        ),
      ),
    );
    expect(find.byType(AdaptiveGlass), findsOneWidget);
    await tester.drag(find.byType(ListView), const Offset(0, -100));
    await tester.pump();
    expect(find.byType(AdaptiveGlass), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('sliver and horizontal scrolling surfaces are solid', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: MoeSegTabBar(
                currentIndex: 0,
                tabs: const ['一', '二', '三'],
                onTap: (_) {},
                scrollable: true,
              ),
            ),
            const SliverToBoxAdapter(
              child: MoeFloatingSurface(child: Text('分组')),
            ),
          ],
        ),
      ),
    );
    _expectSolid(find.byType(CustomScrollView));
  });

  for (final dark in [false, true]) {
    for (final direct in [false, true]) {
      testWidgets(
        'first moved frame paints the surface at its new position $dark $direct',
        (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = const Size(600, 400);
          addTearDown(tester.view.reset);
          final controller = ScrollController();
          addTearDown(controller.dispose);
          final capture = GlobalKey();
          const background = Color(0xff607d8b);
          final surface = dark
              ? MoeColors.dark().componentBackground
              : MoeColors.light().componentBackground;
          await tester.pumpWidget(
            _app(
              RepaintBoundary(
                key: capture,
                child: ColoredBox(
                  color: background,
                  child: ListView(
                    controller: controller,
                    padding: const EdgeInsets.only(
                      left: 60,
                      top: 120,
                      right: 360,
                    ),
                    children: [
                      if (direct)
                        const MoeLiquidGlass(
                          height: 90,
                          border: BorderSide.none,
                          shadows: [],
                          child: SizedBox.expand(),
                        )
                      else
                        const MoeFloatingSurface(
                          border: BorderSide.none,
                          shadows: [],
                          child: SizedBox(height: 90),
                        ),
                      const SizedBox(height: 1000),
                    ],
                  ),
                ),
              ),
              dark: dark,
            ),
          );
          await tester.pumpAndSettle();
          controller.jumpTo(90);
          await tester.pump();
          await tester.runAsync(() async {
            final image =
                await (capture.currentContext!.findRenderObject()
                        as RenderRepaintBoundary)
                    .toImage();
            final bytes = (await image.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            ))!;
            Color pixel(int x, int y) {
              final offset = (y * image.width + x) * 4;
              return Color.fromARGB(
                bytes.getUint8(offset + 3),
                bytes.getUint8(offset),
                bytes.getUint8(offset + 1),
                bytes.getUint8(offset + 2),
              );
            }

            for (final x in [90, 150, 210]) {
              expect(
                pixel(x, 75),
                surface,
                reason:
                    'The new position must contain the solid surface immediately.',
              );
              expect(
                pixel(x, 165),
                background,
                reason:
                    'The vacated position must not retain a black or tinted block.',
              );
            }
            image.dispose();
          });
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('draggable sheet and nested controls remain solid during drag', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showMoeBottomSheet<void>(
              context: context,
              title: '拖动面板',
              builder: (_) => const Padding(
                padding: EdgeInsets.all(20),
                child: MoeTextField(hint: '面板输入'),
              ),
            ),
            child: const Text('打开'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    _expectSolid(find.byType(MoeBottomSheet));
    final before = tester.getTopLeft(find.byType(MoeBottomSheet));
    final gesture = await tester.startGesture(before + const Offset(100, 12));
    await gesture.moveBy(const Offset(0, 20));
    await tester.pump();
    await gesture.moveBy(const Offset(0, 50));
    await tester.pump();
    expect(
      tester.getTopLeft(find.byType(MoeBottomSheet)).dy,
      greaterThan(before.dy),
    );
    _expectSolid(find.byType(MoeBottomSheet));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('slider follower never samples a moving glass backdrop', (
    tester,
  ) async {
    await tester.pumpWidget(_app(MoeSlider(value: .5, onChanged: (_) {})));
    _expectSolid(find.byType(MoeSlider));
  });

  testWidgets('reorder overlay retains solid controls outside the viewport', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        ReorderableListView(
          buildDefaultDragHandles: false,
          onReorderItem: (_, __) {},
          children: [
            for (var i = 0; i < 4; i++)
              ReorderableDelayedDragStartListener(
                key: ValueKey(i),
                index: i,
                child: MoeFloatingSurface(
                  child: SizedBox(height: 80, child: Text('项目 $i')),
                ),
              ),
          ],
        ),
      ),
    );
    expect(find.byType(AdaptiveGlass), findsNothing);
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('项目 0')),
    );
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.moveBy(const Offset(0, 110));
    await tester.pump();
    expect(find.byType(AdaptiveGlass), findsNothing);
    expect(find.byType(BackdropFilter), findsNothing);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
