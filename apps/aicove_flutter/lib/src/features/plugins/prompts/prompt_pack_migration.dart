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
    if (line.startsWith('- 宽度 '))
      width
    else if (line.startsWith('- 高度 '))
      height
    else
      line,
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
          width:
              '- 宽度 width：${blocks.widthDescription} 参考值 {default_width}，可省略。',
          height:
              '- 高度 height：${blocks.heightDescription} 参考值 {default_height}，可省略。',
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

/// Returns the original text only when the legacy sections can be represented
/// without losing their enabled state, scope or distinct content.
String? extractRoleDrawingText(PresetPromptBinding binding) {
  final sections = binding.ownSections
      .where(
        (s) =>
            s.id == kRoleDrawingInlineSection ||
            s.id == kRoleDrawingToolSection,
      )
      .toList();
  if (sections.isEmpty ||
      sections.map((s) => s.id).toSet().length != sections.length) {
    return null;
  }
  String? result;
  for (final section in sections) {
    final inline = section.id == kRoleDrawingInlineSection;
    final prefix = inline ? '角色专属生图要求：\n' : '【角色专属生图要求】\n';
    final scope = inline
        ? PromptScopes.imageInline
        : PromptScopes.imageToolPrompt;
    if (!section.enabled ||
        section.scope != scope ||
        !section.text.startsWith(prefix)) {
      return null;
    }
    final text = section.text.substring(prefix.length);
    if (text.isEmpty ||
        text != text.trim() ||
        (result != null && result != text)) {
      return null;
    }
    result = text;
  }
  return result;
}

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
        extraPrompt: parts.extraPrompt,
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
  final copyId =
      '${DrawingPresetCatalog.roleCopyPrefix}${role.id}_${current.id}';
  return RoleDrawingMove(
    preset: current.copyWith(
      id: copyId,
      name: '${name.trim()} · ${current.name}',
      prompts: binding,
    ),
    personaPrompt: PersonaPromptCodec.compose(
      userPrompt: parts.userPrompt,
      extraPrompt: parts.extraPrompt,
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

  /// Restore role-owned data before removing old role copies or sections.
  Future<void> _unbindRoleCopies() async {
    final prefs = await SharedPreferences.getInstance();
    const nahidaKey = 'nahida_drawing_prompt_restored_v1';
    final restoreNahida = prefs.getBool(nahidaKey) != true;
    final roles = await _ref.read(conversationsProvider.future);
    final catalog = await _ref.read(drawingPresetCatalogProvider.future);
    final recovered = <String, String>{};
    var nahidaDone = restoreNahida;
    for (final role in roles) {
      final parts = PersonaPromptCodec.parse(role.personaPrompt);
      DrawingPreset? preset;
      try {
        preset = catalog.resolve(parts);
      } on StateError {
        // A missing preset cannot supply legacy data.
      }
      final binding = preset?.prompts;
      final extracted = binding == null
          ? null
          : extractRoleDrawingText(binding);
      final hasLegacy =
          binding?.ownSections.any(
            (s) =>
                s.id == kRoleDrawingInlineSection ||
                s.id == kRoleDrawingToolSection,
          ) ??
          false;
      var drawing = parts.customDrawingPrompt;
      if (drawing.trim().isEmpty && extracted != null) drawing = extracted;
      if (restoreNahida &&
          role.id == 'preset_nahida' &&
          drawing.trim().isEmpty) {
        drawing = 'nahida_(genshin_impact)';
      }
      if (role.id == 'preset_nahida' &&
          drawing.trim() == 'danbooru 标签为 nahida_(genshin_impact)') {
        drawing = 'nahida_(genshin_impact)';
      }
      var packId = parts.drawingPromptPackId;
      final oldPack = binding?.packId;
      final copyPrefix = '${DrawingPresetCatalog.roleCopyPrefix}${role.id}_';
      final bound = parts.drawingPresetId;
      final isCopy = bound != null && bound.startsWith(copyPrefix);
      if (packId == null &&
          oldPack != null &&
          (isCopy || !oldPack.startsWith('legacy.image.tools.'))) {
        packId = oldPack;
      }
      var presetId = bound;
      // A copy with divergent or disabled sections still owns unrecoverable
      // data, so keep it bound until the user can resolve it.
      if (isCopy && (!hasLegacy || extracted != null)) {
        final source = bound.substring(copyPrefix.length);
        presetId =
            source != catalog.defaultPresetId &&
                catalog.presets.any((p) => p.id == source)
            ? source
            : null;
      }
      final persona = PersonaPromptCodec.compose(
        userPrompt: parts.userPrompt,
        extraPrompt: parts.extraPrompt,
        customDrawingPrompt: drawing,
        drawingPromptPackId: packId,
        drawingPresetId: presetId,
        drawingToolPresetName: parts.drawingToolPresetName,
        drawingArtistPresetName: parts.drawingArtistPresetName,
      );
      if (persona != role.personaPrompt) {
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
      final current = (await _ref.read(
        conversationsProvider.future,
      )).where((r) => r.id == role.id).firstOrNull;
      if (extracted != null &&
          preset != null &&
          current?.personaPrompt == persona &&
          PersonaPromptCodec.parse(
                current!.personaPrompt,
              ).customDrawingPrompt ==
              extracted) {
        recovered[preset.id] = jsonEncode(preset.prompts.toJson());
      }
      if (restoreNahida &&
          role.id == 'preset_nahida' &&
          current != null &&
          current.personaPrompt != persona &&
          PersonaPromptCodec.parse(
            current.personaPrompt,
          ).customDrawingPrompt.isEmpty) {
        nahidaDone = false;
      }
    }
    if (nahidaDone) await prefs.setBool(nahidaKey, true);
    final currentRoles = await _ref.read(conversationsProvider.future);
    await _ref.read(drawingPresetCatalogProvider.notifier).transact((current) {
      var next = current;
      for (final id in recovered.keys) {
        final preset = next.presets.where((p) => p.id == id).firstOrNull;
        if (preset == null ||
            jsonEncode(preset.prompts.toJson()) != recovered[id]) {
          continue;
        }
        final stillNeeded = currentRoles.any((role) {
          final parts = PersonaPromptCodec.parse(role.personaPrompt);
          if (parts.customDrawingPrompt.trim().isNotEmpty) return false;
          try {
            return next.resolve(parts).id == id;
          } on StateError {
            return false;
          }
        });
        if (stillNeeded) continue;
        final binding = preset.prompts
            .removeSection(kRoleDrawingInlineSection)
            .removeSection(kRoleDrawingToolSection);
        next = next.upsert(preset.copyWith(prompts: binding));
      }
      return next;
    });
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

  /// Role requirements remain on the role; retained for existing callers.
  Future<void> forRole(Conversation role) async {}
}

final promptPackMigratorProvider = Provider<PromptPackMigrator>(
  PromptPackMigrator.new,
);
