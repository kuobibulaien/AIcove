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
import '../settings/app_settings.dart';
import '../plugins/plugin_providers.dart';
import '../voice_call/providers/voice_call_providers.dart';
import 'application/assistant_cards.dart';
import 'application/assistant_checkup.dart';
import 'application/assistant_settings.dart';
import 'application/assistant_settings_tools.dart';
import 'application/assistant_toolset.dart';
import 'application/assistant_write_tools.dart';
import 'domain/aicove_docs.dart';

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
        load: () => ref.read(appSettingsProvider.future),
        notifier: () => ref.read(appSettingsProvider.notifier),
      ),
    },
  ),
);

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
    if (has(RoleField.personaPrompt) || has(RoleField.customDrawingPrompt)) {
      final parts = PersonaPromptCodec.parse(role.personaPrompt);
      persona = PersonaPromptCodec.compose(
        userPrompt: has(RoleField.personaPrompt)
            ? text(RoleField.personaPrompt) ?? ''
            : parts.userPrompt,
        customDrawingPrompt: has(RoleField.customDrawingPrompt)
            ? text(RoleField.customDrawingPrompt)
            : parts.customDrawingPrompt,
        drawingToolPresetName: parts.drawingToolPresetName,
        drawingArtistPresetName: parts.drawingArtistPresetName,
        drawingPresetId: parts.drawingPresetId,
      );
    }
    final plugins = fields[RoleField.enabledPlugins];
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
    );
  }
}
