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

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pumpAndSettle();
}

/// ADR0071：MVU 变量是酒馆预设里的开关，不是独立聊天插件。
/// 用 `--dart-define=MVU_PREVIEW_OUT=<目录>` 运行时写出 PNG。
void main() {
  const out = String.fromEnvironment('MVU_PREVIEW_OUT');

  testWidgets('世界书页可开关 MVU 变量并显示初始变量条目数', (tester) async {
    tester.view.physicalSize = const Size(390 * 2, 900 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    if (out.isNotEmpty) {
      await tester.runAsync(() async {
        final text = FontLoader('Preview')
          ..addFont(
            File(
              '/System/Library/Fonts/STHeiti Medium.ttc',
            ).readAsBytes().then(ByteData.sublistView),
          );
        await text.load();
        final icons = FontLoader('MaterialIcons')
          ..addFont(
            File(
              '${Platform.environment['FLUTTER_ROOT']}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
            ).readAsBytes().then(ByteData.sublistView),
          );
        await icons.load();
      });
    }
    final temp = await tester.runAsync(
      () => Directory.systemTemp.createTemp('tavern_mvu_'),
    );
    addTearDown(() => temp!.delete(recursive: true));
    final store = SillyTavernPresetStore(
      documentsDirectoryResolver: () async => temp!,
    );
    final presetId = (await tester.runAsync(() async {
      final preset = await store.importSource(
        jsonEncode({
          'name': 'MVU 卡',
          'prompts': [
            {'identifier': 'main', 'role': 'system', 'content': '照常聊天'},
          ],
          'prompt_order': [
            {'identifier': 'main', 'enabled': true},
          ],
        }),
        sourceFileName: 'mvu.json',
      );
      await store.importWorldBook(
        preset.id,
        jsonEncode({
          'name': '书',
          'entries': {
            '0': {
              'uid': 0,
              'comment': '[InitVar]初始变量',
              'disable': true,
              'content': '{"好感度": [0, "说明"]}',
            },
          },
        }),
        '书.json',
      );
      return preset.id;
    }))!;

    final key = GlobalKey();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sillyTavernPresetStoreProvider.overrideWithValue(store)],
        child: MaterialApp(
          theme: ThemeData(
            fontFamily: out.isEmpty ? null : 'Preview',
            extensions: [MoeColors.light()],
          ),
          home: RepaintBoundary(
            key: key,
            child: TavernPresetDetailPage(presetId: presetId),
          ),
        ),
      ),
    );
    await _settle(tester);
    await tester.tap(
      find.descendant(
        of: find.byWidgetPredicate((w) => w is MoeToggleBar),
        matching: find.text('世界书'),
      ),
    );
    await _settle(tester);

    expect(find.text('MVU 变量'), findsOneWidget);
    expect(find.textContaining('已找到 1 个 [InitVar]'), findsOneWidget);
    if (out.isNotEmpty) {
      await tester.runAsync(() async {
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 1);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(
          '$out/tavern-mvu-switch.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }

    await tester.tap(find.byKey(const ValueKey('mvu-enabled')));
    await _settle(tester);
    expect(find.textContaining('关着时不解析变量'), findsOneWidget);
    final saved = await tester.runAsync(() => store.get(presetId));
    expect(saved!.mvuEnabled, isFalse);
    expect(tester.takeException(), isNull);
  });
}
