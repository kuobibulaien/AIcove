import 'dart:async';
import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart' show debugPrint, protected;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/thinking/thinking_level.dart';
import '../../core/utils/blurred_background_service.dart';
import 'domain/chat_display_policy.dart';
import 'domain/conversation.dart';
import 'id_gen.dart';
import 'data/preset_characters_loader.dart';
import '../assistant/domain/assistant_onboarding.dart' show kAicoveAssistantId;
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/database/database.dart' as db;
import '../../core/database/database_provider.dart';
import '../../core/database/converters/database_converters.dart';
import '../../core/database/repositories/repositories.dart';
import 'services/conversation_short_window_store.dart';
import '../../ui/features/character/services/contact_edit_snapshot_store.dart';
import '../context/providers/context_providers.dart';
import '../memory/providers/memory_providers.dart';
import '../settings/app_settings.dart';
import '../plugins/tts/tts_config.dart';
import '../../core/utils/message_formatter.dart';

class ConversationsNotifier extends AsyncNotifier<List<Conversation>> {
  StreamSubscription<List<db.Conversation>>? _watchSub;

  @override
  Future<List<Conversation>> build() async {
    final convRepo = ref.read(conversationRepositoryProvider);
    var disposed = false;
    ref.onDispose(() {
      disposed = true;
      _watchSub?.cancel();
    });

    final dbConvs = await convRepo.getAll();
    final List<Conversation> list;
    if (dbConvs.isEmpty) {
      final conv = await _createInitialConversation();
      await _saveOne(conv);
      list = <Conversation>[conv];
    } else {
      list = _mapConversations(dbConvs);
    }
    final assistant = await _seedAssistantOnce(list);
    if (assistant != null) list.insert(0, assistant);

    // Loading awaits the database and the assistant seed; a container
    // disposed meanwhile has closed the database.
    if (!disposed) _bindWatch(convRepo);
    return list;
  }

  static const _assistantSeededKey = 'aicove_assistant_seeded_v1';

  /// Adds the built-in assistant role once per device (new installs and
  /// upgrades alike); a user who deletes it is not given it back on restart.
  Future<Conversation?> _seedAssistantOnce(List<Conversation> list) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_assistantSeededKey) == true) return null;
      await prefs.setBool(_assistantSeededKey, true);
      if (list.any((c) => c.id == kAicoveAssistantId)) return null;
      final assistant = await _loadAssistant();
      if (assistant == null) return null;
      await _saveOne(assistant);
      return assistant;
    } catch (error) {
      // A missing assistant must never keep the contact list from loading.
      debugPrint('[ConversationsNotifier] 内置助手写入失败：$error');
      return null;
    }
  }

  Future<Conversation?> _loadAssistant() async {
    final presets = await PresetCharactersLoader.load();
    final preset = presets.where((c) => c.id == kAicoveAssistantId).firstOrNull;
    if (preset == null) return null;
    final now = DateTime.now();
    return preset.copyWith(createdAt: now, updatedAt: now, isPinned: true);
  }

  /// Brings the assistant back from the settings page: restores it from the
  /// trash, or recreates it with the same id when it is gone.
  Future<Conversation?> restoreAssistant() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_assistantSeededKey, true);
    final existing =
        state.value?.where((c) => c.id == kAicoveAssistantId).firstOrNull;
    if (existing != null) return existing;
    final convRepo = ref.read(conversationRepositoryProvider);
    await convRepo.restore(kAicoveAssistantId);
    final restored = await convRepo.getById(kAicoveAssistantId);
    if (restored != null && restored.deletedAt == null) {
      return ConversationConverter.fromDb(restored);
    }
    final assistant = await _loadAssistant();
    if (assistant != null) await _saveOne(assistant);
    return assistant;
  }

  void _bindWatch(ConversationRepository convRepo) {
    _watchSub?.cancel();
    _watchSub = convRepo.watchAll().listen((dbConvs) {
      state = AsyncValue.data(_mapConversations(dbConvs));
    });
  }

  List<Conversation> _mapConversations(List<db.Conversation> dbConvs) {
    return [
      for (final dbConv in dbConvs) ConversationConverter.fromDb(dbConv),
    ];
  }

  /// Build initial conversation when database is empty
  Future<Conversation> _createInitialConversation() async {
    final now = DateTime.now();
    try {
      final presets = await PresetCharactersLoader.load();
      if (presets.isNotEmpty) {
        final nahida = presets.firstWhere(
          (c) => c.id == 'preset_nahida',
          orElse: () => presets.first,
        );
        return nahida.copyWith(createdAt: now, updatedAt: now);
      }
    } catch (_) {
      // fallback to local default when preset loading fails
    }

    return Conversation(
      id: 'preset_nahida',
      title: 'Nahida',
      displayName: 'Nahida',
      description: 'Default preset character',
      characterImage: 'assets/characters/images/nahida.jpg',
      voiceFile: VoicePreset.defaultPresetId,
      createdAt: now,
      updatedAt: now,
    );
  }

  /// (注释已丢失)
  Conversation _createConversation() {
    final now = DateTime.now();
    return Conversation(
      id: genId('conv'),
      title: 'New Chat',
      displayName: 'New Chat',
      createdAt: now,
      updatedAt: now,
    );
  }

  Future<void> _save(List<Conversation> list) async {
    final convRepo = ref.read(conversationRepositoryProvider);

    for (final conv in list) {
      await convRepo.upsert(ConversationConverter.toCompanion(conv));
    }
  }

  Future<void> _saveOne(Conversation conv) async {
    final convRepo = ref.read(conversationRepositoryProvider);
    await convRepo.upsert(ConversationConverter.toCompanion(conv));
  }

  Future<void> setAll(
    List<Conversation> list, {
    bool persist = true,
  }) async {
    state = AsyncValue.data(list);
    if (!persist) {
      return;
    }
    await _save(list);
  }

  Future<void> updateOne(
    String id,
    Conversation Function(Conversation) fn, {
    bool persist = true,
  }) async {
    final current = state.value ?? <Conversation>[];
    Conversation? changed;
    final next = [
      for (final c in current)
        if (c.id == id) changed = fn(c) else c
    ];
    // Only the row that changed: writing the whole list back would put this
    // state's older copies of other roles over newer saves. Both start
    // before any await, as a single setAll did.
    await Future.wait([
      setAll(next, persist: false),
      if (persist && changed != null) saveOne(changed),
    ]);
  }

  /// Adds [conv] (a preset opened for the first time) without writing the
  /// other rows back.
  Future<void> addOne(Conversation conv) async {
    final list = <Conversation>[...(state.value ?? <Conversation>[]), conv];
    await Future.wait([setAll(list, persist: false), saveOne(conv)]);
  }

  /// Writes one row; tests replace it together with [setAll].
  @protected
  Future<void> saveOne(Conversation conv) => _saveOne(conv);

  Future<String> createNew() async {
    final list = <Conversation>[...(state.value ?? <Conversation>[])];
    final c = _createConversation();
    list.insert(0, c);
    await Future.wait([setAll(list, persist: false), saveOne(c)]);
    return c.id;
  }

  // Apply contact edits
  Future<void> applyContactEdit(
    String id, {
    String? displayName,
    String? avatarUrl,
    bool clearAvatarUrl = false,
    String? characterImage,
    bool clearCharacterImage = false,
    String? chatBackgroundImage,
    bool clearChatBackgroundImage = false,
    double? chatBackgroundMaskOpacity,
    bool clearChatBackgroundMaskOpacity = false,
    double? chatBackgroundBlurSigma,
    bool clearChatBackgroundBlurSigma = false,
    String? chatBackgroundFraming,
    bool clearChatBackgroundFraming = false,
    String? selfAddress,
    bool clearSelfAddress = false,
    String? addressUser,
    bool clearAddressUser = false,
    String? voiceFile,
    bool clearVoiceFile = false,
    String? description,
    bool clearDescription = false,
    String? personaPrompt,
    List<String>? enabledPlugins,
    bool clearEnabledPlugins = false,
    String? recipeId,
    bool clearRecipeId = false,
  }) async {
    final currentList = state.value ?? const <Conversation>[];
    Conversation? current;
    for (final conversation in currentList) {
      if (conversation.id == id) {
        current = conversation;
        break;
      }
    }

    final oldSource = current == null
        ? null
        : BlurredBackgroundService.pickPreferredSource(
            characterImage: current.characterImage,
            avatarUrl: current.avatarUrl,
          );
    String? nextFraming(Conversation c) => nextChatBackgroundFraming(
          c,
          image: chatBackgroundImage,
          clearImage: clearChatBackgroundImage,
          framing: chatBackgroundFraming,
          clearFraming: clearChatBackgroundFraming,
        );

    final nextUpdatedAt = DateTime.now();
    final nextConversation = current?.copyWith(
      displayName: displayName ?? current.displayName,
      avatarUrl: clearAvatarUrl ? null : (avatarUrl ?? current.avatarUrl),
      characterImage: clearCharacterImage
          ? null
          : (characterImage ?? current.characterImage),
      chatBackgroundImage: clearChatBackgroundImage
          ? null
          : (chatBackgroundImage ?? current.chatBackgroundImage),
      chatBackgroundMaskOpacity: clearChatBackgroundMaskOpacity
          ? null
          : (chatBackgroundMaskOpacity ?? current.chatBackgroundMaskOpacity),
      chatBackgroundBlurSigma: clearChatBackgroundBlurSigma
          ? null
          : (chatBackgroundBlurSigma ?? current.chatBackgroundBlurSigma),
      chatBackgroundFraming: nextFraming(current),
      selfAddress:
          clearSelfAddress ? null : (selfAddress ?? current.selfAddress),
      addressUser:
          clearAddressUser ? null : (addressUser ?? current.addressUser),
      voiceFile: clearVoiceFile ? null : (voiceFile ?? current.voiceFile),
      description:
          clearDescription ? null : (description ?? current.description),
      personaPrompt: personaPrompt ?? current.personaPrompt,
      enabledPlugins: clearEnabledPlugins
          ? null
          : (enabledPlugins ?? current.enabledPlugins),
      recipeId: clearRecipeId ? null : (recipeId ?? current.recipeId),
      updatedAt: nextUpdatedAt,
    );

    await updateOne(
        id,
        (c) => c.copyWith(
              displayName: displayName ?? c.displayName,
              avatarUrl: clearAvatarUrl ? null : (avatarUrl ?? c.avatarUrl),
              characterImage: clearCharacterImage
                  ? null
                  : (characterImage ?? c.characterImage),
              chatBackgroundImage: clearChatBackgroundImage
                  ? null
                  : (chatBackgroundImage ?? c.chatBackgroundImage),
              chatBackgroundMaskOpacity: clearChatBackgroundMaskOpacity
                  ? null
                  : (chatBackgroundMaskOpacity ?? c.chatBackgroundMaskOpacity),
              chatBackgroundBlurSigma: clearChatBackgroundBlurSigma
                  ? null
                  : (chatBackgroundBlurSigma ?? c.chatBackgroundBlurSigma),
              chatBackgroundFraming: nextFraming(c),
              selfAddress:
                  clearSelfAddress ? null : (selfAddress ?? c.selfAddress),
              addressUser:
                  clearAddressUser ? null : (addressUser ?? c.addressUser),
              voiceFile: clearVoiceFile ? null : (voiceFile ?? c.voiceFile),
              description:
                  clearDescription ? null : (description ?? c.description),
              personaPrompt: personaPrompt ?? c.personaPrompt,
              enabledPlugins: clearEnabledPlugins
                  ? null
                  : (enabledPlugins ?? c.enabledPlugins),
              recipeId: clearRecipeId ? null : (recipeId ?? c.recipeId),
              updatedAt: nextUpdatedAt,
            ));

    final nextCharacterImage = clearCharacterImage
        ? null
        : (characterImage ?? current?.characterImage);
    final nextAvatarUrl =
        clearAvatarUrl ? null : (avatarUrl ?? current?.avatarUrl);
    final newSource = BlurredBackgroundService.pickPreferredSource(
      characterImage: nextCharacterImage,
      avatarUrl: nextAvatarUrl,
    );

    if (oldSource != null && oldSource != newSource) {
      unawaited(BlurredBackgroundService.evict(oldSource));
    }
    if (newSource != null) {
      unawaited(BlurredBackgroundService.ensureBlur(newSource));
    }
    if (nextConversation != null) {
      unawaited(
        ContactEditSnapshotStore.instance.writeFromConversation(nextConversation),
      );
    }
  }

  // 更新对话设置
  Future<void> updateConversationSettings(
    String id, {
    bool? isPinned,
    bool? isHidden,
    bool? isFavorite,
    bool? isMuted,
    bool? notificationSound,
    List<String>? enabledPlugins,
    bool clearEnabledPlugins = false,
  }) async {
    await updateOne(
        id,
        (c) => c.copyWith(
              isPinned: isPinned ?? c.isPinned,
              isHidden: isHidden ?? c.isHidden,
              isFavorite: isFavorite ?? c.isFavorite,
              isMuted: isMuted ?? c.isMuted,
              notificationSound: notificationSound ?? c.notificationSound,
              enabledPlugins: clearEnabledPlugins
                  ? null
                  : (enabledPlugins ?? c.enabledPlugins),
              updatedAt: DateTime.now(),
            ));
  }

  /// 设置会话内某个模型的思考档位；[level] 为 null 表示清除该模型的覆盖。
  Future<void> setConversationThinkingLevel(
    String id, {
    required String modelRef,
    required ThinkingLevel? level,
  }) async {
    await updateOne(
      id,
      (c) {
        final next = Map<String, ThinkingLevel>.from(c.thinkingLevels);
        if (level == null) {
          next.remove(modelRef);
        } else {
          next[modelRef] = level;
        }
        return c.copyWith(thinkingLevels: next, updatedAt: DateTime.now());
      },
    );
  }

  /// 设置会话聊天样式；[style] 为 null 表示跟随全局默认（ADR0047）。
  Future<void> setConversationChatDisplayStyle(
    String id,
    ChatDisplayStyle? style,
  ) async {
    await updateOne(
      id,
      (c) => c.copyWith(chatDisplayStyle: style, updatedAt: DateTime.now()),
    );
  }

  // (注释已丢失)
  Future<void> clearUnread(String id) async {
    final convRepo = ref.read(conversationRepositoryProvider);

    // update database
    await convRepo.clearUnread(id);

    // update in-memory state
    await updateOne(id, (c) => c.copyWith(unreadCount: 0));
  }

  // 清空消息
  Future<void> clearMessages(String id) async {
    final msgRepo = ref.read(messageRepositoryProvider);

    final now = DateTime.now().millisecondsSinceEpoch;
    final purgeAt = now + 30 * 24 * 60 * 60 * 1000; // (注释已丢失)

    // (注释已丢失)
    await msgRepo.softDeleteByConversation(id, now, purgeAt);
    // 摘要与自动整理的记忆都来自这些原文，随之清空；用户锁定的记忆保留。
    await ref.read(contextSummaryStoreProvider).clear(id);
    await ref.read(memoryStoreProvider).clearDerived(id);

    await updateOne(
      id,
      (conversation) => conversation.copyWith(
        contextStartMessageId: null,
        lastMessage: null,
        lastMessageTime: null,
        unreadCount: 0,
        updatedAt: DateTime.now(),
      ),
    );
    await ref.read(conversationTimelineCacheProvider).clearConversation(id);
  }

  // delete conversation (soft delete to trash)
  Future<void> deleteConversation(String id) async {
    final convRepo = ref.read(conversationRepositoryProvider);
    final msgRepo = ref.read(messageRepositoryProvider);

    final now = DateTime.now().millisecondsSinceEpoch;
    final purgeAt = now + 30 * 24 * 60 * 60 * 1000; // (注释已丢失)

    // (注释已丢失)
    await convRepo.softDelete(id, now, purgeAt);
    await msgRepo.softDeleteByConversation(id, now, purgeAt);

    // update in-memory state
    final current = state.value ?? <Conversation>[];
    state = AsyncValue.data(current.where((c) => c.id != id).toList());
    await ref.read(conversationTimelineCacheProvider).deleteConversation(id);
    await ContactEditSnapshotStore.instance.delete(id);
  }
}

final conversationsProvider =
    AsyncNotifierProvider<ConversationsNotifier, List<Conversation>>(
  ConversationsNotifier.new,
);

final activeConversationIdProvider = StateProvider<String?>((ref) => null);

final conversationSnapshotByIdProvider = Provider.family<Conversation?, String>(
  (ref, conversationId) {
    return ref.watch(
      conversationsProvider.select(
        (listAsync) => listAsync.maybeWhen(
          data: (list) {
            for (final conversation in list) {
              if (conversation.id == conversationId) {
                return conversation;
              }
            }
            return null;
          },
          orElse: () => null,
        ),
      ),
    );
  },
);

/// 会话实际生效的显示策略（ADR0047）：全局默认样式叠加会话覆盖。
/// 按会话的覆盖值取（null 跟随全局），只监听全局设置；会话对象由调用方传入，
/// 避免为读一个字段去监听整个会话列表。
final chatDisplayPolicyProvider =
    Provider.family<ChatDisplayPolicy, ChatDisplayStyle?>(
        (ref, conversationStyle) {
  final global = ref.watch(
    appSettingsProvider.select(
      (settings) => (
        settings.valueOrNull?.messageFormatConfig ??
            const MessageFormatConfig(),
        settings.valueOrNull?.chatDisplayStyle ?? ChatDisplayStyle.bubble,
      ),
    ),
  );
  return ChatDisplayPolicy.resolve(
    formatConfig: global.$1,
    globalStyle: global.$2,
    conversationStyle: conversationStyle,
  );
});

final conversationByIdProvider =
    StreamProvider.autoDispose.family<Conversation?, String>(
  (ref, conversationId) {
    final db = ref.watch(databaseProvider);
    final query = db.select(db.conversations)
      ..where(
        (t) => t.id.equals(conversationId) & t.deletedAt.isNull(),
      );
    return query.watchSingleOrNull().map((row) {
      if (row == null) return null;
      return ConversationConverter.fromDb(row);
    });
  },
);

Conversation? _resolveConversationById(Ref ref, String conversationId) {
  final snapshotConversation =
      ref.watch(conversationSnapshotByIdProvider(conversationId));
  if (snapshotConversation != null) {
    return snapshotConversation;
  }

  final conversationAsync = ref.watch(conversationByIdProvider(conversationId));
  if (conversationAsync.isLoading) {
    return null;
  }
  return conversationAsync.valueOrNull;
}

final resolvedConversationByIdProvider = Provider.family<Conversation?, String>(
  (ref, conversationId) {
    final normalizedId = conversationId.trim();
    if (normalizedId.isEmpty) {
      return null;
    }
    return _resolveConversationById(ref, normalizedId);
  },
);

final activeConversationProvider = Provider<Conversation?>((ref) {
  final rawId = ref.watch(activeConversationIdProvider);
  final activeId = rawId?.trim();
  if (activeId != null && activeId.isNotEmpty) {
    return ref.watch(resolvedConversationByIdProvider(activeId));
  }

  final fallbackId = ref.watch(
    conversationsProvider.select(
      (listAsync) => listAsync.maybeWhen(
        data: (list) => list.isEmpty ? null : list.first.id,
        orElse: () => null,
      ),
    ),
  );
  if (fallbackId == null) {
    return null;
  }
  return ref.watch(resolvedConversationByIdProvider(fallbackId));
});

/// 编辑后的壁纸截取。截取只对当前图片有意义：清除图片，或换了图片又没给新截取
/// 时一并复位。
String? nextChatBackgroundFraming(
  Conversation current, {
  String? image,
  bool clearImage = false,
  String? framing,
  bool clearFraming = false,
}) {
  if (clearFraming || clearImage) return null;
  if (framing != null) return framing;
  final imageChanged = image != null && image != current.chatBackgroundImage;
  return imageChanged ? null : current.chatBackgroundFraming;
}
