import 'dart:io';
import 'dart:ui' as ui;

import 'package:aicove_flutter/src/ui/shared/widgets/index.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const capture = bool.fromEnvironment('WRITE_NAV_HEADER_QA');
  setUp(() => MoeLiquidGlassService.setMockState(available: false));
  tearDown(() => MoeLiquidGlassService.setMockState());
  setUpAll(() async {
    if (!capture) return;
    final font = FontLoader('NavHeaderCapture')
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

  for (final mode in MoeSurfaceMaterial.values) {
    testWidgets('聊天头部不再叠加导航渐隐背景 $mode', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(420, 260);
      tester.view.padding = const FakeViewPadding(top: 24);
      tester.view.viewPadding = const FakeViewPadding(top: 24);
      addTearDown(tester.view.reset);
      final captureKey = GlobalKey();
      final theme = MoeGlassTheme(
        enabled: mode != MoeSurfaceMaterial.solid,
        useLiquidGlass: mode == MoeSurfaceMaterial.liquid,
        blurSigma: 16,
        child: const SizedBox.shrink(),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            fontFamily: capture ? 'NavHeaderCapture' : null,
            extensions: [MoeColors.light()],
          ),
          home: MoeGlassTheme(
            enabled: theme.enabled,
            useLiquidGlass: theme.useLiquidGlass,
            blurSigma: theme.blurSigma,
            child: RepaintBoundary(
              key: captureKey,
              child: Scaffold(
                extendBodyBehindAppBar: true,
                appBar: MoeChatHeader(
                  title: const Text('聊天'),
                  actions: [
                    IconButton(
                      onPressed: () {},
                      icon: const Icon(Icons.more_horiz),
                    ),
                  ],
                  showBackButton: true,
                  nativeInset: 0,
                  toolbarHeight: 48,
                ),
                body: const CustomPaint(
                  painter: _Stripes(),
                  child: SizedBox.expand(),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final headerFilterCount = find
          .descendant(
            of: find.byType(MoeChatHeader),
            matching: find.byType(BackdropFilter),
          )
          .evaluate()
          .length;

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            fontFamily: capture ? 'NavHeaderCapture' : null,
            extensions: [MoeColors.light()],
          ),
          home: MoeGlassTheme(
            enabled: theme.enabled,
            useLiquidGlass: theme.useLiquidGlass,
            blurSigma: theme.blurSigma,
            child: const Scaffold(
              body: Row(
                children: [
                  MoeFloatingSurface(child: SizedBox(width: 48, height: 48)),
                  MoeFloatingSurface(child: SizedBox(width: 200, height: 48)),
                  MoeFloatingSurface(child: SizedBox(width: 48, height: 48)),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        headerFilterCount,
        find.byType(BackdropFilter).evaluate().length,
        reason: '头部滤镜数必须等于三个胶囊自身，不再含整层渐隐背景',
      );

      if (capture) {
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(
              fontFamily: 'NavHeaderCapture',
              extensions: [MoeColors.light()],
            ),
            home: MoeGlassTheme(
              enabled: theme.enabled,
              useLiquidGlass: theme.useLiquidGlass,
              blurSigma: theme.blurSigma,
              child: RepaintBoundary(
                key: captureKey,
                child: Scaffold(
                  extendBodyBehindAppBar: true,
                  appBar: MoeChatHeader(
                    title: const Text('聊天'),
                    actions: [
                      IconButton(
                        onPressed: () {},
                        icon: const Icon(Icons.more_horiz),
                      ),
                    ],
                    showBackButton: true,
                    nativeInset: 0,
                    toolbarHeight: 48,
                  ),
                  body: const CustomPaint(
                    painter: _Stripes(),
                    child: SizedBox.expand(),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          final boundary =
              captureKey.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: 1.5);
          final bytes = await image.toByteData(
            format: ui.ImageByteFormat.png,
          );
          final file = File(
            '../../.codex-temp/nav-header-clean/${mode.name}.png',
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
