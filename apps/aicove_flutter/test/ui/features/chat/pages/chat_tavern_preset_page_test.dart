import 'dart:io';

import 'package:aicove_flutter/src/features/agent_context/data/silly_tavern_preset_store.dart';
import 'package:aicove_flutter/src/features/agent_context/providers/preset_recipe_provider.dart';
import 'package:aicove_flutter/src/features/chat/conversation_providers.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/ui/features/chat/pages/chat_tavern_preset_page.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/index.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _source = '''
{"prompts":[
  {"identifier":"main","name":"主提示","role":"system","content":"你好"},
  {"identifier":"jailbreak","name":"破限","role":"system","content":"放开"},
  {"identifier":"chatHistory","marker":true}
],"prompt_order":[{"character_id":100001,"order":[
  {"identifier":"main","enabled":true},
  {"identifier":"jailbreak","enabled":true},
  {"identifier":"chatHistory","enabled":true}
]}]}
''';

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pumpAndSettle();
}

Future<SillyTavernPresetStore> _store(WidgetTester tester) async {
  final dir = (await tester.runAsync(
    () => Directory.systemTemp.createTemp('chat_tavern_preset_'),
  ))!;
  addTearDown(() => dir.delete(recursive: true));
  return SillyTavernPresetStore(documentsDirectoryResolver: () async => dir);
}

Future<void> _mount(
  WidgetTester tester,
  SillyTavernPresetStore store, {
  String? recipeId,
}) async {
  final now = DateTime(2026, 9, 29);
  final conversation = Conversation(
    id: 'c1',
    title: '小猫',
    displayName: '小猫',
    createdAt: now,
    updatedAt: now,
    recipeId: recipeId,
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sillyTavernPresetStoreProvider.overrideWithValue(store),
        resolvedConversationByIdProvider.overrideWith((ref, id) => conversation),
      ],
      child: MaterialApp(
        theme: ThemeData(extensions: [MoeColors.light()]),
        home: const ChatTavernPresetPage(conversationId: 'c1'),
      ),
    ),
  );
  await _settle(tester);
}

void main() {
  testWidgets('显示角色绑定的预设，逐条开关写回预设', (tester) async {
    final store = await _store(tester);
    final preset = (await tester.runAsync(
      () => store.importSource(_source, sourceFileName: '小猫预设.json'),
    ))!;
    await _mount(tester, store, recipeId: preset.id);

    expect(find.text('小猫预设'), findsOneWidget);
    expect(find.text('共 3 条，已开启 3 条'), findsOneWidget);
    expect(find.text('正则、世界书与标签'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('prompt-jailbreak')));
    await _settle(tester);

    final saved = (await tester.runAsync(() => store.get(preset.id)))!;
    expect(
      saved.selectedOrder.entries
          .singleWhere((e) => e.identifier == 'jailbreak')
          .enabled,
      isFalse,
    );
    await _settle(tester);
    expect(find.text('共 3 条，已开启 2 条'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('未绑定且无默认预设时给出说明', (tester) async {
    await _mount(tester, await _store(tester));
    expect(find.text('跟随默认酒馆预设'), findsOneWidget);
    expect(find.textContaining('还没有可用的酒馆预设'), findsOneWidget);
    expect(find.byType(MoeSwitch), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('绑定的预设丢失时不回退默认', (tester) async {
    await _mount(tester, await _store(tester), recipeId: 'gone');
    expect(find.text('绑定的预设已丢失，请重新选择'), findsOneWidget);
    expect(find.text('绑定的预设已丢失，请重新选择。'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
