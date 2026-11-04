import 'package:aicove_agent_kernel/aicove_agent_kernel.dart' show JournalEntry;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../agent_context/providers/preset_recipe_provider.dart';
import '../agent_plugins/file_change_journal.dart';
import '../../core/database/converters/database_converters.dart';
import '../../core/database/database_provider.dart';
import '../chat/chat_layer_providers.dart';
import '../chat/chat_providers.dart' show conversationSendingProvider;
import '../chat/conversation_providers.dart';
import '../chat/domain/conversation.dart';
import '../chat/domain/message.dart';
import '../memory/domain/memory_item.dart';
import '../chat/domain/persona_prompt_codec.dart';
import '../chat/domain/role_agent_mode.dart';
import '../chat/services/chat_history_store.dart';
import '../context/domain/context_summary.dart';
import '../context/providers/context_providers.dart';
import '../plugins/mcp/mcp_connector_providers.dart';
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
import 'domain/assistant_onboarding.dart' show kAicoveAssistantId;

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
    extensionPlugins: () => _extensionPlugins(ref),
  ),
);

Map<String, String> _extensionPluginNames(Ref ref) => {
  for (final package in ref.read(aicovePackagesProvider))
    package.pluginId: package.name,
  for (final connector in ref.read(mcpConnectorsConfigProvider).connectors)
    'mcp:${connector.id}': connector.displayName,
};

Future<List<Map<String, Object?>>> _extensionPlugins(Ref ref) async {
  await Future.wait([
    ref.read(aicovePackagesProvider.notifier).ready,
    ref.read(mcpConnectorsConfigProvider.notifier).ready,
  ]);
  // Deliberately project an allowlist: never expose credentials, URLs,
  // request headers, local paths or package contents through discovery.
  return [
    for (final package in ref.read(aicovePackagesProvider))
      {
        'plugin_id': package.pluginId,
        'name': package.name,
        'type': 'package',
        'version': package.version,
        'activation': 'roleExplicit',
      },
    for (final connector in ref.read(mcpConnectorsConfigProvider).connectors)
      {
        'plugin_id': 'mcp:${connector.id}',
        'name': connector.displayName,
        'type': 'mcp',
        'enabled': connector.enabled,
        'usable': connector.isUsable,
        'activation': 'roleExplicit',
      },
  ];
}

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
      assistantPrivateDataChangeKind: ref.read(
        assistantPrivateDataChangesProvider,
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
      for (final role in await ref.read(conversationsProvider.future))
        if (!role.isHidden &&
            PersonaPromptCodec.parse(role.personaPrompt).drawingPromptPackId ==
                packId)
          (id: 'role:${role.id}', name: role.displayName),
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
    extensionPlugins: () async => {
      for (final plugin in await _extensionPlugins(ref))
        plugin['plugin_id']! as String: plugin['name']! as String,
    },
    extensionPluginNames: () => _extensionPluginNames(ref),
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
      // Every tool-mode role may use all local workspaces (ADR0111).
      workspaceIds: () async => {
        for (final w in await (await ref.read(
          workspaceStoreProvider.future,
        )).list())
          w.id,
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
        for (final preset in (await ref.read(
          drawingPresetCatalogProvider.future,
        )).presets)
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
      changes: ref.read(assistantPrivateDataChangesProvider),
      writePrivate: (tool, args) => _writePrivateData(ref, tool, args),
      journal: ref.read(assistantChangeJournalProvider),
      onChanged: () => ref.invalidate(assistantRecentChangesProvider),
      rawMessages: (roleId) =>
          ref.read(chatHistoryStoreProvider).loadAllRawMessages(roleId),
      readBoundary: (roleId) async =>
          (await ref.read(conversationRepositoryProvider).getById(roleId))
              ?.contextStartMessageId,
      memoryItems: (roleId) => ref.read(memoryStoreProvider).list(roleId),
      summaryHistory: (roleId) =>
          (ref.read(contextSummaryStoreProvider)
                  as ContextSummaryManagementStorePort)
              .listHistory(roleId),
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

final assistantPrivateDataChangesProvider =
    Provider<AssistantPrivateDataChanges>(_PrivateDataChanges.new);

/// Live adapters keep final ownership and idle checks with the database write;
/// these operations deliberately do not create an undo journal entry.
final assistantPrivateWriteProvider =
    Provider<
      Future<Map<String, Object?>> Function(String, Map<String, dynamic>)
    >(
      (ref) =>
          (tool, args) => _writePrivateData(ref, tool, args),
    );

Future<Map<String, Object?>> _writePrivateData(
  Ref ref,
  String tool,
  Map<String, dynamic> args,
) async {
  final owner = args['role_id'];
  if (owner is! String || owner.trim().isEmpty) throw ArgumentError('请指定角色');
  Future<void> accessible() async {
    final role = await ref.read(conversationRepositoryProvider).getById(owner);
    if (role == null || role.deletedAt != null || role.isHidden) {
      throw StateError('角色不存在、已删除或位于隐私空间');
    }
  }

  Future<void> writable() async {
    await accessible();
    if (ref.read(conversationSendingProvider(owner))) {
      throw StateError('请等这个角色的当前回复结束后再修改');
    }
  }

  String text(String key, {bool allowEmpty = false}) {
    final value = args[key];
    if (value is! String || (!allowEmpty && value.trim().isEmpty)) {
      throw ArgumentError('$key 必须是${allowEmpty ? '' : '非空'}文本');
    }
    return value;
  }

  Map<String, Object?> memoryJson(MemoryItem item) => {
    'id': item.id,
    'owner_id': item.ownerId,
    'layer': item.layer.name,
    'title': item.title,
    'content': item.content,
    'locked': item.locked,
    'created_at': item.createdAt.toIso8601String(),
    'updated_at': item.updatedAt.toIso8601String(),
  };
  // Updating raw text owns its transaction and refreshes its cache afterwards.
  if (tool == AssistantPrivateReadTools.updateChat) {
    final content = args.containsKey('content') ? text('content') : null;
    var oldText = args.containsKey('old_text') ? text('old_text') : null;
    var newText = args.containsKey('new_text')
        ? text('new_text', allowEmpty: true)
        : null;
    if (args.containsKey('content_replace')) {
      if (args.containsKey('content') ||
          args.containsKey('old_text') ||
          args.containsKey('new_text')) {
        throw ArgumentError('content_replace 不能与 content 或旧版替换参数同时使用');
      }
      final replacement = args['content_replace'];
      if (replacement is! Map ||
          replacement['old_text'] is! String ||
          (replacement['old_text'] as String).trim().isEmpty ||
          replacement['new_text'] is! String ||
          replacement.keys.any(
            (key) => key != 'old_text' && key != 'new_text',
          )) {
        throw ArgumentError('content_replace 必须包含非空 old_text 和文本 new_text');
      }
      oldText = replacement['old_text'] as String;
      newText = replacement['new_text'] as String;
    }
    final updated = await ref
        .read(chatHistoryStoreProvider)
        .updateRawMessageText(
          conversationId: owner,
          messageId: text('message_id'),
          content: content,
          oldText: oldText,
          newText: newText,
          ensureWritable: writable,
        );
    return {
      'ok': true,
      'message_id': updated.id,
      'content': updated.content,
      'undoable': false,
    };
  }
  if (tool == AssistantPrivateReadTools.editSummary) {
    await accessible();
    if (args['mode'] != 'compact_current_topic') {
      throw ArgumentError('不支持的摘要操作');
    }
    final summary = text('summary');
    validateContextSummary(summary);
    final snapshot = await ref
        .read(contextSummaryStoreProvider)
        .manualSnapshot(owner);
    if (args['expected_revision'] != null &&
        args['expected_revision'] != snapshot.revision) {
      throw StateError('聊天已变化，请重新读取后再整理');
    }
    await accessible();
    final saved = await ref
        .read(manualCompactionProvider)
        .commit(
          ManualCompactionDraft(snapshot: snapshot, summary: summary),
          summary,
        );
    return {
      'ok': true,
      'summary_id': saved.id,
      'boundary_id': saved.boundaryId,
      'summary': saved.summary,
      'undoable': false,
    };
  }
  if (tool == AssistantPrivateReadTools.deleteSummary &&
      args['kind'] == 'manual') {
    await accessible();
    await ref.read(manualCompactionProvider).undo(owner);
    return {'ok': true, 'undoable': false};
  }
  return ref.read(databaseProvider).transaction(() async {
    await accessible();
    switch (tool) {
      case AssistantPrivateReadTools.appendChat:
        final role = args.containsKey('sender_role')
            ? args['sender_role']
            : 'assistant';
        if (role != 'user' && role != 'assistant') {
          throw ArgumentError('sender_role 只能是 user 或 assistant');
        }
        final message = Message(
          id: const Uuid().v4(),
          role: role! as String,
          content: text('content').trim(),
          status: 'sent',
          createdAt: DateTime.now(),
        );
        await writable();
        await ref
            .read(chatHistoryStoreProvider)
            .appendMessage(conversationId: owner, message: message);
        return {'ok': true, 'message_id': message.id, 'undoable': false};
      case AssistantPrivateReadTools.deleteChat:
        final input = args['message_ids'];
        if (input is! List ||
            input.isEmpty ||
            input.any((id) => id is! String || id.trim().isEmpty)) {
          throw ArgumentError('message_ids 必须是非空消息 id 列表');
        }
        final ids = input.cast<String>().toSet().toList();
        for (final id in ids) {
          final row = await ref.read(messageRepositoryProvider).getById(id);
          if (row == null ||
              row.conversationId != owner ||
              row.deletedAt != null ||
              row.replacedBy != null ||
              row.status == 'sending') {
            throw StateError('有消息不存在、不属于这个角色、已被替换或正在生成，整批未删除');
          }
        }
        await writable();
        await ref
            .read(chatHistoryStoreProvider)
            .softDeleteMessages(owner, ids, clearContextStartIfDeleted: true);
        return {'ok': true, 'deleted': ids.length, 'undoable': false};
      case AssistantPrivateReadTools.deleteSummary:
        if (args['kind'] == 'auto') {
          final boundary =
              (await ref.read(conversationRepositoryProvider).getById(owner))!
                  .contextStartMessageId;
          await writable();
          await (ref.read(contextSummaryStoreProvider)
                  as ContextSummaryManagementStorePort)
              .deleteCurrentAuto(ownerId: owner, expectedBoundaryId: boundary);
        } else {
          throw ArgumentError('kind 只能是 manual 或 auto');
        }
        return {'ok': true, 'undoable': false};
      case AssistantPrivateReadTools.writeMemory:
        final layer = args['layer'];
        if (layer != 'core' && layer != 'archive') {
          throw ArgumentError('layer 只能是 core 或 archive');
        }
        if (args.containsKey('locked') && args['locked'] is! bool) {
          throw ArgumentError('locked 必须是布尔值');
        }
        final id = args.containsKey('memory_id') ? text('memory_id') : null;
        final memory = ref.read(memoryStoreProvider);
        if (id != null && await memory.get(owner, id) == null) {
          throw StateError('记忆不存在或不属于这个角色');
        }
        final title = text('title');
        final content = text('content');
        await accessible();
        final saved = await memory.saveByUser(
          ownerId: owner,
          id: id,
          layer: MemoryLayer.values.byName(layer! as String),
          title: title,
          content: content,
        );
        if (args.containsKey('locked')) {
          await memory.setLocked(owner, saved.id, args['locked']! as bool);
        }
        final current = (await memory.get(owner, saved.id))!;
        return {'ok': true, 'memory': memoryJson(current), 'undoable': false};
      case AssistantPrivateReadTools.deleteMemory:
        final id = text('memory_id');
        final memory = ref.read(memoryStoreProvider);
        if (await memory.get(owner, id) == null) {
          throw StateError('记忆不存在或不属于这个角色');
        }
        await accessible();
        await memory.deleteByUser(owner, id);
        return {'ok': true, 'undoable': false};
      default:
        throw ArgumentError('不支持的私有内容修改');
    }
  });
}

class _PrivateDataChanges extends AssistantPrivateDataChanges {
  _PrivateDataChanges(this.ref);
  final Ref ref;

  Future<void> _visible(String ownerId) async {
    final row = await ref.read(conversationRepositoryProvider).getById(ownerId);
    if (row == null ||
        row.deletedAt != null ||
        ConversationConverter.fromDb(row).isHidden) {
      throw StateError('角色不存在、已删除或位于隐私空间，未修改内容');
    }
  }

  Future<ContextSummary?> _summary(
    String ownerId,
    ContextSummaryKind kind,
  ) async {
    final entries =
        await (ref.read(contextSummaryStoreProvider)
                as ContextSummaryManagementStorePort)
            .listHistory(ownerId);
    return entries
        .where(
          (entry) =>
              entry.isCurrent && entry.isValid && entry.record.kind == kind,
        )
        .firstOrNull
        ?.record;
  }

  @override
  Future<Map<String, Object?>?> summary(
    String ownerId,
    ContextSummaryKind kind,
  ) async {
    await _visible(ownerId);
    final record = await _summary(ownerId, kind);
    if (record == null) return null;
    final boundary =
        (await ref.read(conversationRepositoryProvider).getById(ownerId))!
            .contextStartMessageId;
    return {
      'area': 'summary',
      'owner_id': ownerId,
      'id': record.id,
      'kind': kind.name,
      'owner_boundary': boundary,
      'boundary_id': record.boundaryId,
      'topic_boundary': record.topicBoundary,
      'summary': record.summary,
      'source_ids': record.sourceIds,
      'source_digest': record.sourceDigest,
      'created_at': record.createdAt.millisecondsSinceEpoch,
    };
  }

  @override
  Future<Map<String, Object?>?> memory(String ownerId, String id) async {
    await _visible(ownerId);
    final item = await ref.read(memoryStoreProvider).get(ownerId, id);
    if (item == null) return null;
    return {
      'area': 'memory',
      'owner_id': ownerId,
      'id': item.id,
      'layer': item.layer.name,
      'title': item.title,
      'content': item.content,
      'source_ids': item.sourceIds,
      'locked': item.locked,
      'created_at': item.createdAt.millisecondsSinceEpoch,
      'updated_at': item.updatedAt.millisecondsSinceEpoch,
    };
  }

  Future<Map<String, Object?>?> _current(Map<String, Object?> state) {
    final owner = state['owner_id']! as String;
    return switch (state['area']) {
      'summary' => summary(
        owner,
        ContextSummaryKind.values.byName(state['kind']! as String),
      ),
      'memory' => memory(owner, state['id']! as String),
      _ => throw StateError('不支持的私有内容修改'),
    };
  }

  @override
  Future<bool> isCurrent(Map<String, Object?> state) async {
    final current = await _current(state);
    return current != null && sameAssistantPrivateState(current, state);
  }

  @override
  Future<bool> applyIfCurrent(
    Map<String, Object?> expected,
    Map<String, Object?> state,
  ) => ref.read(databaseProvider).transaction(() async {
    final owner = expected['owner_id']! as String;
    void ensureIdle() {
      if (ref.read(conversationSendingProvider(owner))) {
        throw StateError('请等这个角色的当前回复结束后再修改摘要');
      }
    }

    ensureIdle();
    final current = await _current(expected);
    if (current == null || !sameAssistantPrivateState(current, expected)) {
      return false;
    }
    final field = expected['area'] == 'summary' ? 'summary' : 'locked';
    // A journal entry may change only the field owned by this operation.
    final restricted = {
      ...state,
      field: expected[field],
      if (field == 'summary') 'created_at': expected['created_at'],
    };
    if (!sameAssistantPrivateState(expected, restricted)) {
      throw StateError('修改包含不允许替换的身份或来源信息');
    }
    ensureIdle();
    if (field == 'locked') {
      await ref
          .read(memoryStoreProvider)
          .setLocked(
            owner,
            expected['id']! as String,
            state['locked']! as bool,
          );
    } else {
      final kind = ContextSummaryKind.values.byName(
        expected['kind']! as String,
      );
      final record = await _summary(owner, kind);
      if (record == null) return false;
      await (ref.read(contextSummaryStoreProvider)
              as ContextSummaryManagementStorePort)
          .updateCurrent(
            ownerId: owner,
            kind: kind,
            expectedBoundaryId: expected['owner_boundary'] as String?,
            expectedSummary: record,
            summary: state['summary']! as String,
            createdAt: DateTime.fromMillisecondsSinceEpoch(
              state['created_at']! as int,
            ),
          );
    }
    return true;
  });
}

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
  Future<String> create({RoleAgentMode mode = RoleAgentMode.chat}) => _serial(
    () => _notifier.createNew(
      chatDisplayStyle: mode == RoleAgentMode.tool
          ? ChatDisplayStyle.document
          : ChatDisplayStyle.bubble,
    ),
  );

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
    // A database watch can briefly publish an older list just after create.
    // Restore only this stored row before applying the requested edit.
    if (!snapshot().any((item) => item.id == roleId)) {
      await _notifier.setAll([...snapshot(), role], persist: false);
    }
    bool has(String key) => fields.containsKey(key);
    String? text(String key) => fields[key] as String?;
    final modeName = text(RoleField.agentMode);
    final mode = RoleAgentMode.fromValue(modeName);
    if (role.id == kAicoveAssistantId &&
        mode != null &&
        mode != RoleAgentMode.tool) {
      throw StateError('AIcove酱恒为 tool 模式，不能改为 ${mode.name}');
    }
    String? persona;
    if (has(RoleField.personaPrompt) ||
        has(RoleField.extraPrompt) ||
        has(RoleField.drawingPromptPackId) ||
        has(RoleField.customDrawingPrompt) ||
        has(RoleField.drawingPreset)) {
      final parts = PersonaPromptCodec.parse(role.personaPrompt);
      // A new binding replaces the legacy by-name ones as a whole.
      final drawing = fields[RoleField.drawingPreset] as Map?;
      final rebind = has(RoleField.drawingPreset);
      final isAssistant = role.id == kAicoveAssistantId;
      final extraPrompt = has(RoleField.extraPrompt)
          ? text(RoleField.extraPrompt) ?? ''
          : has(RoleField.personaPrompt) && isAssistant
          ? text(RoleField.personaPrompt) ?? ''
          : parts.extraPrompt;
      persona = PersonaPromptCodec.compose(
        userPrompt: has(RoleField.personaPrompt) && !isAssistant
            ? text(RoleField.personaPrompt) ?? ''
            : parts.userPrompt,
        extraPrompt: extraPrompt,
        customDrawingPrompt: has(RoleField.customDrawingPrompt)
            ? text(RoleField.customDrawingPrompt)
            : parts.customDrawingPrompt,
        drawingPromptPackId: has(RoleField.drawingPromptPackId)
            ? text(RoleField.drawingPromptPackId)
            : parts.drawingPromptPackId,
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
      if (isAssistant || has(RoleField.extraPrompt)) {
        final nextParts = PersonaPromptCodec.parse(persona);
        // Internal markers in tool input must not escape the editable block.
        if ((isAssistant && nextParts.userPrompt != parts.userPrompt) ||
            nextParts.extraPrompt != extraPrompt.trim()) {
          throw StateError('附加提示词包含冲突的内部标记，未保存；请移除标记后重试');
        }
      }
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
    if (has(RoleField.imagePreviewScale) ||
        has(RoleField.expandAudioText) ||
        has(RoleField.hideUserAvatar) ||
        has(RoleField.chunkEnabled)) {
      await _notifier.setConversationChatView(
        roleId,
        imagePreviewScale: number(RoleField.imagePreviewScale),
        clearImagePreviewScale:
            has(RoleField.imagePreviewScale) &&
            fields[RoleField.imagePreviewScale] == null,
        expandAudioText: fields[RoleField.expandAudioText] as bool?,
        clearExpandAudioText:
            has(RoleField.expandAudioText) &&
            fields[RoleField.expandAudioText] == null,
        hideUserAvatar: fields[RoleField.hideUserAvatar] as bool?,
        clearHideUserAvatar:
            has(RoleField.hideUserAvatar) &&
            fields[RoleField.hideUserAvatar] == null,
        chunkEnabled: fields[RoleField.chunkEnabled] as bool?,
        clearChunkEnabled:
            has(RoleField.chunkEnabled) &&
            fields[RoleField.chunkEnabled] == null,
      );
    }
    if (has(RoleField.pinned) || has(RoleField.muted)) {
      await _notifier.updateConversationSettings(
        roleId,
        isPinned: fields[RoleField.pinned] as bool?,
        isMuted: fields[RoleField.muted] as bool?,
      );
    }
    await _notifier.applyContactEdit(
      roleId,
      agentMode: mode,
      clearAgentMode: has(RoleField.agentMode) && mode == null,
      sessionProvider: text(RoleField.modelOverride),
      clearSessionProvider:
          has(RoleField.modelOverride) && text(RoleField.modelOverride) == null,
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
          has(RoleField.wallpaperMask) &&
          fields[RoleField.wallpaperMask] == null,
      chatBackgroundBlurSigma: number(RoleField.wallpaperBlur),
      clearChatBackgroundBlurSigma:
          has(RoleField.wallpaperBlur) &&
          fields[RoleField.wallpaperBlur] == null,
      voiceFile: text(RoleField.voiceFile),
      clearVoiceFile:
          has(RoleField.voiceFile) && text(RoleField.voiceFile) == null,
    );
  }
}
