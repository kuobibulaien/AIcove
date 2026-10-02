import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:aicove_flutter/src/features/agent_context/data/silly_tavern_preset_store.dart';
import 'package:aicove_flutter/src/features/agent_context/providers/preset_recipe_provider.dart';
import 'package:aicove_flutter/src/ui/features/plugins/pages/tavern_preset_detail_page.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/index.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 仿小猫之神结构自拟的预设：思维链与摘要由正则识别，正文标签只写在提示词里。
final _presetSource = jsonEncode({
  'name': '标签识别示例',
  'prompts': [
    {'identifier': 'main', 'role': 'system', 'content': '正文要用<game></game>标签包上'},
    {'identifier': 'extra', 'role': 'system', 'content': '额外内容用<extra>包裹'},
  ],
  'prompt_order': [
    {'identifier': 'main', 'enabled': true},
    {'identifier': 'extra', 'enabled': true},
  ],
  'extensions': {
    'regex_scripts': [
      {
        'id': 'think',
        'scriptName': '思维链折叠',
        'findRegex': r'/<think_nya\~>([\s\S]*?)<\/think_nya~>/g',
        'replaceString': r'<div class="fold">$1</div>',
        'placement': [2],
        'markdownOnly': true,
      },
      {
        'id': 'summary',
        'scriptName': '小总结',
        'findRegex': r'/(?<!<details>\s*)<summary>([\s\S]*?)<\/summary>/g',
        'replaceString': '<details>\n<summary>摘要</summary>\n\$1\n</details>',
        'placement': [2],
        'markdownOnly': true,
      },
    ],
  },
});

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pumpAndSettle();
}

void main() {
  const capture = bool.fromEnvironment('WRITE_TAG_SECTION_PREVIEW');
  for (final width in [360.0, 1000.0]) {
    testWidgets('tag section lists prompt, pending and discovered tags $width',
        (tester) async {
      tester.view.physicalSize = Size(width * 2, 1800);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      if (capture) {
        await tester.runAsync(() async {
          final loader = FontLoader('Preview')
            ..addFont(File('/System/Library/Fonts/STHeiti Medium.ttc')
                .readAsBytes()
                .then(ByteData.sublistView));
          await loader.load();
          // 图标字体：Lucide（包内）与 Material。
          final lucide = FontLoader('packages/lucide_icons/Lucide')
            ..addFont(File('third_party/lucide_icons/assets/lucide.ttf')
                .readAsBytes()
                .then(ByteData.sublistView));
          await lucide.load();
          final material = FontLoader('MaterialIcons')
            ..addFont(File(
                    '${Platform.environment['HOME']}/dev-sdks/flutter-3.44.6/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf')
                .readAsBytes()
                .then(ByteData.sublistView));
          await material.load();
        });
      }
      final temp = await tester.runAsync(
        () => Directory.systemTemp.createTemp('tavern_tags_'),
      );
      addTearDown(() => temp!.delete(recursive: true));
      final store =
          SillyTavernPresetStore(documentsDirectoryResolver: () async => temp!);
      final preset = (await tester.runAsync(
        () => store.importSource(_presetSource, sourceFileName: 'demo.json'),
      ))!;
      final key = GlobalKey();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sillyTavernPresetStoreProvider.overrideWithValue(store),
            observedUnknownTagsProvider.overrideWith(
              (ref) => {
                observedTagsKey(preset.id): {'ztl'},
              },
            ),
          ],
          child: MaterialApp(
            theme: ThemeData(
              fontFamily: capture ? 'Preview' : null,
              extensions: [MoeColors.light()],
            ),
            home: RepaintBoundary(
              key: key,
              child: TavernPresetDetailPage(presetId: preset.id),
            ),
          ),
        ),
      );
      await _settle(tester);
      final tab = find.descendant(
        of: find.byWidgetPredicate((w) => w is MoeToggleBar),
        matching: find.text('标签'),
      );
      await tester.tap(tab);
      await _settle(tester);

      expect(find.text('<game>'), findsOneWidget);
      expect(find.text('<summary>'), findsOneWidget);
      expect(find.text('<think_nya~>'), findsOneWidget);
      expect(find.text('<extra>'), findsOneWidget);
      expect(find.text('<ztl>'), findsOneWidget);
      expect(tester.takeException(), isNull);

      if (capture) {
        await tester.runAsync(() async {
          final boundary =
              key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: 2);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final dir = Directory('../../scratch/tag-fold')
            ..createSync(recursive: true);
          await File('${dir.path}/tag-section-${width.toInt()}.png')
              .writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
    });
  }
}
