import 'dart:io';
import 'dart:ui' as ui;

import 'package:aicove_flutter/src/features/plugins/prompts/plugin_prompts.dart';
import 'package:aicove_flutter/src/ui/features/plugins/pages/plugin_prompts_page.dart';
import 'package:aicove_flutter/src/ui/theme/skin_provider.dart';
import 'package:aicove_flutter/src/ui/theme/skins/moetalk_skin.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _MemoryStore implements PluginPromptStore {
  _MemoryStore(this.saved);
  PluginPrompts saved;

  @override
  Future<PluginPrompts> load() async => saved;

  @override
  Future<void> save(PluginPrompts prompts) async => saved = prompts;
}

void main() {
  const capture = bool.fromEnvironment('WRITE_PLUGIN_PROMPTS_PREVIEW');

  Future<_MemoryStore> mount(
    WidgetTester tester, {
    double width = 400,
    GlobalKey? boundary,
  }) async {
    tester.view.physicalSize = Size(width, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = _MemoryStore(
      const PluginPrompts().withText(PluginPromptSlot.sticker, '少发表情包，{tags}'),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [pluginPromptStoreProvider.overrideWithValue(store)],
        child: SkinScope(
          skin: const MoeTalkSkin(),
          child: MaterialApp(
            theme: ThemeData(
              fontFamily: capture ? 'Preview' : null,
              extensions: [MoeColors.light()],
            ),
            home: RepaintBoundary(
              key: boundary,
              child: const PluginPromptsPage(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return store;
  }

  Finder field(int index) => find.byType(TextField).at(index);

  testWidgets('编辑自动保存为全局一份，恢复默认会去掉覆盖', (tester) async {
    final store = await mount(tester);
    final timeIndex = PluginPromptSlot.values.indexOf(
      PluginPromptSlot.currentTime,
    );
    final stickerIndex = PluginPromptSlot.values.indexOf(
      PluginPromptSlot.sticker,
    );
    expect(
      tester.widget<TextField>(field(stickerIndex)).controller!.text,
      '少发表情包，{tags}',
    );
    expect(find.text('恢复默认'), findsOneWidget);

    await tester.ensureVisible(field(timeIndex));
    await tester.enterText(field(timeIndex), '此刻 {datetime}');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(store.saved.of(PluginPromptSlot.currentTime), '此刻 {datetime}');

    await tester.ensureVisible(find.text('恢复默认').first);
    await tester.tap(find.text('恢复默认').first);
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(store.saved.isDefault(PluginPromptSlot.sticker), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('plugin prompts source rendered preview', (tester) async {
    if (!capture) return;
    await tester.runAsync(() async {
      final loader = FontLoader('Preview')
        ..addFont(
          File(
            '/System/Library/Fonts/STHeiti Medium.ttc',
          ).readAsBytes().then(ByteData.sublistView),
        );
      await loader.load();
      final icons = FontLoader('MaterialIcons')
        ..addFont(
          File(
            '${Platform.environment['HOME']}/dev-sdks/flutter-3.44.6/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
          ).readAsBytes().then(ByteData.sublistView),
        );
      await icons.load();
    });
    final key = GlobalKey();
    await mount(tester, boundary: key);
    await tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final dir = Directory('../../.codex-temp/plugin-prompts')
        ..createSync(recursive: true);
      await File(
        '${dir.path}/plugin-prompts-400.png',
      ).writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  });
}
