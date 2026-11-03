import 'dart:convert';
import 'dart:io';

import 'package:aicove_flutter/src/features/agent_context/data/silly_tavern_preset_store.dart';
import 'package:aicove_flutter/src/features/agent_context/providers/preset_recipe_provider.dart';
import 'package:aicove_flutter/src/ui/features/plugins/pages/tavern_preset_detail_page.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:flutter/material.dart';
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

Map<String, dynamic> _presetJson() => {
  'name': '采样',
  'temperature': 0.8,
  'top_p': 0.9,
  'prompts': [
    {'identifier': 'main', 'role': 'system', 'content': '照常聊天'},
  ],
  'prompt_order': [
    {'identifier': 'main', 'enabled': true},
  ],
};

void main() {
  test('改温度只动 temperature，清空后跟随模型；包装格式同样生效', () async {
    final temp = await Directory.systemTemp.createTemp('tavern_sampling_');
    addTearDown(() => temp.delete(recursive: true));
    final store = SillyTavernPresetStore(
      documentsDirectoryResolver: () async => temp,
    );
    for (final source in [
      _presetJson(),
      {'type': 'openai', 'data': _presetJson()},
    ]) {
      final preset = await store.importSource(
        jsonEncode(source),
        sourceFileName: 'sampling.json',
      );
      await store.setTemperature(preset.id, 1);
      var saved = await store.get(preset.id);
      expect(saved!.temperature, 1);
      expect(saved.topP, 0.9);

      await store.setTemperature(preset.id, null);
      saved = await store.get(preset.id);
      expect(saved!.temperature, isNull);
      expect(saved.topP, 0.9);

      await expectLater(store.setTopP(preset.id, 1.5), throwsRangeError);
    }
  });

  testWidgets('预设页可把温度改成 1', (tester) async {
    tester.view.physicalSize = const Size(390 * 2, 1400 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final temp = await tester.runAsync(
      () => Directory.systemTemp.createTemp('tavern_sampling_ui_'),
    );
    addTearDown(() => temp!.delete(recursive: true));
    final store = SillyTavernPresetStore(
      documentsDirectoryResolver: () async => temp!,
    );
    final presetId = (await tester.runAsync(
      () async => (await store.importSource(
        jsonEncode(_presetJson()),
        sourceFileName: 'sampling.json',
      )).id,
    ))!;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [sillyTavernPresetStoreProvider.overrideWithValue(store)],
        child: MaterialApp(
          theme: ThemeData(extensions: [MoeColors.light()]),
          home: TavernPresetDetailPage(presetId: presetId),
        ),
      ),
    );
    await _settle(tester);

    expect(find.text('0.8'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('sampling-温度')));
    await _settle(tester);
    await tester.enterText(find.byType(TextField), '1');
    await tester.tap(find.text('保存'));
    await _settle(tester);

    final saved = await tester.runAsync(() => store.get(presetId));
    expect(saved!.temperature, 1);
    expect(saved.topP, 0.9);
    expect(tester.takeException(), isNull);
  });
}
