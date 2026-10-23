import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/app_logger.dart';
import '../../chat/conversation_providers.dart';
import '../../chat/domain/conversation.dart';
import '../../chat/domain/persona_prompt_codec.dart';
import '../image/drawing_preset.dart';
import '../image/drawing_preset_provider.dart';
import '../image/image_config.dart';
import '../tts/tts_config.dart';
import 'plugin_prompts.dart';
import 'prompt_pack.dart';
import 'prompt_pack_store.dart';

/// One-time moves into prompt packs (ADR0092). Old keys and fields stay.
abstract final class PromptPackMigrations {
  static const globalSlots = 'global_slots_v1';
  static const drawingTools = 'drawing_tools_v1';
}

/// The old global `<tts>`／`<image>` texts the user changed become unbound
/// custom packs; the new per-model defaults take over.
PromptPackState migrateGlobalSlots(
  PromptPackState state,
  Map<String, dynamic>? oldSlots,
) {
  if (state.migrations.contains(PromptPackMigrations.globalSlots)) {
    return state;
  }
  var library = state.library;
  final tts = oldSlots?['tts'];
  if (tts is String &&
      tts.trim().isNotEmpty &&
      tts.trim() != TtsConfig.defaultSystemPromptTemplate.trim()) {
    final text = tts
        .replaceAll('{minimax_guide}', '')
        .replaceAll('{fish_audio_guide}', '')
        .trim();
    library = library.saveCustom(
      library
          .require('builtin.tts.generic')
          .copyWith(
            id: 'legacy.tts.global',
            name: '旧版自定义说明（语音）',
            description: '10-19 前在「工具提示词」里改过的 <tts> 说明，需要时手动绑到音色预设',
            match: const [],
            sections: [
              PromptSection(
                id: 'legacy.text',
                scope: PromptScopes.ttsChat,
                title: '旧版 <tts> 说明',
                text: text,
              ),
              library.require('builtin.tts.generic').section('tts.off')!,
            ],
          ),
    );
  }
  final image = oldSlots?['image'];
  if (image is String &&
      image.trim().isNotEmpty &&
      image.trim() != ImageConfig.defaultInlinePromptTemplate.trim()) {
    final novelai = library.require('builtin.image.novelai');
    // Only the parameter contract of the factory inline text is kept, so the
    // JSON form still works next to the user's own text.
    final factoryInline = novelai.sections
        .where((s) => s.scope == PromptScopes.imageInline)
        .single
        .text;
    final contractAt = factoryInline.indexOf('【本次绘图参数契约】');
    library = library.saveCustom(
      novelai.copyWith(
        id: 'legacy.image.global',
        name: '旧版自定义说明（绘图）',
        description: '10-19 前在「工具提示词」里改过的 <image> 说明，需要时手动绑到绘图预设',
        match: const [],
        sections: [
          PromptSection(
            id: 'legacy.text',
            scope: PromptScopes.imageInline,
            title: '旧版 <image> 说明',
            text: image.trim(),
          ),
          if (contractAt >= 0)
            PromptSection(
              id: 'legacy.contract',
              scope: PromptScopes.imageInline,
              title: '参数契约',
              text: factoryInline.substring(contractAt),
            ),
          for (final s in novelai.sections)
            if (s.scope != PromptScopes.imageInline) s,
        ],
      ),
    );
  }
  return state.copyWith(
    library: library,
    migrations: {...state.migrations, PromptPackMigrations.globalSlots},
  );
}

/// Puts the custom width and height lines in place of the factory ones.
String _replaceSizeLines(
  String text, {
  required String width,
  required String height,
}) => [
  for (final line in text.split('\n'))
    if (line.startsWith('- 宽度 ')) width
    else if (line.startsWith('- 高度 ')) height
    else line,
].join('\n');

/// A drawing preset whose `draw_image` descriptions differ from the factory
/// text gets its own pack carrying them, bound to it, so it keeps behaving
/// as before.
({PromptPackState state, List<DrawingPreset> changed}) migrateDrawingTools(
  PromptPackState state,
  DrawingPresetCatalog catalog,
) {
  if (state.migrations.contains(PromptPackMigrations.drawingTools)) {
    return (state: state, changed: const []);
  }
  var library = state.library;
  final changed = <DrawingPreset>[];
  final factory = ImageConfig.runtimeDefaultToolDescriptionBlocks;
  for (final preset in catalog.presets) {
    if (preset.prompts.packId != null) continue;
    final blocks = preset.config.effectiveToolDescriptionBlocks;
    if (jsonEncode(blocks.toJson()) == jsonEncode(factory.toJson())) continue;
    final id = 'legacy.image.tools.${preset.id}';
    final base = library.require('builtin.image.novelai');
    final baseParams = base.sections
        .where((s) => s.scope == PromptScopes.imageToolParams)
        .firstOrNull;
    final texts = {
      PromptScopes.imageToolDescription: blocks.toolDescription,
      PromptScopes.imageToolPrompt: [
        blocks.promptDescription,
        blocks.negativePromptDescription,
      ].where((text) => text.trim().isNotEmpty).join('\n\n'),
      if (baseParams != null)
        PromptScopes.imageToolParams: _replaceSizeLines(
          baseParams.text,
          width: '- 宽度 width：${blocks.widthDescription} 参考值 {default_width}，可省略。',
          height: '- 高度 height：${blocks.heightDescription} 参考值 {default_height}，可省略。',
        ),
    };
    if (library.byId(id) == null) {
      library = library.saveCustom(
        base.copyWith(
          id: id,
          name: '旧绘图工具说明 · ${preset.name}',
          description: '迁移自这个绘图预设里改过的 draw_image 工具说明',
          match: const [],
          sections: [
            for (final s in base.sections)
              texts.containsKey(s.scope) ? s.copyWith(text: texts[s.scope]) : s,
          ],
        ),
      );
    }
    changed.add(preset.copyWith(prompts: preset.prompts.withPack(id)));
  }
  // Marked done only after every binding is saved ([markDrawingToolsDone]),
  // so an interrupted run binds the rest next time; packs are reused.
  return (state: state.copyWith(library: library), changed: changed);
}

PromptPackState markDrawingToolsDone(PromptPackState state) =>
    state.migrations.contains(PromptPackMigrations.drawingTools)
    ? state
    : state.copyWith(
        migrations: {...state.migrations, PromptPackMigrations.drawingTools},
      );

/// Ids of the preset sections a role's old drawing requirement becomes.
const kRoleDrawingInlineSection = 'role_drawing.inline';
const kRoleDrawingToolSection = 'role_drawing.tool';

/// The two preset sections that carry a role's old drawing requirement, as
/// the old code appended it to each route.
List<PromptSection> roleDrawingSections(String text) => [
  PromptSection(
    id: kRoleDrawingInlineSection,
    scope: PromptScopes.imageInline,
    title: '角色专属生图要求',
    text: '角色专属生图要求：\n${text.trim()}',
  ),
  PromptSection(
    id: kRoleDrawingToolSection,
    scope: PromptScopes.imageToolPrompt,
    title: '角色专属生图要求（自动模式）',
    text: '【角色专属生图要求】\n${text.trim()}',
  ),
];

/// What moving one role's drawing requirement into a preset writes.
class RoleDrawingMove {
  const RoleDrawingMove({
    required this.preset,
    required this.personaPrompt,
    required this.sourcePersona,
    required this.sections,
  });

  /// The preset to save: the role's own one with the sections added, or a
  /// new copy only this role uses.
  final DrawingPreset preset;
  final String personaPrompt;

  /// The persona the move was planned from; the role is rewritten only
  /// while it still has exactly this.
  final String sourcePersona;
  final List<PromptSection> sections;

  /// Puts the sections into the catalog as it is now: into the stored
  /// preset when it exists, else adds [preset]. Only missing sections are
  /// added: one already there (an earlier run, then edited by the user)
  /// is kept as it is.
  DrawingPresetCatalog applyTo(DrawingPresetCatalog catalog) {
    final existing = catalog.presets
        .where((p) => p.id == preset.id)
        .firstOrNull;
    if (existing == null) return catalog.upsert(preset);
    final next = existing.prompts.addMissing(sections);
    return identical(next, existing.prompts)
        ? catalog
        : catalog.upsert(existing.copyWith(prompts: next));
  }
}

/// Plans moving [role]'s drawing requirement into its drawing preset. The
/// preset is reused only when the role is its sole user and it is not the
/// default; otherwise a copy named after the role is made (ADR0092).
RoleDrawingMove? planRoleDrawingMove(
  Conversation role,
  DrawingPresetCatalog catalog,
  List<Conversation> roles,
) {
  final parts = PersonaPromptCodec.parse(role.personaPrompt);
  final text = parts.customDrawingPrompt.trim();
  if (text.isEmpty) return null;
  final current = catalog.resolve(parts);
  String? presetOf(Conversation other) {
    try {
      return catalog.resolve(PersonaPromptCodec.parse(other.personaPrompt)).id;
    } on StateError {
      return null;
    }
  }

  final shared =
      current.id == catalog.defaultPresetId ||
      roles.any((r) => r.id != role.id && presetOf(r) == current.id) ||
      !catalog.presets.any((p) => p.id == current.id);
  final sections = roleDrawingSections(text);
  var binding = current.prompts;
  for (final section in sections) {
    binding = binding.upsertSection(section);
  }
  if (!shared) {
    return RoleDrawingMove(
      preset: current.copyWith(prompts: binding),
      personaPrompt: PersonaPromptCodec.compose(
        userPrompt: parts.userPrompt,
        drawingToolPresetName: parts.drawingToolPresetName,
        drawingArtistPresetName: parts.drawingArtistPresetName,
        drawingPresetId: parts.drawingPresetId,
      ),
      sourcePersona: role.personaPrompt,
      sections: sections,
    );
  }
  final name = role.displayName.trim().isEmpty ? role.title : role.displayName;
  // The copy is named after its source too: if the role is rebound while a
  // move runs, the next run copies the new source instead of reusing a
  // copy of the old one.
  final copyId = '${DrawingPresetCatalog.roleCopyPrefix}${role.id}_${current.id}';
  return RoleDrawingMove(
    preset: current.copyWith(
      id: copyId,
      name: '${name.trim()} · ${current.name}',
      prompts: binding,
    ),
    personaPrompt: PersonaPromptCodec.compose(
      userPrompt: parts.userPrompt,
      drawingPresetId: copyId,
    ),
    sourcePersona: role.personaPrompt,
    sections: sections,
  );
}

/// Runs the moves once per app session. Requests only need [ensurePacks];
/// moving the roles' drawing requirements runs at start-up ([ensure]), and
/// a request for a role not moved yet adds the requirement itself.
class PromptPackMigrator {
  PromptPackMigrator(this._ref);

  final Ref _ref;
  Future<void>? _packs;
  Future<void>? _all;

  Future<void> ensurePacks() =>
      _packs ??= _guard(_runPacks, () => _packs = null);

  Future<void> ensure() => _all ??= _guard(() async {
    await ensurePacks();
    final roles = await _ref.read(conversationsProvider.future);
    for (final role in roles) {
      await forRole(role);
    }
    await _tidyDrawingPresets();
  }, () => _all = null);

  Future<void> _tidyDrawingPresets() async {
    await _unbindRoleCopies();
    final roles = await _ref.read(conversationsProvider.future);
    DrawingPresetCatalog tidy(DrawingPresetCatalog catalog) {
      final used = <String>{};
      for (final role in roles) {
        try {
          used.add(
            catalog.resolve(PersonaPromptCodec.parse(role.personaPrompt)).id,
          );
        } on StateError {
          // A broken binding uses no preset.
        }
      }
      return catalog.tidied(used);
    }

    // Writing is skipped when there is nothing to tidy, so a start-up
    // does not touch the synced catalog every time.
    final catalog = await _ref.read(drawingPresetCatalogProvider.future);
    if (identical(tidy(catalog), catalog)) return;
    await _ref.read(drawingPresetCatalogProvider.notifier).transact(tidy);
  }

  /// The moved drawing requirements are dropped (the user found them too
  /// hidden to use): a role on its own copy goes back to the preset the copy
  /// was made from, or to the default when that one is gone.
  Future<void> _unbindRoleCopies() async {
    final roles = await _ref.read(conversationsProvider.future);
    final catalog = await _ref.read(drawingPresetCatalogProvider.future);
    for (final role in roles) {
      final parts = PersonaPromptCodec.parse(role.personaPrompt);
      final copyPrefix = '${DrawingPresetCatalog.roleCopyPrefix}${role.id}_';
      final bound = parts.drawingPresetId;
      if (bound == null || !bound.startsWith(copyPrefix)) continue;
      final source = bound.substring(copyPrefix.length);
      final keep =
          source != catalog.defaultPresetId &&
          catalog.presets.any((p) => p.id == source);
      final persona = PersonaPromptCodec.compose(
        userPrompt: parts.userPrompt,
        drawingPresetId: keep ? source : null,
      );
      await _ref
          .read(conversationsProvider.notifier)
          .updateOne(
            role.id,
            (current) => current.personaPrompt != role.personaPrompt
                ? current
                : current.copyWith(
                    personaPrompt: persona,
                    updatedAt: DateTime.now(),
                  ),
          );
    }
  }

  Future<void> _guard(Future<void> Function() body, void Function() reset) =>
      body().catchError((Object e) {
        reset();
        AppLogger.warning(
          'PromptPacks',
          '提示词包迁移失败，下次再试',
          metadata: {'errorType': e.runtimeType.toString()},
        );
      });

  Future<void> _runPacks() async {
    final prefs = await SharedPreferences.getInstance();
    Map<String, dynamic>? oldSlots;
    final raw = prefs.getString(PreferencesPluginPromptStore.storageKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        oldSlots = jsonDecode(raw) as Map<String, dynamic>;
      } on FormatException {
        oldSlots = null;
      }
    }
    final packs = _ref.read(promptPackProvider.notifier);
    final drawing = _ref.read(drawingPresetCatalogProvider.notifier);
    await packs.transact((s) => migrateGlobalSlots(s, oldSlots));
    final catalog = await _ref.read(drawingPresetCatalogProvider.future);
    var changed = const <DrawingPreset>[];
    await packs.transact((s) {
      final result = migrateDrawingTools(s, catalog);
      changed = result.changed;
      return result.state;
    });
    // Bind each preset on its stored value, so edits made meanwhile stay.
    for (final preset in changed) {
      await drawing.transact((catalog) {
        final stored = catalog.presets
            .where((p) => p.id == preset.id)
            .firstOrNull;
        if (stored == null || stored.prompts.packId != null) return catalog;
        return catalog.upsert(
          stored.copyWith(
            prompts: stored.prompts.withPack(preset.prompts.packId),
          ),
        );
      });
    }
    await packs.transact(markDrawingToolsDone);
  }

  final _roles = <String, Future<void>>{};

  /// Moves [role]'s drawing requirement, if it still has one. Calls for the
  /// same role while one runs share it.
  Future<void> forRole(Conversation role) =>
      _roles[role.id] ??= _forRole(role).whenComplete(() {
        // A block, not `=> remove(...)`: whenComplete would wait for the
        // removed future, which is this one.
        _roles.remove(role.id);
      });

  Future<void> _forRole(Conversation role) async {
    final roles = await _ref.read(conversationsProvider.future);
    // Only stored roles are moved; the request falls back on its own.
    final latest = roles.where((r) => r.id == role.id).firstOrNull;
    if (latest == null) return;
    final catalog = await _ref.read(drawingPresetCatalogProvider.future);
    final RoleDrawingMove? move;
    try {
      move = planRoleDrawingMove(latest, catalog, roles);
    } on StateError catch (e) {
      AppLogger.warning(
        'PromptPacks',
        '角色绘图提示迁移跳过：绘图预设不可用',
        metadata: {'roleId': role.id, 'error': e.message},
      );
      return;
    }
    if (move == null) return;
    final planned = move;
    // Preset first: if the role write fails the text is already safe there
    // and the retry finds the same section ids.
    await _ref
        .read(drawingPresetCatalogProvider.notifier)
        .transact(planned.applyTo);
    // Only while the persona is still the one planned from: an edit made
    // meanwhile keeps the role as it is, and the next run plans again.
    await _ref
        .read(conversationsProvider.notifier)
        .updateOne(
          latest.id,
          (current) => current.personaPrompt != planned.sourcePersona
              ? current
              : current.copyWith(
                  personaPrompt: planned.personaPrompt,
                  updatedAt: DateTime.now(),
                ),
        );
  }
}

final promptPackMigratorProvider = Provider<PromptPackMigrator>(
  PromptPackMigrator.new,
);
