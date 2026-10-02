import 'dart:io';

import 'package:aicove_flutter/src/features/agent_context/data/silly_tavern_preset_store.dart';
import 'package:aicove_flutter/src/features/agent_context/domain/tavern_compatibility_port.dart';
import 'package:aicove_flutter/src/features/agent_context/providers/preset_recipe_provider.dart';
import 'package:aicove_flutter/src/features/chat/conversation_providers.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _source = '''{"name":"组合A","prompts":[
{"identifier":"chatHistory","marker":true}],"prompt_order":[
{"identifier":"chatHistory","enabled":true}]}''';

class _Roles extends ConversationsNotifier {
  _Roles(this.roles);
  final List<Conversation> roles;
  @override
  Future<List<Conversation>> build() async => roles;
}

Conversation _role(String name, String? recipeId) => Conversation(
  id: name,
  title: name,
  displayName: name,
  recipeId: recipeId,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late SillyTavernPresetStore store;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('tavern_delete_');
    store = SillyTavernPresetStore(
      documentsDirectoryResolver: () async => directory,
    );
  });
  tearDown(() => directory.delete(recursive: true));

  ProviderContainer container(List<Conversation> roles) {
    final c = ProviderContainer(
      overrides: [
        sillyTavernPresetStoreProvider.overrideWithValue(store),
        conversationsProvider.overrideWith(() => _Roles(roles)),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  test('删除默认预设时同时清掉默认选择，其他预设不受影响', () async {
    final a = await store.importSource(_source, sourceFileName: 'a.json');
    final b = await store.importSource(
      _source.replaceAll('组合A', '组合B'),
      sourceFileName: 'b.json',
    );
    await store.savePluginSettings(TavernPluginSettings(defaultPresetId: a.id));

    await container([
      _role('小明', b.id),
    ]).read(presetRecipeImportControllerProvider.notifier).deletePreset(a.id);

    expect(await store.get(a.id), isNull);
    expect((await store.get(b.id))?.id, b.id);
    expect((await store.loadPluginSettings()).defaultPresetId, isNull);
    expect(await store.resolvePreset(null), isNull);
  });

  test('仍被角色绑定的预设拒绝删除并保留文件', () async {
    final a = await store.importSource(_source, sourceFileName: 'a.json');

    await expectLater(
      container([
        _role('小明', a.id),
        _role('小红', null),
      ]).read(presetRecipeImportControllerProvider.notifier).deletePreset(a.id),
      throwsA(
        isA<StateError>().having((e) => e.message, 'message', contains('小明')),
      ),
    );
    expect((await store.get(a.id))?.id, a.id);
  });
}
