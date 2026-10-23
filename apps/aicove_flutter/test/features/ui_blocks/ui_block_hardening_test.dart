import 'dart:convert';
import 'dart:io';

import 'package:aicove_flutter/src/features/ui_blocks/application/ui_block_state_store.dart';
import 'package:aicove_flutter/src/features/ui_blocks/domain/ui_block.dart';
import 'package:aicove_flutter/src/features/ui_blocks/domain/ui_block_catalog.dart';
import 'package:aicove_flutter/src/features/ui_blocks/domain/ui_expression.dart';
import 'package:aicove_flutter/src/features/ui_blocks/domain/ui_json.dart';
import 'package:aicove_flutter/src/features/ui_blocks/domain/ui_saved_state.dart';
import 'package:aicove_flutter/src/features/ui_blocks/domain/ui_state_context.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Hostile and broken input found in review: none of it may throw anything
/// but a formula error, exhaust memory, or report what the user cannot see.
Object? eval(String source, [Map<String, Object?> scope = const {}]) =>
    UiExpression.parse(source).evaluate(scope, UiBudget());

UiNode resolve(String raw, [Map<String, Object?> state = const {}]) =>
    UiProgram.compile(UiBlock.parse(raw).block!).resolve(state);

void main() {
  group('formula limits', () {
    test('doubling text through computed stops at the text limit', () {
      final computed = {'c1': 's+s', for (var i = 2; i <= 40; i++) 'c$i': 'c${i - 1}+c${i - 1}'};
      final node = resolve(jsonEncode({
        'component': 'panel',
        'state': {'s': 'x'},
        'computed': computed,
        'children': [
          {'component': 'text', 'text': '{c40}'},
        ],
      }));
      expect(node.children.single.props['text'], isNull); // an error, not 1 TiB
    });

    test('nesting a list in itself is charged by its full size', () {
      final computed = {'l1': '[s, s]', for (var i = 2; i <= 40; i++) 'l$i': '[l${i - 1}, l${i - 1}]'};
      final node = resolve(jsonEncode({
        'component': 'panel',
        'state': {'s': 1},
        'computed': computed,
        'children': [
          {'component': 'text', 'text': '共 {l40}'},
        ],
      }));
      expect(node.children.single.props['text'], '共 —');
    });

    test('non-finite numbers raise formula errors', () {
      expect(eval('round(1/0)'), double.infinity);
      expect(() => eval('round(1, 1/0)'), throwsA(isA<UiExpressionError>()));
      expect(() => eval('range(0, 1, 1e-320)'), throwsA(isA<UiExpressionError>()));
      expect(() => eval('[1, 2][1/0]'), throwsA(isA<UiExpressionError>()));
      expect(eval('fixed(1/0)'), '—');
      expect(uiFormatNumber(1e308), isNotEmpty);
    });

    test('JSON rejects numbers out of range', () {
      expect(() => readLenientJson('{"a": 1e999}'), throwsFormatException);
      expect(UiBlock.parse('{"component": "steps", "n": 1e999}').error, isNotNull);
    });

    test('non-finite props read as missing numbers', () {
      final node = resolve('{"component": "panel", "children": [{"component": "grid", "columns": "{1/0}"}]}');
      expect(node.children.single.number('columns'), isNull);
      expect(uiJsonSafe({'a': double.infinity, 'b': [double.nan, 1]}), {'a': null, 'b': [null, 1]});
    });
  });

  test('long text leaves nested in lists are paid for before printing', () {
    final computed = {'l1': '[s, s]', for (var i = 2; i <= 15; i++) 'l$i': '[l${i - 1}, l${i - 1}]'};
    final node = resolve(jsonEncode({
      'component': 'panel',
      'state': {'s': 'x' * 10000},
      'computed': computed,
      'children': [
        {'component': 'text', 'text': '{l15}'},
      ],
    }));
    expect(node.children.single.props['text'], isNull);
  });

  test('object leaves are paid for too, and printing is capped', () {
    final computed = {'l1': '[s, s]', for (var i = 2; i <= 15; i++) 'l$i': '[l${i - 1}, l${i - 1}]'};
    final node = resolve(jsonEncode({
      'component': 'panel',
      'state': {
        's': {'v': 'x' * 10000},
      },
      'computed': computed,
      'children': [
        {'component': 'text', 'text': '{l15}'},
      ],
    }));
    expect(node.children.single.props['text'], isNull);
    final printed = uiStringify(List.filled(5000, 'abcdefghij'));
    expect(printed.length, kUiPrintMaxLength + 1);
    expect(printed, endsWith('…'));
  });

  test('failed formulas and non-finite numbers print safely', () {
    expect(uiStringify(const UiExpressionError('x')), '—');
    expect(uiStringify([const UiExpressionError('x'), 1]), '—, 1');
    expect(uiEditText(double.infinity), '');
    expect(uiEditText(double.nan), '');
    final node = resolve('{"component": "panel", "computed": {"x": "missing"}, "children": [{"component": "input", "bind": "x"}]}');
    expect(node.children.single.props['value'], isNull);
  });

  test('crossed cycles mark every member', () {
    final node = resolve(
      '{"component": "panel", "computed": {"a": "b + c", "b": "a", "c": "true ? 2 : b", "d": 5}, '
      '"children": [{"component": "text", "text": "{a}|{b}|{c}|{d}"}]}',
    );
    expect(node.children.single.props['text'], '—|—|—|5');
  });

  group('saved state cleaning', () {
    UiBlock block(String raw) => UiBlock.parse(raw).block!;

    test('each component keeps only what its block accepts', () {
      expect(uiCleanSavedState(block('{"component": "panel", "state": {"n": 1}, "children": []}'), {'n': 'oops', 'gone': 1}), isEmpty);
      expect(uiCleanSavedState(block('{"component": "checklist", "items": ["a", "b"]}'), {'done': [1, 5, -1, 1.5]}), {'done': [1]});
      expect(uiCleanSavedState(block('{"component": "steps", "items": [{"title": "a"}, {"title": "b"}]}'), {'step': 9}), isEmpty);
      const tree = '{"component": "decision-tree", "nodes": [{"id": "a", "text": "?", "options": [{"label": "x", "next": "b"}]}, '
          '{"id": "b", "text": "!"}, {"id": "c", "text": "?"}]}';
      expect(uiCleanSavedState(block(tree), {'path': ['a', 'c']}), isEmpty); // c is not linked from a
      expect(uiCleanSavedState(block(tree), {'path': ['a', 'b']}), {'path': ['a', 'b']});
      expect(
        uiCleanSavedState(block('{"component": "quiz", "questions": [{"question": "q", "options": ["x", "y"]}]}'), {
          'answers': {'0': 1, '1': 0, '0x': 1},
        }),
        {'answers': {'0': 1}},
      );
      const form = '{"component": "form", "fields": [{"key": "g", "label": "性别", "type": "select", "options": ["女", "男"]}, '
          '{"key": "n", "label": "年龄", "type": "number"}, {"key": "k", "label": "API Key"}, '
          '{"key": "c", "label": "API Key 来源", "type": "select", "options": ["官网", "代理"]}]}';
      expect(
        uiCleanSavedState(block(form), {
          'values': {'g': '猫', 'n': 'sk-xxx', 'k': 'sk-xxx', 'gone': 1},
          'other': {'g': '机器人', 'c': 'sk-xxx'},
        }),
        {'other': {'g': '机器人'}}, // 其他 is withheld on the secret-looking choice
      );
    });

    test('panel secrets, filtered quiz numbering and loud fence names', () {
      expect(
        uiCleanSavedState(block('{"component": "panel", "state": {"k": "", "n": 1}, "children": ['
            '{"component": "input", "bind": "k", "label": "API Key"}, {"component": "slider", "bind": "n", "min": 0, "max": 9}]}'),
            {'k': 'sk-xxx', 'n': 3}),
        {'n': 3},
      );
      expect(
        uiCleanSavedState(block('{"component": "quiz", "questions": [null, {"question": "Q", "options": ["A", "B"]}]}'), {
          'answers': {'0': 1},
        }),
        {'answers': {'0': 1}},
      );
      final cleaned = uiSavedBlocksInMessages(
        {uiSavedBlockKey('m1', 'p'): const UiSavedBlock(state: {'n': 2})},
        [(id: 'm1', text: '```AICOVE-UI\n{"component": "panel", "id": "p", "state": {"n": 1}, "children": []}\n```')],
      );
      expect(cleaned.keys, ['m1/p']);
    });

    test('secret inputs are found the way the screen finds them', () {
      expect(
        uiCleanSavedState(block('{"component": "panel", "state": {"k": ""}, "children": ['
            '{"component": "input", "value": "{k}", "label": "API Key"}]}'), {'k': 'sk-xxx'}),
        isEmpty,
      );
      expect(
        uiCleanSavedState(block('{"component": "panel", "state": {"k": "", "label": "API Key"}, "children": ['
            '{"component": "input", "bind": "k", "label": "{label}"}]}'), {'k': 'sk-xxx'}),
        isEmpty,
      );
      expect(
        uiCleanSavedState(block('{"component": "panel", "state": {"k": "", "show": false}, "children": ['
            '{"component": "input", "bind": "k", "label": "API Key", "visible": "{show}"}]}'), {'k': 'sk-xxx'}),
        isEmpty,
      );
    });

    test('hidden inputs with templated labels count; templated number types do not', () {
      expect(
        uiCleanSavedState(block('{"component": "panel", "state": {"k": "", "label": "API Key", "show": false}, "children": ['
            '{"component": "stack", "visible": "{show}", "children": [{"component": "input", "bind": "k", "label": "{label}"}]}]}'),
            {'k': 'sk-xxx'}),
        isEmpty,
      );
      expect(
        uiCleanSavedState(block('{"component": "panel", "state": {"n": 0, "kind": "number"}, "children": ['
            '{"component": "input", "bind": "n", "type": "{kind}", "label": "token 数量"}]}'), {'n': 5}),
        {'n': 5},
      );
    });

    test('a hidden heavy node cannot spend the secret check\'s budget', () {
      final raw = jsonEncode({
        'component': 'panel',
        'state': {'k': '', 'label': 'API Key'},
        'children': [
          {'component': 'text', 'visible': false, 'text': List.filled(101, '{sum(range(1,1000))}').join()},
          {'component': 'input', 'bind': 'k', 'label': '{label}'},
        ],
      });
      expect(uiCleanSavedState(block(raw), {'k': 'sk-xxx'}), isEmpty);
      final failing = jsonEncode({
        'component': 'panel',
        'state': {'k': ''},
        'children': [
          {'component': 'input', 'bind': 'k', 'label': '{nope.x}'},
        ],
      });
      expect(uiCleanSavedState(block(failing), {'k': 'v'}), isEmpty); // cannot be shown safe
      for (final label in ['用途：{nope.x}', ['{nope.x}'], '用途：{1 +}']) {
        final raw = jsonEncode({
          'component': 'panel',
          'state': {'k': ''},
          'children': [
            {'component': 'input', 'bind': 'k', 'label': label},
          ],
        });
        expect(uiCleanSavedState(block(raw), {'k': 'v'}), isEmpty, reason: '$label');
      }
      for (final computed in [
        {'caption': '1 +'},
        {'bad': '1 +', 'caption': "'用途：' + bad"},
      ]) {
        final raw = jsonEncode({
          'component': 'panel',
          'state': {'k': ''},
          'computed': computed,
          'children': [
            {'component': 'input', 'bind': 'k', 'label': '{caption}'},
          ],
        });
        expect(uiCleanSavedState(block(raw), {'k': 'v'}), isEmpty, reason: '$computed');
      }
    });

    test('<ui_state> reads saved state through the blocks in history', () {
      const reply = 'text\n```aicove-ui\n{"component": "panel", "id": "p", "state": {"n": 1}, "children": []}\n```\n';
      final cleaned = uiSavedBlocksInMessages({
        uiSavedBlockKey('m1', 'p'): const UiSavedBlock(state: {'n': 'oops'}),
        uiSavedBlockKey('m2', 'p'): const UiSavedBlock(state: {'n': 2}),
        uiSavedBlockKey('m3', 'gone'): const UiSavedBlock(state: {'n': 3}),
      }, [(id: 'm1', text: reply), (id: 'm2', text: reply), (id: 'm3', text: reply)]);
      expect(cleaned.keys, ['m2/p']);
      expect(cleaned['m2/p']!.state, {'n': 2});
    });
  });

  group('compile', () {
    test('doubled braces in plain text show single braces', () {
      final node = resolve('{"component": "panel", "children": [{"component": "text", "text": "{{literal}} }}"}]}');
      expect(node.children.single.props['text'], '{literal} }');
    });

    test('constants cannot be state or computed names', () {
      final program = UiProgram.compile(UiBlock.parse(
        '{"component": "panel", "state": {"e": 1}, "computed": {"area": "pi*2", "pi": 4}, '
        '"children": [{"component": "text", "text": "{round(area, 2)}"}]}',
      ).block!);
      expect(program.initialState, isNot(contains('e')));
      expect(program.issues.map((i) => i.path), containsAll(['state.e', 'computed.pi']));
      expect(program.resolve(const {}).children.single.props['text'], 6.28);
    });

    test('every value in a cycle is an error, short-circuit or not', () {
      final node = resolve(
        '{"component": "panel", "computed": {"a": "b", "b": "true ? 2 : a", "c": "a + 1"}, '
        '"children": [{"component": "text", "text": "{a}|{b}|{c}"}]}',
      );
      expect(node.children.single.props['text'], '—|—|—');
    });
  });

  group('<ui_state>', () {
    test('keeps long ids apart', () {
      final a = '${'a' * 40}x';
      final b = '${'a' * 40}y';
      final text = buildUiStateContext({
        uiSavedBlockKey('m1', a): const UiSavedBlock(state: {'n': 1}),
        uiSavedBlockKey('m1', b): const UiSavedBlock(state: {'n': 2}),
      }, ['m1'])!;
      expect(text, contains('id="$a"'));
      expect(text, contains('id="$b"'));
    });
  });

  group('state store', () {
    test('a clear made before the load is not undone by stored values', () async {
      SharedPreferences.setMockInitialValues({
        '${UiBlockStateNotifier.prefsPrefix}c1': jsonEncode({
          'm1/x': {'state': {'n': 5}},
          'm1/y': {'state': {'n': 6}},
        }),
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(uiBlockStateProvider('c1').notifier);
      notifier.write('m1/x', const {});
      notifier.write('m1/z', const {'n': double.infinity});
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      final state = container.read(uiBlockStateProvider('c1'));
      expect(state.keys, unorderedEquals(['m1/y', 'm1/z']));
      expect(state['m1/z']!.state, {'n': null});
    });
  });

  test('the protocol document carries the prompt the app sends', () {
    final doc = File('docs/04_功能模块规范/交互组件/README.md').readAsStringSync();
    final start = doc.indexOf('````text\n') + '````text\n'.length;
    final end = doc.indexOf('\n````', start);
    expect(doc.substring(start, end).trim(), uiBlockPrompt().trim());
  });
}
