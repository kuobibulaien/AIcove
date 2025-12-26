import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'domain/conversation.dart';
import 'domain/message.dart';
import 'id_gen.dart';
import '../tts/data/tts_api.dart';
import '../tts/tts_player.dart';
import '../../core/models/message_block.dart';
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
      final conv = _createConversation();
      await _saveOne(conv);
      return [conv];
    }

    // 加载消息
    final result = <Conversation>[];
    for (final dbConv in dbConvs) {
      final dbMsgs = await msgRepo.getByConversation(dbConv.id, limit: 1000);
      final messages = <Message>[];
      for (final dbMsg in dbMsgs.reversed) {
        final dbBlocks = await blockRepo.getByMessage(dbMsg.id);
        final blocks = dbBlocks.map(MessageBlockConverter.fromDb).whereType<MessageBlock>().toList();
        messages.add(MessageConverter.fromDb(dbMsg, blocks: blocks.isEmpty ? null : blocks));
      }
      result.add(ConversationConverter.fromDb(dbConv, messages: messages));
    }
    return result;
  }

  Conversation _createConversation() {
    final now = DateTime.now();
    final examples = [
      {'name': 'Arona', 'org': '联邦学生会', 'char': 'assets/characters/Arona.webp'},
      {'name': 'Aru', 'org': '便利屋68', 'char': 'assets/characters/Aru.webp'},
      {'name': 'Hoshino', 'org': '对策委员会', 'char': 'assets/characters/Hoshino.webp'},
      {'name': 'Shiroko', 'org': '对策委员会', 'char': 'assets/characters/Shiroko.webp'},
      {'name': 'Hina', 'org': '风纪委员会', 'char': 'assets/characters/Hina.webp'},
    ];
    final random = (now.millisecondsSinceEpoch % examples.length);
    final example = examples[random];

    return Conversation(
      id: genId('conv'),
      title: example['name']!,
      displayName: example['name']!,
      characterImage: example['char'],
      createdAt: now,
      updatedAt: now,
      messages: const [],
    );
  }

  Future<void> _save(List<Conversation> list) async {
    // 保存到 SQLite
    final convRepo = ref.read(conversationRepositoryProvider);

    for (final conv in list) {
      await convRepo.upsert(ConversationConverter.toCompanion(conv));
      // 消息单独处理（在 updateOne 中按需保存）
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
      await msgRepo.insert(MessageConverter.toCompanion(msg, conv.id));
      if (msg.blocks != null) {
        for (var j = 0; j < msg.blocks!.length; j++) {
          await blockRepo.insert(
            MessageBlockConverter.toCompanion(msg.blocks![j], msg.id, j),
          );
        }
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
    String? personaPrompt,
  }) async {
    await updateOne(id, (c) => c.copyWith(
      displayName: displayName ?? c.displayName,
      avatarUrl: avatarUrl ?? c.avatarUrl,
      characterImage: characterImage ?? c.characterImage,
      addressUser: addressUser ?? c.addressUser,
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
  }) async {
    await updateOne(id, (c) => c.copyWith(
      isPinned: isPinned ?? c.isPinned,
      isFavorite: isFavorite ?? c.isFavorite,
      isMuted: isMuted ?? c.isMuted,
      notificationSound: notificationSound ?? c.notificationSound,
      updatedAt: DateTime.now(),
    ));
  }

  // 清空消息
  Future<void> clearMessages(String id) async {
    await updateOne(id, (c) => Conversation(
      id: c.id,
      title: c.title,
      displayName: c.displayName,
      avatarUrl: c.avatarUrl,
      characterImage: c.characterImage,
      addressUser: c.addressUser,
      personaPrompt: c.personaPrompt,
      messages: const [],
      createdAt: c.createdAt,
      updatedAt: DateTime.now(),
      defaultProvider: c.defaultProvider,
      sessionProvider: c.sessionProvider,
      isPinned: c.isPinned,
      isFavorite: c.isFavorite, // 保留 isFavorite
      isMuted: c.isMuted,
      notificationSound: c.notificationSound,
      lastMessage: null,
      lastMessageTime: null,
      unreadCount: 0,
    ));
  }

  // 删除对话
  Future<void> deleteConversation(String id) async {
    final current = state.value ?? <Conversation>[];
    final next = current.where((c) => c.id != id).toList();
    await setAll(next);
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
