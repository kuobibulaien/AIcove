import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/features/agent_context/domain/silly_tavern_preset_parser.dart';

void main() {
  const parser = SillyTavernPresetParser();

  test(
    'parses official Default-compatible shape and selects richest order',
    () async {
      final source = await File(
        'test/fixtures/sillytavern/openai_default_shape.json',
      ).readAsString();
      final preset = parser.parseSource(
        source,
        sourceFileName: 'Default.json',
        importedAt: DateTime.utc(2026, 8, 27),
      );

      expect(preset.id, startsWith('st_preset_'));
      expect(preset.sourceFormat, 'chat_completion_preset');
      expect(preset.selectedOrder.sourceIndex, 1);
      expect(preset.selectedOrder.characterId, '100001');
      expect(preset.enabledPromptCount, 6);
      expect(preset.markerCount, 4);
      expect(preset.absoluteInjectionCount, 0);
      expect(preset.temperature, 0.85);
      expect(preset.topP, 0.92);
      expect(preset.regexScriptCount, 1);
      expect(preset.warnings, contains(contains('尚未授权')));
    },
  );

  test('parses Prompt Manager wrapper export', () {
    const source = '''
{
  "version": 1,
  "type": "full",
  "data": {
    "name": "Wrapped",
    "prompts": [
      {"identifier":"custom","role":"system","content":"hello"}
    ],
    "prompt_order": [
      {"identifier":"main","enabled":true},
      {"identifier":"charDescription","enabled":true},
      {"identifier":"chatHistory","enabled":true},
      {"identifier":"custom","enabled":true}
    ]
  }
}
''';
    final preset = parser.parseSource(source, sourceFileName: 'wrapped.json');

    expect(preset.name, 'Wrapped');
    expect(preset.sourceFormat, 'prompt_manager_export');
    expect(preset.selectedOrder.entries, hasLength(4));
    expect(preset.promptsById['chatHistory']?.marker, isTrue);
    expect(preset.promptsById['main']?.content, isEmpty);
    expect(preset.warnings, contains(contains('不携带酒馆内置 prompt 正文')));
  });

  test('rejects JSON without prompts and prompt_order', () {
    expect(
      () => parser.parseSource('{}', sourceFileName: 'bad.json'),
      throwsA(isA<SillyTavernPresetParseException>()),
    );
  });

  test('stable id is based on raw preset content', () {
    const source = '''
{"prompts":[{"identifier":"main","content":"x"}],"prompt_order":[{"order":[{"identifier":"main","enabled":true}]}]}
''';
    final first = parser.parseSource(source, sourceFileName: 'one.json');
    final second = parser.parseSource(source, sourceFileName: 'two.json');
    expect(first.id, second.id);
  });

  test(
    'duplicate prompt identifier keeps the later definition with warning',
    () {
      const source = '''
{"prompts":[{"identifier":"main","content":"old"},{"identifier":"main","content":"new"}],"prompt_order":[{"order":[{"identifier":"main","enabled":true}]}]}
''';
      final preset = parser.parseSource(
        source,
        sourceFileName: 'duplicate.json',
      );

      expect(preset.promptsById['main']?.content, 'new');
      expect(preset.warnings, contains(contains('已保留后一个')));
    },
  );

  test(
    'parses exporter attachment, prefill, context, and model parameters',
    () {
      const source = '''
{
  "temperature": 1.1,
  "top_p": 0.95,
  "top_k": 64,
  "min_p": 0.08,
  "top_a": 0.2,
  "repetition_penalty": 1.05,
  "frequency_penalty": 0.1,
  "presence_penalty": 0.2,
  "seed": 42,
  "openai_max_context": 2000000,
  "openai_max_tokens": 30000,
  "max_context_unlocked": true,
  "assistant_prefill": "思考已结束。",
  "assistant_impersonation": "模拟用户",
  "function_calling": false,
  "use_sysprompt": false,
  "squash_system_messages": true,
  "reasoning_effort": "high",
  "prompts": [
    {
      "identifier":"jailbreak",
      "role":"system",
      "content":"rules",
      "attach_index":1,
      "attach_role":"user",
      "attach_side":"end"
    },
    {"identifier":"chatHistory","marker":true}
  ],
  "prompt_order": [{"order":[
    {"identifier":"chatHistory","enabled":true},
    {"identifier":"jailbreak","enabled":true}
  ]}]
}
''';
      final preset = parser.parseSource(source, sourceFileName: 'params.json');
      final jailbreak = preset.promptsById['jailbreak']!;

      expect(jailbreak.attachIndex, 1);
      expect(jailbreak.attachRole, 'user');
      expect(jailbreak.attachSide, 'end');
      expect(preset.attachmentCount, 1);
      expect(preset.temperature, 1.1);
      expect(preset.topP, 0.95);
      expect(preset.topK, 64);
      expect(preset.minP, 0.08);
      expect(preset.topA, 0.2);
      expect(preset.repetitionPenalty, 1.05);
      expect(preset.frequencyPenalty, 0.1);
      expect(preset.presencePenalty, 0.2);
      expect(preset.seed, 42);
      expect(preset.maxContextTokens, 2000000);
      expect(preset.maxOutputTokens, 30000);
      expect(preset.maxContextUnlocked, isTrue);
      expect(preset.assistantPrefill, '思考已结束。');
      expect(preset.assistantImpersonation, '模拟用户');
      expect(preset.functionCalling, isFalse);
      expect(preset.useSystemPrompt, isFalse);
      expect(preset.squashSystemMessages, isTrue);
      expect(preset.reasoningEffort, 'high');
    },
  );

  test('invalid partial attachment falls back with warning', () {
    const source = '''
{"prompts":[{"identifier":"main","content":"x","attach_index":1,"attach_role":"user"}],"prompt_order":[{"order":[{"identifier":"main","enabled":true}]}]}
''';
    final preset = parser.parseSource(
      source,
      sourceFileName: 'bad-attach.json',
    );

    expect(preset.promptsById['main']?.hasAttachment, isFalse);
    expect(preset.warnings, contains(contains('attach_*')));
  });

  test('parses standard and SPreset regex declarations with id dedupe', () {
    const source = '''
{
  "extensions": {
    "regex_scripts": [
      {"id":"same","scriptName":"standard","findRegex":"/x/g","replaceString":"y","placement":[2],"promptOnly":true}
    ],
    "SPreset": {"RegexBinding":{"regexes":[
      {"id":"same","scriptName":"duplicate","findRegex":"x","replaceString":"z","placement":[2]},
      {"id":"second","scriptName":"spreset","findRegex":"q","replaceString":"r","placement":[1],"minDepth":1}
    ]}}
  },
  "prompts":[{"identifier":"chatHistory","marker":true}],
  "prompt_order":[{"order":[{"identifier":"chatHistory","enabled":true}]}]
}
''';
    final preset = parser.parseSource(source, sourceFileName: 'regex.json');

    expect(preset.regexScriptCount, 2);
    expect(preset.regexScripts.map((script) => script.id), <String>[
      'same',
      'second',
    ]);
    expect(preset.regexScripts.first.name, 'standard');
    expect(
      preset.regexScripts.last.source,
      'extensions.SPreset.RegexBinding.regexes',
    );
    expect(preset.warnings, contains(contains('按 id 去重')));
  });
}
