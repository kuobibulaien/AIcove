import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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

final activeConversationProvider = Provider<Conversation?>((ref) {
  final id = ref.watch(activeConversationIdProvider);
  final listAsync = ref.watch(conversationsProvider);
  return listAsync.maybeWhen(
    data: (list) {
      if (list.isEmpty) return null;
      if (id == null) return list.first;
      for (final c in list) {
        if (c.id == id) return c;
      }
      return list.first;
    },
    orElse: () => null,
  );
});
