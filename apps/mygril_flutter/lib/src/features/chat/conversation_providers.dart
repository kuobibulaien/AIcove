import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'domain/conversation.dart';
import 'domain/message.dart';
import 'id_gen.dart';
import 'data/preset_characters_loader.dart';
import '../tts/data/tts_api.dart';
import '../tts/tts_player.dart';
import '../../core/models/message_block.dart';
import '../../core/app_logger.dart';
import '../../core/database/database_provider.dart';
import '../../core/database/converters/database_converters.dart';

final ttsApiProvider = Provider((ref) => TtsApi());

final ttsPlayerUsecaseProvider = Provider((ref) {
  final player = ref.watch(ttsPlayerProvider);
  return (String url) => player.playUrl(url);
});

class ConversationsNotifier extends AsyncNotifier<List<Conversation>> {
  @override
  Future<List<Conversation>> build() async {
    final convRepo = ref.read(conversationRepositoryProvider);
    final msgRepo = ref.read(messageRepositoryProvider);
    final blockRepo = ref.read(messageBlockRepositoryProvider);

    // 从 SQLite 加载
    final dbConvs = await convRepo.getAll();
    if (dbConvs.isEmpty) {
      final conv = await _createInitialConversation();
      await _saveOne(conv);
      return [conv];
    }

    // 加载消息（性能优化：首屏只加载30条，批量查询blocks）
    final result = <Conversation>[];
    for (final dbConv in dbConvs) {
      // 只加载最近30条消息（首屏限制）
      final dbMsgs = await msgRepo.getByConversation(dbConv.id, limit: 30);
      
      // 批量获取所有消息的 blocks（减少数据库查询次数）
      final messageIds = dbMsgs.map((m) => m.id).toList();
      final dbBlocks = await blockRepo.getByMessages(messageIds);
      
      // 按 messageId 分组
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
      // 记录需要回退为文本的消息（孤立的 pending AudioBlock）
      final orphanPendingByMsgId = <String, String>{}; // msgId -> fallbackText
      for (final entry in emptyAudioBlockIdsByMsgId.entries) {
        final msgId = entry.key;
        final ids = entry.value;
        if (ids.isEmpty) continue;
        if (hasPlayableAudioByMsgId[msgId] == true) {
          // 情况1：同一消息中既有可播放音频又有空URL音频 → 删除空URL的
          final blocks = blocksByMsgId[msgId];
          if (blocks != null) {
            blocksByMsgId[msgId] = [
              for (final b in blocks)
                if (b is! AudioBlock || b.url.isNotEmpty) b,
            ];
          }
          stalePendingAudioBlockIds.addAll(ids);
        } else {
          // 情况2：消息只有空URL的AudioBlock（孤立的pending占位）
          // → 回退为文本消息：从 AudioBlock.text 取回原始文本，清除 blocks
          final blocks = blocksByMsgId[msgId];
          if (blocks != null) {
            final audioBlock = blocks.whereType<AudioBlock>().firstOrNull;
            final fallbackText = audioBlock?.text ?? '';
            orphanPendingByMsgId[msgId] = fallbackText;
            blocksByMsgId.remove(msgId); // 清除 blocks，让消息回退为纯文本
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
            AppLogger.warning('DB', '清理残留语音占位块失败', metadata: {
              'error': e.toString(),
              'conversationId': dbConv.id,
            });
          }
        }());
      }
      
      // 组装消息（reversed: 数据库返回 desc，UI 需要 asc）
      final messages = dbMsgs.reversed.map((dbMsg) {
        final blocks = blocksByMsgId[dbMsg.id];
        // 孤立 pending AudioBlock 回退：用 AudioBlock.text 覆盖空 content
        final fallbackText = orphanPendingByMsgId[dbMsg.id];
        if (fallbackText != null) {
          return MessageConverter.fromDb(dbMsg, blocks: null)
              .copyWith(content: fallbackText.isNotEmpty ? fallbackText : dbMsg.content);
        }
        return MessageConverter.fromDb(dbMsg, blocks: blocks);
      }).toList();
      
      result.add(ConversationConverter.fromDb(dbConv, messages: messages));
    }
    return result;
  }

  /// 首次启动（数据库为空）时的默认会话：固定使用“纳西妲”预设
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
      // 读取预设失败时，走兜底（避免启动崩溃）
    }

    return Conversation(
      id: 'preset_nahida',
      title: '纳西妲',
      displayName: '纳西妲',
      description: '全肯定溺爱女友，你的专属妈咪',
      characterImage: 'assets/characters/images/nahida.jpg',
      createdAt: now,
      updatedAt: now,
      messages: const [],
    );
  }

  /// 用户主动创建的新会话（占位，后续可在编辑页完善）
  Conversation _createConversation() {
    final now = DateTime.now();
    return Conversation(
      id: genId('conv'),
      title: '新会话',
      displayName: '新会话',
      createdAt: now,
      updatedAt: now,
      messages: const [],
    );
  }

  Future<void> _save(List<Conversation> list) async {
    // 保存到 SQLite
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
        // 消息没有 blocks 时，删除数据库中该消息的所有旧 blocks
        // 场景：TTS 失败回退到文本消息时，需要清理残留的 pending AudioBlock
        await blockRepo.deleteByMessage(msg.id);
      }
    }
  }

  Future<void> setAll(List<Conversation> list) async {
    state = AsyncValue.data(list);
    await _save(list);
  }

  Future<void> updateOne(String id, Conversation Function(Conversation) fn) async {
    final current = state.value ?? <Conversation>[];
    final next = [for (final c in current) if (c.id == id) fn(c) else c];
    await setAll(next);
  }

  Future<String> createNew() async {
    final list = <Conversation>[...(state.value ?? <Conversation>[])];
    final c = _createConversation();
    list.insert(0, c);
    await setAll(list);
    return c.id;
  }

  // 应用联系人编辑
  Future<void> applyContactEdit(
    String id, {
    String? displayName,
    String? avatarUrl,
    String? characterImage,
    String? addressUser,
    String? description,
    String? personaPrompt,
  }) async {
    await updateOne(id, (c) => c.copyWith(
      displayName: displayName ?? c.displayName,
      avatarUrl: avatarUrl ?? c.avatarUrl,
      characterImage: characterImage ?? c.characterImage,
      addressUser: addressUser ?? c.addressUser,
      description: description ?? c.description,
      personaPrompt: personaPrompt ?? c.personaPrompt,
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
    await updateOne(id, (c) => c.copyWith(
      isPinned: isPinned ?? c.isPinned,
      isFavorite: isFavorite ?? c.isFavorite,
      isMuted: isMuted ?? c.isMuted,
      notificationSound: notificationSound ?? c.notificationSound,
      enabledPlugins: clearEnabledPlugins ? null : (enabledPlugins ?? c.enabledPlugins),
      updatedAt: DateTime.now(),
    ));
  }

  // 清空消息
  Future<void> clearMessages(String id) async {
    final msgRepo = ref.read(messageRepositoryProvider);

    final now = DateTime.now().millisecondsSinceEpoch;
    final purgeAt = now + 30 * 24 * 60 * 60 * 1000; // 30天后彻底删除

    // 软删除数据库中的消息
    await msgRepo.softDeleteByConversation(id, now, purgeAt);

    // 更新内存状态
    await updateOne(id, (c) => c.copyWith(
      messages: const [],
      lastMessage: null,
      lastMessageTime: null,
      unreadCount: 0,
      updatedAt: DateTime.now(),
    ));
  }

  // 删除对话（软删除到回收站）
  Future<void> deleteConversation(String id) async {
    final convRepo = ref.read(conversationRepositoryProvider);
    final msgRepo = ref.read(messageRepositoryProvider);

    final now = DateTime.now().millisecondsSinceEpoch;
    final purgeAt = now + 30 * 24 * 60 * 60 * 1000; // 30天后彻底删除

    // 软删除数据库记录
    await convRepo.softDelete(id, now, purgeAt);
    await msgRepo.softDeleteByConversation(id, now, purgeAt);

    // 更新内存状态
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
