import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/index.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';

void main() {
  setUp(() => MoeLiquidGlassService.setMockState(available: false));
  tearDown(() => MoeLiquidGlassService.setMockState());
  setUpAll(() async {
    if (!const bool.fromEnvironment('WRITE_BASELINE_QA')) return;
    final font = FontLoader('BaselineCapture');
    font.addFont(
      File(
        '/System/Library/Fonts/STHeiti Medium.ttc',
      ).readAsBytes().then(ByteData.sublistView),
    );
    await font.load();
    final icons = FontLoader('MaterialIcons');
    icons.addFont(
      File(
        '${Platform.environment['FLUTTER_ROOT']}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
      ).readAsBytes().then(ByteData.sublistView),
    );
    await icons.load();
  });
  for (final dark in [false, true]) {
    testWidgets('actual shared header and sheet at zero dark=$dark', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(420, 480);
      addTearDown(tester.view.reset);
      final key = GlobalKey();
      final colors = dark ? MoeColors.dark() : MoeColors.light();
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            brightness: dark ? Brightness.dark : Brightness.light,
            fontFamily: const bool.fromEnvironment('WRITE_BASELINE_QA')
                ? 'BaselineCapture'
                : null,
            extensions: [colors],
          ),
          home: MoeGlassTheme(
            useLiquidGlass: true,
            enabled: true,
            blurSigma: 0,
            child: RepaintBoundary(
              key: key,
              child: ColoredBox(
                color: dark ? const Color(0xFF26313C) : const Color(0xFFE6EBF0),
                child: Column(
                  children: [
                    const SizedBox(height: 16),
                    Text(
                      '材质厚度 0',
                      style: TextStyle(
                        color: colors.textSecondary,
                        fontSize: 13,
                        inherit: false,
                        fontFamily: 'BaselineCapture',
                      ),
                    ),
                    MoeChatHeader(
                      title: Text(
                        '聊天悬浮组件',
                        style: TextStyle(color: colors.text, fontSize: 16),
                      ),
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
                    const Spacer(),
                    const MoeBottomSheet(
                      title: '文字面板：10% 保底',
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(20, 16, 20, 32),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            ListTile(title: Text('模糊保底 10%')),
                            ListTile(title: Text('底色保底 10%')),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final surfaces = tester
          .widgetList<MoeFloatingSurface>(find.byType(MoeFloatingSurface))
          .toList();
      expect(
        surfaces.take(3).every((s) => s.baseline == MoeMaterialBaseline.none),
        isTrue,
      );
      expect(surfaces.last.baseline, MoeMaterialBaseline.background);
      expect(tester.takeException(), isNull);
      if (const bool.fromEnvironment('WRITE_BASELINE_QA')) {
        await tester.runAsync(() async {
          final boundary =
              key.currentContext!.findRenderObject() as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: 1.5);
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File(
            '../../.codex-temp/material-baseline/${dark ? 'dark' : 'light'}.png',
          );
          await file.parent.create(recursive: true);
          await file.writeAsBytes(data!.buffer.asUint8List());
          image.dispose();
        });
      }
    });
  }
}
