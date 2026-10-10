import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/converters/database_converters.dart';
import '../../../core/database/database_provider.dart';
import '../../agent_context/domain/silly_tavern_preset.dart';
import '../../agent_context/providers/preset_recipe_provider.dart';
import '../../chat/application/chat_page_conversation_actions.dart';
import '../../settings/app_settings.dart';
import '../data/sqlite_conversation_state_store.dart';
import '../domain/conversation_state_port.dart';
import '../domain/mvu_content.dart';
import '../domain/mvu_engine.dart';

final conversationStatePortProvider = Provider<ConversationStatePort>(
  (ref) => SqliteConversationStateStore(
    ref.read(databaseProvider),
    resolveSources: (id) => resolveMvuSources(ref, id),
    greetingMessageId: ChatPageConversationActions.greetingMessageId,
  ),
);

/// MVU 是酒馆兼容的一部分：会话用上了酒馆预设且该预设没关 MVU 时才可能生效（ADR0071）。
bool mvuAllowedFor(SillyTavernPreset? preset) =>
    preset != null && preset.mvuEnabled;

/// 按请求 owner 的预设与名字组装初始化来源；一次请求内固定。
MvuSourceSnapshot buildMvuSourceSnapshot({
  required SillyTavernPreset preset,
  required String characterName,
  required String userName,
}) {
  final macro = RegExp(r'\{\{\s*(char|user)\s*\}\}', caseSensitive: false);
  return MvuSourceSnapshot(
    sources: [
      for (final entry in mvuInitVarEntries(preset.worldBooks))
        MvuInitSource(name: entry.name, content: entry.content),
    ],
    expandMacros: (text) => text.replaceAllMapped(
      macro,
      (m) => m[1]!.toLowerCase() == 'char' ? characterName : userName,
    ),
  );
}

/// 发送链路之外（落库后刷新、状态面板）解析来源；MVU 未启用时返回 null。
Future<MvuSourceSnapshot?> resolveMvuSources(
  Ref ref,
  String conversationId,
) async {
  final row = await ref
      .read(conversationRepositoryProvider)
      .getById(conversationId);
  if (row == null || row.deletedAt != null) return null;
  final conversation = ConversationConverter.fromDb(row);
  final preset = await ref
      .read(tavernCompatibilityPortProvider)
      .resolvePreset(conversation.recipeId?.trim());
  if (!mvuAllowedFor(preset)) return null;
  final settings = await ref.read(appSettingsProvider.future);
  final userName = settings.userName?.trim() ?? '';
  return buildMvuSourceSnapshot(
    preset: preset!,
    characterName: conversation.displayName.trim().isEmpty
        ? conversation.title
        : conversation.displayName,
    userName: preset.userNameMacroEnabled && userName.isNotEmpty
        ? userName
        : kNeutralUserName,
  );
}
