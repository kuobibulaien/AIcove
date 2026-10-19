import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/task_agent/domain/task_relay.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final t0 = DateTime(2026, 10, 17, 9);

  Message msg(String id, int seconds, [String? receiptId]) => Message.text(
    id: id,
    role: 'assistant',
    content: id,
    createdAt: t0.add(Duration(seconds: seconds)),
  ).copyWith(
    rawPayload: receiptId == null ? null : {taskRelayReceiptKey: receiptId},
  );

  test('请求副本按回执只留最早的转告，同时间按消息 ID', () {
    final history = [
      msg('user_1', 0),
      msg('relay_b', 2, 'r1'),
      msg('relay_a', 1, 'r1'),
      msg('relay_y', 3, 'r2'),
      msg('relay_x', 3, 'r2'),
      msg('relay_c', 4, 'r3'),
    ];
    expect(dropSupersededTaskRelays(history).map((m) => m.id), [
      'user_1',
      'relay_a',
      'relay_x',
      'relay_c',
    ]);
  });

  test('没有重复时原样返回', () {
    final history = [msg('user_1', 0), msg('relay_a', 1, 'r1')];
    expect(identical(dropSupersededTaskRelays(history), history), isTrue);
  });

  test('从编码后的载荷读出回执 ID', () {
    expect(
      taskRelayReceiptIdFromEncoded('{"version":1,"taskRelayReceiptId":"r9"}'),
      'r9',
    );
    expect(taskRelayReceiptIdFromEncoded('{"taskRelayReceiptId":null}'), null);
    expect(taskRelayReceiptIdFromEncoded(null), null);
  });
}
