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

    // 浠?SQLite 鍔犺浇
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

      // 鎸?messageId 鍒嗙粍
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
          // 鎯呭喌2锛氭秷鎭彧鏈夌┖URL鐨凙udioBlock锛堝绔嬬殑pending鍗犱綅锛?          // 鈫?鍥為€€涓烘枃鏈秷鎭細浠?AudioBlock.text 鍙栧洖鍘熷鏂囨湰锛屾竻闄?blocks
          final blocks = blocksByMsgId[msgId];
          if (blocks != null) {
            final audioBlock = blocks.whereType<AudioBlock>().firstOrNull;
            final fallbackText = audioBlock?.text ?? '';
            orphanPendingByMsgId[msgId] = fallbackText;
            blocksByMsgId.remove(msgId); // 娓呴櫎 blocks锛岃娑堟伅鍥為€€涓虹函鏂囨湰
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
            AppLogger.info('DB', '宸叉竻鐞嗘畫鐣欒闊冲崰浣嶅潡', metadata: {
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
        // 瀛ょ珛 pending AudioBlock 鍥為€€锛氱敤 AudioBlock.text 瑕嗙洊绌?content
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

  /// 鐢ㄦ埛涓诲姩鍒涘缓鐨勬柊浼氳瘽锛堝崰浣嶏紝鍚庣画鍙湪缂栬緫椤靛畬鍠勶級
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
    // 淇濆瓨鍒?SQLite
    final convRepo = ref.read(conversationRepositoryProvider);
    final msgRepo = ref.read(messageRepositoryProvider);
    final blockRepo = ref.read(messageBlockRepositoryProvider);

    for (final conv in list) {
      await convRepo.upsert(ConversationConverter.toCompanion(conv));
      // 淇濆瓨娑堟伅鍜屽唴瀹瑰潡
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

  /// 淇濆瓨鍗曚釜浼氳瘽鍙婂叾娑堟伅
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
        // 娑堟伅娌℃湁 blocks 鏃讹紝鍒犻櫎鏁版嵁搴撲腑璇ユ秷鎭殑鎵€鏈夋棫 blocks
        // 鍦烘櫙锛歍TS 澶辫触鍥為€€鍒版枃鏈秷鎭椂锛岄渶瑕佹竻鐞嗘畫鐣欑殑 pending AudioBlock
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

  // 鏇存柊瀵硅瘽璁剧疆
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

  // 娓呴櫎鏈璁℃暟锛堣繘鍏ヨ亰澶╁鏃惰皟鐢級
  Future<void> clearUnread(String id) async {
    final convRepo = ref.read(conversationRepositoryProvider);

    // update database
    await convRepo.clearUnread(id);

    // update in-memory state
    await updateOne(id, (c) => c.copyWith(unreadCount: 0));
  }

  // 娓呯┖娑堟伅
  Future<void> clearMessages(String id) async {
    final msgRepo = ref.read(messageRepositoryProvider);

    final now = DateTime.now().millisecondsSinceEpoch;
    final purgeAt = now + 30 * 24 * 60 * 60 * 1000; // 30澶╁悗褰诲簳鍒犻櫎

    // 杞垹闄ゆ暟鎹簱涓殑娑堟伅
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
    final purgeAt = now + 30 * 24 * 60 * 60 * 1000; // 30澶╁悗褰诲簳鍒犻櫎

    // 杞垹闄ゆ暟鎹簱璁板綍
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
