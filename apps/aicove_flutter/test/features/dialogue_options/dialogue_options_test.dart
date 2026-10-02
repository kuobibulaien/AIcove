import 'package:aicove_flutter/src/core/models/message_block.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/dialogue_options/domain/dialogue_options.dart';
import 'package:aicove_flutter/src/ui/features/chat/widgets/chat_message_list_items.dart';
import 'package:flutter_test/flutter_test.dart';

Message _assistant(String id, String content, {String? status}) =>
    Message.text(
      id: id,
      role: 'assistant',
      content: content,
      createdAt: DateTime(2026, 9, 29, 12),
    ).copyWith(status: status);

void main() {
  test('parses <option> children, ignoring surrounding text', () {
    expect(
      parseDialogueOptions(
        '她笑了。\n<OPTIONS>\n<option>😏 靠近一点</option>\n'
        '<option> 转身离开 </option>\n<option>😏 靠近一点</option>\n</options>',
      ),
      ['😏 靠近一点', '转身离开'],
    );
  });

  test('falls back to one option per line and strips list markers', () {
    expect(parseDialogueOptions('<options>\n1. 答应\n2、拒绝\n- 沉默\n\n</options>'), [
      '答应',
      '拒绝',
      '沉默',
    ]);
  });

  test('uses the last options block and ignores text without one', () {
    expect(parseDialogueOptions('没有选项 <option>x</option>'), isEmpty);
    expect(
      parseDialogueOptions('<options>旧</options>正文<options>新</options>'),
      ['新'],
    );
  });

  test('display copy removes options, including an unclosed tail', () {
    expect(
      stripDialogueOptions('正文。\n\n<options><option>a</option></options>'),
      '正文。',
    );
    expect(stripDialogueOptions('正文<options><option>a'), '正文');
    final raw = _assistant('m1', '正文<options>a</options>');
    final shown = stripDialogueOptionsForDisplay(raw);
    expect(shown.displayText, '正文');
    expect(raw.content, '正文<options>a</options>', reason: 'raw stays intact');
    final plain = _assistant('m2', '没有标签');
    expect(identical(stripDialogueOptionsForDisplay(plain), plain), isTrue);
  });

  test('strips options inside text blocks without touching other blocks', () {
    final message = Message.fromBlocks(
      id: 'm1',
      role: 'assistant',
      blocks: [
        TextBlock(messageId: 'm1', content: '你好<options>a\nb</options>'),
        ThinkingBlock(messageId: 'm1', content: '<options>保留</options>'),
      ],
      createdAt: DateTime(2026, 9, 29),
    );
    final shown = stripDialogueOptionsForDisplay(message).blocks!;
    expect((shown[0] as TextBlock).content, '你好');
    expect((shown[1] as ThinkingBlock).content, '<options>保留</options>');
  });

  test('latest options come from the trailing assistant turn only', () {
    final user = Message.text(
      id: 'u1',
      role: 'user',
      content: '在吗',
      createdAt: DateTime(2026, 9, 29),
    );
    final withOptions = _assistant('a1', '好的<options>去吃饭\n去散步</options>');
    final trailingMedia = _assistant('a2', '[图片]');
    expect(latestDialogueOptions([user, withOptions, trailingMedia])?.items, [
      '去吃饭',
      '去散步',
    ]);
    expect(latestDialogueOptions([withOptions, user]), isNull);
    expect(
      latestDialogueOptions([
        withOptions,
        _assistant('a3', '生成中', status: 'sending'),
      ]),
      isNull,
    );
    final a = latestDialogueOptions([withOptions])!;
    final b = latestDialogueOptions([_assistant('a1', '<options>换了</options>')])!;
    expect(a.signature, isNot(b.signature));
  });

  test('list items hide options and drop options-only segments', () {
    final items = buildChatMessageListItems(
      messages: [
        _assistant('a1', '正文<options>a</options>'),
        _assistant('a2', '<options>\n<option>a</option>\n</options>'),
      ],
    ).whereType<ChatMessageItem>().toList();
    expect(items.map((i) => i.message.id), ['a1']);
    expect(items.single.message.displayText, '正文');
  });

  test('preset option tags such as branches are parsed when mapped', () {
    const text = '正文<branches>A. 去吃饭\nB. 去散步</branches>';
    expect(parseDialogueOptions(text), isEmpty);
    expect(
      parseDialogueOptions(text, tags: {'options', 'branches'}),
      ['去吃饭', '去散步'],
    );
  });
}
