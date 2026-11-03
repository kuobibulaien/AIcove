import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../agent_context/domain/silly_tavern_character_card.dart';
import '../../agent_context/providers/preset_recipe_provider.dart';
import '../conversation_providers.dart';
import '../domain/chat_display_policy.dart';
import '../domain/conversation.dart';
import '../domain/persona_prompt_codec.dart';
import '../domain/role_agent_mode.dart';
import 'chat_page_conversation_actions.dart';

/// A role stored by [ContactEditRoleActions.createRole].
class ContactRoleCreation {
  const ContactRoleCreation({required this.id, required this.problems});

  final String id;

  /// Steps after the role was stored that failed; they do not undo the role.
  final List<String> problems;
}

/// Role edit page business steps that do not need widgets.
class ContactEditRoleActions {
  const ContactEditRoleActions(this._ref);

  final Ref _ref;

  /// A new role's chat style follows its agent mode: documents for tool
  /// roles, bubbles for chat roles.
  static ChatDisplayStyle initialDisplayStyle(RoleAgentMode? agentMode) =>
      agentMode == RoleAgentMode.tool
      ? ChatDisplayStyle.document
      : ChatDisplayStyle.bubble;

  /// Creates a plain role without card resources, e.g. a saved copy.
  Future<String> createConversation(RoleAgentMode? agentMode) {
    return _ref
        .read(conversationsProvider.notifier)
        .createNew(chatDisplayStyle: initialDisplayStyle(agentMode));
  }

  /// Creates a role and makes it the active conversation.
  ///
  /// Reuses [existingId] when a previous attempt already created the role;
  /// [onCreated] receives a newly created id before [applyEdit] runs, so a
  /// retry after a failed edit does not create a second role. Errors from
  /// creating or editing the role are rethrown. Once stored, the card preset
  /// and [greeting] are best effort: their failures land in
  /// [ContactRoleCreation.problems]. When [isActive] turns false (the page
  /// left), the greeting and activation steps are skipped.
  Future<ContactRoleCreation> createRole({
    required String? existingId,
    required void Function(String id) onCreated,
    required Future<void> Function(String id) applyEdit,
    required String displayName,
    required String? recipeId,
    required RoleAgentMode? agentMode,
    required bool Function() isActive,
    SillyTavernCharacterCard? card,
    String? greeting,
  }) async {
    final controller = _ref.read(presetRecipeImportControllerProvider.notifier);
    final notifier = _ref.read(conversationsProvider.notifier);

    var id = existingId;
    if (id == null) {
      id = await createConversation(agentMode);
      onCreated(id);
    }
    await applyEdit(id);

    final problems = <String>[];
    var boundRecipeId = recipeId;
    if (card != null && card.hasPresetResources) {
      try {
        final created = await controller.createCardPreset(
          explicitBaseId: recipeId,
          name: '$displayName 专用',
          regexScripts: card.regexScripts,
          characterBook: card.characterBook,
          // 导入卡即视为要用卡内正则：直接允许运行，之后在预设里逐条管理。
          regexAuthorized: card.regexScripts.isNotEmpty ? true : null,
        );
        try {
          await notifier.applyContactEdit(id, recipeId: created.preset.id);
          boundRecipeId = created.preset.id;
          problems.addAll(created.warnings);
          if (created.skippedRegexCount > 0) {
            problems.add('${created.skippedRegexCount} 条卡内正则与原预设重复或无效，已跳过');
          }
        } catch (e) {
          await controller.deletePreset(created.preset.id).catchError((_) {});
          problems.add('专用预设绑定失败：$e');
        }
      } catch (e) {
        problems.add('专用预设未建立：$e');
      }
    }
    if (card != null && card.hasHelperScripts) {
      problems.add('卡内酒馆助手脚本（变量系统、状态栏）无法运行');
    }
    if (!isActive()) return ContactRoleCreation(id: id, problems: problems);
    if (greeting != null) {
      try {
        await _ref
            .read(chatPageConversationActionsProvider)
            .appendCharacterGreeting(
              id,
              greeting: greeting,
              charName: displayName,
              recipeId: boundRecipeId,
            );
      } catch (e) {
        problems.add('开场白未写入：$e');
      }
    }

    if (!isActive()) return ContactRoleCreation(id: id, problems: problems);
    _ref.read(activeConversationIdProvider.notifier).state = id;
    return ContactRoleCreation(id: id, problems: problems);
  }

  /// Reads the stored persona without moving its drawing requirement.
  /// Returns null when the role is gone.
  Future<PersonaPromptParts?> moveDrawingPromptIntoPreset(
    Conversation role,
  ) async {
    final roles = await _ref.read(conversationsProvider.future);
    final saved = roles.where((r) => r.id == role.id).firstOrNull;
    if (saved == null) return null;
    final parts = PersonaPromptCodec.parse(saved.personaPrompt);
    return parts;
  }
}

final contactEditRoleActionsProvider = Provider<ContactEditRoleActions>(
  ContactEditRoleActions.new,
);

/// Guesses an image MIME type from its leading bytes; PNG when unknown.
String sniffContactImageMime(Uint8List bytes) {
  if (SillyTavernCharacterCard.isPng(bytes)) return 'image/png';
  if (bytes.length > 2 && bytes[0] == 0xFF && bytes[1] == 0xD8) {
    return 'image/jpeg';
  }
  if (bytes.length > 12 &&
      String.fromCharCodes(bytes.sublist(8, 12)) == 'WEBP') {
    return 'image/webp';
  }
  if (bytes.length > 3 && String.fromCharCodes(bytes.sublist(0, 3)) == 'GIF') {
    return 'image/gif';
  }
  return 'image/png';
}
