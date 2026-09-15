import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:aicove_flutter/src/features/chat/domain/persona_prompt_codec.dart';
import 'package:aicove_flutter/src/features/plugins/image/drawing_parameters.dart';
import 'package:aicove_flutter/src/features/plugins/image/drawing_preset.dart';
import 'package:aicove_flutter/src/features/plugins/image/drawing_preset_provider.dart';
import 'package:aicove_flutter/src/features/plugins/image/image_config.dart';

class MemoryDrawingStore implements DrawingPresetStore {
  DrawingPresetCatalog catalog;
  bool fail = false;
  int saves = 0;
  MemoryDrawingStore(this.catalog);
  @override
  Future<DrawingPresetCatalog> load() async => catalog;
  @override
  Future<void> save(DrawingPresetCatalog value) async {
    if (fail) throw StateError('disk full');
    await Future<void>.delayed(Duration.zero);
    catalog = value;
    saves++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const legacy = ImageConfig(
      selectedProviderId: 'nai',
      selectedModelId: 'nai:model',
      selectedArtistPresetName: 'A',
      defaultSteps: 23,
      defaultGuidanceScale: 7,
      artistPresets: [
        ArtistPreset(name: 'A', content: 'style A'),
        ArtistPreset(name: 'B', content: 'style B')
      ],
      systemPromptPresets: [
        DrawingPromptPreset(name: '工具B', content: 'custom rule')
      ]);

  test('codec keeps stable ID separate from persona and preserves old bindings',
      () {
    final encoded = PersonaPromptCodec.compose(
        userPrompt: '角色正文',
        customDrawingPrompt: '外貌',
        drawingPresetId: 'preset-123',
        drawingArtistPresetName: '旧画师');
    final parsed = PersonaPromptCodec.parse(encoded);
    expect(parsed.userPrompt, '角色正文');
    expect(parsed.customDrawingPrompt, '外貌');
    expect(parsed.drawingPresetId, 'preset-123');
    expect(parsed.drawingArtistPresetName, '旧画师');
  });

  test(
      'migration freezes defaults and independently reconstructs legacy combinations',
      () {
    final catalog = DrawingPresetCatalog.migrate(legacy);
    final a = catalog.resolve(PersonaPromptCodec.parse(''));
    final b = catalog.resolve(const PersonaPromptParts(
        userPrompt: '',
        customDrawingPrompt: '',
        drawingArtistPresetName: 'B',
        drawingToolPresetName: '工具B'));
    final disabled = catalog.resolve(const PersonaPromptParts(
        userPrompt: '',
        customDrawingPrompt: '',
        drawingArtistPresetName:
            PersonaPromptCodec.artistPresetDisabledBinding));
    expect(a.config.selectedArtistPreset!.content, 'style A');
    expect(b.config.selectedArtistPreset!.content, 'style B');
    expect(b.config.effectiveToolDescriptionBlocks.promptDescription,
        'custom rule');
    expect(b.config.selectedProviderId, 'nai');
    expect(b.config.defaultSteps, 23);
    expect(disabled.config.selectedArtistPreset, isNull);
    expect(a.id, isNot(b.id));
    expect(
        b.id,
        catalog
            .resolve(const PersonaPromptParts(
                userPrompt: '',
                customDrawingPrompt: '',
                drawingArtistPresetName: 'B',
                drawingToolPresetName: '工具B'))
            .id);
  });

  test(
      'rename/default changes cannot change existing role binding; missing IDs fail',
      () {
    var catalog = DrawingPresetCatalog.migrate(legacy);
    final original = catalog.presets.first;
    catalog = catalog.upsert(
        DrawingPreset(id: original.id, name: '重命名', config: original.config));
    catalog = catalog
        .upsert(const DrawingPreset(
            id: 'other', name: '另一个', config: ImageConfig()))
        .withDefault('other');
    expect(catalog.resolve(PersonaPromptCodec.parse('')).id, 'other');
    expect(
        catalog
            .resolve(PersonaPromptCodec.parse(PersonaPromptCodec.compose(
                userPrompt: '', drawingPresetId: original.id)))
            .name,
        '重命名');
    expect(() => catalog.require('missing'), throwsStateError);
    final roundTrip = DrawingPresetCatalog.fromJson(
        jsonDecode(jsonEncode(catalog.toJson())) as Map<String, dynamic>);
    expect(roundTrip.require(original.id).config.selectedArtistPreset!.content,
        'style A');
  });

  test('preferences migration keeps old bytes and is idempotent after restart',
      () async {
    final oldBytes = jsonEncode(legacy.toJson());
    SharedPreferences.setMockInitialValues(
        {PreferencesDrawingPresetStore.legacyKey: oldBytes});
    final store = PreferencesDrawingPresetStore();
    final first = await store.load();
    await store.save(first.upsert(
        const DrawingPreset(id: 'saved', name: '自定义', config: ImageConfig())));
    final second = await PreferencesDrawingPresetStore().load();
    expect(second.require('saved').name, '自定义');
    expect(
        (await SharedPreferences.getInstance())
            .getString(PreferencesDrawingPresetStore.legacyKey),
        oldBytes);
  });

  test('corrupt catalog never falls back and overwrites user presets',
      () async {
    SharedPreferences.setMockInitialValues(
        {PreferencesDrawingPresetStore.storageKey: '{broken'});
    await expectLater(
        PreferencesDrawingPresetStore().load(), throwsFormatException);
    expect(
        (await SharedPreferences.getInstance())
            .getString(PreferencesDrawingPresetStore.storageKey),
        '{broken');
  });

  test(
      'concurrent migration and saves do not lose presets; failed saves do not publish',
      () async {
    final store = MemoryDrawingStore(DrawingPresetCatalog.migrate(legacy));
    final container = ProviderContainer(
        overrides: [drawingPresetStoreProvider.overrideWithValue(store)]);
    addTearDown(container.dispose);
    final notifier = container.read(drawingPresetCatalogProvider.notifier);
    await container.read(drawingPresetCatalogProvider.future);
    await Future.wait([
      notifier.savePreset(
          const DrawingPreset(id: 'one', name: '一', config: ImageConfig())),
      notifier.savePreset(
          const DrawingPreset(id: 'two', name: '二', config: ImageConfig()))
    ]);
    expect(store.catalog.presets.map((p) => p.id), containsAll(['one', 'two']));
    final persona = PersonaPromptCodec.compose(
        userPrompt: '', drawingArtistPresetName: 'B');
    final resolved = await Future.wait([
      notifier.resolveForPersona(persona),
      notifier.resolveForPersona(persona)
    ]);
    expect(resolved[0].id, resolved[1].id);
    expect(
        store.catalog.presets.where((p) => p.id == resolved[0].id).length, 1);
    store.fail = true;
    await expectLater(
        notifier.savePreset(
            const DrawingPreset(id: 'bad', name: '未保存', config: ImageConfig())),
        throwsStateError);
    expect(
        container
            .read(drawingPresetCatalogProvider)
            .requireValue
            .presets
            .any((p) => p.id == 'bad'),
        isFalse);
    store.fail = false;
    await notifier.setDefault('two');
    expect(store.catalog.defaultPresetId, 'two');
  });

  test(
      'parameters use request overrides then preset defaults, without mutating presets',
      () {
    final p = DrawingParameters.resolve(
        legacy,
        {
          'width': 1024,
          'height': 1024,
          'steps': 35,
          'guidance_scale': 6,
          'count': 2
        },
        novelAi: true);
    expect([p.width, p.height, p.steps, p.guidanceScale, p.count],
        [1024, 1024, 35, 6, 2]);
    final defaults = DrawingParameters.resolve(legacy, {}, novelAi: true);
    expect(defaults.steps, 23);
    expect(legacy.defaultSteps, 23);
  });

  for (final args in <Map<String, dynamic>>[
    {'width': 0},
    {'height': 100000},
    {'steps': 1.5},
    {'guidance_scale': double.nan},
    {'count': double.infinity},
    {'width': 833},
    {'steps': 'garbage'},
  ]) {
    test('rejects invalid image parameters $args', () {
      expect(() => DrawingParameters.resolve(legacy, args, novelAi: true),
          throwsFormatException);
    });
  }
  test('unsupported provider parameters are rejected, not silently forwarded',
      () {
    expect(
        () => DrawingParameters.resolve(legacy, {'steps': 35}, novelAi: false),
        throwsFormatException);
    expect(
        DrawingParameters.resolve(legacy, {'width': 1024}, novelAi: false)
            .width,
        1024);
  });
}
