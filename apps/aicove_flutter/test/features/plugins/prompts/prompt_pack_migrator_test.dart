// ADR0092 role move: concurrent runs for one role share a single move,
// and an edit made meanwhile is never overwritten.
import 'package:aicove_flutter/src/features/chat/conversation_providers.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/features/chat/domain/persona_prompt_codec.dart';
import 'package:aicove_flutter/src/features/plugins/image/drawing_preset.dart';
import 'package:aicove_flutter/src/features/plugins/image/drawing_preset_provider.dart';
import 'package:aicove_flutter/src/features/plugins/image/image_config.dart';
import 'package:aicove_flutter/src/features/plugins/prompts/prompt_pack_migration.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../image/drawing_preset_test.dart' show MemoryDrawingStore;

class _Roles extends ConversationsNotifier {
  _Roles(this.initial);
  final List<Conversation> initial;
  Conversation Function(Conversation)? beforeWrite;

  @override
  Future<List<Conversation>> build() async => initial;

  @override
  Future<void> updateOne(
    String id,
    Conversation Function(Conversation) fn, {
    bool persist = true,
  }) async {
    if (beforeWrite != null) {
      state = AsyncData([
        for (final c in state.requireValue) c.id == id ? beforeWrite!(c) : c,
      ]);
    }
    state = AsyncData([
      for (final c in state.requireValue) c.id == id ? fn(c) : c,
    ]);
  }
}

void main() {
  final now = DateTime(2026, 10, 19);
  Conversation role() => Conversation(
    id: 'nahida',
    title: '纳西妲',
    displayName: '纳西妲',
    createdAt: now,
    updatedAt: now,
    personaPrompt: PersonaPromptCodec.compose(
      userPrompt: '你是纳西妲。',
      customDrawingPrompt: '白发绿眼',
      drawingPresetId: 'own',
    ),
  );

  ({ProviderContainer container, MemoryDrawingStore store, _Roles roles})
  setUpContainer() {
    final store = MemoryDrawingStore(
      DrawingPresetCatalog(
        presets: const [
          DrawingPreset(id: 'default', name: '默认', config: ImageConfig()),
          DrawingPreset(id: 'own', name: '纳西妲绘图', config: ImageConfig()),
        ],
        defaultPresetId: 'default',
        legacyConfig: const ImageConfig(),
      ),
    );
    final roles = _Roles([role()]);
    final container = ProviderContainer(
      overrides: [
        drawingPresetStoreProvider.overrideWithValue(store),
        conversationsProvider.overrideWith(() => roles),
      ],
    );
    addTearDown(container.dispose);
    return (container: container, store: store, roles: roles);
  }

  test('two runs at once both finish and add the sections once', () async {
    final t = setUpContainer();
    final migrator = t.container.read(promptPackMigratorProvider);
    await t.container.read(conversationsProvider.future);
    await Future.wait([migrator.forRole(role()), migrator.forRole(role())]);
    await migrator.forRole(role());
    final own = t.store.catalog.require('own');
    expect(own.prompts.ownSections, hasLength(2));
    final parts = PersonaPromptCodec.parse(
      t.container.read(conversationsProvider).requireValue.single.personaPrompt,
    );
    expect(parts.customDrawingPrompt, isEmpty);
    expect(parts.drawingPresetId, 'own');
  });

  test('a persona edited meanwhile is kept for the next run', () async {
    final t = setUpContainer();
    final migrator = t.container.read(promptPackMigratorProvider);
    await t.container.read(conversationsProvider.future);
    t.roles.beforeWrite = (c) => c.copyWith(
      personaPrompt: PersonaPromptCodec.compose(
        userPrompt: '用户刚改的人设。',
        customDrawingPrompt: '白发绿眼',
        drawingPresetId: 'own',
      ),
    );
    await migrator.forRole(role());
    final parts = PersonaPromptCodec.parse(
      t.container.read(conversationsProvider).requireValue.single.personaPrompt,
    );
    expect(parts.userPrompt, '用户刚改的人设。');
    expect(parts.customDrawingPrompt, '白发绿眼');
    // The text is safe in the preset already.
    expect(t.store.catalog.require('own').prompts.ownSections, hasLength(2));
  });
}
