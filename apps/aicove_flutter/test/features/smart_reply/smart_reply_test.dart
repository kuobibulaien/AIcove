import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/core/models/message_block.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/features/smart_reply/domain/smart_reply.dart';
import 'package:aicove_flutter/src/features/smart_reply/application/smart_reply_controller.dart';

Message message(
  String id,
  String text, {
  String role = 'assistant',
  List<MessageBlock>? blocks,
}) => Message(
  id: id,
  role: role,
  content: text,
  blocks: blocks,
  createdAt: DateTime(2026),
);

class FakePort implements SmartReplyPort {
  List<Message> messages = [message('1', '你好')];
  int calls = 0;
  Completer<List<String>>? pending;
  @override
  Future<SmartReplySnapshot> snapshot(String id) async =>
      SmartReplySnapshot(id, messages);
  @override
  Future<List<String>> generate(
    SmartReplySnapshot snapshot,
    String modelRef,
  ) async {
    calls++;
    return pending?.future ?? ['你好呀', '今天有点累', '想聊点轻松的'];
  }
}

void main() {
  test(
    'old settings default off; mapping and copies retain independent model',
    () {
      expect(mapUiModelsToAppSettings({}).smartReplyEnabled, isFalse);
      final settings = mapUiModelsToAppSettings({
        'smart_reply_enabled': true,
        'smart_reply_model': 'a:fast',
      }).copyWith(isDarkMode: true);
      expect(settings.smartReplyEnabled, isTrue);
      expect(settings.smartReplyModel, 'a:fast');
    },
  );
  test(
    'context has hard count and character bounds, preserving recent order',
    () {
      final raw = List.generate(30, (i) => message('$i', '你' * 2000));
      final result = buildSmartReplyContext(raw);
      expect(result.length, 5);
      expect(result.first.id, '25');
      expect(result.last.id, '29');
      expect(result.fold<int>(0, (n, m) => n + m.content.runes.length), 6000);
      expect(
        buildSmartReplyContext(
          List.generate(30, (i) => message('$i', '短句')),
        ).length,
        10,
      );
    },
  );
  test(
    'only text and speech transcripts survive; no raw payload or system',
    () {
      final result = buildSmartReplyContext([
        message('0', 'SYSTEM SECRET', role: 'system'),
        message('1', 'TOOL SECRET', role: 'tool'),
        message(
          '2',
          'RAW SECRET',
          blocks: [
            TextBlock(messageId: '2', content: 'hello'),
            ImageBlock(messageId: '2', url: 'https://secret.invalid/image'),
          ],
        ),
        message('3', '<think>SECRET</think><tts>晚安</tts>'),
      ]);
      expect(result.map((m) => m.content), ['hello', '晚安']);
      expect(
        result.every((m) => m.blocks == null && m.rawPayload == null),
        isTrue,
      );
    },
  );
  test('strict three distinct replies; malformed output remains an error', () {
    expect(parseSmartReplies('```json\n{"replies":["一","二","三"]}\n```'), [
      '一',
      '二',
      '三',
    ]);
    for (final value in [
      '{"replies":["一","一","三"]}',
      '{"replies":["一"]}',
      '{"replies":[1,2,3]}',
      'not json',
    ]) {
      expect(() => parseSmartReplies(value), throwsFormatException);
    }
  });
  test(
    'deduplicates inflight requests and caches by model and raw contents',
    () async {
      final port = FakePort()..pending = Completer<List<String>>();
      final controller = SmartReplyController(port, 'c1');
      final first = controller.load('a:fast');
      final second = controller.load('a:fast');
      await Future<void>.delayed(Duration.zero);
      expect(port.calls, 1);
      port.pending!.complete(['一', '二', '三']);
      await Future.wait([first, second]);
      await controller.load('a:fast');
      expect(port.calls, 1);
      port.messages = [message('1', '已编辑')];
      expect(await controller.isCurrent('a:fast'), isFalse);
      await controller.load('a:fast');
      await controller.load('b:fast');
      expect(port.calls, 3);
    },
  );
  test('late result cannot be used after conversation changed', () async {
    final port = FakePort()..pending = Completer<List<String>>();
    final controller = SmartReplyController(port, 'c1');
    final future = controller.load('a:fast');
    await Future<void>.delayed(Duration.zero);
    port.messages = [message('2', '新回复')];
    port.pending!.complete(['一', '二', '三']);
    await expectLater(future, throwsFormatException);
  });
  test('request is one user turn so providers never see an assistant tail', () {
    final request = buildSmartReplyRequest([
      message('1', '今天吃什么', role: 'user'),
      message('2', '火锅怎么样'),
    ]);
    expect(request.role, 'user');
    expect(request.content, '我：今天吃什么\n对方：火锅怎么样');
  });
}
