import 'package:flutter_test/flutter_test.dart';
import 'package:drift/native.dart';

import 'package:aicove_flutter/src/core/database/database.dart' as db;
import 'package:aicove_flutter/src/core/database/repositories/memory_repository.dart';
import 'package:aicove_flutter/src/core/database/repositories/message_repository.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart' as chat;
import 'package:aicove_flutter/src/features/memory/models/memory_entity.dart';
import 'package:aicove_flutter/src/features/memory/services/memory_service.dart';
import 'package:aicove_flutter/src/features/plugins/memory/memory_plugin.dart';

void main() {
  group('memory regressions', () {
    test('search query should include current user message', () {
      final query = buildMemorySearchQuery(
        [
          chat.Message.text(
            id: 'm1',
            role: 'assistant',
            content: '昨天你说最近总是睡不好。',
          ),
          chat.Message.text(
            id: 'm2',
            role: 'user',
            content: '我和妈妈又吵架了。',
          ),
        ],
        currentUserMessage: '我现在最担心的是明天复诊。',
      );

      expect(query, contains('我和妈妈又吵架了。'));
      expect(query, contains('我现在最担心的是明天复诊。'));
    });

    test('explicit target layer should override heuristic downgrade', () {
      final layer = resolveMemoryTargetLayerForTest(
        preferredLayer: 'L2',
        category: 'daily_chatter',
        totalMessages: 2,
        avgUserChars: 5,
      );

      expect(layer, 'L2');
    });

    test('plain text fallback should stay on L3 path', () {
      final items = parseMemorySummaryItemsForTest('''
- 用户最近总因为复诊焦虑
- 和妈妈冲突后情绪很差
''');

      expect(items, hasLength(2));
      expect(
        items.map((item) => item['targetLayer']).toList(),
        everyElement(equals('L3')),
      );
      expect(
        items
            .map(
              (item) => resolveMemoryTargetLayerForTest(
                preferredLayer: item['targetLayer'],
                category: item['category'] ?? 'daily_chatter',
                totalMessages: 2,
                avgUserChars: 10,
              ),
            )
            .toList(),
        everyElement(equals('L3')),
      );
    });

    test('role scoped prompt should separate L1 direct insert and L2 skill',
        () {
      final prompt = buildRoleScopedMemoryPrompt(
        roleLabel: '小璃',
        profilePrompt: '''
## 用户画像
- 3天前：被否定时会很难受
''',
        l2SkillIndex: const <String>[
          '- 技能名：复诊焦虑安抚\n  时间：3天前\n  触发线索：复诊焦虑 / 害怕被否定',
        ],
        l2SkillDetails: const <String>[
          '- 技能：复诊焦虑安抚\n  时间：3天前\n  详细内容：\n    事件：用户担心明天复诊会被医生否定',
        ],
        l3Memories: const <String>[
          '2天前的对话摘要"用户说今晚想早点睡，明天再继续准备复诊。"',
        ],
      );

      expect(prompt, contains('### L1 用户攻略'));
      expect(prompt, contains('### L2 技能索引'));
      expect(prompt, contains('### 已命中的 L2 技能详情'));
      expect(prompt, contains('### L2/L3/L4 相关记忆'));
      expect(prompt, contains('注入方式：L1 直接插入；L2 以 skill 索引和命中详情插入；L3 以召回回忆插入'));
      expect(prompt, contains('时间：3天前'));
    });

    test('L2 skill formatter should include time prefix and trigger hints', () {
      final now = DateTime.now();
      final memory = MemoryEntity(
        id: 'l2_1',
        content: '''
【复诊焦虑安抚】
事件：用户担心明天复诊时被医生否定，整个人很紧张。
情绪：焦虑、害怕被批评
性格分析：对权威评价非常敏感
应对策略：先安抚，再陪她梳理最坏情况。
''',
        layer: 'L2',
        category: 'emotional_event',
        conversationId: 'conv_a',
        createdAt: now.subtract(const Duration(days: 3)),
      );

      final indexEntry = formatL2SkillIndexEntry(memory);
      final detailBlock = formatL2SkillDetailBlock(memory);

      expect(indexEntry, contains('技能名：复诊焦虑安抚'));
      expect(indexEntry, contains('时间：3天前'));
      expect(indexEntry, contains('触发线索：'));
      expect(detailBlock, contains('技能：复诊焦虑安抚'));
      expect(detailBlock, contains('时间：3天前'));
      expect(detailBlock, contains('详细内容：'));
    });

    test('search should fallback to keyword retrieval when embedding is absent',
        () async {
      final database = db.AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final memoryRepository = MemoryRepository(database);
      final messageRepository = MessageRepository(database);
      final now = DateTime.now();

      await memoryRepository.addMemory(
        MemoryEntity(
          id: 'memory_keyword_fallback',
          content: '''
【复诊焦虑安抚】
事件：用户担心明天复诊时会被医生否定。
情绪：焦虑、紧张
''',
          layer: 'L2',
          category: 'emotional_event',
          conversationId: 'conv_keyword',
          contentHash: 'keyword_hash',
          createdAt: now.subtract(const Duration(days: 1)),
        ),
      );

      final service = MemoryService(
        const MemoryServiceConfig(
          enabled: true,
          enableHybridSearch: true,
          enableProfileLayer: false,
          enableMemoryMerge: false,
          enableCapacityCompress: false,
          enablePreFlush: false,
        ),
        memoryRepository,
        messageRepository,
      );

      final results = await service.search(
        conversationId: 'conv_keyword',
        query: '复诊',
      );

      expect(results, isNotEmpty);
      expect(results.first.content, contains('复诊'));
    });
  });
}
