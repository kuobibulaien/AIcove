import 'package:aicove_flutter/src/features/ui_blocks/domain/ui_block.dart';
import 'package:aicove_flutter/src/features/ui_blocks/domain/ui_expression.dart';
import 'package:aicove_flutter/src/features/ui_blocks/domain/ui_json.dart';
import 'package:aicove_flutter/src/features/ui_blocks/domain/ui_lines.dart';
import 'package:aicove_flutter/src/features/ui_blocks/domain/ui_template.dart';
import 'package:flutter_test/flutter_test.dart';

Object? eval(String source, [Map<String, Object?> scope = const {}]) =>
    UiExpression.parse(source).evaluate(scope);

void main() {
  group('lenient JSON', () {
    test('accepts trailing commas, comments and bare keys', () {
      expect(
        readLenientJson('{"a": [1, 2,], // note\n /* x */ b: "t",}'),
        {'a': [1, 2], 'b': 't'},
      );
    });

    test('keeps unescaped quotes inside text', () {
      expect(
        readLenientJson('{"text": "点"保存"按钮", "n": 1}'),
        {'text': '点"保存"按钮', 'n': 1},
      );
    });

    test('reads raw line breaks and escapes', () {
      expect(readLenientJson('{"t": "a\nb\\u4e2d"}'), {'t': 'a\nb中'});
    });

    test('closes objects and arrays left open at the end', () {
      expect(readLenientJson('{"a": [1, 2'), {'a': [1, 2]});
      expect(
        readLenientJson('{"component": "form", "fields": [\n'
            '  {"key": "a", "options": ["x", "y"]},\n'
            '  {"key": "b", "options": ["z"]}'),
        {
          'component': 'form',
          'fields': [
            {'key': 'a', 'options': ['x', 'y']},
            {'key': 'b', 'options': ['z']},
          ],
        },
      );
    });

    test('rejects cut-off values and over-deep input', () {
      expect(() => readLenientJson('{"a": "unfinished'), throwsFormatException);
      expect(() => readLenientJson('{"a": '), throwsFormatException);
      expect(() => readLenientJson('[' * 70 + ']' * 70), throwsFormatException);
    });
  });

  group('line syntax', () {
    test('form: types, options, placeholders and flags', () {
      expect(
        readUiLines('''
form rr-config
# 要我改哪些
@submit: 就这样改
改到什么程度 | 单选 | 除 Key 以外全配好 / 先别改 | 必填
接口地址 | 文字 | 例：https://api.deepseek.com
模型 | deepseek-flash
顺带要的 | 多选 | 中文界面/深色主题 | 无其他
'''),
        {
          'component': 'form',
          'id': 'rr-config',
          'title': '要我改哪些',
          'submit': '就这样改',
          'fields': [
            {'key': '改到什么程度', 'label': '改到什么程度', 'type': 'select', 'options': ['除 Key 以外全配好', '先别改'], 'required': true},
            {'key': '接口地址', 'label': '接口地址', 'type': 'text', 'placeholder': '例：https://api.deepseek.com'},
            {'key': '模型', 'label': '模型', 'type': 'text', 'placeholder': 'deepseek-flash'},
            {'key': '顺带要的', 'label': '顺带要的', 'type': 'multiselect', 'options': ['中文界面', '深色主题'], 'other': false},
          ],
        },
      );
    });

    test('checklist and steps ignore list markers and take notes', () {
      expect(readUiLines('checklist\n- 选音色 | 决定声音\n2. 填 Key\n> 在渠道页')['items'], [
        {'text': '选音色', 'note': '决定声音'},
        {'text': '填 Key', 'note': '在渠道页'},
      ]);
      expect(readUiLines('steps s\n打开平台 | 注册登录\n创建 Key')['items'], [
        {'title': '打开平台', 'text': '注册登录'},
        {'title': '创建 Key'},
      ]);
    });

    test('decision-tree nodes, arrows and details', () {
      expect(
        readUiLines('''
decision-tree t
[q1] 开了绘图吗？ | other=false
> 角色编辑页
- 开了 -> done
- 没开 → [fix]
[fix] 去打开
[done] 没问题
''')['nodes'],
        [
          {
            'id': 'q1',
            'text': '开了绘图吗？',
            'other': false,
            'detail': '角色编辑页',
            'options': [
              {'label': '开了', 'next': 'done'},
              {'label': '没开', 'next': 'fix'},
            ],
          },
          {'id': 'fix', 'text': '去打开'},
          {'id': 'done', 'text': '没问题'},
        ],
      );
    });

    test('quiz marks the right answer', () {
      expect(readUiLines('quiz\n? 窗口满了？\n- 报错\n- 压缩 ✓\n> 会摘要\n？Key 发哪？\n- 卡片（对）\n- 聊天')['questions'], [
        {'question': '窗口满了？', 'options': ['报错', '压缩'], 'answer': 1, 'explanation': '会摘要'},
        {'question': 'Key 发哪？', 'options': ['卡片', '聊天'], 'answer': 0},
      ]);
    });

    test('stat-grid columns and attributes', () {
      expect(readUiLines('stat-grid\n记录 | 18,400 | token | -2,100 | 压缩后 | tone=positive\n占比 | 33%')['items'], [
        {'label': '记录', 'value': '18,400', 'unit': 'token', 'delta': '-2,100', 'note': '压缩后', 'tone': 'positive'},
        {'label': '占比', 'value': '33%'},
      ]);
    });

    test('data-table detects number columns and drops Markdown rules', () {
      final table = readUiLines('data-table\n@pageSize: 5\n| 角色 | 插件数 |\n|---|---|\n| 小雪 | 4 |\n| 阿澈 | 1,200 |');
      expect(table['pageSize'], 5);
      expect(table['columns'], [
        {'key': 'c0', 'label': '角色'},
        {'key': 'c1', 'label': '插件数', 'type': 'number'},
      ]);
      expect(table['rows'], [
        {'c0': '小雪', 'c1': 4},
        {'c0': '阿澈', 'c1': 1200},
      ]);
    });

    test('line blocks compile cleanly; JSON still parses', () {
      for (final raw in [
        'checklist a\n一\n二',
        'form b\n名字 | 文字 | 小雪 | 必填\n性别 | 单选 | 女 / 男',
        'decision-tree c\n[q] 问？\n- 是 -> y\n[y] 好',
        'quiz d\n? 问\n- 甲 ✓\n- 乙',
        'stat-grid e\n条数 | 3',
        'data-table f\n名 | 数\n甲 | 1',
        '{"component": "checklist", "id": "g", "items": ["一"]}',
      ]) {
        final parsed = UiBlock.parse(raw);
        expect(parsed.error, isNull, reason: raw);
        expect(UiProgram.compile(parsed.block!).issues, isEmpty, reason: raw);
      }
      expect(UiBlock.parse('form rr\n名字').block!.key, 'rr');
    });
  });

  group('expression', () {
    test('precedence and power', () {
      expect(eval('1 + 2 * 3'), 7);
      expect(eval('-2^2'), -4);
      expect(eval('2^3^2'), 512);
      expect(eval('(1 + 2) * 3 % 4'), 1);
    });

    test('logic, comparison and text', () {
      expect(eval('a > 1 && b == "x"', {'a': 2, 'b': 'x'}), true);
      expect(eval('a === 1 ? "one" : "other"', {'a': 1}), 'one');
      expect(eval('"共 " + n + " 年"', {'n': 30}), '共 30 年');
      expect(eval('!0'), true);
    });

    test('members and lists', () {
      final scope = {
        'rows': [
          {'name': 'a', 'v': 3},
          {'name': 'b', 'v': 5},
        ],
      };
      expect(eval('rows[1].v', scope), 5);
      expect(eval('rows.length', scope), 2);
      expect(eval('sum([1, 2, 3])'), 6);
      expect(eval('range(1, 5)'), [1, 2, 3, 4, 5]);
      expect(eval('range(0, 1, 0.1)').toString(), contains('0.3'));
      expect(eval('contains([1, 2], 2)'), true);
      expect(eval('max([4, 9, 2])'), 9);
      expect(eval('round(3.14159, 2)'), 3.14);
      expect(eval('fixed(2, 1)'), '2.0');
    });

    test('rejects unsafe or runaway formulas', () {
      expect(() => eval('a.constructor', {'a': <String, Object?>{}}),
          throwsA(isA<UiExpressionError>()));
      expect(() => eval('x = 1'), throwsA(isA<UiExpressionError>()));
      expect(() => eval('alert(1)'), throwsA(isA<UiExpressionError>()));
      expect(() => eval('range(1, 5000)'), throwsA(isA<UiExpressionError>()));
      expect(() => eval('missing + 1'), throwsA(isA<UiExpressionError>()));
      expect(() => eval('a' * 600), throwsA(isA<UiExpressionError>()));
    });

    test('formats numbers with grouping', () {
      expect(uiFormatNumber(1234567.891), '1,234,567.89');
      expect(uiFormatNumber(-0.001), '0');
      expect(uiFormatNumber(double.nan), '—');
    });
  });

  group('template', () {
    test('single hole keeps its type, mixed text formats', () {
      final scope = {'a': 1234.5, 'list': [1, 2]};
      expect(UiTemplate.compile('{a}')!.evaluate(scope, UiBudget()), 1234.5);
      expect(UiTemplate.compile('{list}')!.evaluate(scope, UiBudget()), [1, 2]);
      expect(UiTemplate.compile('共 {a} 元')!.evaluate(scope, UiBudget()), '共 1,234.5 元');
      expect(UiTemplate.compile('坏 {nope} 了')!.evaluate(scope, UiBudget()), '坏 — 了');
      expect(UiTemplate.compile('{{literal}}'), isNull); // plain text; the block decodes it
      expect(UiTemplate.compile('plain'), isNull);
    });
  });

  group('block', () {
    const loan = '''
{"component": "panel", "id": "loan", "title": "房贷计算器",
 "state": {"amount": 100, "years": 30},
 "computed": {"monthly": "amount * 10000 * r * (1+r)^n / ((1+r)^n - 1)",
              "r": "3.5 / 1200", "n": "years * 12"},
 "children": [
   {"component": "slider", "bind": "amount", "label": "贷款金额（万）", "min": 10, "max": 500},
   {"component": "select", "value": "{plan}", "options": ["等额本息", "等额本金"]},
   {"component": "stat", "label": "每月还款", "value": "{round(monthly)}", "unit": "元"},
   {"component": "callout", "text": "超过 30 年", "visible": "{years > 30}"},
   {"component": "button", "ask": "按 {amount} 万、{years} 年，列出还款计划"}
 ]}''';

    test('parses id, key, title and children', () {
      final block = UiBlock.parse(loan).block!;
      expect(block.id, 'loan');
      expect(block.key, 'loan');
      expect(block.title, '房贷计算器');
      expect(block.live, isTrue);
      expect(block.root.children.map((c) => c.component),
          ['slider', 'select', 'stat', 'callout', 'button']);
    });

    test('computed in dependency order, implicit state and visibility', () {
      final program = UiProgram.compile(UiBlock.parse(loan).block!);
      expect(program.issues, isEmpty);
      expect(program.initialState['plan'], '等额本息');
      final node = program.resolve(const {});
      final stat = node.children.firstWhere((c) => c.component == 'stat');
      expect(stat.props['value'], 4490);
      expect(node.children.any((c) => c.component == 'callout'), isFalse);
      expect(node.children.last.props['ask'], '按 100 万、30 年，列出还款计划');

      final longer = program.resolve({'years': 35});
      expect(longer.children.any((c) => c.component == 'callout'), isTrue);
      expect(longer.children.first.props['value'], 100);
    });

    test('static blocks pass braces through; ids fall back to a hash', () {
      final block = UiBlock.parse(
              '{"component": "checklist", "id": "bad id!", "items": ["写 {不是公式}"]}')
          .block!;
      expect(block.live, isFalse);
      expect(block.key, startsWith('auto-'));
      final node = UiProgram.compile(block).resolve(const {});
      expect(node.list('items'), ['写 {不是公式}']);
    });

    test('cycles and bad formulas degrade without throwing', () {
      final program = UiProgram.compile(UiBlock.parse(
              '{"component": "panel", "computed": {"a": "b + 1", "b": "a + 1", "c": "1 +"},'
              ' "children": [{"component": "stat", "value": "{a}"}, {"component": "text", "text": "c={c}"}]}')
          .block!);
      expect(program.issues, isNotEmpty);
      final node = program.resolve(const {});
      expect(node.children.first.props['value'], isNull);
      expect(node.children.last.props['text'], 'c=—');
    });

    test('rejects text that is not a block', () {
      expect(UiBlock.parse('[1, 2]').error, isNotNull);
      expect(UiBlock.parse('{"title": "x"}').error, isNotNull);
      expect(UiBlock.parse('{"component": ').error, isNotNull);
    });

    test('state diff and restore keep only valid changes', () {
      const initial = {'a': 1, 'b': 'x', 'c': true};
      expect(uiStateDiff(initial, {'a': 1, 'b': 'y', 'c': true}), {'b': 'y'});
      expect(
        uiRestoreState(initial, {'a': 'oops', 'b': 'z', 'gone': 1}),
        {'a': 1, 'b': 'z', 'c': true},
      );
    });
  });
}
