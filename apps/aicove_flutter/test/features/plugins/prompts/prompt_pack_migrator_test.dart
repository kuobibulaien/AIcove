// ADR0092 role move: concurrent runs for one role share a single move,
// and an edit made meanwhile is never overwritten.
import 'package:aicove_flutter/src/features/chat/conversation_providers.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/features/chat/domain/persona_prompt_codec.dart';
import 'package:aicove_flutter/src/features/plugins/image/drawing_preset.dart';
import 'package:aicove_flutter/src/features/plugins/image/drawing_preset_provider.dart';
import 'package:aicove_flutter/src/features/plugins/image/image_config.dart';
import 'package:aicove_flutter/src/features/plugins/prompts/prompt_pack_migration.dart';
import 'package:aicove_flutter/src/features/plugins/prompts/prompt_pack.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
  TestWidgetsFlutterBinding.ensureInitialized();
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
  setUpContainer({List<Conversation>? initial}) {
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
    final roles = _Roles(initial ?? [role()]);
    final container = ProviderContainer(
      overrides: [
        drawingPresetStoreProvider.overrideWithValue(store),
        conversationsProvider.overrideWith(() => roles),
      ],
    );
    addTearDown(container.dispose);
    return (container: container, store: store, roles: roles);
  }

  test('forRole leaves role drawing text in place', () async {
    final t = setUpContainer();
    await t.container.read(conversationsProvider.future);
    await t.container.read(promptPackMigratorProvider).forRole(role());
    expect(t.store.catalog.require('own').prompts.ownSections, isEmpty);
    final parts = PersonaPromptCodec.parse(
      t.container.read(conversationsProvider).requireValue.single.personaPrompt,
    );
    expect(parts.customDrawingPrompt, '白发绿眼');
  });

  test('legacy sections extract only when content and enabled state agree', () {
    final sections = roleDrawingSections('白发绿眼');
    expect(
      extractRoleDrawingText(PresetPromptBinding(ownSections: sections)),
      '白发绿眼',
    );
    expect(
      extractRoleDrawingText(
        PresetPromptBinding(ownSections: [sections.first]),
      ),
      '白发绿眼',
    );
    expect(
      extractRoleDrawingText(
        PresetPromptBinding(
          ownSections: [sections.first, sections.last.copyWith(enabled: false)],
        ),
      ),
      isNull,
    );
    expect(
      extractRoleDrawingText(
        PresetPromptBinding(
          ownSections: [
            sections.first,
            sections.last.copyWith(text: '【角色专属生图要求】\n不同'),
          ],
        ),
      ),
      isNull,
    );
  });

  test('startup restores role copy data before deleting the copy', () async {
    SharedPreferences.setMockInitialValues({});
    final t = setUpContainer();
    await t.container.read(conversationsProvider.future);
    const copy = 'drawing_role_nahida_own';
    await t.container
        .read(drawingPresetCatalogProvider.notifier)
        .transact(
          (catalog) => catalog.upsert(
            DrawingPreset(
              id: copy,
              name: '副本',
              config: const ImageConfig(),
              prompts: PresetPromptBinding(
                packId: 'builtin.image.danbooru',
                ownSections: roleDrawingSections('绿眼'),
              ),
            ),
          ),
        );
    await t.roles.updateOne(
      'nahida',
      (c) => c.copyWith(
        personaPrompt: PersonaPromptCodec.compose(
          userPrompt: '人设',
          extraPrompt: '附加',
          drawingPresetId: copy,
          drawingToolPresetName: '旧工具',
          drawingArtistPresetName: '旧画师',
        ),
      ),
    );
    await t.container.read(promptPackMigratorProvider).ensure();
    final parts = PersonaPromptCodec.parse(
      t.container.read(conversationsProvider).requireValue.single.personaPrompt,
    );
    expect(parts.customDrawingPrompt, '绿眼');
    expect(parts.drawingPromptPackId, 'builtin.image.danbooru');
    expect(parts.extraPrompt, '附加');
    expect(parts.drawingPresetId, 'own');
    expect(parts.drawingToolPresetName, '旧工具');
    expect(parts.drawingArtistPresetName, '旧画师');
    expect(t.store.catalog.presets.any((p) => p.id == copy), isFalse);
  });

  test('divergent legacy copy stays bound and keeps both sections', () async {
    SharedPreferences.setMockInitialValues({});
    final t = setUpContainer();
    await t.container.read(conversationsProvider.future);
    const copy = 'drawing_role_nahida_own';
    final sections = roleDrawingSections('绿眼');
    await t.container
        .read(drawingPresetCatalogProvider.notifier)
        .transact(
          (catalog) => catalog.upsert(
            DrawingPreset(
              id: copy,
              name: '副本',
              config: const ImageConfig(),
              prompts: PresetPromptBinding(
                ownSections: [
                  sections.first,
                  sections.last.copyWith(enabled: false),
                ],
              ),
            ),
          ),
        );
    await t.roles.updateOne(
      'nahida',
      (c) => c.copyWith(
        personaPrompt: PersonaPromptCodec.compose(
          userPrompt: '人设',
          drawingPresetId: copy,
        ),
      ),
    );
    await t.container.read(promptPackMigratorProvider).ensure();
    final parts = PersonaPromptCodec.parse(
      t.container.read(conversationsProvider).requireValue.single.personaPrompt,
    );
    expect(parts.customDrawingPrompt, isEmpty);
    expect(parts.drawingPresetId, copy);
    expect(
      t.store.catalog.require(copy).prompts.ownSections.last.enabled,
      isFalse,
    );
  });

  test('Nahida is restored once, then a user clear survives restart', () async {
    SharedPreferences.setMockInitialValues({});
    final initial = role().copyWith(
      id: 'preset_nahida',
      personaPrompt: PersonaPromptCodec.compose(
        userPrompt: '人设',
        extraPrompt: '附加',
      ),
    );
    final t = setUpContainer(initial: [initial]);
    await t.container.read(conversationsProvider.future);
    await t.container.read(promptPackMigratorProvider).ensure();
    final restored = t.container
        .read(conversationsProvider)
        .requireValue
        .single;
    expect(
      PersonaPromptCodec.parse(restored.personaPrompt).customDrawingPrompt,
      'nahida_(genshin_impact)',
    );
    final cleared = restored.copyWith(
      personaPrompt: PersonaPromptCodec.compose(
        userPrompt: '人设',
        extraPrompt: '附加',
      ),
    );
    final next = setUpContainer(initial: [cleared]);
    await next.container.read(conversationsProvider.future);
    await next.container.read(promptPackMigratorProvider).ensure();
    final parts = PersonaPromptCodec.parse(
      next.container
          .read(conversationsProvider)
          .requireValue
          .single
          .personaPrompt,
    );
    expect(parts.customDrawingPrompt, isEmpty);
    expect(parts.extraPrompt, '附加');
  });

  test(
    'startup unbinding a role drawing copy keeps its extra prompt',
    () async {
      SharedPreferences.setMockInitialValues({});
      final t = setUpContainer();
      await t.container.read(conversationsProvider.future);
      await t.roles.updateOne(
        'nahida',
        (c) => c.copyWith(
          personaPrompt: PersonaPromptCodec.compose(
            userPrompt: '人设',
            extraPrompt: '保留补充',
            drawingPresetId: '${DrawingPresetCatalog.roleCopyPrefix}nahida_own',
          ),
        ),
      );
      await t.container.read(promptPackMigratorProvider).ensure();
      final parts = PersonaPromptCodec.parse(
        t.container
            .read(conversationsProvider)
            .requireValue
            .single
            .personaPrompt,
      );
      expect(parts.userPrompt, '人设');
      expect(parts.extraPrompt, '保留补充');
      expect(parts.drawingPresetId, 'own');
    },
  );
}
