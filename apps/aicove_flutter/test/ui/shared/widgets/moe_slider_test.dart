import 'dart:io';
import 'dart:ui' as ui;

import 'package:aicove_flutter/src/ui/shared/widgets/form/moe_slider.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/moe_liquid_glass.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

void main() {
  const capture = bool.fromEnvironment('WRITE_SLIDER_QA');
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    for (final name in [
      'liquid_glass_render.frag',
      'liquid_glass_geometry_blended.frag',
      'lightweight_glass.frag',
      'interactive_indicator.frag',
      'progressive_blur.frag',
    ]) {
      final target = File('build/unit_test_assets/shaders/$name');
      await target.parent.create(recursive: true);
      await File(
        'build/unit_test_assets/packages/liquid_glass_widgets/shaders/$name',
      ).copy(target.path);
    }
    await LiquidGlassWidgets.initialize(enablePerformanceMonitor: false);
    if (capture) {
      for (final entry in {
        'MaterialPreview': '/System/Library/Fonts/STHeiti Medium.ttc',
        'MaterialIcons':
            '${Platform.environment['FLUTTER_ROOT']}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
      }.entries) {
        final font = FontLoader(entry.key)
          ..addFont(File(entry.value).readAsBytes().then(ByteData.sublistView));
        await font.load();
      }
    }
  });

  tearDownAll(() => MoeLiquidGlassService.setMockState(available: true));

  Widget wrap(Widget child) => MaterialApp(
    home: Scaffold(
      body: Center(child: SizedBox(width: 300, child: child)),
    ),
  );

  Widget themed(
    Widget child, {
    bool dark = false,
    bool enabled = true,
    bool useLiquid = false,
    double sigma = 16,
    bool reduceTransparency = false,
    bool highContrast = false,
    bool disableAnimations = false,
    TextDirection direction = TextDirection.ltr,
    double width = 300,
    double textScale = 1,
  }) {
    return MaterialApp(
      theme: ThemeData(
        brightness: dark ? Brightness.dark : Brightness.light,
        fontFamily: capture ? 'MaterialPreview' : null,
        extensions: [dark ? MoeColors.dark() : MoeColors.light()],
      ),
      home: MediaQuery(
        data: MediaQueryData(
          highContrast: highContrast,
          disableAnimations: disableAnimations,
          textScaler: TextScaler.linear(textScale),
        ),
        child: Directionality(
          textDirection: direction,
          child: Scaffold(
            body: Center(
              child: MoeGlassTheme(
                enabled: enabled,
                blurSigma: sigma,
                useLiquidGlass: useLiquid,
                child: GlassAccessibilityScope(
                  reduceTransparency: reduceTransparency,
                  child: SizedBox(width: width, child: child),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Finder thumb() => find.byKey(const ValueKey('moe-slider-thumb'));

  Finder inThumb(Type type) => find.descendant(
    of: thumb(),
    matching: find.byType(type),
    matchRoot: true,
  );

  double renderedScale(WidgetTester tester) => tester
      .widget<Transform>(
        find.ancestor(
          of: inThumb(MoeLiquidGlass),
          matching: find.byType(Transform),
        ),
      )
      .transform
      .getMaxScaleOnAxis();

  Offset expectedThumbCenter(
    WidgetTester tester,
    double value,
    double min,
    double max, {
    TextDirection direction = TextDirection.ltr,
  }) {
    final slider = tester.getRect(find.byType(Slider));
    final fraction = (value - min) / (max - min);
    final dx = direction == TextDirection.ltr
        ? slider.left + 20 + fraction * (slider.width - 40)
        : slider.right - 20 - fraction * (slider.width - 40);
    return Offset(dx, slider.center.dy);
  }

  testWidgets('MoeSlider 无极调节输出连续值', (tester) async {
    final values = <double>[];
    await tester.pumpWidget(
      wrap(MoeSlider(value: 0, min: 0, max: 32, onChanged: values.add)),
    );
    final start = tester.getCenter(thumb());
    await tester.dragFrom(start, const Offset(300 * 0.613, 0));
    await tester.pump();
    expect(values, isNotEmpty);
    expect(values.last, greaterThan(0));
    expect(values.last, lessThan(32));
    expect(
      values.last,
      isNot(equals(values.last.roundToDouble())),
      reason: '未设置 divisions 时不得吸附到整数',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('MoeSlider divisions 只保留吸附语义', (tester) async {
    final values = <double>[];
    await tester.pumpWidget(
      wrap(
        MoeSlider(
          value: 0,
          min: 0,
          max: 32,
          divisions: 2,
          onChanged: values.add,
        ),
      ),
    );
    final start = tester.getCenter(thumb());
    await tester.dragFrom(start, const Offset(300 * 0.4, 0));
    await tester.pump();
    expect(values.last, 16);
  });

  testWidgets('MoeSlider 轨道不渲染刻度点', (tester) async {
    await tester.pumpWidget(
      wrap(
        MoeSlider(value: 8, min: 0, max: 32, divisions: 4, onChanged: (_) {}),
      ),
    );
    final theme = tester.widget<SliderTheme>(
      find.descendant(
        of: find.byType(MoeSlider),
        matching: find.byType(SliderTheme),
      ),
    );
    expect(theme.data.tickMarkShape, SliderTickMarkShape.noTickMark);
    expect(tester.takeException(), isNull);
  });

  testWidgets('MoeSlider 禁用态可渲染', (tester) async {
    await tester.pumpWidget(wrap(const MoeSlider(value: 8, min: 0, max: 32)));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('滑钮为 32×24 圆角矩形并采用实色材质', (tester) async {
    await tester.pumpWidget(
      wrap(MoeSlider(value: 16, min: 0, max: 32, onChanged: (_) {})),
    );
    expect(thumb(), findsOneWidget);
    expect(tester.getSize(thumb()), const Size(32, 24));
    final glass = tester.widget<MoeLiquidGlass>(inThumb(MoeLiquidGlass));
    expect(glass.radius, 8);
    expect(glass.quality, GlassQuality.standard);
    expect(glass.baseline, same(MoeMaterialBaseline.none));
    expect(tester.takeException(), isNull);
  });

  for (final dark in [false, true]) {
    testWidgets('滑钮在全局三态下始终不采样背景 dark=$dark', (tester) async {
      Widget slider() =>
          MoeSlider(value: 16, min: 0, max: 32, onChanged: (_) {});

      await tester.pumpWidget(themed(slider(), dark: dark, enabled: false));
      expect(inThumb(BackdropFilter), findsNothing);
      expect(inThumb(AdaptiveGlass), findsNothing);

      await tester.pumpWidget(
        themed(slider(), dark: dark, enabled: true, useLiquid: false),
      );
      expect(inThumb(BackdropFilter), findsNothing);
      expect(inThumb(AdaptiveGlass), findsNothing);

      await tester.pumpWidget(
        themed(slider(), dark: dark, enabled: true, useLiquid: true),
      );
      expect(inThumb(AdaptiveGlass), findsNothing);
      expect(inThumb(BackdropFilter), findsNothing);

      MoeLiquidGlassService.setMockState(available: false);
      await tester.pumpWidget(
        themed(slider(), dark: dark, enabled: true, useLiquid: true),
      );
      expect(inThumb(AdaptiveGlass), findsNothing);
      expect(inThumb(BackdropFilter), findsNothing);
      MoeLiquidGlassService.setMockState(available: true);

      await tester.pumpWidget(
        themed(
          slider(),
          dark: dark,
          enabled: true,
          useLiquid: true,
          reduceTransparency: true,
        ),
      );
      expect(inThumb(AdaptiveGlass), findsNothing);
      expect(inThumb(BackdropFilter), findsNothing);

      await tester.pumpWidget(
        themed(
          slider(),
          dark: dark,
          enabled: true,
          useLiquid: true,
          highContrast: true,
        ),
      );
      expect(inThumb(AdaptiveGlass), findsNothing);
      expect(inThumb(BackdropFilter), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('滑钮在全局强度 0/16/32 下保持不透明', (tester) async {
    for (final sigma in [0.0, 16.0, 32.0]) {
      await tester.pumpWidget(
        themed(
          MoeSlider(value: 16, min: 0, max: 32, onChanged: (_) {}),
          useLiquid: true,
          sigma: sigma,
        ),
      );
      expect(inThumb(AdaptiveGlass), findsNothing);
      expect(inThumb(BackdropFilter), findsNothing);
      final surfaces = tester.widgetList<Material>(inThumb(Material));
      expect(surfaces.where((surface) => surface.color?.a == 1), isNotEmpty);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('按住滑钮放大 1.25 拖动跟随松手恢复', (tester) async {
    final values = <double>[];
    final ends = <double>[];
    double current = 16;
    await tester.pumpWidget(
      wrap(
        StatefulBuilder(
          builder: (context, setInner) => MoeSlider(
            value: current,
            min: 0,
            max: 32,
            onChanged: (v) {
              values.add(v);
              setInner(() => current = v);
            },
            onChangeEnd: ends.add,
          ),
        ),
      ),
    );
    double target() =>
        tester.widget<AnimatedScale>(inThumb(AnimatedScale)).scale;
    expect(target(), 1.0);
    expect(renderedScale(tester), moreOrLessEquals(1, epsilon: 0.01));

    final gesture = await tester.startGesture(tester.getCenter(thumb()));
    await tester.pump();
    expect(target(), 1.25);
    await tester.pump(kAnimFast * 2);
    expect(target(), 1.25);
    expect(renderedScale(tester), moreOrLessEquals(1.25, epsilon: 0.01));

    final before = tester.getCenter(thumb());
    await gesture.moveBy(const Offset(48, 0));
    await tester.pump();
    expect(values, isNotEmpty);
    expect(tester.getCenter(thumb()).dx, greaterThan(before.dx));

    await gesture.up();
    await tester.pump();
    expect(ends.length, 1);
    await tester.pump(kAnimFast * 2);
    expect(target(), 1.0);
    expect(renderedScale(tester), moreOrLessEquals(1, epsilon: 0.01));
    expect(tester.takeException(), isNull);
  });

  testWidgets('取消按下恢复且不额外派发 onChanged', (tester) async {
    final values = <double>[];
    final ends = <double>[];
    await tester.pumpWidget(
      wrap(
        MoeSlider(
          value: 16,
          min: 0,
          max: 32,
          onChanged: values.add,
          onChangeEnd: ends.add,
        ),
      ),
    );
    final gesture = await tester.startGesture(tester.getCenter(thumb()));
    await tester.pump();
    expect(tester.widget<AnimatedScale>(inThumb(AnimatedScale)).scale, 1.25);
    final afterDown = values.length;
    await gesture.cancel();
    await tester.pump();
    await tester.pump(kAnimFast * 2);
    expect(values.length, afterDown);
    expect(tester.widget<AnimatedScale>(inThumb(AnimatedScale)).scale, 1.0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('禁用与零范围滑钮不放大不派发回调', (tester) async {
    final values = <double>[];
    final ends = <double>[];
    await tester.pumpWidget(
      wrap(MoeSlider(value: 16, min: 0, max: 32, onChangeEnd: ends.add)),
    );
    var gesture = await tester.startGesture(tester.getCenter(thumb()));
    await tester.pump();
    await tester.pump(kAnimFast * 2);
    expect(tester.widget<AnimatedScale>(inThumb(AnimatedScale)).scale, 1.0);
    await gesture.up();
    await tester.pump();
    expect(values, isEmpty);
    expect(ends, isEmpty);

    await tester.pumpWidget(
      wrap(
        MoeSlider(
          value: 8,
          min: 8,
          max: 8,
          onChanged: values.add,
          onChangeEnd: ends.add,
        ),
      ),
    );
    gesture = await tester.startGesture(tester.getCenter(thumb()));
    await tester.pump();
    await gesture.moveBy(const Offset(40, 0));
    await tester.pump();
    await tester.pump(kAnimFast * 2);
    expect(tester.widget<AnimatedScale>(inThumb(AnimatedScale)).scale, 1.0);
    await gesture.up();
    await tester.pump();
    expect(values, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('滑钮中心与轨道取值对齐（LTR/RTL/离散动画帧）', (tester) async {
    for (final direction in [TextDirection.ltr, TextDirection.rtl]) {
      for (final value in [0.0, 16.0, 32.0]) {
        await tester.pumpWidget(
          themed(
            MoeSlider(value: value, min: 0, max: 32, onChanged: (_) {}),
            direction: direction,
          ),
        );
        final center = tester.getCenter(thumb());
        final expected = expectedThumbCenter(
          tester,
          value,
          0,
          32,
          direction: direction,
        );
        expect(
          center.dx,
          moreOrLessEquals(expected.dx, epsilon: 1),
          reason: '$direction value=$value 滑钮未对齐轨道取值',
        );
        expect(center.dy, moreOrLessEquals(expected.dy, epsilon: 1));
      }
    }

    final follower = tester.renderObject<RenderFollowerLayer>(
      find.ancestor(
        of: thumb(),
        matching: find.byType(CompositedTransformFollower),
      ),
    );
    expect(follower.link.leader, isNotNull);

    final values = <double>[];
    double current = 0;
    await tester.pumpWidget(
      themed(
        StatefulBuilder(
          builder: (context, setInner) => MoeSlider(
            value: current,
            min: 0,
            max: 32,
            divisions: 2,
            onChanged: (v) {
              values.add(v);
              setInner(() => current = v);
            },
          ),
        ),
      ),
    );
    final track = tester.getRect(find.byType(Slider));
    final gesture = await tester.startGesture(
      Offset(track.left + 24, track.center.dy),
    );
    await gesture.moveBy(Offset(track.width - 52, 0));
    await tester.pump();
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 20));
    final mid1 = tester.getCenter(thumb()).dx;
    await tester.pump(const Duration(milliseconds: 40));
    final mid2 = tester.getCenter(thumb()).dx;
    await tester.pump(kAnimFast * 3);
    final end = tester.getCenter(thumb()).dx;
    expect(values.last, 32);
    expect(end, moreOrLessEquals(track.right - 20, epsilon: 1));
    expect(mid1, lessThan(end));
    expect(mid2, lessThanOrEqualTo(end));
    expect(tester.takeException(), isNull);
  });

  testWidgets('外部重建改变取值滑钮跟随且不派发回调', (tester) async {
    final values = <double>[];
    Widget host(double v, {double top = 0}) => MaterialApp(
      home: Scaffold(
        body: Padding(
          padding: EdgeInsets.only(top: top),
          child: Align(
            alignment: Alignment.topCenter,
            child: SizedBox(
              width: 300,
              height: 48,
              child: MoeSlider(
                value: v,
                min: 0,
                max: 32,
                onChanged: values.add,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpWidget(host(16));
    final before = tester.getCenter(thumb());
    await tester.pumpWidget(host(24));
    final moved = tester.getCenter(thumb());
    expect(moved.dx, greaterThan(before.dx));
    expect(
      moved.dx,
      moreOrLessEquals(expectedThumbCenter(tester, 24, 0, 32).dx, epsilon: 1),
    );
    await tester.pumpWidget(host(24, top: 100));
    await tester.pump();
    final shifted = tester.getCenter(thumb());
    expect(shifted.dy, moreOrLessEquals(moved.dy + 100, epsilon: 1));
    expect(values, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('键盘与读屏语义保持原生行为', (tester) async {
    final semantics = tester.ensureSemantics();
    final values = <double>[];
    final ends = <double>[];
    await tester.pumpWidget(
      wrap(
        MoeSlider(
          value: 16,
          min: 0,
          max: 32,
          semanticFormatterCallback: (v) => '模糊度 ${v.round()}%',
          onChanged: values.add,
          onChangeEnd: ends.add,
        ),
      ),
    );
    expect(
      find.ancestor(of: thumb(), matching: find.byType(ExcludeSemantics)),
      findsOneWidget,
    );
    final sliders = <SemanticsNode>[];
    bool collectSliders(SemanticsNode n) {
      if (n.getSemanticsData().flagsCollection.isSlider) {
        sliders.add(n);
      }
      n.visitChildren(collectSliders);
      return true;
    }

    void collectRoots(PipelineOwner owner) {
      final root = owner.semanticsOwner?.rootSemanticsNode;
      if (root != null) {
        collectSliders(root);
      }
      owner.visitChildren(collectRoots);
    }

    collectRoots(tester.binding.rootPipelineOwner);
    expect(sliders, hasLength(1));
    expect(sliders.single.value, contains('16%'));

    await tester.tap(find.byType(Slider));
    await tester.pump();
    values.clear();
    final focusNode = tester
        .widgetList<Focus>(
          find.descendant(
            of: find.byType(Slider),
            matching: find.byType(Focus),
          ),
        )
        .where((f) => f.focusNode != null)
        .first
        .focusNode;
    focusNode!.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(values, isNotEmpty);
    expect(values.last, greaterThan(16));
    expect(ends, isNotEmpty);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('纵向滚动不被滑钮截获且滑钮跟随滚动', (tester) async {
    final values = <double>[];
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            controller: controller,
            children: [
              const SizedBox(height: 300),
              SizedBox(
                width: 300,
                child: MoeSlider(
                  value: 16,
                  min: 0,
                  max: 32,
                  onChanged: values.add,
                ),
              ),
              const SizedBox(height: 900),
            ],
          ),
        ),
      ),
    );
    final before = tester.getCenter(thumb());
    final vertical = await tester.startGesture(tester.getCenter(thumb()));
    for (var i = 0; i < 12; i++) {
      await vertical.moveBy(const Offset(0, -10));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await vertical.up();
    await tester.pump();
    expect(controller.offset, greaterThan(0));
    expect(tester.getCenter(thumb()).dy, lessThan(before.dy));

    values.clear();
    final horizontal = await tester.startGesture(tester.getCenter(thumb()));
    await horizontal.moveBy(const Offset(40, 0));
    await horizontal.up();
    await tester.pump();
    expect(values, isNotEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('滑钮可见半区与高热区内按下即可拖动', (tester) async {
    final values = <double>[];
    final ends = <double>[];
    double current = 0;
    int? divisions;
    TextDirection dir = TextDirection.ltr;
    bool enabled = true;

    Widget host() => themed(
      SizedBox(
        height: 48,
        child: StatefulBuilder(
          builder: (context, setInner) => MoeSlider(
            value: current,
            min: 0,
            max: 32,
            divisions: divisions,
            onChanged: enabled
                ? (v) {
                    values.add(v);
                    setInner(() => current = v);
                  }
                : null,
            onChangeEnd: ends.add,
          ),
        ),
      ),
      direction: dir,
    );

    double scale() =>
        tester.widget<AnimatedScale>(inThumb(AnimatedScale)).scale;

    Future<TestGesture> grabAt(Offset point) async {
      final g = await tester.startGesture(point);
      await tester.pump();
      await tester.pump(kAnimFast * 2);
      return g;
    }

    await tester.pumpWidget(host());
    var center = tester.getCenter(thumb());
    var g = await grabAt(center - const Offset(10, 0));
    expect(scale(), 1.25, reason: 'min 端可见中心左 10px 应可按下');
    await g.moveBy(const Offset(60, 0));
    await tester.pump();
    expect(values, isNotEmpty);
    expect(current, greaterThan(0));
    await g.up();
    await tester.pump();
    expect(ends, isNotEmpty);

    current = 32;
    await tester.pumpWidget(host());
    values.clear();
    ends.clear();
    center = tester.getCenter(thumb());
    g = await grabAt(center + const Offset(10, 0));
    expect(scale(), 1.25, reason: 'max 端可见中心右 10px 应可按下');
    await g.moveBy(const Offset(-60, 0));
    await tester.pump();
    expect(values, isNotEmpty);
    expect(current, lessThan(32));
    await g.up();
    await tester.pump();

    g = await grabAt(tester.getCenter(thumb()));
    expect(scale(), 1.25, reason: 'max 端可见中心正点应可按下');
    await g.up();
    await tester.pump();

    current = 16;
    await tester.pumpWidget(host());
    values.clear();
    center = tester.getCenter(thumb());
    g = await grabAt(center - const Offset(0, 20));
    expect(scale(), 1.25, reason: '滑钮上方 20px 高热区应可按下');
    await g.moveBy(const Offset(40, 0));
    await tester.pump();
    expect(values, isNotEmpty);
    await g.up();
    await tester.pump();
    values.clear();
    g = await grabAt(center + const Offset(0, 20));
    expect(scale(), 1.25, reason: '滑钮下方 20px 高热区应可按下');
    await g.up();
    await tester.pump();

    divisions = 2;
    current = 0;
    await tester.pumpWidget(host());
    values.clear();
    center = tester.getCenter(thumb());
    g = await grabAt(center - const Offset(10, 0));
    expect(scale(), 1.25, reason: '离散 min 端左 10px 应可按下');
    await g.moveBy(const Offset(60, 0));
    await tester.pump();
    expect(values, isNotEmpty);
    await g.up();
    await tester.pump();
    divisions = null;

    dir = TextDirection.rtl;
    current = 0;
    await tester.pumpWidget(host());
    values.clear();
    center = tester.getCenter(thumb());
    g = await grabAt(center + const Offset(10, 0));
    expect(scale(), 1.25, reason: 'RTL min 端（右侧）可见中心右 10px 应可按下');
    await g.moveBy(const Offset(-60, 0));
    await tester.pump();
    expect(values, isNotEmpty);
    expect(current, greaterThan(0));
    await g.up();
    await tester.pump();
    dir = TextDirection.ltr;

    enabled = false;
    current = 16;
    await tester.pumpWidget(host());
    values.clear();
    ends.clear();
    g = await grabAt(tester.getCenter(thumb()));
    expect(scale(), 1.0, reason: '禁用态不应放大');
    expect(values, isEmpty);
    await g.up();
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('减少动画时按下立即放大松手立即恢复', (tester) async {
    double current = 16;
    await tester.pumpWidget(
      themed(
        StatefulBuilder(
          builder: (context, setInner) => MoeSlider(
            value: current,
            min: 0,
            max: 32,
            onChanged: (v) => setInner(() => current = v),
          ),
        ),
        disableAnimations: true,
      ),
    );
    final g = await tester.startGesture(tester.getCenter(thumb()));
    await tester.pump();
    expect(renderedScale(tester), moreOrLessEquals(1.25, epsilon: 0.01));
    await g.up();
    await tester.pump();
    expect(renderedScale(tester), moreOrLessEquals(1.0, epsilon: 0.01));
    expect(tester.takeException(), isNull);
  });

  testWidgets('祖先缩放与不对称纵向内距下滑钮中心与轨道一致', (tester) async {
    RenderBox sliderRender() {
      RenderObject? ro = tester.renderObject(find.byType(Slider));
      while (ro != null && ro.runtimeType.toString() != '_RenderSlider') {
        RenderObject? next;
        ro.visitChildren((child) => next = child);
        ro = next;
      }
      return ro! as RenderBox;
    }

    Offset expectedCenter(double fraction) {
      final render = sliderRender();
      final theme = tester
          .widget<SliderTheme>(
            find.descendant(
              of: find.byType(MoeSlider),
              matching: find.byType(SliderTheme),
            ),
          )
          .data;
      final track = theme.trackShape!.getPreferredRect(
        parentBox: render,
        sliderTheme: theme,
      );
      return render.localToGlobal(
        Offset(track.left + fraction * track.width, track.center.dy),
      );
    }

    for (final scaleFactor in [0.9, 1.2]) {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(extensions: [MoeColors.light()]),
          home: Scaffold(
            body: Center(
              child: Transform.scale(
                scale: scaleFactor,
                child: SizedBox(
                  width: 300,
                  child: MoeSlider(
                    value: 8,
                    min: 0,
                    max: 32,
                    onChanged: (_) {},
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final expected = expectedCenter(0.25);
      final actual = tester.getCenter(thumb());
      expect(actual.dx, moreOrLessEquals(expected.dx, epsilon: 1));
      expect(actual.dy, moreOrLessEquals(expected.dy, epsilon: 1));
    }

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(extensions: [MoeColors.light()]),
        home: Scaffold(
          body: Center(
            child: SliderTheme(
              data: const SliderThemeData(padding: EdgeInsets.only(top: 24)),
              child: SizedBox(
                width: 300,
                child: MoeSlider(value: 8, min: 0, max: 32, onChanged: (_) {}),
              ),
            ),
          ),
        ),
      ),
    );
    final expected = expectedCenter(0.25);
    final actual = tester.getCenter(thumb());
    expect(actual.dx, moreOrLessEquals(expected.dx, epsilon: 1));
    expect(actual.dy, moreOrLessEquals(expected.dy, epsilon: 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄宽与 1.8 字级布局无溢出且端点放大不裁切', (tester) async {
    for (final width in [320.0, 420.0, 1000.0]) {
      for (final scale in [1.0, 1.8]) {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(width, 300 * scale);
        await tester.pumpWidget(
          themed(
            MoeSlider(value: 32, min: 0, max: 32, onChanged: (_) {}),
            width: width - 24,
            textScale: scale,
          ),
        );
        expect(tester.takeException(), isNull);
        final size = tester.getSize(find.byType(MoeSlider));
        expect(size.height, greaterThanOrEqualTo(48));
        final gesture = await tester.startGesture(tester.getCenter(thumb()));
        await tester.pump();
        await tester.pump(kAnimFast * 2);
        expect(
          tester.widget<AnimatedScale>(inThumb(AnimatedScale)).scale,
          1.25,
        );
        final center = tester.getCenter(thumb());
        final slider = tester.getRect(find.byType(Slider));
        expect(center.dx, lessThanOrEqualTo(slider.right));
        expect(
          center.dx + 20,
          lessThanOrEqualTo(slider.right + 0.5),
          reason: '端点放大后的可视边缘不得超出滑条边界',
        );
        await gesture.up();
        await tester.pump();
      }
    }
    tester.view.reset();
  });

  testWidgets('slider thumb material QA preview', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(420, 320);
    addTearDown(tester.view.reset);

    final logs = <String>[];
    final originalDebugPrint = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) logs.add(message);
      originalDebugPrint(message, wrapWidth: wrapWidth);
    };
    addTearDown(() => debugPrint = originalDebugPrint);

    Widget row(String label, {required bool enabled, required bool liquid}) {
      Widget cell() => Expanded(
        child: MoeGlassTheme(
          enabled: enabled,
          blurSigma: 16,
          useLiquidGlass: liquid,
          child: MoeSlider(value: 16, min: 0, max: 32, onChanged: (_) {}),
        ),
      );
      return SizedBox(
        height: 64,
        child: Row(
          children: [
            SizedBox(width: 44, child: Text(label)),
            cell(),
            const SizedBox(width: 12),
            cell(),
          ],
        ),
      );
    }

    try {
      for (final dark in [false, true]) {
        final boundaryKey = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(
              brightness: dark ? Brightness.dark : Brightness.light,
              fontFamily: capture ? 'MaterialPreview' : null,
              extensions: [dark ? MoeColors.dark() : MoeColors.light()],
            ),
            home: Scaffold(
              body: RepaintBoundary(
                key: boundaryKey,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(
                        height: 24,
                        child: Row(
                          children: [
                            SizedBox(width: 44),
                            Expanded(
                              child: Center(
                                child: Text(
                                  '普通',
                                  style: TextStyle(fontSize: 12),
                                ),
                              ),
                            ),
                            SizedBox(width: 12),
                            Expanded(
                              child: Center(
                                child: Text(
                                  '按住拖动',
                                  style: TextStyle(fontSize: 12),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      row('纯色', enabled: false, liquid: false),
                      row('模糊', enabled: true, liquid: false),
                      row('玻璃', enabled: true, liquid: true),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        final shaderProblems = logs.where(
          (line) =>
              (line.contains('LiquidGlass') ||
                  line.contains('LightweightGlass') ||
                  line.toLowerCase().contains('shader')) &&
              (line.contains('failed') ||
                  line.contains('Error') ||
                  line.contains('fallback')),
        );
        expect(shaderProblems, isEmpty);
        expect(thumb(), findsNWidgets(6));
        expect(find.byType(LightweightLiquidGlass), findsNothing);

        final presses = <TestGesture>[];
        for (final i in [1, 3, 5]) {
          presses.add(
            await tester.startGesture(tester.getCenter(thumb().at(i))),
          );
        }
        await tester.pump();
        await tester.pump(kAnimFast * 2);
        expect(
          tester
              .widget<AnimatedScale>(
                find.descendant(
                  of: thumb().at(1),
                  matching: find.byType(AnimatedScale),
                  matchRoot: true,
                ),
              )
              .scale,
          1.25,
        );

        if (capture) {
          await tester.runAsync(() async {
            tester.binding.drawFrame();
            final boundary =
                boundaryKey.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            final image = await boundary.toImage(pixelRatio: 2);
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final file = File(
              '../../scratch/slider-thumb-20260916/slider-thumb-${dark ? 'dark' : 'light'}.png',
            );
            await file.parent.create(recursive: true);
            await file.writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
        for (final press in presses) {
          await press.up();
        }
        await tester.pump();
      }
    } finally {
      debugPrint = originalDebugPrint;
    }
    expect(tester.takeException(), isNull);
  });
}
