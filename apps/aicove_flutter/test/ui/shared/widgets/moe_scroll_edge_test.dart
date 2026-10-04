import 'dart:io';
import 'dart:ui' as ui;

import 'package:aicove_flutter/src/ui/shared/widgets/moe_app_bar.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/moe_chat_header.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/moe_scroll_edge.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/moe_search_field.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const capture = bool.fromEnvironment('WRITE_SCROLL_EDGE_QA');
  setUp(() => MoeLiquidGlassService.setMockState(available: false));
  tearDown(() => MoeLiquidGlassService.setMockState());
  setUpAll(() async {
    if (!capture) return;
    final font = FontLoader('ScrollEdgeCapture')
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

  double edgeOpacity(WidgetTester tester) => tester
      .widget<AnimatedOpacity>(
        find.descendant(
          of: find.byType(MoeScrollEdgeBackdrop),
          matching: find.byType(AnimatedOpacity),
        ),
      )
      .opacity;

  Widget app({
    required Widget home,
    MoeSurfaceMaterial material = MoeSurfaceMaterial.frosted,
    bool dark = false,
  }) => MaterialApp(
    theme: ThemeData(
      brightness: dark ? Brightness.dark : Brightness.light,
      fontFamily: capture ? 'ScrollEdgeCapture' : null,
      extensions: [dark ? MoeColors.dark() : MoeColors.light()],
    ),
    home: MoeGlassTheme(
      enabled: material != MoeSurfaceMaterial.solid,
      useLiquidGlass: material == MoeSurfaceMaterial.liquid,
      blurSigma: kDefaultGlassBlurSigma,
      child: home,
    ),
  );

  Widget rows(BuildContext context, {bool reverse = false}) => ListView.builder(
    reverse: reverse,
    padding: moeUnderBarPadding(context),
    itemCount: 40,
    itemBuilder: (context, index) => Container(
      key: ValueKey('row-$index'),
      height: 56,
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      color: Color([0xFF35A795, 0xFFE27291, 0xFF4A90E2, 0xFFFFD54F][index % 4]),
      child: Text('内容行 $index'),
    ),
  );

  Widget rootPage() => Builder(
    builder: (context) => Scaffold(
      extendBodyBehindAppBar: true,
      appBar: MoeAppBar(
        title: '聊天',
        centerTitle: true,
        bottom: const MoeSearchField(),
        bottomHeight: MoeSearchField.heightFor(context),
      ),
      body: Builder(builder: rows),
    ),
  );

  testWidgets('一级栏静止时透明，内容从栏下滑过时出现滚动边缘', (tester) async {
    await tester.pumpWidget(app(home: rootPage()));
    await tester.pumpAndSettle();

    final barBottom = tester.getBottomLeft(find.byType(AppBar)).dy;
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('row-0'))).dy,
      barBottom,
    );
    expect(edgeOpacity(tester), 0);
    expect(
      find.descendant(
        of: find.byType(MoeScrollEdgeBackdrop),
        matching: find.byType(BackdropFilter),
      ),
      findsNothing,
    );

    await tester.drag(find.byType(ListView), const Offset(0, -120));
    await tester.pumpAndSettle();
    expect(edgeOpacity(tester), 1);
    expect(
      find.descendant(
        of: find.byType(MoeScrollEdgeBackdrop),
        matching: find.byType(BackdropFilter),
      ),
      findsWidgets,
    );

    await tester.drag(find.byType(ListView), const Offset(0, 400));
    await tester.pumpAndSettle();
    expect(edgeOpacity(tester), 0);
    expect(
      find.descendant(
        of: find.byType(MoeScrollEdgeBackdrop),
        matching: find.byType(BackdropFilter),
      ),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('倒序聊天列表按上方剩余内容判断', (tester) async {
    await tester.pumpWidget(
      app(
        home: Scaffold(
          extendBodyBehindAppBar: true,
          appBar: const MoeAppBar(title: '会话', showBackButton: true),
          body: Builder(builder: (context) => rows(context, reverse: true)),
        ),
      ),
    );
    await tester.drag(find.byType(ListView), const Offset(0, -10));
    await tester.pumpAndSettle();
    expect(edgeOpacity(tester), 1);
  });

  testWidgets('纯色与降低透明度时退回不透明栏和分隔线，不做模糊', (tester) async {
    await tester.pumpWidget(
      app(home: rootPage(), material: MoeSurfaceMaterial.solid),
    );
    await tester.drag(find.byType(ListView), const Offset(0, -120));
    await tester.pumpAndSettle();
    expect(edgeOpacity(tester), 1);
    expect(
      find.descendant(
        of: find.byType(MoeScrollEdgeBackdrop),
        matching: find.byType(BackdropFilter),
      ),
      findsNothing,
    );
  });

  testWidgets('聊天标题栏纯色时控件自带底色，滑过内容也不铺整条背板', (tester) async {
    await tester.pumpWidget(
      app(
        material: MoeSurfaceMaterial.solid,
        home: Scaffold(
          extendBodyBehindAppBar: true,
          appBar: const MoeChatHeader(
            title: Text('text1'),
            actions: [Icon(Icons.more_horiz)],
            showBackButton: true,
            nativeInset: 0,
            toolbarHeight: telegramChatHeaderHeight,
          ),
          body: Builder(builder: (context) => rows(context, reverse: true)),
        ),
      ),
    );
    await tester.drag(find.byType(ListView), const Offset(0, -10));
    await tester.pumpAndSettle();
    final backdrop = find.byType(MoeScrollEdgeBackdrop);
    expect(
      find.descendant(of: backdrop, matching: find.byType(DecoratedBox)),
      findsNothing,
    );
    expect(
      find.descendant(of: backdrop, matching: find.byType(BackdropFilter)),
      findsNothing,
    );
  });

  if (!capture) return;
  for (final dark in [false, true]) {
    for (final material in [
      MoeSurfaceMaterial.frosted,
      MoeSurfaceMaterial.liquid,
    ]) {
      testWidgets('capture ${material.name} dark=$dark', (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(400, 420);
        tester.view.padding = const FakeViewPadding(top: 28);
        tester.view.viewPadding = const FakeViewPadding(top: 28);
        addTearDown(tester.view.reset);
        final key = GlobalKey();
        final detail = Scaffold(
          extendBodyBehindAppBar: true,
          appBar: MoeAppBar(
            title: '模型',
            showBackButton: true,
            actions: [
              IconButton(onPressed: () {}, icon: const Icon(Icons.add)),
            ],
          ),
          body: Builder(builder: rows),
        );
        for (final (name, page) in [('root', rootPage()), ('detail', detail)]) {
          await tester.pumpWidget(
            app(
              home: RepaintBoundary(key: key, child: page),
              material: material,
              dark: dark,
            ),
          );
          await tester.drag(find.byType(ListView), const Offset(0, -130));
          await tester.pumpAndSettle();
          await tester.runAsync(() async {
            final boundary =
                key.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            final image = await boundary.toImage(pixelRatio: 2);
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final file = File(
              '../../.codex-temp/scroll-edge/$name-${material.name}-${dark ? 'dark' : 'light'}.png',
            );
            await file.parent.create(recursive: true);
            await file.writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
      });
    }
  }
}
