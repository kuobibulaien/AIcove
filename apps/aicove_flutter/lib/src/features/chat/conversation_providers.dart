import 'dart:async';
import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/utils/blurred_background_service.dart';
import 'domain/conversation.dart';
import 'id_gen.dart';
import 'data/preset_characters_loader.dart';
import '../../core/database/database.dart' as db;
import '../../core/database/database_provider.dart';
import '../../core/database/converters/database_converters.dart';
import '../../core/database/repositories/repositories.dart';

class ConversationsNotifier extends AsyncNotifier<List<Conversation>> {
  StreamSubscription<List<db.Conversation>>? _watchSub;

  @override
  Future<List<Conversation>> build() async {
    final convRepo = ref.read(conversationRepositoryProvider);
    ref.onDispose(() => _watchSub?.cancel());

    final dbConvs = await convRepo.getAll();
    if (dbConvs.isEmpty) {
      final conv = await _createInitialConversation();
      await _saveOne(conv);
      _bindWatch(convRepo);
      return <Conversation>[conv];
    }

    _bindWatch(convRepo);
    return _mapConversations(dbConvs);
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
    final next = [
      for (final c in current)
        if (c.id == id) fn(c) else c
    ];
    await setAll(next, persist: persist);
  }

  Future<String> createNew() async {
    final list = <Conversation>[...(state.value ?? <Conversation>[])];
    final c = _createConversation();
    list.insert(0, c);
    await setAll(list);
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
              updatedAt: DateTime.now(),
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
  }

  // 更新对话设置
  Future<void> updateConversationSettings(
    String id, {
    bool? isPinned,
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
              isFavorite: isFavorite ?? c.isFavorite,
              isMuted: isMuted ?? c.isMuted,
              notificationSound: notificationSound ?? c.notificationSound,
              enabledPlugins: clearEnabledPlugins
                  ? null
                  : (enabledPlugins ?? c.enabledPlugins),
              updatedAt: DateTime.now(),
            ));
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
    final convRepo = ref.read(conversationRepositoryProvider);

    final now = DateTime.now().millisecondsSinceEpoch;
    final purgeAt = now + 30 * 24 * 60 * 60 * 1000; // (注释已丢失)

    // (注释已丢失)
    await msgRepo.softDeleteByConversation(id, now, purgeAt);
    await convRepo.clearSummary(id, now);
    await clearUnread(id);
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

final activeConversationProvider = Provider<Conversation?>((ref) {
  final rawId = ref.watch(activeConversationIdProvider);
  final activeId = rawId?.trim();
  if (activeId != null && activeId.isNotEmpty) {
    final snapshotConversation =
        ref.watch(conversationSnapshotByIdProvider(activeId));
    if (snapshotConversation != null) {
      return snapshotConversation;
    }

    final activeConversationAsync =
        ref.watch(conversationByIdProvider(activeId));
    if (activeConversationAsync.isLoading) {
      return null;
    }

    final activeConversation = activeConversationAsync.valueOrNull;
    if (activeConversation != null) {
      return activeConversation;
    }

    return null;
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

  final fallbackSnapshot =
      ref.watch(conversationSnapshotByIdProvider(fallbackId));
  if (fallbackSnapshot != null) {
    return fallbackSnapshot;
  }

  final fallbackConversationAsync =
      ref.watch(conversationByIdProvider(fallbackId));
  if (fallbackConversationAsync.isLoading) {
    return null;
  }

  return fallbackConversationAsync.valueOrNull;
});
