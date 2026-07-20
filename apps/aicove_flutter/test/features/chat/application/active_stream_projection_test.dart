import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/core/models/block_status.dart';
import 'package:aicove_flutter/src/core/models/message_block.dart';
import 'package:aicove_flutter/src/features/chat/application/active_stream_projection.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';

ActiveStreamProjection _proj({
  String conversationId = 'conv_a',
  int generationSeq = 1,
  int writeEpoch = 0,
  String? tailMessageId = 'msg_tail',
  String tailText = '',
  ActiveStreamPhase phase = ActiveStreamPhase.streamingTail,
}) {
  return ActiveStreamProjection(
    conversationId: conversationId,
    generationSeq: generationSeq,
    writeEpoch: writeEpoch,
    tailMessageId: tailMessageId,
    tailText: tailText,
    phase: phase,
  );
}

void main() {
  late ProviderContainer container;
  late ActiveStreamProjectionsNotifier notifier;

  setUp(() {
    container = ProviderContainer();
    notifier = container.read(activeStreamProjectionsProvider.notifier);
  });

  tearDown(() => container.dispose());

  group('CAS publish', () {
    test('同代 writeEpoch 递增可覆盖，回退被拒', () {
      expect(notifier.publish(_proj(writeEpoch: 1, tailText: 'a')), isTrue);
      expect(notifier.publish(_proj(writeEpoch: 2, tailText: 'ab')), isTrue);
      expect(notifier.publish(_proj(writeEpoch: 1, tailText: 'stale')),
          isFalse, reason: '旧 epoch 不得覆盖新 epoch');
      expect(container.read(activeStreamProjectionsProvider)['conv_a']!.tailText,
          'ab');
    });

    test('新 generationSeq 覆盖旧代；旧代迟到 publish 被拒', () {
      expect(notifier.publish(_proj(generationSeq: 1, tailText: 'old')), isTrue);
      expect(notifier.publish(_proj(generationSeq: 2, tailText: 'new')), isTrue);
      expect(
          notifier.publish(
              _proj(generationSeq: 1, writeEpoch: 9, tailText: 'stale')),
          isFalse,
          reason: '旧流即使 epoch 更高也不得覆盖新流');
      expect(container.read(activeStreamProjectionsProvider)['conv_a']!.tailText,
          'new');
    });

    test('等值 publish 幂等且不触发监听', () {
      var notifyCount = 0;
      container.listen(activeStreamProjectionsProvider, (_, __) {
        notifyCount++;
      });
      final p = _proj(tailText: 'same');
      expect(notifier.publish(p), isTrue);
      final afterFirst = notifyCount;
      expect(notifier.publish(p), isTrue);
      expect(notifyCount, afterFirst, reason: '等值 publish 不应再通知');
    });
  });

  group('CAS clear', () {
    test('同代 clear 移除条目', () {
      notifier.publish(_proj(generationSeq: 3));
      expect(
          notifier.clear('conv_a', generationSeq: 3), isTrue);
      expect(container.read(activeStreamProjectionsProvider), isEmpty);
    });

    test('旧代迟到 clear 不得清掉新流', () {
      notifier.publish(_proj(generationSeq: 5, tailText: 'live'));
      expect(notifier.clear('conv_a', generationSeq: 4), isFalse);
      expect(container.read(activeStreamProjectionsProvider)['conv_a']!.tailText,
          'live');
    });

    test('清除不存在的会话为 no-op', () {
      expect(notifier.clear('conv_missing', generationSeq: 1), isFalse);
    });
  });

  group('会话隔离与生命周期', () {
    test('A/B 会话条目互不干扰', () {
      notifier.publish(_proj(conversationId: 'conv_a', tailText: 'aa'));
      notifier.publish(
          _proj(conversationId: 'conv_b', generationSeq: 2, tailText: 'bb'));
      final map = container.read(activeStreamProjectionsProvider);
      expect(map['conv_a']!.tailText, 'aa');
      expect(map['conv_b']!.tailText, 'bb');
      notifier.clear('conv_a', generationSeq: 1);
      expect(container.read(activeStreamProjectionsProvider).keys,
          <String>['conv_b'], reason: '清 A 不影响 B');
    });

    test('流结束条目移除后 map 无残留（B3 回收契约）', () {
      notifier.publish(_proj(conversationId: 'conv_a'));
      notifier.publish(_proj(conversationId: 'conv_b', generationSeq: 2));
      notifier.clear('conv_a', generationSeq: 1);
      notifier.clear('conv_b', generationSeq: 2);
      expect(container.read(activeStreamProjectionsProvider), isEmpty);
    });
  });

  test('policy 默认启用活跃流通道（2026-07-20 翻默认；off 为回滚面）', () {
    expect(
      container.read(streamProjectionPolicyProvider).useActiveStreamChannel,
      isTrue,
    );
  });

  test('select 按会话过滤：其他会话更新不惊动无关订阅', () {
    var hits = 0;
    container.listen(
      activeStreamProjectionsProvider.select((m) => m['conv_a']),
      (_, __) => hits++,
    );
    notifier.publish(_proj(conversationId: 'conv_b', generationSeq: 2));
    expect(hits, 0, reason: 'conv_b 的更新不应触发 conv_a 的 select 订阅');
    notifier.publish(_proj(conversationId: 'conv_a', tailText: 'x'));
    expect(hits, 1);
  });

  group('resolveActiveStreamTailMessage（S-02 防御边界）', () {
    Message textMessage(String id, String content) => Message.fromBlocks(
          id: id,
          role: 'assistant',
          blocks: <MessageBlock>[
            TextBlock(messageId: id, content: content),
          ],
          createdAt: DateTime(2026, 1, 1),
          status: 'sending',
        );

    test('命中：单 TextBlock 壳被替换为通道文本', () {
      final msg = textMessage('msg_tail', '壳');
      final out = resolveActiveStreamTailMessage(
        msg,
        _proj(tailMessageId: 'msg_tail', tailText: '实时文本'),
      );
      expect(out.content, '实时文本');
      expect((out.blocks!.single as TextBlock).content, '实时文本');
      expect(out.id, msg.id);
    });

    test('id 不匹配原样返回（helper 自身校验，不依赖调用点 selector）', () {
      final msg = textMessage('msg_other', '壳');
      final out = resolveActiveStreamTailMessage(
        msg,
        _proj(tailMessageId: 'msg_tail', tailText: '实时文本'),
      );
      expect(identical(out, msg), isTrue);
    });

    test('thinking 相位 / 空文本 / null 均原样返回', () {
      final msg = textMessage('msg_tail', '壳');
      expect(
        identical(
          resolveActiveStreamTailMessage(
            msg,
            _proj(
              tailMessageId: 'msg_tail',
              phase: ActiveStreamPhase.thinking,
            ),
          ),
          msg,
        ),
        isTrue,
      );
      expect(
        identical(
          resolveActiveStreamTailMessage(
            msg,
            _proj(tailMessageId: 'msg_tail', tailText: ''),
          ),
          msg,
        ),
        isTrue,
      );
      expect(identical(resolveActiveStreamTailMessage(msg, null), msg), isTrue);
    });

    test('多块 / 非文本块原样返回', () {
      final multi = Message.fromBlocks(
        id: 'msg_tail',
        role: 'assistant',
        blocks: <MessageBlock>[
          TextBlock(messageId: 'msg_tail', content: '壳'),
          TextBlock(messageId: 'msg_tail', content: '第二块'),
        ],
        createdAt: DateTime(2026, 1, 1),
        status: 'sending',
      );
      final audio = Message.fromBlocks(
        id: 'msg_tail',
        role: 'assistant',
        blocks: <MessageBlock>[
          AudioBlock(
            messageId: 'msg_tail',
            url: '',
            text: '语音',
            status: BlockStatus.pending,
          ),
        ],
        createdAt: DateTime(2026, 1, 1),
        status: 'sending',
      );
      final live = _proj(tailMessageId: 'msg_tail', tailText: '实时文本');
      expect(identical(resolveActiveStreamTailMessage(multi, live), multi),
          isTrue);
      expect(identical(resolveActiveStreamTailMessage(audio, live), audio),
          isTrue);
    });
  });
}
