import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/features/agent_context/domain/silly_tavern_macro_evaluator.dart';

void main() {
  const evaluator = SillyTavernMacroEvaluator();

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
