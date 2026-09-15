import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:aicove_flutter/src/features/chat/conversation_providers.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/features/chat/domain/persona_prompt_codec.dart';
import 'package:aicove_flutter/src/features/plugins/image/drawing_preset.dart';
import 'package:aicove_flutter/src/features/plugins/image/drawing_preset_provider.dart';
import 'package:aicove_flutter/src/features/plugins/image/image_config.dart';
import 'drawing_preset_test.dart' show MemoryDrawingStore;

class DrawingTestRoles extends ConversationsNotifier {
  DrawingTestRoles(this.roles, {this.fail = false});
  final List<Conversation> roles;
  final bool fail;
  @override
  Future<List<Conversation>> build() async {
    if (fail) throw StateError('roles unavailable');
    return roles;
  }
}

Conversation roleWithDrawing(String persona) => Conversation(
    id: 'role',
    title: '角色A',
    displayName: '角色A',
    createdAt: DateTime(2026),
    updatedAt: DateTime(2026),
    personaPrompt: persona);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const extra = DrawingPreset(id: 'extra', name: '待删除', config: ImageConfig());
  DrawingPresetCatalog catalog() => DrawingPresetCatalog(presets: [
        const DrawingPreset(
            id: 'drawing_default', name: '默认绘图', config: ImageConfig()),
        extra,
      ], defaultPresetId: 'drawing_default', legacyConfig: const ImageConfig());
  ProviderContainer container(DrawingPresetStore store,
      {List<Conversation> roles = const [], bool failRoles = false}) {
    final result = ProviderContainer(overrides: [
      drawingPresetStoreProvider.overrideWithValue(store),
      conversationsProvider
          .overrideWith(() => DrawingTestRoles(roles, fail: failRoles)),
    ]);
    addTearDown(result.dispose);
    return result;
  }

  test('deletion persists through a fresh preferences store and provider',
      () async {
    SharedPreferences.setMockInitialValues({});
    final store = PreferencesDrawingPresetStore();
    await store.save(catalog());
    final first = container(store);
    await first
        .read(drawingPresetCatalogProvider.notifier)
        .deletePreset('extra');
    final second = container(PreferencesDrawingPresetStore());
    final reloaded = await second.read(drawingPresetCatalogProvider.future);
    expect(reloaded.presets.map((p) => p.id), ['drawing_default']);
    expect(reloaded.defaultPresetId, 'drawing_default');
  });

  test(
      'default and last preset are protected; queued default change is respected',
      () async {
    final store = MemoryDrawingStore(catalog());
    final c = container(store);
    final notifier = c.read(drawingPresetCatalogProvider.notifier);
    await expectLater(
        notifier.deletePreset('drawing_default'), throwsStateError);
    final change = notifier.setDefault('extra');
    final deletion = notifier.deletePreset('extra');
    await change;
    await expectLater(deletion, throwsStateError);
    await notifier.deletePreset('drawing_default');
    await expectLater(notifier.deletePreset('extra'), throwsStateError);
    expect(store.catalog.presets.single.id, 'extra');
  });

  test('explicit role binding prevents deletion without writing', () async {
    final store = MemoryDrawingStore(catalog());
    final c = container(store, roles: [
      roleWithDrawing(
          PersonaPromptCodec.compose(userPrompt: '', drawingPresetId: 'extra'))
    ]);
    await expectLater(
        c.read(drawingPresetCatalogProvider.notifier).deletePreset('extra'),
        throwsA(isA<StateError>()
            .having((e) => e.message, 'message', contains('角色A'))));
    expect(store.saves, 0);
    expect(store.catalog.require('extra').name, '待删除');
  });

  test('legacy artist and tool combination binding also prevents deletion',
      () async {
    final migrated = DrawingPresetCatalog.migrate(const ImageConfig(
        artistPresets: [
          ArtistPreset(name: '画师A', content: 'style')
        ],
        systemPromptPresets: [
          DrawingPromptPreset(name: '工具A', content: 'tool')
        ]));
    final persona = PersonaPromptCodec.compose(
        userPrompt: '',
        drawingArtistPresetName: '画师A',
        drawingToolPresetName: '工具A');
    final preset = migrated.resolve(PersonaPromptCodec.parse(persona));
    final store = MemoryDrawingStore(migrated.upsert(preset));
    final c = container(store, roles: [roleWithDrawing(persona)]);
    await expectLater(
        c.read(drawingPresetCatalogProvider.notifier).deletePreset(preset.id),
        throwsStateError);
    expect(store.saves, 0);
    expect(store.catalog.require(preset.id).id, preset.id);
  });

  test('failed reference lookup leaves all presets intact', () async {
    final store = MemoryDrawingStore(catalog());
    final c = container(store, failRoles: true);
    await expectLater(
        c.read(drawingPresetCatalogProvider.notifier).deletePreset('extra'),
        throwsStateError);
    expect(store.saves, 0);
    expect(store.catalog.presets.length, 2);
  });

  test('failed persistence keeps published state and later retry works',
      () async {
    final store = MemoryDrawingStore(catalog())..fail = true;
    final c = container(store);
    final notifier = c.read(drawingPresetCatalogProvider.notifier);
    await expectLater(notifier.deletePreset('extra'), throwsStateError);
    expect(
        (await c.read(drawingPresetCatalogProvider.future)).presets.length, 2);
    store.fail = false;
    await notifier.deletePreset('extra');
    expect(
        (await c.read(drawingPresetCatalogProvider.future)).presets.length, 1);
  });
}
