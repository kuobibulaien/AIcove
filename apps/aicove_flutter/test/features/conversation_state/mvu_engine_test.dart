import 'package:aicove_flutter/src/features/conversation_state/domain/mvu_engine.dart';
import 'package:aicove_flutter/src/features/conversation_state/domain/mvu_markup.dart';
import 'package:flutter_test/flutter_test.dart';

const engine = MvuEngine();

MvuState stateOf(Map<String, Object?> data, {bool strictSet = false}) =>
    MvuState(statData: data, strictSet: strictSet);

MvuStepResult run(
  Map<String, Object?> data,
  String text, {
  bool strictSet = false,
}) => engine.apply(stateOf(data, strictSet: strictSet), text);

void main() {
  group('命令提取', () {
    test('脚本命令带注释原因，按原文位置与补丁混排', () {
      final result = extractMvuCommands('''
<UpdateVariable>
_.set('理.好感度', 33, 35);//愉快的讨论
<JSONPatch>[{"op":"delta","path":"/理/好感度","value":1}]</JSONPatch>
_.add('理.好感度', 2);
</UpdateVariable>''');
      expect(result.commands.map((c) => c.type), [
        MvuCommandType.set,
        MvuCommandType.add,
        MvuCommandType.add,
      ]);
      expect(result.commands.first.reason, '愉快的讨论');
      expect(result.commands.first.path, ['理', '好感度']);
      expect(result.commands[1].fromPatch, isTrue);
    });

    test('思考区内的命令不执行，未闭合思考区到文末都忽略', () {
      final closed = extractMvuCommands(
        "<think>_.set('a', 1, 2);</think>_.set('b', 1, 2);",
      );
      expect(closed.commands.single.path, ['b']);
      final open = extractMvuCommands(
        "_.set('a', 1, 2);<thinking>_.set('b', 1, 2);",
      );
      expect(open.commands.single.path, ['a']);
    });

    test('嵌套在 UpdateVariable 里的 Analysis 段不执行', () {
      final result = extractMvuCommands('''
<UpdateVariable>
<Analysis>_.set('x', 1, 2);</Analysis>
_.set('y', 1, 2);
</UpdateVariable>''');
      expect(result.commands.single.path, ['y']);
    });

    test('字符串字面量里的伪命令不执行', () {
      final result = extractMvuCommands(
        "_.set('note', \"她写下 _.set('evil', 0, 1); 作为玩笑\");",
      );
      expect(result.commands, hasLength(1));
      expect(result.commands.single.path, ['note']);
    });

    test('JSON Patch 字符串值里的结束标签不截断补丁', () {
      final result = extractMvuCommands(
        '<JSONPatch>[{"op":"replace","path":"/memo","value":"</JSONPatch> 不是结束"}]</JSONPatch>',
      );
      expect(result.brokenBlocks, isEmpty);
      expect(result.commands.single.args.single, '"</JSONPatch> 不是结束"');
    });

    test('JSON Patch 值里像脚本的字符串是数据', () {
      final result = extractMvuCommands(
        '<JSONPatch>[{"op":"replace","path":"/memo","value":"_.set(\'evil\', 0, 1);"}]</JSONPatch>',
      );
      expect(result.commands, hasLength(1));
      expect(result.commands.single.fromPatch, isTrue);
    });

    test('缺分号的命令不执行；<update> 通用标签不算更新标签', () {
      final result = extractMvuCommands("<update>_.set('a', 1, 2)</update>");
      expect(result.commands, isEmpty);
      expect(result.hasUpdateMarkup, isFalse);
    });
  });

  group('set', () {
    test('[值, 说明] 只改第 0 项并保留说明，数字目标转数字', () {
      final result = run({
        '好感度': [33, '[-30,100]'],
      }, "_.set('好感度', 33, '35');");
      expect(result.state.statData['好感度'], [35, '[-30,100]']);
      expect(result.status, StateStepStatus.applied);
    });

    test('第一项是数组的 [值, 说明] 被整体替换', () {
      final result = run({
        'list': [
          [1, 2],
          '说明',
        ],
      }, "_.set('list', [9]);");
      expect(result.state.statData['list'], [9]);
    });

    test('开启 strictSet 时整体替换', () {
      final result = run(
        {
          '好感度': [33, '说明'],
        },
        "_.set('好感度', 40);",
        strictSet: true,
      );
      expect(result.state.statData['好感度'], 40);
    });

    test('数字目标设为 null 保留 null；字符串目标可设为空串', () {
      final result = run({
        'hp': [10, '说明'],
        'name': '理',
      }, "_.set('hp', null);_.set('name', '');");
      expect(result.state.statData['hp'], [null, '说明']);
      expect(result.state.statData['name'], '');
    });

    test('路径不存在时跳过，不自动建路径', () {
      final result = run({'a': 1}, "_.set('b.c', 0, 1);");
      expect(result.state.statData.containsKey('b'), isFalse);
      expect(result.status, StateStepStatus.parseError);
      expect(result.diagnostics.single, contains('路径不存在'));
    });

    test('空路径替换整个根状态', () {
      final result = run({'a': 1}, "_.set('', {\"b\": 2});");
      expect(result.state.statData, {'b': 2});
    });

    test('不带引号的纯数字四则运算求值，math.* 不执行', () {
      final result = run({
        'x': 1,
        'y': 1,
      }, "_.set('x', 1, 10 + 2 * 3);_.set('y', 1, math.pow(2, 3));");
      expect(result.state.statData['x'], 16);
      expect(result.state.statData['y'], 1);
      expect(result.status, StateStepStatus.partial);
    });

    test('带引号的日期是字符串', () {
      final result = run({'d': ''}, "_.set('d', '2000-01-01');");
      expect(result.state.statData['d'], '2000-01-01');
    });
  });

  group('insert / assign', () {
    test('两参数向数组追加一个元素，不展开数组值', () {
      final result = run({
        'items': <Object?>['钥匙'],
      }, "_.insert('items', ['地图', '火把']);");
      expect(result.state.statData['items'], [
        '钥匙',
        ['地图', '火把'],
      ]);
    });

    test('两参数向对象深合并', () {
      final result = run({
        'npc': {
          '理': {'hp': 1},
        },
      }, "_.assign('npc', {\"理\": {\"mp\": 2}});");
      expect(result.state.statData['npc'], {
        '理': {'hp': 1, 'mp': 2},
      });
    });

    test('三参数数组下标按 splice 语义：-1 插在末项之前，超长追加', () {
      final result = run({
        'a': <Object?>[1, 2, 3],
        'b': <Object?>[1],
      }, "_.insert('a', -1, 9);_.insert('b', 99, 2);");
      expect(result.state.statData['a'], [1, 2, 9, 3]);
      expect(result.state.statData['b'], [1, 2]);
    });

    test('三参数对象键是字面量，不再解释成路径，已有键被覆盖', () {
      final result = run({
        'map': {'a.b': 1},
      }, "_.insert('map', 'a.b', 2);");
      expect(result.state.statData['map'], {'a.b': 2});
    });

    test('父路径不存在时跳过', () {
      final result = run({}, "_.insert('x.y', 1);");
      expect(result.status, StateStepStatus.parseError);
    });
  });

  group('remove / delete', () {
    test('数组按值只删第一个深相等的元素', () {
      final result = run({
        'items': <Object?>['a', 'b', 'a'],
      }, "_.remove('items', 'a');");
      expect(result.state.statData['items'], ['b', 'a']);
    });

    test('数组数字参数是下标', () {
      final result = run({
        'items': <Object?>[5, 6, 7],
      }, "_.remove('items', 0);");
      expect(result.state.statData['items'], [6, 7]);
    });

    test('对象数字参数按键顺序选键，字符串按键名删', () {
      final result = run({
        'o': {'x': 1, 'y': 2, 'z': 3},
      }, "_.remove('o', 1);_.delete('o', 'z');");
      expect(result.state.statData['o'], {'x': 1});
    });

    test('一参数删除数组元素时数组收缩', () {
      final result = run({
        'items': <Object?>['a', 'b', 'c'],
      }, "_.unset('items[1]');");
      expect(result.state.statData['items'], ['a', 'c']);
    });
  });

  group('add', () {
    test('数字与 [值, 说明] 的数值相加', () {
      final result = run({
        'n': 1,
        'v': [0.1, '说明'],
      }, "_.add('n', 2);_.add('v', 0.2);");
      expect(result.state.statData['n'], 3);
      expect(result.state.statData['v'], [0.3, '说明']);
    });

    test('布尔值不修改并诊断', () {
      final result = run({'flag': true}, "_.add('flag', 1);");
      expect(result.state.statData['flag'], isTrue);
      expect(result.status, StateStepStatus.parseError);
    });

    test('带时区的 ISO 日期按毫秒偏移并以 UTC 存回；无时区日期跳过', () {
      final result = run({
        't': '2024-01-01T08:00:00+08:00',
        'local': '2024-01-01T08:00:00',
      }, "_.add('t', 3600000);_.add('local', 1000);");
      expect(result.state.statData['t'], '2024-01-01T01:00:00.000Z');
      expect(result.state.statData['local'], '2024-01-01T08:00:00');
      expect(result.status, StateStepStatus.partial);
    });
  });

  test('JSON Patch move 跳过并诊断', () {
    final result = run({
      'a': 1,
    }, '<JSONPatch>[{"op":"move","from":"/a","path":"/b"}]</JSONPatch>');
    expect(result.state.statData, {'a': 1});
    expect(result.diagnostics.single, contains('move'));
  });

  test('有效 → 非法 → 有效三条命令：第一、三条生效', () {
    final result = run({
      'n': 0,
    }, "_.add('n', 1);_.add('missing', 1);_.add('n', 2);");
    expect(result.state.statData['n'], 3);
    expect(result.status, StateStepStatus.partial);
  });

  test('坏补丁块只贡献零条命令，不回滚其他块', () {
    final result = run(
      {'n': 0},
      '''
<UpdateVariable>_.add('n', 1);</UpdateVariable>
<JSONPatch>[{"op": "delta", "path": </JSONPatch>
<UpdateVariable>_.add('n', 2);</UpdateVariable>''',
    );
    expect(result.state.statData['n'], 3);
    expect(result.status, StateStepStatus.partial);
  });

  test('只有失败时状态等于前态；没有更新块时为 no_ops', () {
    final previous = stateOf({'n': 0});
    final failed = engine.apply(previous, '<JSONPatch>not json</JSONPatch>');
    expect(failed.status, StateStepStatus.parseError);
    expect(failed.state.statData, {'n': 0});
    final none = engine.apply(previous, '普通回复，没有变量更新。');
    expect(none.status, StateStepStatus.noOps);
  });

  test('执行不修改前态对象', () {
    final previous = stateOf({'n': 0});
    engine.apply(previous, "_.add('n', 1);");
    expect(previous.statData['n'], 0);
  });

  group('初始化', () {
    test('合并多个条目，去 <initvar> 包装、代码围栏与 JSON5 注释', () {
      final result = engine.initialize(
        sources: const [
          MvuInitSource(
            name: '[InitVar]一',
            content: '''
<initvar>
```json
{
  "理": {"好感度": [0, "说明"], /* 略 */ },
  // 注释
}
```
</initvar>''',
          ),
          MvuInitSource(
            name: '[initvar]二',
            content: '日期: ["03月15日", "格式 mm月dd日"]',
          ),
        ],
      );
      expect(result.ok, isTrue);
      expect(result.state!.statData, {
        '理': {
          '好感度': [0, '说明'],
        },
        '日期': ['03月15日', '格式 mm月dd日'],
      });
    });

    test('开场白 <initvar> 替换世界书初始化结果', () {
      final result = engine.initialize(
        sources: const [MvuInitSource(name: '[InitVar]', content: '{"a": 1}')],
        greetingRaw: '你好\n<initvar>{"b": 2}</initvar>',
      );
      expect(result.state!.statData, {'b': 2});
    });

    test('含 EJS 的条目使初始化失败，不假装成功', () {
      final result = engine.initialize(
        sources: const [
          MvuInitSource(name: '[InitVar]', content: '{"a": <%= 1 %>}'),
        ],
      );
      expect(result.ok, isFalse);
      expect(result.failure, contains('EJS'));
    });

    test('提取 strictSet 后清理元数据，数组下标与上游一致', () {
      final result = engine.initialize(
        sources: const [
          MvuInitSource(
            name: '[InitVar]',
            content: r'''
{
  "$meta": {"strictSet": true},
  "背包": ["$__META_EXTENSIBLE__$", "钥匙"],
  "队伍": [{"$meta": {"template": {}}, "$arrayMeta": true}, "理"],
  "角色": {"$meta": {"extensible": true}, "hp": 1}
}''',
          ),
        ],
      );
      final state = result.state!;
      expect(state.strictSet, isTrue);
      expect(state.statData, {
        '背包': ['钥匙'],
        '队伍': ['理'],
        '角色': {'hp': 1},
      });
      expect(state.unsupportedFeatures, {'template', 'constraints'});
      final removed = engine.apply(state, "_.remove('背包', 0);");
      expect(removed.state.statData['背包'], isEmpty);
    });

    test('宏展开在解析前进行', () {
      final result = engine.initialize(
        sources: const [
          MvuInitSource(name: '[InitVar]', content: '{"{{user}}": {"hp": 1}}'),
        ],
        expandMacros: (text) => text.replaceAll('{{user}}', '阿明'),
      );
      expect(result.state!.statData.keys, ['阿明']);
    });
  });
}
