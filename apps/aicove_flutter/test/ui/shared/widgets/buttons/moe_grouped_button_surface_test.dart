import 'dart:io';
import 'dart:ui' as ui;
import 'package:aicove_flutter/src/features/chat/presentation/widgets/composer_more_panel.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/index.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:aicove_flutter/src/ui/theme/moe_interaction_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const capture = bool.fromEnvironment('WRITE_GROUP_QA');
  setUpAll(() async {
    if (!capture) return;
    for (final entry in {
      'GroupCapture': '/System/Library/Fonts/STHeiti Medium.ttc',
      'MaterialIcons':
          '${Platform.environment['FLUTTER_ROOT']}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    }.entries) {
      final loader = FontLoader(entry.key)
        ..addFont(File(entry.value).readAsBytes().then(ByteData.sublistView));
      await loader.load();
    }
  });
  for (final dark in [false, true]) {
    for (final liquid in [false, true]) {
      testWidgets('grouped buttons share outer surface $dark/$liquid', (
        tester,
      ) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(420, 720);
        addTearDown(tester.view.reset);
        MoeLiquidGlassService.setMockState(available: true);
        final boundary = GlobalKey();
        final menuKey = GlobalKey();
        var taps = 0;
        await tester.pumpWidget(
          MaterialApp(
            theme: withMoeInteractionTheme(
              ThemeData(
                brightness: dark ? Brightness.dark : Brightness.light,
                fontFamily: capture ? 'GroupCapture' : null,
                extensions: [dark ? MoeColors.dark() : MoeColors.light()],
              ),
            ),
            home: MoeGlassTheme(
              enabled: true,
              useLiquidGlass: liquid,
              blurSigma: 16,
              child: Scaffold(
                body: RepaintBoundary(
                  key: boundary,
                  child: ColoredBox(
                    color: dark
                        ? const Color(0xFF17232B)
                        : const Color(0xFFE8EDF2),
                    child: Column(
                      children: [
                        const SizedBox(height: 24),
                        MoeChatHeader(
                          title: const Text('聊天'),
                          actions: [
                            IconButton(
                              onPressed: () => taps++,
                              icon: const Icon(Icons.call_outlined),
                            ),
                            IconButton(
                              key: menuKey,
                              onPressed: () => MoePopupMenu.show(
                                menuKey.currentContext!,
                                targetBox:
                                    menuKey.currentContext!.findRenderObject()
                                        as RenderBox,
                                items: [
                                  MoePopupMenuItem(
                                    label: '详情',
                                    onTap: () => taps++,
                                  ),
                                ],
                              ),
                              icon: const Icon(Icons.more_horiz),
                            ),
                          ],
                          showBackButton: true,
                          nativeInset: 0,
                          toolbarHeight: 48,
                        ),
                        const Spacer(),
                        Padding(
                          padding: const EdgeInsets.all(12),
                          child: MoeFloatingSurface(
                            child: Row(
                              children: [
                                IconButton(
                                  onPressed: () => taps++,
                                  icon: const Icon(Icons.add),
                                ),
                                const Expanded(child: Text('输入消息')),
                                IconButton(
                                  onPressed: () => taps++,
                                  icon: const Icon(Icons.send),
                                ),
                              ],
                            ),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.all(12),
                          child: MoeFloatingSurface(
                            child: ComposerMorePanel(onAction: (_) => taps++),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        // Three header capsules, one composer capsule, one panel and seven tiles.
        expect(find.byType(MoeFloatingSurface), findsNWidgets(12));
        await tester.tap(find.byIcon(Icons.call_outlined));
        await tester.tap(find.text('相册'));
        expect(taps, 2);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.tap(find.byIcon(Icons.more_horiz));
        await tester.pumpAndSettle();
        expect(find.byType(MoeFloatingSurface), findsNWidgets(13));
        await tester.tap(find.text('详情'));
        await tester.pumpAndSettle();
        expect(taps, 3);
        expect(find.byType(MoeFloatingSurface), findsNWidgets(12));
        if (capture && liquid) {
          await tester.runAsync(() async {
            final render =
                boundary.currentContext!.findRenderObject()
                    as RenderRepaintBoundary;
            final image = await render.toImage();
            final data = await image.toByteData(format: ui.ImageByteFormat.png);
            final file = File(
              '../../.codex-temp/shared-button-surface/${dark ? 'dark' : 'light'}.png',
            );
            await file.parent.create(recursive: true);
            await file.writeAsBytes(data!.buffer.asUint8List());
            image.dispose();
          });
        }
      });
    }
  }
}
