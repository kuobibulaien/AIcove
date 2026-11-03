import 'dart:io';

import 'package:aicove_flutter/src/features/agent_context/data/silly_tavern_preset_store.dart';
import 'package:aicove_flutter/src/features/agent_context/domain/silly_tavern_preset.dart';
import 'package:aicove_flutter/src/features/agent_context/providers/preset_recipe_provider.dart';
import 'package:aicove_flutter/src/features/chat/conversation_providers.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/ui/features/plugins/pages/tavern_preset_detail_page.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../helpers/release_source_preview.dart';

class _NoRoles extends ConversationsNotifier {
  @override
  Future<List<Conversation>> build() async => const [];
}

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
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('预设详情页可添加并修改提示词', (tester) async {
    await loadReleasePreviewFonts(tester);
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final directory = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('tavern_prompt_ui_'),
    ))!;
    addTearDown(() => directory.delete(recursive: true));
    final store = SillyTavernPresetStore(
      documentsDirectoryResolver: () async => directory,
    );
    final preset = (await tester.runAsync(
      () => store.importSource(
        kBasicContextPresetSource,
        sourceFileName: '基础上下文.json',
      ),
    ))!;
    Future<SillyTavernPreset> load() async => (await tester
        .runAsync<SillyTavernPreset?>(() => store.get(preset.id)))!;
    final boundary = GlobalKey();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sillyTavernPresetStoreProvider.overrideWithValue(store),
          conversationsProvider.overrideWith(_NoRoles.new),
        ],
        child: RepaintBoundary(
          key: boundary,
          child: MaterialApp(
            theme: ThemeData(
              fontFamily: captureReleaseSourcePreview ? 'ReleasePreview' : null,
              extensions: [MoeColors.light()],
            ),
            home: TavernPresetDetailPage(presetId: preset.id),
          ),
        ),
      ),
    );
    await _settle(tester);

    final add = find.byKey(const ValueKey('add-tavern-prompt'));
    await tester.ensureVisible(add);
    await _settle(tester);
    await saveReleaseSourcePreview(tester, boundary, 'tavern-prompt-add-row');
    await tester.tap(add);
    await _settle(tester);
    expect(find.text('添加提示词'), findsWidgets);

    final fields = find.byType(EditableText);
    await tester.enterText(fields.at(0), '我的系统提示词');
    await tester.enterText(fields.at(1), '你是一只猫');
    await _settle(tester);
    await saveReleaseSourcePreview(tester, boundary, 'tavern-prompt-editor');
    await tester.pageBack();
    await _settle(tester);

    var saved = await load();
    var mine = saved.prompts.singleWhere((p) => p.name == '我的系统提示词');
    expect(mine.content, '你是一只猫');
    expect(mine.role, 'system');
    expect(find.text('我的系统提示词'), findsOneWidget);
    await saveReleaseSourcePreview(tester, boundary, 'tavern-prompt-listed');

    await tester.tap(find.text('我的系统提示词'));
    await _settle(tester);
    expect(find.text('编辑提示词'), findsOneWidget);
    await tester.tap(find.text('用户'));
    await tester.enterText(find.byType(EditableText).at(1), '你是一只狗');
    await _settle(tester);
    await tester.pageBack();
    await _settle(tester);

    saved = await load();
    mine = saved.promptsById[mine.identifier]!;
    expect(mine.content, '你是一只狗');
    expect(mine.role, 'user');
    expect(saved.prompts.where((p) => !p.marker), hasLength(1));

    await tester.tap(find.text('我的系统提示词'));
    await _settle(tester);
    final delete = find.text('删除这条提示词');
    await tester.ensureVisible(delete);
    await _settle(tester);
    await saveReleaseSourcePreview(tester, boundary, 'tavern-prompt-delete');
    await tester.tap(delete);
    await _settle(tester);
    await tester.tap(find.text('删除').last);
    await _settle(tester);

    expect(find.text('我的系统提示词'), findsNothing);
    expect(find.byKey(const ValueKey('add-tavern-prompt')), findsOneWidget);
    saved = await load();
    expect(saved.prompts.where((p) => !p.marker), isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 5));
  });
}
