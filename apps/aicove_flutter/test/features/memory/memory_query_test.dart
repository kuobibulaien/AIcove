import 'dart:collection';

import 'package:aicove_flutter/src/core/models/message_block.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/memory/application/memory_retrieval.dart';
import 'package:flutter_test/flutter_test.dart';

Message _message(String id, String text, {String role = 'user'}) =>
    Message(id: id, role: role, content: text, createdAt: DateTime(2026));

class _ReadTrackingMessages extends ListBase<Message> {
  _ReadTrackingMessages(this.messages);

  final List<Message> messages;
  final reads = <int>[];

  @override
  int get length => messages.length;

  @override
  set length(int value) => throw UnsupportedError('Read-only history');

  @override
  Message operator [](int index) {
    reads.add(index);
    return messages[index];
  }

  @override
  void operator []=(int index, Message value) =>
      throw UnsupportedError('Read-only history');
}

void main() {
  test('assistant 检索使用 rawReplyText，不使用展示正文或 blocks', () {
    final assistant = _message('a', '展示替换污染', role: 'assistant').copyWith(
      rawPayload: {'rawReplyText': '我们去海边看日落'},
      blocks: [TextBlock(messageId: 'a', content: '气泡污染')],
    );
    expect(buildMemoryQuery([assistant], ''), '我们去海边看日落');
  });

  test('剔除思考与插件载荷，保留普通对话和 TTS 口语正文', () {
    final assistant = _message(
      'a',
      '<think reason="x">隐藏推理</think>海边很好看。'
          '<image source="history">图片描述污染</image>'
          '<sticker>表情资源污染</sticker>'
          '<tts>下次还一起去。</tts><scene>普通角色对话</scene>',
      role: 'assistant',
    );
    expect(
      buildMemoryQuery([assistant], ''),
      '海边很好看。下次还一起去。<scene>普通角色对话</scene>',
    );
  });

  test('过滤注入及无效角色后，再取最近四条有效对话', () {
    final history = [
      _message('old', '不应保留'),
      for (var i = 0; i < 4; i++) _message('u$i', '对话$i'),
      _message('system_reminder_1', '自动提醒污染'),
      _message('system', '系统污染', role: 'system'),
      _message('tool', '工具污染', role: 'tool'),
      _message('empty', '<think>仅有思考</think>', role: 'assistant'),
    ];
    expect(buildMemoryQuery(history, ''), '对话0\n对话1\n对话2\n对话3');
  });

  test('rawReplyText 为空时不回退展示，旧消息仍兼容 content', () {
    expect(
      buildMemoryQuery([
        _message('legacy', '旧版普通对话', role: 'assistant'),
        _message(
          'a',
          '展示污染',
          role: 'assistant',
        ).copyWith(rawPayload: {'rawReplyText': ''}),
      ], ''),
      '旧版普通对话',
    );
  });

  test('从末尾扫描，收齐四条非空有效消息即停止读取旧历史', () {
    final history = _ReadTrackingMessages([
      for (var i = 0; i < 100; i++) _message('old$i', '旧历史$i'),
      _message('u0', '第一条'),
      _message('failed', '失败污染').copyWith(status: 'failed'),
      _message('u1', '第二条'),
      _message('empty', '<think>不计入条数</think>'),
      _message('u2', '第三条'),
      _message('sending', '发送中污染').copyWith(status: 'sending'),
      _message('u3', '第四条'),
    ]);

    expect(buildMemoryQuery(history, '本轮'), '第一条\n第二条\n第三条\n第四条\n本轮');
    expect(history.reads, [106, 105, 104, 103, 102, 101, 100]);
  });

  test('本轮去标签后与末条相同不重复，空输入不追加', () {
    final history = [_message('a', '  海边  ')];
    expect(buildMemoryQuery(history, '<tts>海边</tts>'), '海边');
    expect(buildMemoryQuery(history, '<think>隐藏</think>'), '海边');
    expect(buildMemoryQuery([], '  本轮  '), '本轮');
    expect(buildMemoryQuery([], ''), '');
  });

  test('按时间顺序拼接后只保留末尾400字', () {
    final first = List.filled(300, '甲').join();
    final current = List.filled(300, '乙').join();
    final joined = '$first\n$current';
    expect(
      buildMemoryQuery([_message('a', first)], current),
      joined.substring(joined.length - 400),
    );
  });
}
