import 'package:aicove_flutter/src/features/ui_blocks/domain/ui_block.dart';
import 'package:aicove_flutter/src/features/ui_blocks/domain/ui_expression.dart';
import 'package:aicove_flutter/src/features/ui_blocks/domain/ui_json.dart';
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

    test('rejects unfinished and over-deep input', () {
      expect(() => readLenientJson('{"a": [1, 2'), throwsFormatException);
      expect(() => readLenientJson('[' * 70 + ']' * 70), throwsFormatException);
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
      expect(UiTemplate.compile('{{literal}}'), isNull);
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
