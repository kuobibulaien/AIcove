import 'package:aicove_agent_kernel/aicove_agent_kernel.dart' show JournalEntry;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../agent_context/providers/preset_recipe_provider.dart';
import '../agent_plugins/file_change_journal.dart';
import '../../core/database/converters/database_converters.dart';
import '../../core/database/database_provider.dart';
import '../chat/chat_layer_providers.dart';
import '../chat/conversation_providers.dart';
import '../chat/domain/conversation.dart';
import '../chat/domain/persona_prompt_codec.dart';
import '../memory/providers/memory_providers.dart';
import '../settings/app_settings.dart';
import '../settings/provider_detail/provider_detail_actions.dart';
import '../plugins/image/drawing_preset_provider.dart';
import '../plugins/image/image_plugin.dart';
import '../plugins/plugin_providers.dart';
import '../plugins/prompts/plugin_prompt_resolution.dart';
import '../plugins/prompts/plugin_prompts.dart';
import '../plugins/prompts/prompt_pack.dart';
import '../plugins/prompts/prompt_pack_store.dart';
import '../plugins/tts/tts_config.dart';
import '../plugins/tts/tts_provider_context.dart';
import '../voice_call/providers/voice_call_providers.dart';
import 'application/assistant_cards.dart';
import 'application/assistant_package_tools.dart';
import '../plugins/packages/package_providers.dart';
import '../workspace/workspace_providers.dart';
import '../workspace/domain/workspace_grants.dart';
import 'application/assistant_checkup.dart';
import 'application/assistant_plugin_option_tools.dart';
import 'application/assistant_preset_tools.dart';
import 'application/assistant_private_read_tools.dart';
import 'application/assistant_prompt_pack_tools.dart';
import 'application/assistant_provider_tools.dart';
import 'application/assistant_sticker_tools.dart';
import '../stickers/sticker_library_provider.dart';
import 'application/assistant_role_tools.dart';
import 'application/assistant_settings.dart';
import 'application/assistant_settings_tools.dart';
import 'application/assistant_tool_group.dart';
import 'application/assistant_toolset.dart';
import 'application/assistant_write_tools.dart';
import 'domain/aicove_docs.dart';
import 'domain/assistant_onboarding.dart';

/// Every dependency is read when a tool runs, not when the toolset is built:
/// the toolset is created inside request assembly, which the context preview
/// itself goes through.
final assistantToolsetProvider = Provider<AssistantToolset>(
  (ref) => AssistantToolset(
    roles: () => ref.read(conversationsProvider.future),
    presets: () => ref.read(sillyTavernPresetStoreProvider).list(),
    previewContext: (role) =>
        ref.read(chatContextPreviewPortProvider).preview(role),
    readDoc: (id) async => id == kAicoveSettingsDocId
        ? assistantSettingsDoc()
        : readBundledAicoveDoc(id),
  ),
);

final assistantRoleStoreProvider = Provider<AssistantRoleStore>(
  _ConversationsRoleStore.new,
);

/// The local, unsynced journal the assistant's changes are undone from.
final assistantChangeJournalProvider = Provider<FileChangeJournal>(
  (ref) => FileChangeJournal(
    file: FileChangeJournal.defaultFile,
    appliers: {
      ...assistantChangeAppliers(
        roles: ref.read(assistantRoleStoreProvider),
        presets: ref.read(sillyTavernPresetStoreProvider),
      ),
      assistantSettingChangeKind: AssistantSettingApplier(
        notifier: () => ref.read(appSettingsProvider.notifier),
      ),
      assistantInterfaceResetChangeKind: AssistantInterfaceResetApplier(
        notifier: () => ref.read(appSettingsProvider.notifier),
      ),
      assistantPluginOptionChangeKind: AssistantPluginOptionApplier(
        () => ref.read(assistantPluginOptionsProvider),
      ),
      assistantStickerImportKind: AssistantStickerImportApplier(
        () => StickerLibraryNotifier.open(),
      ),
      assistantStickerTagsKind: AssistantStickerTagsApplier(
        () => StickerLibraryNotifier.open(),
      ),
      assistantProviderChangeKind: AssistantProviderApplier(
        notifier: () => ref.read(appSettingsProvider.notifier),
      ),
      ..._promptPackAppliers(ref),
    },
  ),
);

Map<String, ChangeApplier> _promptPackAppliers(Ref ref) {
  final packs = AssistantPromptPackApplier(
    library: () => ref.read(promptPackProvider.notifier).library,
    change: (edit) => ref.read(promptPackProvider.notifier).change(edit),
    boundBy: (packId) async => [
      for (final preset in await _promptPresets(ref))
        if (preset.binding.packId == packId) (id: preset.id, name: preset.name),
    ],
  );
  final presets = AssistantPresetPromptsApplier(
    presets: () => _promptPresets(ref),
    save: (pluginId, presetId, binding, {expected}) => _savePresetPrompts(
      ref,
      pluginId,
      presetId,
      binding,
      expected: expected,
    ),
  );
  return {
    assistantPromptPackChangeKind: packs,
    assistantPresetPromptsChangeKind: presets,
    assistantPromptPackForkChangeKind: AssistantPromptPackForkApplier(
      packs: packs,
      presets: presets,
    ),
  };
}

/// Voice and drawing presets with what their 「自动」 prompt pack matches on,
/// worked out the way their editors do (ADR0092).
Future<List<AssistantPromptPreset>> _promptPresets(Ref ref) async {
  final settings = await ref.read(appSettingsProvider.future);
  final catalog = await ref.read(drawingPresetCatalogProvider.future);
  return [
    for (final preset in ref.read(ttsPluginConfigProvider).voicePresets)
      if (preset.synthesis case final synthesis?)
        AssistantPromptPreset(
          pluginId: 'tts',
          id: preset.id,
          name: preset.name,
          binding: synthesis.prompts,
          format: ttsPromptFormat(
            TtsProviderContext.resolveForSelection(
              config: TtsConfig(),
              settings: settings,
              providerId: synthesis.providerId,
              modelId: synthesis.modelId,
            ).requestFormat,
          ),
          model: synthesis.modelId,
          variables: {
            'max_chars_per_chunk': synthesis.maxCharsPerChunk,
            'voice_frequency': synthesis.voiceFrequency,
          },
        ),
    for (final preset in catalog.presets)
      () {
        final target = ImagePlugin(
          preset.config,
          ref,
          requestSettings: settings,
          isRequestSnapshot: true,
        ).promptTarget(settings);
        return AssistantPromptPreset(
          pluginId: 'image',
          id: preset.id,
          name: preset.name,
          binding: preset.prompts,
          format: target?.format ?? 'openai',
          model: target?.model ?? '',
          variables: imagePromptVariables(preset.config),
        );
      }(),
  ];
}

/// Writes a preset's prompt binding in its store's write queue. With
/// [expected], only while the stored binding still equals it; returns
/// whether it wrote.
Future<bool> _savePresetPrompts(
  Ref ref,
  String pluginId,
  String presetId,
  PresetPromptBinding binding, {
  PresetPromptBinding? expected,
}) async {
  bool matches(PresetPromptBinding stored) =>
      expected == null || samePromptState(stored.toJson(), expected.toJson());
  var wrote = false;
  if (pluginId == 'image') {
    await ref.read(drawingPresetCatalogProvider.notifier).transact((catalog) {
      final stored = catalog.presets.where((p) => p.id == presetId).firstOrNull;
      if (stored == null) throw StateError('绘图预设已经不在了：$presetId');
      if (!matches(stored.prompts)) return catalog;
      wrote = true;
      return catalog.upsert(stored.copyWith(prompts: binding));
    });
    return wrote;
  }
  await ref.read(ttsPluginConfigProvider.notifier).updatePreset(presetId, (
    stored,
  ) {
    final synthesis = stored.synthesis;
    if (synthesis == null) throw StateError('音色预设已经不在了：$presetId');
    if (!matches(synthesis.prompts)) return null;
    wrote = true;
    return stored.copyWith(synthesis: synthesis.withPrompts(binding));
  });
  return wrote;
}

final assistantWriteToolsProvider = Provider<AssistantWriteTools>(
  (ref) => AssistantWriteTools(
    roles: ref.read(assistantRoleStoreProvider),
    presets: ref.read(sillyTavernPresetStoreProvider),
    journal: ref.read(assistantChangeJournalProvider),
    onChanged: () => ref.invalidate(assistantRecentChangesProvider),
  ),
);

final assistantSettingsToolsProvider = Provider<AssistantSettingsTools>(
  (ref) => AssistantSettingsTools(
    current: () => ref.read(appSettingsProvider).valueOrNull,
    load: () => ref.read(appSettingsProvider.future),
    notifier: () => ref.read(appSettingsProvider.notifier),
    journal: ref.read(assistantChangeJournalProvider),
    onChanged: () => ref.invalidate(assistantRecentChangesProvider),
  ),
);

/// Tool groups beyond the original roles, presets and settings tools
/// (ADR0073 full access); each rates and describes its own calls.
final assistantToolGroupsProvider = Provider<List<AssistantToolGroup>>((ref) {
  return [
    AssistantPackageTools(
      store: () => ref.read(workspaceStoreProvider.future),
      packages: () => ref.read(aicovePackagesProvider.notifier),
      workspaceIds: () async {
        final roles = await ref.read(conversationsProvider.future);
        final assistant = roles.where((r) => r.id == kAicoveAssistantId).firstOrNull;
        if (assistant == null) return {};
        final store = await ref.read(workspaceStoreProvider.future);
        return WorkspaceGrants.effective(
          roleGrants: WorkspaceGrants.forRole(assistant.id, assistant.enabledPlugins),
          presetAllows: null, pluginEnabled: true,
          localIds: [for (final w in await store.list()) w.id],
        );
      },
    ),
    AssistantProviderTools(
      current: () => ref.read(appSettingsProvider).valueOrNull,
      load: () => ref.read(appSettingsProvider.future),
      notifier: () => ref.read(appSettingsProvider.notifier),
      journal: ref.read(assistantChangeJournalProvider),
      cards: () => ref.read(assistantCardsProvider.notifier),
      primaryKey: (provider) => ref
          .read(providerDetailActionsProvider)
          .resolvePrimaryApiKey(provider),
      testModel: (provider, model) => ref
          .read(providerDetailActionsProvider)
          .testModel(
            provider: provider,
            apiKey: ref
                .read(providerDetailActionsProvider)
                .resolvePrimaryApiKey(provider),
            modelId: model,
          ),
      onChanged: () => ref.invalidate(assistantRecentChangesProvider),
    ),
    AssistantRoleTools(
      writes: ref.read(assistantWriteToolsProvider),
      rolesNow: ref.read(assistantRoleStoreProvider).snapshot,
      roles: () async => [
        for (final role in await ref.read(assistantRoleStoreProvider).load())
          if (!role.isHidden) role,
      ],
      settings: () => ref.read(appSettingsProvider.future),
      voices: () => ref.read(ttsPluginConfigProvider).voicePresets,
      cards: () => ref.read(assistantCardsProvider.notifier),
      deleteRole: ref.read(assistantRoleStoreProvider).delete,
      clearChat: (id) =>
          ref.read(conversationsProvider.notifier).clearMessages(id),
      drawingPresets: () async => [
        for (final preset
            in (await ref.read(drawingPresetCatalogProvider.future)).presets)
          (id: preset.id, name: preset.name),
      ],
      onChanged: () => ref.invalidate(assistantRecentChangesProvider),
    ),
    AssistantPresetTools(
      presets: () => ref.read(sillyTavernPresetStoreProvider).list(),
      importPreset: (source, name) => ref
          .read(presetRecipeImportControllerProvider.notifier)
          .importSource(source, sourceFileName: name),
      change: (id, action) => ref
          .read(presetRecipeImportControllerProvider.notifier)
          .change(id, action),
      deletePreset: (id) => ref
          .read(presetRecipeImportControllerProvider.notifier)
          .deletePreset(id),
      cards: () => ref.read(assistantCardsProvider.notifier),
    ),
    AssistantPluginOptionTools(
      options: ref.read(assistantPluginOptionsProvider),
      journal: ref.read(assistantChangeJournalProvider),
      onChanged: () => ref.invalidate(assistantRecentChangesProvider),
    ),
    AssistantStickerTools(
      library: () => StickerLibraryNotifier.open(),
      journal: ref.read(assistantChangeJournalProvider),
      onChanged: () {
        ref.invalidate(assistantRecentChangesProvider);
        ref.invalidate(stickerLibraryProvider);
      },
    ),
    AssistantPromptPackTools(
      library: () => ref.read(promptPackProvider.notifier).library,
      change: (edit) => ref.read(promptPackProvider.notifier).change(edit),
      presets: () => _promptPresets(ref),
      journal: ref.read(assistantChangeJournalProvider),
      onChanged: () => ref.invalidate(assistantRecentChangesProvider),
    ),
    AssistantPrivateReadTools(
      rolesNow: ref.read(assistantRoleStoreProvider).snapshot,
      roles: () async => [
        for (final role in await ref.read(assistantRoleStoreProvider).load())
          if (!role.isHidden) role,
      ],
      grants: ref.read(assistantReadGrantsProvider),
      messages: (roleId, {required limit, before, keyword}) async {
        final repo = ref.read(messageRepositoryProvider);
        final rows = keyword == null
            ? await repo.getByConversationStable(
                roleId,
                limit: limit,
                beforeTime: before?.millisecondsSinceEpoch,
              )
            : await repo.searchByConversation(
                roleId,
                keyword: keyword,
                endTime: before?.millisecondsSinceEpoch,
                limit: limit,
              );
        return [
          for (final row in rows)
            (
              role: row.role,
              content: row.content,
              at: DateTime.fromMillisecondsSinceEpoch(row.createdAt),
            ),
        ];
      },
      memories: (roleId) async => [
        for (final item in await ref.read(memoryStoreProvider).list(roleId))
          (title: item.title, content: item.content, locked: item.locked),
      ],
    ),
  ];
});

/// Global plugin options the assistant may change.
final assistantPluginOptionsProvider = Provider<List<AssistantPluginOption>>((
  ref,
) {
  // Starts loading the tool prompts now, so they have loaded long before a
  // tool reads them synchronously.
  ref.read(pluginPromptsProvider);
  return assistantPluginOptions(
    time: () {
      final config = ref.read(timeAwarenessPluginConfigProvider);
      return (
        messageTimestamp: config.includeMessageTimestamp,
        currentTime: config.includeCurrentTime,
      );
    },
    setTime: ({messageTimestamp, currentTime}) async {
      final notifier = ref.read(timeAwarenessPluginConfigProvider.notifier);
      if (messageTimestamp != null) {
        await notifier.setIncludeMessageTimestamp(messageTimestamp);
      }
      if (currentTime != null) {
        await notifier.setIncludeCurrentTime(currentTime);
      }
    },
    webSearch: () => ref.read(webSearchPluginConfigProvider),
    setWebSearch: (config) =>
        ref.read(webSearchPluginConfigProvider.notifier).updateConfig(config),
    prompts: () =>
        ref.read(pluginPromptsProvider).valueOrNull ?? const PluginPrompts(),
    setPrompt: (slot, text) =>
        ref.read(pluginPromptsProvider.notifier).setText(slot, text),
    setPromptIf: (slot, expected, text) => ref
        .read(pluginPromptsProvider.notifier)
        .setTextIf(slot, expected, text),
  );
});

/// Roles the user let the assistant read; loaded once at start so the first
/// rating sees stored grants.
final assistantReadGrantsProvider = Provider<AssistantReadGrants>(
  (ref) => AssistantReadGrants()..load(),
);

final assistantCardToolsProvider = Provider<AssistantCardTools>(
  (ref) => AssistantCardTools(
    settings: () => ref.read(appSettingsProvider.future),
    cards: () => ref.read(assistantCardsProvider.notifier),
    roleExists: (id) async =>
        (await ref.read(assistantRoleStoreProvider).load()).any(
          (role) => role.id == id && !role.isHidden,
        ),
    presetExists: (id) async =>
        await ref.read(sillyTavernPresetStoreProvider).get(id) != null,
  ),
);

final assistantCheckupProvider = Provider<AssistantCheckup>(
  (ref) => AssistantCheckup(
    settings: () => ref.read(appSettingsProvider.future),
    roles: () => ref.read(assistantRoleStoreProvider).load(),
    presets: () => ref.read(sillyTavernPresetStoreProvider).list(),
    defaultPresetId: () async =>
        (await ref.read(sillyTavernPresetStoreProvider).loadPluginSettings())
            .defaultPresetId,
    voiceEnabled: () => ref.read(ttsPluginConfigProvider).enabled,
    callUnavailable: (role) =>
        ref.read(voiceCallFactoryProvider).unavailableReason(role),
  ),
);

/// The assistant's changes that can still be undone, newest first.
final assistantRecentChangesProvider = FutureProvider<List<JournalEntry>>((
  ref,
) async {
  final entries = await ref.read(assistantChangeJournalProvider).recent();
  return [
    for (final entry in entries)
      if (entry.undoneAt == null && entry.change.kind.startsWith('assistant.'))
        if (entry.toolName != 'undo') entry,
  ];
});

class _ConversationsRoleStore implements AssistantRoleStore {
  _ConversationsRoleStore(this._ref);

  final Ref _ref;

  ConversationsNotifier get _notifier =>
      _ref.read(conversationsProvider.notifier);

  @override
  List<Conversation> snapshot() =>
      _ref.read(conversationsProvider).valueOrNull ?? const [];

  /// From the database, not the list state: that state follows a database
  /// watch and may still show the previous value right after a write.
  @override
  Future<List<Conversation>> load() async => [
    for (final row in await _ref.read(conversationRepositoryProvider).getAll())
      ConversationConverter.fromDb(row),
  ];

  @override
  Future<String> create() => _serial(_notifier.createNew);

  @override
  Future<void> delete(String roleId) => _serial(() async {
    await _visibleRole(roleId);
    await _notifier.deleteConversation(roleId);
  });

  @override
  Future<bool> editIf(
    String roleId,
    bool Function(Conversation role) test,
    Map<String, Object?> fields,
  ) => _serial(
    () => _atomically(() async {
      final role = await _stored(roleId);
      if (role == null || role.isHidden || !test(role)) return false;
      // The list notifier writes from its state; a state that trails the
      // database would put the older card back.
      if (!_listMatches(role)) return false;
      await _edit(roleId, fields);
      return true;
    }),
  );

  @override
  Future<bool> deleteIf(
    String roleId,
    bool Function(Conversation role, int messageCount) test,
  ) => _serial(
    () => _atomically(() async {
      final role = await _stored(roleId);
      if (role == null || role.isHidden) return false;
      final messages = await _ref
          .read(messageRepositoryProvider)
          .countByConversation(roleId);
      if (!test(role, messages)) return false;
      await _notifier.deleteConversation(roleId);
      return true;
    }),
  );

  /// Check and write in one database transaction, so a save from the role
  /// edit page or a sync lands before the check or after the write, never
  /// in between.
  Future<T> _atomically<T>(Future<T> Function() body) =>
      _ref.read(conversationRepositoryProvider).transaction(body);

  bool _listMatches(Conversation stored) {
    final listed = snapshot().where((c) => c.id == stored.id).firstOrNull;
    // The database keeps milliseconds; a fresh state may carry more.
    return listed != null &&
        listed.updatedAt.millisecondsSinceEpoch ==
            stored.updatedAt.millisecondsSinceEpoch;
  }

  Future<Conversation?> _stored(String roleId) async =>
      (await load()).where((c) => c.id == roleId).firstOrNull;

  /// The last line against touching the privacy space: every assistant
  /// write, undo included, ends here.
  Future<Conversation> _visibleRole(String roleId) async {
    final role = await _stored(roleId);
    if (role == null) throw StateError('角色不存在或已删除');
    if (role.isHidden) throw StateError('角色在隐私空间里，助手不能修改');
    return role;
  }

  /// The list notifier writes the whole list from its state, so two edits
  /// at once (a parallel tool batch) would drop one of them.
  Future<void> _last = Future.value();

  Future<T> _serial<T>(Future<T> Function() body) {
    final result = _last.then((_) => body());
    _last = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  @override
  Future<void> edit(String roleId, Map<String, Object?> fields) =>
      _serial(() => _edit(roleId, fields));

  Future<void> _edit(String roleId, Map<String, Object?> fields) async {
    final role = await _visibleRole(roleId);
    bool has(String key) => fields.containsKey(key);
    String? text(String key) => fields[key] as String?;
    String? persona;
    if (has(RoleField.personaPrompt) ||
        has(RoleField.customDrawingPrompt) ||
        has(RoleField.drawingPreset)) {
      final parts = PersonaPromptCodec.parse(role.personaPrompt);
      // A new binding replaces the legacy by-name ones as a whole.
      final drawing = fields[RoleField.drawingPreset] as Map?;
      final rebind = has(RoleField.drawingPreset);
      persona = PersonaPromptCodec.compose(
        userPrompt: has(RoleField.personaPrompt)
            ? text(RoleField.personaPrompt) ?? ''
            : parts.userPrompt,
        customDrawingPrompt: has(RoleField.customDrawingPrompt)
            ? text(RoleField.customDrawingPrompt)
            : parts.customDrawingPrompt,
        drawingToolPresetName: rebind
            ? (drawing?['tool'] as String?)
            : parts.drawingToolPresetName,
        drawingArtistPresetName: rebind
            ? (drawing?['artist'] as String?)
            : parts.drawingArtistPresetName,
        drawingPresetId: rebind
            ? (drawing?['id'] as String?)
            : parts.drawingPresetId,
      );
    }
    final plugins = fields[RoleField.enabledPlugins];
    final background = fields[RoleField.chatBackground] as Map?;
    if (has(RoleField.thinkingLevels)) {
      final wanted = (fields[RoleField.thinkingLevels] as Map? ?? const {}).map(
        (key, value) => MapEntry('$key', ThinkingLevel.values.byName('$value')),
      );
      for (final model in {...role.thinkingLevels.keys, ...wanted.keys}) {
        if (role.thinkingLevels[model] == wanted[model]) continue;
        await _notifier.setConversationThinkingLevel(
          roleId,
          modelRef: model,
          level: wanted[model],
        );
      }
    }
    if (has(RoleField.displayStyle)) {
      final style = text(RoleField.displayStyle);
      await _notifier.setConversationChatDisplayStyle(
        roleId,
        style == null ? null : ChatDisplayStyle.values.byName(style),
      );
    }
    double? number(String key) => (fields[key] as num?)?.toDouble();
    if (has(RoleField.pinned) || has(RoleField.muted)) {
      await _notifier.updateConversationSettings(
        roleId,
        isPinned: fields[RoleField.pinned] as bool?,
        isMuted: fields[RoleField.muted] as bool?,
      );
    }
    await _notifier.applyContactEdit(
      roleId,
      displayName: text(RoleField.displayName),
      description: text(RoleField.description),
      clearDescription:
          has(RoleField.description) && text(RoleField.description) == null,
      selfAddress: text(RoleField.selfAddress),
      clearSelfAddress:
          has(RoleField.selfAddress) && text(RoleField.selfAddress) == null,
      addressUser: text(RoleField.addressUser),
      clearAddressUser:
          has(RoleField.addressUser) && text(RoleField.addressUser) == null,
      personaPrompt: persona,
      enabledPlugins: plugins is List
          ? [for (final id in plugins) id.toString()]
          : null,
      clearEnabledPlugins: has(RoleField.enabledPlugins) && plugins == null,
      recipeId: text(RoleField.recipeId),
      clearRecipeId:
          has(RoleField.recipeId) && text(RoleField.recipeId) == null,
      avatarUrl: text(RoleField.avatarUrl),
      clearAvatarUrl:
          has(RoleField.avatarUrl) && text(RoleField.avatarUrl) == null,
      characterImage: text(RoleField.characterImage),
      clearCharacterImage:
          has(RoleField.characterImage) &&
          text(RoleField.characterImage) == null,
      chatBackgroundImage: background?['image'] as String?,
      clearChatBackgroundImage:
          has(RoleField.chatBackground) && background == null,
      chatBackgroundFraming: background?['framing'] as String?,
      clearChatBackgroundFraming:
          background != null && background['framing'] == null,
      chatBackgroundMaskOpacity: number(RoleField.wallpaperMask),
      clearChatBackgroundMaskOpacity:
          has(RoleField.wallpaperMask) && fields[RoleField.wallpaperMask] == null,
      chatBackgroundBlurSigma: number(RoleField.wallpaperBlur),
      clearChatBackgroundBlurSigma:
          has(RoleField.wallpaperBlur) && fields[RoleField.wallpaperBlur] == null,
      voiceFile: text(RoleField.voiceFile),
      clearVoiceFile:
          has(RoleField.voiceFile) && text(RoleField.voiceFile) == null,
    );
  }
}
