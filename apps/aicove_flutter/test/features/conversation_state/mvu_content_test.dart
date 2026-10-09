import 'package:aicove_flutter/src/features/agent_context/domain/silly_tavern_macro_evaluator.dart';
import 'package:aicove_flutter/src/features/agent_context/domain/silly_tavern_world_book.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/conversation_state/domain/mvu_content.dart';
import 'package:flutter_test/flutter_test.dart';

String evaluate(
  String source, {
  Map<String, Object?>? variables,
  List<String>? warnings,
}) => const SillyTavernMacroEvaluator()
    .evaluate(
      source,
      promptId: 'p',
      values: const {},
      variables: {},
      randomIndexPicker: (_) => 0,
      warnings: warnings ?? [],
      messageVariables: variables,
    )
    .text;

void main() {
  final vars = <String, Object?>{
    'stat_data': {
      '理': {
        '好感度': [15, '说明'],
        r'$hidden': 1,
        '地点': '教堂',
      },
    },
  };

  group('MVU 宏', () {
    test('字符串原样，其余 JSON，去掉 \$ 开头的键', () {
      expect(
        evaluate('{{get_message_variable::stat_data.理.地点}}', variables: vars),
        '教堂',
      );
      expect(
        evaluate('{{get_message_variable::stat_data.理}}', variables: vars),
        '{"好感度":[15,"说明"],"地点":"教堂"}',
      );
    });

    test('format_message_variable 输出 YAML', () {
      expect(
        evaluate('{{format_message_variable::stat_data.理}}', variables: vars),
        '好感度:\n  - 15\n  - "说明"\n地点: "教堂"',
      );
    });

    test('路径不存在替换为空并提示；MVU 未启用时原样保留', () {
      final warnings = <String>[];
      expect(
        evaluate(
          '[{{get_message_variable::stat_data.无}}]',
          variables: vars,
          warnings: warnings,
        ),
        '[]',
      );
      expect(warnings.single, contains('路径不存在'));
      expect(
        evaluate('{{get_message_variable::stat_data}}'),
        '{{get_message_variable::stat_data}}',
      );
    });

    test('不影响现有 setvar/getvar', () {
      expect(evaluate('{{setvar::a::1}}{{getvar::a}}', variables: vars), '1');
    });
  });

  test('历史清理只动 user/assistant，预设与世界书里的协议示例保留', () {
    final result = stripMvuUpdatesFromHistory([
      {
        'role': 'system',
        'content': '示例 <UpdateVariable>_.set(...)</UpdateVariable>',
      },
      {
        'role': 'assistant',
        'content': '正文<UpdateVariable>_.add("n", 1);</UpdateVariable>',
      },
      {
        'role': 'user',
        'content': [
          {'type': 'text', 'text': '看<JSONPatch>[]</JSONPatch>'},
        ],
      },
    ]);
    expect(result[0]['content'], contains('<UpdateVariable>'));
    expect(result[1]['content'], '正文');
    expect((result[2]['content'] as List).single['text'], '看');
  });

  test('显示副本隐藏更新块（含流式未闭合）；无更新块时返回同一实例', () {
    final message = Message(
      id: 'a',
      role: 'assistant',
      content: '她笑了。\n<UpdateVariable>_.add("n", 1',
      createdAt: DateTime(2026),
    );
    expect(stripMvuUpdatesForDisplay(message).content, '她笑了。');
    final plain = message.copyWith(content: '普通');
    expect(identical(stripMvuUpdatesForDisplay(plain), plain), isTrue);
  });

  test('JSONPatch 显示隐藏时字符串里的结束标签不提前截断', () {
    expect(
      stripMvuUpdateBlocks(
        '前<JSONPatch>[{"value":"</JSONPatch>"}]</JSONPatch>后',
      ),
      '前后',
    );
  });

  test('世界书跳过：InitVar 永不注入，EJS 跳过，MVU 关闭时跳过专属条目', () async {
    final book = TavernWorldBook.parse({
      'entries': {
        '0': {
          'uid': 0,
          'comment': '[InitVar]',
          'constant': true,
          'content': '{}',
        },
        '1': {
          'uid': 1,
          'comment': 'ejs',
          'constant': true,
          'content': '<% x %>',
        },
        '2': {
          'uid': 2,
          'comment': 'mvu',
          'constant': true,
          'content': '{{get_message_variable::stat_data}}',
        },
        '3': {'uid': 3, 'comment': '普通', 'constant': true, 'content': '普通'},
      },
    }, 'b.json');
    Future<List<String>> injected(bool active) async {
      final result = await const TavernWorldScanner().scan(
        books: [book],
        messages: const [
          {'role': 'user', 'content': 'hi'},
        ],
        tokenBudget: 2048,
        entrySkips: mvuWorldEntrySkips([book], mvuActive: active),
      );
      return [for (final i in result.injections) i.content];
    }

    expect(
      await injected(true),
      unorderedEquals(['{{get_message_variable::stat_data}}', '普通']),
    );
    expect(await injected(false), ['普通']);
  });
}
