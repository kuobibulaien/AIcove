// ignore_for_file: use_super_parameters

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/core/database/database.dart';
import 'package:aicove_flutter/src/core/database/repositories/memory_repository.dart';
import 'package:aicove_flutter/src/core/database/repositories/message_repository.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart' as chat;
import 'package:aicove_flutter/src/features/memory/services/memory_service.dart';

Future<void> _insertConversation(AppDatabase db, String id) async {
  final now = DateTime.now().millisecondsSinceEpoch;
  await db.into(db.conversations).insert(
        ConversationsCompanion.insert(
          id: id,
          title: id,
          displayName: id,
          createdAt: now,
          updatedAt: now,
        ),
      );
}

Future<void> _insertMessage(
  AppDatabase db, {
  required String id,
  required String conversationId,
  required String role,
  required DateTime createdAt,
  bool summarized = false,
}) async {
  await db.into(db.messages).insert(
        MessagesCompanion.insert(
          id: id,
          conversationId: conversationId,
          role: role,
          content: '$role:$id',
          status: const Value('sent'),
          summarized: Value(summarized),
          createdAt: createdAt.millisecondsSinceEpoch,
        ),
      );
}

class _RecordingMemoryService extends MemoryService {
  _RecordingMemoryService(
    MemoryServiceConfig config,
    MemoryRepository memoryRepository,
    MessageRepository messageRepository,
  ) : super(config, memoryRepository, messageRepository);

  final List<List<String>> summarizedBatchIds = <List<String>>[];

  @override
  Future<void> summarizeAndStore(
    List<chat.Message> messages, {
    required String conversationId,
  }) async {
    summarizedBatchIds.add(
      messages.map((message) => message.id).toList(growable: false),
    );
  }
}

void main() {
  group('MemoryService 触发时机', () {
    late AppDatabase db;
    late MessageRepository messageRepository;
    late _RecordingMemoryService service;

    setUp(() async {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      messageRepository = MessageRepository(db);
      service = _RecordingMemoryService(
        const MemoryServiceConfig(
          enabled: true,
          enableNextDayTrigger: true,
          enableCapacityCompress: false,
          enableMemoryMerge: false,
          enableProfileLayer: false,
          enablePreFlush: false,
        ),
        MemoryRepository(db),
        messageRepository,
      );
      await _insertConversation(db, 'conv_trigger');
    });

    tearDown(() async {
      await db.close();
    });

    test('24小时保护期内没有陈旧消息时保持休眠', () async {
      final disturbanceTime = DateTime(2026, 3, 18, 12, 0);
      await _insertMessage(
        db,
        id: 'recent_1',
        conversationId: 'conv_trigger',
        role: 'assistant',
        createdAt: disturbanceTime.subtract(const Duration(hours: 6)),
      );
      await _insertMessage(
        db,
        id: 'recent_2',
        conversationId: 'conv_trigger',
        role: 'user',
        createdAt: disturbanceTime,
      );

      await service.checkAndTriggerDailySummarization(
        conversationId: 'conv_trigger',
        disturbanceTime: disturbanceTime,
      );

      expect(service.summarizedBatchIds, isEmpty);
      expect(
          (await messageRepository.getById('recent_1'))!.summarized, isFalse);
      expect(
          (await messageRepository.getById('recent_2'))!.summarized, isFalse);
    });

    test('24小时外存在未总结消息时会触发总结', () async {
      final disturbanceTime = DateTime(2026, 3, 18, 12, 0);
      await _insertMessage(
        db,
        id: 'old_user',
        conversationId: 'conv_trigger',
        role: 'user',
        createdAt: disturbanceTime.subtract(const Duration(hours: 26)),
      );
      await _insertMessage(
        db,
        id: 'old_ai',
        conversationId: 'conv_trigger',
        role: 'assistant',
        createdAt:
            disturbanceTime.subtract(const Duration(hours: 25, minutes: 50)),
      );
      await _insertMessage(
        db,
        id: 'protected_user',
        conversationId: 'conv_trigger',
        role: 'user',
        createdAt: disturbanceTime.subtract(const Duration(hours: 23)),
      );
      await _insertMessage(
        db,
        id: 'current_user',
        conversationId: 'conv_trigger',
        role: 'user',
        createdAt: disturbanceTime,
      );

      await service.checkAndTriggerDailySummarization(
        conversationId: 'conv_trigger',
        disturbanceTime: disturbanceTime,
      );

      expect(service.summarizedBatchIds, hasLength(1));
      expect(service.summarizedBatchIds.single, ['old_user', 'old_ai']);
      expect((await messageRepository.getById('old_user'))!.summarized, isTrue);
      expect((await messageRepository.getById('old_ai'))!.summarized, isTrue);
      expect((await messageRepository.getById('protected_user'))!.summarized,
          isFalse);
      expect((await messageRepository.getById('current_user'))!.summarized,
          isFalse);
    });

    test('保护期边界按用户消息十分钟续接并携带中间对话', () async {
      final disturbanceTime = DateTime(2026, 3, 18, 12, 0);
      await _insertMessage(
        db,
        id: 'a',
        conversationId: 'conv_trigger',
        role: 'user',
        createdAt:
            disturbanceTime.subtract(const Duration(hours: 24, minutes: 5)),
      );
      await _insertMessage(
        db,
        id: 'a_assistant',
        conversationId: 'conv_trigger',
        role: 'assistant',
        createdAt:
            disturbanceTime.subtract(const Duration(hours: 24, minutes: 3)),
      );
      await _insertMessage(
        db,
        id: 'b_user',
        conversationId: 'conv_trigger',
        role: 'user',
        createdAt:
            disturbanceTime.subtract(const Duration(hours: 23, minutes: 58)),
      );
      await _insertMessage(
        db,
        id: 'b_assistant',
        conversationId: 'conv_trigger',
        role: 'assistant',
        createdAt:
            disturbanceTime.subtract(const Duration(hours: 23, minutes: 55)),
      );
      await _insertMessage(
        db,
        id: 'c_user',
        conversationId: 'conv_trigger',
        role: 'user',
        createdAt:
            disturbanceTime.subtract(const Duration(hours: 23, minutes: 51)),
      );
      await _insertMessage(
        db,
        id: 'd',
        conversationId: 'conv_trigger',
        role: 'assistant',
        createdAt:
            disturbanceTime.subtract(const Duration(hours: 23, minutes: 39)),
      );
      await _insertMessage(
        db,
        id: 'current_user',
        conversationId: 'conv_trigger',
        role: 'user',
        createdAt: disturbanceTime,
      );

      await service.checkAndTriggerDailySummarization(
        conversationId: 'conv_trigger',
        disturbanceTime: disturbanceTime,
      );

      expect(service.summarizedBatchIds, hasLength(1));
      expect(
        service.summarizedBatchIds.single,
        ['a', 'a_assistant', 'b_user', 'b_assistant', 'c_user'],
      );
      expect((await messageRepository.getById('a'))!.summarized, isTrue);
      expect(
          (await messageRepository.getById('a_assistant'))!.summarized, isTrue);
      expect((await messageRepository.getById('b_user'))!.summarized, isTrue);
      expect(
          (await messageRepository.getById('b_assistant'))!.summarized, isTrue);
      expect((await messageRepository.getById('c_user'))!.summarized, isTrue);
      expect((await messageRepository.getById('d'))!.summarized, isFalse);
      expect((await messageRepository.getById('current_user'))!.summarized,
          isFalse);
    });

    test('边界附近只有助手消息时不会错误突破保护期', () async {
      final disturbanceTime = DateTime(2026, 3, 18, 12, 0);
      await _insertMessage(
        db,
        id: 'old_user',
        conversationId: 'conv_trigger',
        role: 'user',
        createdAt:
            disturbanceTime.subtract(const Duration(hours: 24, minutes: 5)),
      );
      await _insertMessage(
        db,
        id: 'protected_assistant',
        conversationId: 'conv_trigger',
        role: 'assistant',
        createdAt:
            disturbanceTime.subtract(const Duration(hours: 23, minutes: 58)),
      );
      await _insertMessage(
        db,
        id: 'protected_user',
        conversationId: 'conv_trigger',
        role: 'user',
        createdAt:
            disturbanceTime.subtract(const Duration(hours: 23, minutes: 40)),
      );
      await _insertMessage(
        db,
        id: 'current_user',
        conversationId: 'conv_trigger',
        role: 'user',
        createdAt: disturbanceTime,
      );

      await service.checkAndTriggerDailySummarization(
        conversationId: 'conv_trigger',
        disturbanceTime: disturbanceTime,
      );

      expect(service.summarizedBatchIds, hasLength(1));
      expect(service.summarizedBatchIds.single, ['old_user']);
      expect((await messageRepository.getById('old_user'))!.summarized, isTrue);
      expect(
          (await messageRepository.getById('protected_assistant'))!.summarized,
          isFalse);
      expect((await messageRepository.getById('protected_user'))!.summarized,
          isFalse);
    });
  });
}
