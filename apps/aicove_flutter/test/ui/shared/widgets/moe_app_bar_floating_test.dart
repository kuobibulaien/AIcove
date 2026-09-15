import 'dart:io';
import 'dart:ui' as ui;

import 'package:aicove_flutter/src/ui/shared/widgets/moe_app_bar.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/moe_chat_header.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/moe_floating_surface.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const capture = bool.fromEnvironment('WRITE_DETAIL_HEADER_QA');
  setUp(() => MoeLiquidGlassService.setMockState(available: false));
  tearDown(() => MoeLiquidGlassService.setMockState());
  setUpAll(() async {
    if (!capture) return;
    final font = FontLoader('DetailHeaderCapture')
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

  testWidgets('带返回的详情页复用聊天悬浮头部，一级页保持平铺', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(extensions: [MoeColors.light()]),
        home: const Scaffold(
          appBar: MoeAppBar(title: '渠道详情', showBackButton: true),
        ),
      ),
    );
    expect(find.byType(MoeChatHeader), findsOneWidget);
    expect(find.byType(AppBar), findsNothing);
    expect(find.byType(BackButton), findsOneWidget);
    // 返回圆与标题胶囊各一个 MoeFloatingSurface；无操作时不生成第三个胶囊。
    expect(
      find.descendant(
        of: find.byType(MoeChatHeader),
        matching: find.byType(MoeFloatingSurface),
      ),
      findsNWidgets(2),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(extensions: [MoeColors.light()]),
        home: const Scaffold(appBar: MoeAppBar(title: '设置')),
      ),
    );
    expect(find.byType(MoeChatHeader), findsNothing);
    expect(find.byType(AppBar), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final mode in MoeSurfaceMaterial.values) {
    testWidgets('详情页悬浮头部三材质渲染 $mode', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(420, 260);
      tester.view.padding = const FakeViewPadding(top: 24);
      tester.view.viewPadding = const FakeViewPadding(top: 24);
      addTearDown(tester.view.reset);
      final captureKey = GlobalKey();
      Widget header({required bool back}) => RepaintBoundary(
        key: captureKey,
        child: Scaffold(
          extendBodyBehindAppBar: true,
          appBar: MoeAppBar(
            title: '渠道详情',
            showBackButton: back,
            actions: [
              IconButton(
                onPressed: () {},
                icon: const Icon(Icons.edit_outlined),
              ),
              IconButton(
                onPressed: () {},
                icon: const Icon(Icons.delete_outline),
              ),
            ],
          ),
          body: const CustomPaint(
            painter: _Stripes(),
            child: SizedBox.expand(),
          ),
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            fontFamily: capture ? 'DetailHeaderCapture' : null,
            extensions: [MoeColors.light()],
          ),
          home: MoeGlassTheme(
            enabled: mode != MoeSurfaceMaterial.solid,
            useLiquidGlass: mode == MoeSurfaceMaterial.liquid,
            blurSigma: 16,
            child: header(back: true),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(MoeChatHeader), findsOneWidget);
      expect(find.byType(BackButton), findsOneWidget);
      expect(find.text('渠道详情'), findsOneWidget);
      // 返回圆、标题胶囊、操作胶囊各一个表面；两个操作按钮共享同一胶囊。
      expect(
        find.descendant(
          of: find.byType(MoeChatHeader),
          matching: find.byType(MoeFloatingSurface),
        ),
        findsNWidgets(3),
      );

      if (capture) {
        await tester.runAsync(() async {
          final boundary =
              captureKey.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: 1.5);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File(
            '../../.codex-temp/detail-header-floating/${mode.name}.png',
          );
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      expect(tester.takeException(), isNull);
    });
  }
}

class _Stripes extends CustomPainter {
  const _Stripes();

  @override
  void paint(Canvas canvas, Size size) {
    final colors = [
      const Color(0xFF35A795),
      const Color(0xFFE27291),
      const Color(0xFF4A90E2),
      const Color(0xFFFFD54F),
    ];
    var i = 0;
    for (var x = 0.0; x < size.width; x += 24) {
      canvas.drawRect(
        Rect.fromLTWH(x, 0, 24, size.height),
        Paint()..color = colors[i++ % colors.length],
      );
    }
  }

  @override
  bool shouldRepaint(_Stripes oldDelegate) => false;
}
