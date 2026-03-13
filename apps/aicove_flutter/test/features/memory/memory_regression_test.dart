import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/features/chat/domain/message.dart' as chat;
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
  });
}
