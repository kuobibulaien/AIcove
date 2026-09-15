import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/features/agent_context/domain/silly_tavern_preset_assembler.dart';
import 'package:aicove_flutter/src/features/agent_context/domain/silly_tavern_preset_parser.dart';

void main() {
  const parser = SillyTavernPresetParser();
  const assembler = SillyTavernPresetAssembler();

  test(
    'preserves prompt_order and expands dynamic markers and macros',
    () async {
      final source = await File(
        'test/fixtures/sillytavern/openai_default_shape.json',
      ).readAsString();
      final preset = parser.parseSource(source, sourceFileName: 'Default.json');
      final result = assembler.assemble(
        preset: preset,
        historyMessages: const <Map<String, dynamic>>[
          {'role': 'user', 'content': '你好'},
          {'role': 'assistant', 'content': '你好呀'},
        ],
        context: const SillyTavernAssemblyContext(
          characterName: '爱丽丝',
          userName: '小云',
          characterDescription: '你是温柔的爱丽丝。',
          scenario: '两人在图书馆。',
          runtimeSystemContent: '只在必要时输出工具标签。',
        ),
        maxContextTokens: 16000,
      );

      expect(
        result.messages.map((message) => message['content']).toList(),
        <dynamic>[
          "Write 爱丽丝's next reply to 小云.",
          '你是温柔的爱丽丝。',
          '两人在图书馆。',
          '只在必要时输出工具标签。',
          '你好',
          '你好呀',
          'Stay in character.',
        ],
      );
      expect(result.historyIncluded, isTrue);
      // 空世界书是正常状态，不再报告“功能未实现”。
      expect(result.warnings, isNot(contains(contains('本批次按空节点处理'))));
    },
  );

  test(
    'absolute injections use depth then descending order and role groups',
    () {
      const source = '''
{
  "prompts": [
    {"identifier":"chatHistory","marker":true},
    {"identifier":"low","role":"system","content":"low","injection_position":1,"injection_depth":1,"injection_order":10},
    {"identifier":"low2","role":"system","content":"low2","injection_position":1,"injection_depth":1,"injection_order":10},
    {"identifier":"high","role":"system","content":"high","injection_position":1,"injection_depth":1,"injection_order":20},
    {"identifier":"userInject","role":"user","content":"user-inject","injection_position":1,"injection_depth":1,"injection_order":30}
  ],
  "prompt_order": [{"order":[
    {"identifier":"chatHistory","enabled":true},
    {"identifier":"low","enabled":true},
    {"identifier":"low2","enabled":true},
    {"identifier":"high","enabled":true},
    {"identifier":"userInject","enabled":true}
  ]}]
}
''';
      final preset = parser.parseSource(source, sourceFileName: 'inject.json');
      final result = assembler.assemble(
        preset: preset,
        historyMessages: const <Map<String, dynamic>>[
          {'role': 'user', 'content': 'first'},
          {'role': 'assistant', 'content': 'latest'},
        ],
        context: const SillyTavernAssemblyContext(
          characterName: 'C',
          userName: 'U',
          characterDescription: '',
          scenario: '',
        ),
        maxContextTokens: 16000,
      );

      expect(
        result.messages.map((message) => message['content']).toList(),
        <dynamic>['first', 'low\nlow2', 'high', 'user-inject', 'latest'],
      );
    },
  );

  test('disabled chatHistory omits history but keeps runtime rules', () {
    const source = '''
{
  "prompts": [
    {"identifier":"main","role":"system","content":"main"},
    {"identifier":"chatHistory","marker":true}
  ],
  "prompt_order": [{"order":[
    {"identifier":"main","enabled":true},
    {"identifier":"chatHistory","enabled":false}
  ]}]
}
''';
    final preset = parser.parseSource(source, sourceFileName: 'disabled.json');
    final result = assembler.assemble(
      preset: preset,
      historyMessages: const <Map<String, dynamic>>[
        {'role': 'user', 'content': 'must-not-appear'},
      ],
      context: const SillyTavernAssemblyContext(
        characterName: 'C',
        userName: 'U',
        characterDescription: '',
        scenario: '',
        runtimeSystemContent: 'runtime',
        protectedRuntimeMessages: <Map<String, dynamic>>[
          {
            'role': 'user',
            'content': '<system-reminder>\nnow\n</system-reminder>',
          },
        ],
      ),
      maxContextTokens: 16000,
    );

    expect(result.historyIncluded, isFalse);
    expect(
      result.messages.map((message) => message['content']).toList(),
      <dynamic>[
        'main',
        'runtime',
        '<system-reminder>\nnow\n</system-reminder>',
      ],
    );
  });

  test('token trimming drops oldest history without moving preset nodes', () {
    const source = '''
{
  "prompts": [
    {"identifier":"main","role":"system","content":"main"},
    {"identifier":"chatHistory","marker":true},
    {"identifier":"tail","role":"system","content":"tail"}
  ],
  "prompt_order": [{"order":[
    {"identifier":"main","enabled":true},
    {"identifier":"chatHistory","enabled":true},
    {"identifier":"tail","enabled":true}
  ]}]
}
''';
    final preset = parser.parseSource(source, sourceFileName: 'trim.json');
    final result = assembler.assemble(
      preset: preset,
      historyMessages: <Map<String, dynamic>>[
        {'role': 'user', 'content': 'old ${List.filled(200, 'x').join()}'},
        {
          'role': 'assistant',
          'content': 'middle ${List.filled(200, 'y').join()}',
        },
        {'role': 'user', 'content': 'latest'},
      ],
      context: const SillyTavernAssemblyContext(
        characterName: 'C',
        userName: 'U',
        characterDescription: '',
        scenario: '',
      ),
      maxContextTokens: 90,
      reserveTokens: 20,
    );

    expect(result.messages.first['content'], 'main');
    expect(result.messages.last['content'], 'tail');
    expect(
      result.messages.any((message) => message['content'] == 'latest'),
      isTrue,
    );
    expect(result.droppedHistoryCount, greaterThan(0));
  });

  test(
    'normal trigger skips quiet prompts and preserves unavailable macros',
    () {
      const source = '''
{
  "prompts": [
    {"identifier":"main","role":"system","content":"{{original}} {{futureMacro}}"},
    {"identifier":"quietOnly","role":"system","content":"quiet","injection_trigger":["quiet"]},
    {"identifier":"chatHistory","marker":true}
  ],
  "prompt_order": [{"order":[
    {"identifier":"main","enabled":true},
    {"identifier":"quietOnly","enabled":true},
    {"identifier":"chatHistory","enabled":true}
  ]}]
}
''';
      final preset = parser.parseSource(source, sourceFileName: 'trigger.json');
      final result = assembler.assemble(
        preset: preset,
        historyMessages: const <Map<String, dynamic>>[
          {'role': 'user', 'content': 'history'},
        ],
        context: const SillyTavernAssemblyContext(
          characterName: 'C',
          userName: 'U',
          characterDescription: '',
          scenario: '',
        ),
        maxContextTokens: 16000,
      );

      expect(result.messages.first['content'], '{{original}} {{futureMacro}}');
      expect(
        result.messages.any((message) => message['content'] == 'quiet'),
        isFalse,
      );
      expect(result.warnings, contains(contains('仅用于非 normal')));
      expect(result.warnings, contains(contains('已保留 {{original}}')));
      expect(result.warnings, contains(contains('futureMacro')));
    },
  );

  test('ARGO attachment appends ordered jailbreak prompts to last user', () {
    const source = '''
{
  "prompts": [
    {"identifier":"main","role":"system","content":"main"},
    {"identifier":"chatHistory","marker":true},
    {"identifier":"guard1","role":"system","content":"rule-1","attach_index":1,"attach_role":"user","attach_side":"end"},
    {"identifier":"guard2","role":"system","content":"rule-2","attach_index":1,"attach_role":"user","attach_side":"end"}
  ],
  "prompt_order": [{"order":[
    {"identifier":"main","enabled":true},
    {"identifier":"chatHistory","enabled":true},
    {"identifier":"guard1","enabled":true},
    {"identifier":"guard2","enabled":true}
  ]}]
}
''';
    final preset = parser.parseSource(source, sourceFileName: 'argo.json');
    final result = assembler.assemble(
      preset: preset,
      historyMessages: const <Map<String, dynamic>>[
        {'role': 'user', 'content': 'old user'},
        {'role': 'assistant', 'content': 'answer'},
        {'role': 'user', 'content': 'latest user'},
      ],
      context: const SillyTavernAssemblyContext(
        characterName: 'C',
        userName: 'U',
        characterDescription: '',
        scenario: '',
      ),
      maxContextTokens: 16000,
    );

    expect(
      result.messages.map((message) => message['content']).toList(),
      <dynamic>[
        'main',
        'old user',
        'answer',
        'latest user\n\nrule-1\n\nrule-2',
      ],
    );
    expect(
      result.messages.where((message) => message['role'] == 'system'),
      hasLength(1),
    );
    expect(result.entries.last.source, contains('attach.guard1+guard2'));
  });

  test('Cloud variables flow left-to-right across prompt nodes', () {
    const source = '''
{
  "prompts": [
    {"identifier":"vars","role":"system","content":"{{setvar::mode::bold}}{{setvar::topic::{{char}}}}"},
    {"identifier":"main","role":"system","content":"mode={{getvar::mode}} topic={{getvar::topic}}"},
    {"identifier":"chatHistory","marker":true}
  ],
  "prompt_order": [{"order":[
    {"identifier":"vars","enabled":true},
    {"identifier":"main","enabled":true},
    {"identifier":"chatHistory","enabled":true}
  ]}]
}
''';
    final preset = parser.parseSource(source, sourceFileName: 'cloud.json');
    final result = assembler.assemble(
      preset: preset,
      historyMessages: const <Map<String, dynamic>>[],
      context: const SillyTavernAssemblyContext(
        characterName: '爱丽丝',
        userName: 'U',
        characterDescription: '',
        scenario: '',
      ),
      maxContextTokens: 16000,
    );

    expect(result.messages.single['content'], 'mode=bold topic=爱丽丝');
    expect(result.variables, <String, String>{'mode': 'bold', 'topic': '爱丽丝'});
    expect(result.appliedMacros, containsAll(<String>['setvar', 'getvar']));
  });

  test('Two Rooms appends assistant prefill and squashes system messages', () {
    const source = '''
{
  "assistant_prefill": "思考已结束。",
  "squash_system_messages": true,
  "prompts": [
    {"identifier":"main","role":"system","content":"main"},
    {"identifier":"rules","role":"system","content":"rules"},
    {"identifier":"jailbreak","role":"system","content":""},
    {"identifier":"chatHistory","marker":true}
  ],
  "prompt_order": [{"order":[
    {"identifier":"main","enabled":true},
    {"identifier":"rules","enabled":true},
    {"identifier":"jailbreak","enabled":true},
    {"identifier":"chatHistory","enabled":true}
  ]}]
}
''';
    final preset = parser.parseSource(source, sourceFileName: 'two.json');
    final result = assembler.assemble(
      preset: preset,
      historyMessages: const <Map<String, dynamic>>[
        {'role': 'user', 'content': 'continue'},
      ],
      context: const SillyTavernAssemblyContext(
        characterName: 'C',
        userName: 'U',
        characterDescription: '',
        scenario: '',
      ),
      maxContextTokens: 16000,
    );

    expect(result.messages, <Map<String, dynamic>>[
      {'role': 'system', 'content': 'main\nrules'},
      {'role': 'user', 'content': 'continue'},
      {'role': 'assistant', 'content': '思考已结束。'},
    ]);
    expect(result.entries.last.protectedFromTruncation, isTrue);
  });
}
