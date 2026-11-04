import 'package:aicove_flutter/src/core/models/message_block.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/content_tags/domain/tag_presentation.dart';
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

List<String> _texts(
  String text, {
  Set<String> tags = defaultDialogueOptionTags,
  Set<String> foldTags = const {},
}) => [
  for (final option in parseDialogueOptions(text, tags: tags, foldTags: foldTags))
    option.text,
];

void main() {
  test('parses <option> children, ignoring surrounding text', () {
    expect(
      _texts(
        '她笑了。\n<OPTIONS>\n<option>😏 靠近一点</option>\n'
        '<option> 转身离开 </option>\n<option>😏 靠近一点</option>\n</options>',
      ),
      ['😏 靠近一点', '转身离开'],
    );
  });

  test('falls back to one option per line and strips list markers', () {
    expect(_texts('<options>\n1. 答应\n2、拒绝\n- 沉默\n\n</options>'), [
      '答应',
      '拒绝',
      '沉默',
    ]);
  });

  test('uses the last options block and ignores text without one', () {
    expect(_texts('没有选项 <option>x</option>'), isEmpty);
    expect(
      _texts('<options>旧</options>正文<options>新</options>'),
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
    expect(
      latestDialogueOptions([
        user,
        withOptions,
        trailingMedia,
      ])?.items.map((item) => item.text),
      ['去吃饭', '去散步'],
    );
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

  test('bold category prefixes become labels and placeholders are dropped', () {
    const text =
        '<wave_options>\n1. **稳步推进**：先把门锁好\n'
        '2. **积极行动：** 追上去问清楚\n'
        '3. **出奇制胜**——躲进柜子\n'
        '4. **暧昧挑逗**：本场景不适用\n'
        '5. **彻底发癫**：不适用。\n'
        '6. **整句加粗的选项**\n</wave_options>';
    expect(parseDialogueOptions(text, tags: {'wave_options'}), const [
      DialogueOption('先把门锁好', label: '稳步推进'),
      DialogueOption('追上去问清楚', label: '积极行动'),
      DialogueOption('躲进柜子', label: '出奇制胜'),
      DialogueOption('**整句加粗的选项**'),
    ]);
    expect(
      const DialogueOption('先把门锁好', label: '稳步推进').display,
      '稳步推进：先把门锁好',
    );
  });

  test('unnumbered bold options keep their asterisks intact', () {
    expect(
      parseDialogueOptions('<options>**稳步推进**：行动\n**整句加粗**\n* 普通项</options>'),
      const [
        DialogueOption('行动', label: '稳步推进'),
        DialogueOption('**整句加粗**'),
        DialogueOption('普通项'),
      ],
    );
  });

  test('a single line using literal \\n separators is split', () {
    expect(
      _texts(r'<options>1. 答应\n2. 拒绝\n3. 沉默</options>'),
      ['答应', '拒绝', '沉默'],
    );
  });

  test('signature depends on option text, not labels', () {
    const a = DialogueOptions(
      messageId: 'a1',
      items: [DialogueOption('走', label: '稳步推进')],
    );
    const b = DialogueOptions(messageId: 'a1', items: [DialogueOption('走')]);
    expect(a.signature, b.signature);
  });

  test('preset option tags such as branches are parsed when mapped', () {
    const text = '正文<branches>A. 去吃饭\nB. 去散步</branches>';
    expect(_texts(text), isEmpty);
    expect(
      _texts(text, tags: {'options', 'branches'}),
      ['去吃饭', '去散步'],
    );
  });

  group('code and fold boundaries', () {
    test('backticked and fenced tags are never options', () {
      const inline = '用 `<options>a</options>` 写选项';
      expect(_texts(inline), isEmpty);
      expect(stripDialogueOptions(inline), inline);
      const fenced = '示例：\n```\n<options>a</options>\n```\n结束';
      expect(_texts(fenced), isEmpty);
      expect(stripDialogueOptions(fenced), fenced);
      expect(
        _texts('`<options>x</options>`<options>真的</options>'),
        ['真的'],
      );
      expect(
        _texts('<options><option>写 `<b>` 标签</option></options>'),
        ['写 `<b>` 标签'],
      );
      expect(
        stripDialogueOptions('`<options>` 留下<options>a</options>'),
        '`<options>` 留下',
      );
    });

    test('options written inside a fold stay inside it', () {
      const nya = '<think_nya>要写 <options> 吗</think_nya>正文';
      expect(stripDialogueOptions(nya), nya);
      expect(_texts(nya), isEmpty);
      const nyaTilde = '<think_nya~><options>假</options></think_nya~>正文';
      expect(_texts(nyaTilde), isEmpty);
      expect(stripDialogueOptions(nyaTilde), nyaTilde);
      const think = '<think><options>假</options></think>正文<options>真</options>';
      expect(_texts(think), ['真']);
      expect(
        stripDialogueOptions(think),
        '<think><options>假</options></think>正文',
      );
    });

    test('an unclosed fold still wraps options written after it', () {
      const text = '<think><options><option>离开</option></options>';
      expect(_texts(text), isEmpty);
      expect(stripDialogueOptions(text), text);
      const custom = '<tuiyan>推演<options>假</options>';
      expect(_texts(custom, foldTags: {'tuiyan'}), isEmpty);
      expect(stripDialogueOptions(custom, foldTags: {'tuiyan'}), custom);
    });

    test('caller fold tags wrap options; option tags win a name clash', () {
      const text = '<tuiyan><options>假</options></tuiyan>正文';
      expect(_texts(text), ['假']);
      expect(_texts(text, foldTags: {'tuiyan'}), isEmpty);
      expect(stripDialogueOptions(text, foldTags: {'tuiyan'}), text);
      expect(
        _texts('<details>甲\n乙</details>', tags: {'details'}),
        ['甲', '乙'],
      );
    });

    test('only closed tags produce clickable options', () {
      expect(_texts('正文<options><option>a</option>'), isEmpty);
      expect(_texts('<options><option>a</options>'), isEmpty);
      expect(
        _texts('<options><option>a</option><option>b</options>'),
        ['a'],
      );
    });

    test('unclosed tail is cut only while the reply is being generated', () {
      const text = '正文<options><option>a';
      expect(stripDialogueOptions(text, allowUnclosedTail: false), text);
      expect(
        stripDialogueOptions('前<options>a</options>后', allowUnclosedTail: false),
        '前后',
      );
      expect(
        stripDialogueOptionsForDisplay(
          _assistant('a', text, status: 'sending'),
        ).displayText,
        '正文',
      );
      expect(
        stripDialogueOptionsForDisplay(_assistant('b', text)).displayText,
        text,
      );
    });

    test('display copy reads option and fold tags from the presentation map', () {
      const map = {
        'branches': TagPresentationEntry(TagPresentation.options, '选项'),
        'tuiyan': TagPresentationEntry(TagPresentation.fold, '推演'),
      };
      final shown = stripDialogueOptionsForDisplay(
        _assistant(
          'a',
          '<tuiyan><branches>假</branches></tuiyan>正文<branches>真</branches>',
        ),
        tagPresentation: map,
      );
      expect(shown.displayText, '<tuiyan><branches>假</branches></tuiyan>正文');
    });

    test('a finished unclosed tail stays visible through the list items', () {
      const map = {
        'options': TagPresentationEntry(TagPresentation.options, '选项'),
      };
      final items = buildChatMessageListItems(
        messages: [_assistant('a', '正文<options>半截')],
        tagPresentation: map,
      ).whereType<ChatMessageItem>().toList();
      expect(items.single.message.displayText, contains('半截'));
    });
  });
}
