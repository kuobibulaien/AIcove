import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'domain/conversation.dart';
import 'id_gen.dart';
import 'data/preset_characters_loader.dart';
import '../../core/models/message_block.dart';
import '../../core/app_logger.dart';
import '../../core/database/database_provider.dart';
import '../../core/database/converters/database_converters.dart';

class ConversationsNotifier extends AsyncNotifier<List<Conversation>> {
  @override
  Future<List<Conversation>> build() async {
    final convRepo = ref.read(conversationRepositoryProvider);
    final msgRepo = ref.read(messageRepositoryProvider);
    final blockRepo = ref.read(messageBlockRepositoryProvider);

    // (注释已丢失)
    final dbConvs = await convRepo.getAll();
    if (dbConvs.isEmpty) {
      final conv = await _createInitialConversation();
      await _saveOne(conv);
      return [conv];
    }

    // load initial messages (first page) with batched blocks
    final result = <Conversation>[];
    for (final dbConv in dbConvs) {
      // only load recent messages for first paint
      final dbMsgs = await msgRepo.getByConversation(dbConv.id, limit: 30);

      // batch load blocks for these messages
      final messageIds = dbMsgs.map((m) => m.id).toList();
      final dbBlocks = await blockRepo.getByMessages(messageIds);

      // (注释已丢失)
      final blocksByMsgId = <String, List<MessageBlock>>{};
      final hasPlayableAudioByMsgId = <String, bool>{};
      final emptyAudioBlockIdsByMsgId = <String, List<String>>{};
      for (final dbBlock in dbBlocks) {
        final block = MessageBlockConverter.fromDb(dbBlock);
        if (block != null) {
          blocksByMsgId.putIfAbsent(dbBlock.messageId, () => []).add(block);
          if (block is AudioBlock) {
            if (block.url.isNotEmpty) {
              hasPlayableAudioByMsgId[dbBlock.messageId] = true;
            } else {
              emptyAudioBlockIdsByMsgId
                  .putIfAbsent(dbBlock.messageId, () => [])
                  .add(dbBlock.id);
            }
          }
        }
      }

      final stalePendingAudioBlockIds = <String>[];
      // Track messages that should fallback to plain text
      final orphanPendingByMsgId = <String, String>{}; // msgId -> fallbackText
      for (final entry in emptyAudioBlockIdsByMsgId.entries) {
        final msgId = entry.key;
        final ids = entry.value;
        if (ids.isEmpty) continue;
        if (hasPlayableAudioByMsgId[msgId] == true) {
          // Case 1: message has both playable and empty audio blocks
          final blocks = blocksByMsgId[msgId];
          if (blocks != null) {
            blocksByMsgId[msgId] = [
              for (final b in blocks)
                if (b is! AudioBlock || b.url.isNotEmpty) b,
            ];
          }
          stalePendingAudioBlockIds.addAll(ids);
        } else {
          // (注释已丢失)
          final blocks = blocksByMsgId[msgId];
          if (blocks != null) {
            final audioBlock = blocks.whereType<AudioBlock>().firstOrNull;
            final fallbackText = audioBlock?.text ?? '';
            orphanPendingByMsgId[msgId] = fallbackText;
            blocksByMsgId.remove(msgId); // (注释已丢失)
            stalePendingAudioBlockIds.addAll(ids);
          }
        }
      }

      if (stalePendingAudioBlockIds.isNotEmpty) {
        unawaited(() async {
          try {
            final deletedAt = DateTime.now().millisecondsSinceEpoch;
            for (final id in stalePendingAudioBlockIds) {
              await blockRepo.softDelete(id, deletedAt);
            }
            AppLogger.info('DB', '已清理残留语音占位块', metadata: {
              'count': stalePendingAudioBlockIds.length,
              'orphanCount': orphanPendingByMsgId.length,
              'conversationId': dbConv.id,
            });
          } catch (e) {
            AppLogger.warning('DB', 'Failed to cleanup stale audio blocks',
                metadata: {
                  'error': e.toString(),
                  'conversationId': dbConv.id,
                });
          }
        }());
      }

      // Assemble messages (db desc -> ui asc)
      final messages = dbMsgs.reversed.map((dbMsg) {
        final blocks = blocksByMsgId[dbMsg.id];
        // (注释已丢失)
        final fallbackText = orphanPendingByMsgId[dbMsg.id];
        if (fallbackText != null) {
          return MessageConverter.fromDb(dbMsg, blocks: null).copyWith(
              content: fallbackText.isNotEmpty ? fallbackText : dbMsg.content);
        }
        return MessageConverter.fromDb(dbMsg, blocks: blocks);
      }).toList();

      result.add(ConversationConverter.fromDb(dbConv, messages: messages));
    }
    return result;
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
      messages: const [],
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
      messages: const [],
    );
  }

  Future<void> _save(List<Conversation> list) async {
    // (注释已丢失)
    final convRepo = ref.read(conversationRepositoryProvider);
    final msgRepo = ref.read(messageRepositoryProvider);
    final blockRepo = ref.read(messageBlockRepositoryProvider);

    for (final conv in list) {
      await convRepo.upsert(ConversationConverter.toCompanion(conv));
      // 保存消息和内容块
      for (var i = 0; i < conv.messages.length; i++) {
        final msg = conv.messages[i];
        await msgRepo.upsert(MessageConverter.toCompanion(msg, conv.id));
        if (msg.blocks != null) {
          for (var j = 0; j < msg.blocks!.length; j++) {
            await blockRepo.upsert(
              MessageBlockConverter.toCompanion(msg.blocks![j], msg.id, j),
            );
          }
        }
      }
    }
  }

  /// 保存单个会话及其消息
  Future<void> _saveOne(Conversation conv) async {
    final convRepo = ref.read(conversationRepositoryProvider);
    final msgRepo = ref.read(messageRepositoryProvider);
    final blockRepo = ref.read(messageBlockRepositoryProvider);

    await convRepo.upsert(ConversationConverter.toCompanion(conv));
    for (var i = 0; i < conv.messages.length; i++) {
      final msg = conv.messages[i];
      await msgRepo.upsert(MessageConverter.toCompanion(msg, conv.id));
      if (msg.blocks != null && msg.blocks!.isNotEmpty) {
        for (var j = 0; j < msg.blocks!.length; j++) {
          await blockRepo.upsert(
            MessageBlockConverter.toCompanion(msg.blocks![j], msg.id, j),
          );
        }
      } else {
        // (注释已丢失)
        // (注释已丢失)
        await blockRepo.deleteByMessage(msg.id);
      }
    }
  }

  Future<void> setAll(List<Conversation> list) async {
    state = AsyncValue.data(list);
    await _save(list);
  }

  Future<void> updateOne(
      String id, Conversation Function(Conversation) fn) async {
    final current = state.value ?? <Conversation>[];
    final next = [
      for (final c in current)
        if (c.id == id) fn(c) else c
    ];
    await setAll(next);
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

    final now = DateTime.now().millisecondsSinceEpoch;
    final purgeAt = now + 30 * 24 * 60 * 60 * 1000; // (注释已丢失)

    // (注释已丢失)
    await msgRepo.softDeleteByConversation(id, now, purgeAt);

    // update in-memory state
    await updateOne(
        id,
        (c) => c.copyWith(
              messages: const [],
              lastMessage: null,
              lastMessageTime: null,
              unreadCount: 0,
              updatedAt: DateTime.now(),
            ));
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
