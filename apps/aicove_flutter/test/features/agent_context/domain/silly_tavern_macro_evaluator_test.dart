import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/features/agent_context/domain/silly_tavern_macro_evaluator.dart';

void main() {
  const evaluator = SillyTavernMacroEvaluator();

  test('can escape values and limit expansion to one pass', () {
    final result = evaluator.evaluate(
      r'^{{char}}$', promptId: 'test', values: {'char': 'a.b'}, variables: {},
      randomIndexPicker: (_) => 0, warnings: [], escapeMacroValues: true,
    );
    expect(result.text, r'^a\.b$');
    final once = evaluator.evaluate(
      '{{char}}', promptId: 'test', values: {'char': '{{user}}', 'user': 'A'},
      variables: {}, randomIndexPicker: (_) => 0, warnings: [], recursive: false,
    );
    expect(once.text, '{{user}}');
  });

  test('roll supports spaces and both colon separators', () {
    final result = evaluator.evaluate(
      '{{roll 1999999}}/{{roll 1d99999}}/{{roll::2d6+3}}/{{roll:1d20-2}}/{{roll::1001d6}}',
      promptId: 'roll', values: {}, variables: {},
      randomIndexPicker: (_) => 0, warnings: [],
    );
    expect(result.text, '1/1/5/-1/1001');
  });

  test('variable arithmetic updates subsequent reads', () {
    final variables = <String, String>{'score': '2'};
    final result = evaluator.evaluate(
      '{{incvar::score}}{{decvar::score}}{{addvar::score::3}}{{getvar::score}}',
      promptId: 'variables', values: {}, variables: variables,
      randomIndexPicker: (_) => 0, warnings: [],
    );
    expect(result.text, '5');
    expect(variables['score'], '5');
  });

  test('expands many flat macros without consuming the pass limit', () {
    final warnings = <String>[];
    final result = evaluator.evaluate(
      List.filled(1350, '{{random::A::B}}').join(),
      promptId: 'flat', values: {}, variables: {},
      randomIndexPicker: (_) => 0, warnings: warnings,
    );
    expect(result.text, 'A' * 1350);
    expect(warnings, isEmpty);
  });

  test('expands flat macros whose values contain a brace', () {
    final warnings = <String>[];
    final result = evaluator.evaluate(
      List.filled(257, '{{char}}').join(),
      promptId: 'braces', values: {'char': '{'}, variables: {},
      randomIndexPicker: (_) => 0, warnings: warnings,
    );
    expect(result.text, '{' * 257);
    expect(warnings, isEmpty);
  });

  test('stops self-expanding macros at the evaluation limit', () {
    final warnings = <String>[];
    final result = evaluator.evaluate(
      '{{getvar::a}}', promptId: 'loop', values: {},
      variables: {'a': '{{getvar::a}}'},
      randomIndexPicker: (_) => 0, warnings: warnings,
    );
    expect(result.text, '{{getvar::a}}');
    expect(warnings, contains(
      'loop 宏求值超过 ${SillyTavernMacroEvaluator.maxEvaluations} 次，已停止继续展开',
    ));
  });

  test('preserves side effect order around nested macros', () {
    final variables = <String, String>{'y': 'value', 'a': 'old'};
    final result = evaluator.evaluate(
      '{{setvar::x::{{getvar::y}}}}{{getvar::x}}'
      '{{setvar::a::{{getvar::a}}X}}{{getvar::a}}',
      promptId: 'order', values: {}, variables: variables,
      randomIndexPicker: (_) => 0, warnings: [],
    );
    expect(result.text, 'valueoldX');
    expect(variables['a'], 'oldX');
  });

  test('macros produced by a replacement run before later macros', () {
    final variables = <String, String>{'a': '{{setvar::x::新值}}', 'x': '旧值'};
    final result = evaluator.evaluate(
      '{{getvar::a}}{{getvar::x}}',
      promptId: 'generated', values: {}, variables: variables,
      randomIndexPicker: (_) => 0, warnings: [],
    );
    expect(result.text, '新值');
  });

  test('a single brace joining neighbouring text still keeps order', () {
    final variables = <String, String>{'a': '{', 'x': '旧值'};
    final result = evaluator.evaluate(
      '{{getvar::a}}{setvar::x::新值}}{{getvar::x}}',
      promptId: 'joined', values: {}, variables: variables,
      randomIndexPicker: (_) => 0, warnings: [],
    );
    expect(result.text, '新值');
  });

  test('expands large text without truncation', () {
    final warnings = <String>[];
    final result = evaluator.evaluate(
      '{{char}}{{char}}', promptId: 'large',
      values: {'char': 'x' * (2 * 1024 * 1024 + 1)},
      variables: {}, randomIndexPicker: (_) => 0, warnings: warnings,
    );
    expect(result.text.length, 2 * (2 * 1024 * 1024 + 1));
    expect(warnings, isEmpty);
  });

  test('evaluates nested random before setvar and getvar', () {
    final variables = <String, String>{};
    final warnings = <String>[];
    final result = evaluator.evaluate(
      '{{setvar::key::{{random::A::B}}{{random::1::2}}}}key={{getvar::key}}',
      promptId: 'main',
      values: const <String, String>{},
      variables: variables,
      randomIndexPicker: (_) => 0,
      warnings: warnings,
    );

    expect(result.text, 'key=A1');
    expect(variables, <String, String>{'key': 'A1'});
    expect(
      result.appliedMacros,
      containsAll(<String>['random', 'setvar', 'getvar']),
    );
    expect(warnings, isEmpty);
  });

  test('removes comments and trim with surrounding newlines', () {
    final result = evaluator.evaluate(
      'before\n{{// comment}}\n{{trim}}\nafter',
      promptId: 'main',
      values: const <String, String>{},
      variables: <String, String>{},
      randomIndexPicker: (_) => 0,
      warnings: <String>[],
    );

    expect(result.text, 'beforeafter');
    expect(result.appliedMacros, containsAll(<String>['//', 'trim']));
  });

  test('expands runtime values case-insensitively', () {
    final result = evaluator.evaluate(
      '{{CHAR}}/{{user}}/{{lastUserMessage}}',
      promptId: 'main',
      values: const <String, String>{
        'char': 'Alice',
        'user': 'Yun',
        'lastusermessage': 'hello',
      },
      variables: <String, String>{},
      randomIndexPicker: (_) => 0,
      warnings: <String>[],
    );

    expect(result.text, 'Alice/Yun/hello');
  });

  test('preserves unknown macros with one warning per macro name', () {
    final warnings = <String>[];
    final result = evaluator.evaluate(
      '{{future::1}} {{future::2}}',
      promptId: 'main',
      values: const <String, String>{},
      variables: <String, String>{},
      randomIndexPicker: (_) => 0,
      warnings: warnings,
    );

    expect(result.text, '{{future::1}} {{future::2}}');
    expect(result.unknownMacros, <String>{'future'});
    expect(warnings, hasLength(1));
  });
}
