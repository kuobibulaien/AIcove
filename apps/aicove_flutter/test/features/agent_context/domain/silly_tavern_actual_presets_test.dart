import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/core/api/providers/claude_adapter.dart';
import 'package:aicove_flutter/src/core/api/providers/gemini_adapter.dart';
import 'package:aicove_flutter/src/core/api/providers/openai_adapter.dart';
import 'package:aicove_flutter/src/core/api/providers/provider_adapter.dart';
import 'package:aicove_flutter/src/features/agent_context/domain/silly_tavern_preset_assembler.dart';
import 'package:aicove_flutter/src/features/agent_context/domain/silly_tavern_preset.dart';
import 'package:aicove_flutter/src/features/agent_context/domain/silly_tavern_preset_parser.dart';
import 'package:aicove_flutter/src/features/agent_context/domain/silly_tavern_regex_processor.dart';

void main() {
  const parser = SillyTavernPresetParser();
  const assembler = SillyTavernPresetAssembler();
  const regexProcessor = SillyTavernRegexProcessor();
  const context = SillyTavernAssemblyContext(
    characterName: '角色',
    userName: '用户',
    characterDescription: '角色设定',
    scenario: '场景设定',
  );
  const history = <Map<String, dynamic>>[
    {'role': 'user', 'content': '上一轮用户消息'},
    {'role': 'assistant', 'content': '上一轮助手消息'},
    {'role': 'user', 'content': '请继续故事'},
  ];

  test('actual ARGO preset attaches jailbreak to final user message', () async {
    final preset = parser.parseSource(
      await File('../../opusdocs/预设与正则/ARGO-1.5.json').readAsString(),
      sourceFileName: 'ARGO-1.5.json',
    );
    final result = assembler.assemble(
      preset: preset,
      historyMessages: history,
      context: context,
      maxContextTokens: preset.maxContextTokens ?? 2000000,
      reserveTokens: preset.maxOutputTokens ?? 2048,
      randomIndexPicker: (_) => 0,
    );
    final lastUser = result.messages.lastWhere(
      (message) => message['role'] == 'user',
    );
    final rendered = result.messages
        .map((message) => message['content']?.toString() ?? '')
        .join('\n');

    expect(preset.attachmentCount, 7);
    expect(preset.rawPreset.length, 47);
    expect(
      preset.parameterCompatibility.where(
        (entry) => !entry.field.startsWith('extensions.'),
      ),
      hasLength(47),
    );
    expect(
      preset.parameterStatusCount(
        SillyTavernParameterStatus.applied,
        topLevelOnly: true,
      ),
      12,
    );
    expect(
      preset.parameterStatusCount(
        SillyTavernParameterStatus.notApplicable,
        topLevelOnly: true,
      ),
      35,
    );
    expect(
      preset.parameterStatusCount(
        SillyTavernParameterStatus.intentionallyUnsupported,
        topLevelOnly: true,
      ),
      0,
    );
    expect(lastUser['content'].toString(), contains('#铁律：'));
    expect(lastUser['content'].toString(), contains('请继续故事'));
    final attachedText = lastUser['content'].toString();
    final attachmentOffsets = <String>[
      '<主动推理框架智能体>',
      '<拓扑量子计算智能体>',
      '<液态神经网络智能体>',
      '<密集混合专家智能体>',
      '<神经符号融合智能体>',
      '<GBNF>',
      '⦿发展前行：',
    ].map(attachedText.indexOf).toList(growable: false);
    expect(attachmentOffsets.every((offset) => offset >= 0), isTrue);
    expect(
      attachmentOffsets,
      orderedEquals(<int>[...attachmentOffsets]..sort()),
    );
    final generatedKey = result.variables['key'] ?? '';
    expect(generatedKey, hasLength(64));
    expect(
      generatedKey.runes.every((rune) => rune == '0'.codeUnitAt(0)),
      isTrue,
    );
    expect(
      RegExp(RegExp.escape(generatedKey)).allMatches(rendered).length,
      greaterThanOrEqualTo(6),
    );
    expect(
      result.appliedMacros,
      containsAll(<String>['random', 'setvar', 'getvar']),
    );
    _expectNoSupportedMacroLiterals(rendered);
    expect(rendered, isNot(contains('{{random::')));
    expect(rendered, isNot(contains('{{setvar::')));
    expect(rendered, isNot(contains('{{getvar::')));
  });

  test(
    'actual Cloud preset resolves its variable-driven prompt graph',
    () async {
      final preset = parser.parseSource(
        await File('../../opusdocs/预设与正则/☁️小金的云中梦工作室7.30.json').readAsString(),
        sourceFileName: '☁️小金的云中梦工作室7.30.json',
      );
      final result = assembler.assemble(
        preset: preset,
        historyMessages: history,
        context: context,
        maxContextTokens: preset.maxContextTokens ?? 2000000,
        reserveTokens: preset.maxOutputTokens ?? 2048,
        randomIndexPicker: (_) => 0,
      );
      final rendered = result.messages
          .map((message) => message['content']?.toString() ?? '')
          .join('\n');

      expect(result.variables, isNotEmpty);
      expect(preset.rawPreset.length, 47);
      expect(_topLevelCompatibility(preset), hasLength(47));
      expect(
        preset.parameterStatusCount(
          SillyTavernParameterStatus.applied,
          topLevelOnly: true,
        ),
        14,
      );
      expect(
        preset.parameterStatusCount(
          SillyTavernParameterStatus.notApplicable,
          topLevelOnly: true,
        ),
        33,
      );
      expect(
        preset.parameterStatusCount(
          SillyTavernParameterStatus.intentionallyUnsupported,
          topLevelOnly: true,
        ),
        0,
      );
      _expectNoSupportedMacroLiterals(rendered);
      expect(rendered, isNot(contains('{{setvar::')));
      expect(rendered, isNot(contains('{{getvar::')));
      expect(rendered, contains('请继续故事'));
    },
  );

  test('actual Two Rooms preset ends with assistant prefill', () async {
    final preset = parser.parseSource(
      await File('../../opusdocs/预设与正则/双人成行_精简版 (2).json').readAsString(),
      sourceFileName: '双人成行_精简版 (2).json',
    );
    final result = assembler.assemble(
      preset: preset,
      historyMessages: history,
      context: context,
      maxContextTokens: preset.maxContextTokens ?? 2000000,
      reserveTokens: preset.maxOutputTokens ?? 2048,
      randomIndexPicker: (_) => 0,
    );
    final rendered = result.messages
        .map((message) => message['content']?.toString() ?? '')
        .join('\n');

    expect(preset.functionCalling, isFalse);
    expect(preset.regexScriptCount, 28);
    expect(preset.rawPreset.length, 47);
    expect(_topLevelCompatibility(preset), hasLength(47));
    expect(
      preset.parameterStatusCount(
        SillyTavernParameterStatus.applied,
        topLevelOnly: true,
      ),
      13,
    );
    expect(
      preset.parameterStatusCount(
        SillyTavernParameterStatus.notApplicable,
        topLevelOnly: true,
      ),
      33,
    );
    expect(
      preset.parameterStatusCount(
        SillyTavernParameterStatus.intentionallyUnsupported,
        topLevelOnly: true,
      ),
      1,
    );
    expect(result.messages.last['role'], 'assistant');
    expect(result.messages.last['content'].toString(), endsWith('思考已结束。'));
    expect(result.messages.last['content'].toString(), contains('要求阅读完毕'));
    _expectNoSupportedMacroLiterals(rendered);
    expect(rendered, isNot(contains('{{setvar::')));
    expect(rendered, isNot(contains('{{getvar::')));
    expect(rendered, isNot(contains('{{trim}}')));
    expect(rendered, isNot(contains('{{lastUserMessage}}')));
  });

  test(
    'actual ARGO attachment survives all three provider renderers',
    () async {
      final preset = parser.parseSource(
        await File('../../opusdocs/预设与正则/ARGO-1.5.json').readAsString(),
        sourceFileName: 'ARGO-1.5.json',
      );
      final assembled = assembler.assemble(
        preset: preset,
        historyMessages: history,
        context: context,
        maxContextTokens: preset.maxContextTokens!,
        reserveTokens: preset.maxOutputTokens!,
        randomIndexPicker: (_) => 0,
      );
      final options = _options(preset);

      final openAiBody = OpenAIAdapter().buildRequestBody(
        model: 'custom-model',
        messages: assembled.messages,
        requestOptions: options,
      );
      final openAiMessages = openAiBody['messages'] as List<dynamic>;
      expect(
        openAiMessages.any(
          (message) =>
              message['role'] == 'user' &&
              message['content'].toString().contains('⦿发展前行：'),
        ),
        isTrue,
      );
      expect(
        openAiMessages.any(
          (message) =>
              message['role'] == 'system' &&
              message['content'].toString().contains('⦿发展前行：'),
        ),
        isFalse,
      );

      final claudeBody = ClaudeAdapter().buildRequestBody(
        model: 'claude-sonnet-4-5',
        messages: assembled.messages,
        requestOptions: options,
      );
      expect(claudeBody['system'].toString(), isNot(contains('⦿发展前行：')));
      expect(
        (claudeBody['messages'] as List<dynamic>).any(
          (message) => message['content'].toString().contains('⦿发展前行：'),
        ),
        isTrue,
      );

      final geminiBody = GeminiAdapter().buildRequestBody(
        model: 'gemini-2.5-pro',
        messages: assembled.messages,
        requestOptions: options,
      );
      expect(
        geminiBody['systemInstruction'].toString(),
        isNot(contains('⦿发展前行：')),
      );
      expect(geminiBody['contents'].toString(), contains('⦿发展前行：'));
    },
  );

  test(
    'actual Cloud variables are resolved in all provider request bodies',
    () async {
      final preset = parser.parseSource(
        await File('../../opusdocs/预设与正则/☁️小金的云中梦工作室7.30.json').readAsString(),
        sourceFileName: '☁️小金的云中梦工作室7.30.json',
      );
      final assembled = assembler.assemble(
        preset: preset,
        historyMessages: history,
        context: context,
        maxContextTokens: preset.maxContextTokens!,
        reserveTokens: preset.maxOutputTokens!,
        randomIndexPicker: (_) => 0,
      );

      for (final body in _providerBodies(preset, assembled.messages)) {
        final serialized = jsonEncode(body);
        expect(serialized, isNot(contains('{{setvar::')));
        expect(serialized, isNot(contains('{{getvar::')));
        expect(serialized, isNot(contains('{{trim}}')));
      }
    },
  );

  test(
    'actual Two Rooms prefill is final assistant content for all providers',
    () async {
      final preset = parser.parseSource(
        await File('../../opusdocs/预设与正则/双人成行_精简版 (2).json').readAsString(),
        sourceFileName: '双人成行_精简版 (2).json',
      );
      final assembled = assembler.assemble(
        preset: preset,
        historyMessages: history,
        context: context,
        maxContextTokens: preset.maxContextTokens!,
        reserveTokens: preset.maxOutputTokens!,
        randomIndexPicker: (_) => 0,
      );
      final bodies = _providerBodies(preset, assembled.messages);

      final openAiMessages = bodies[0]['messages'] as List<dynamic>;
      expect(openAiMessages.last['role'], 'assistant');
      expect(openAiMessages.last['content'].toString(), endsWith('思考已结束。'));

      final claudeMessages = bodies[1]['messages'] as List<dynamic>;
      expect(claudeMessages.last['role'], 'assistant');
      expect(claudeMessages.last['content'].toString(), endsWith('思考已结束。'));

      final geminiContents = bodies[2]['contents'] as List<dynamic>;
      expect(geminiContents.last['role'], 'model');
      final geminiParts = geminiContents.last['parts'] as List<dynamic>;
      expect(geminiParts.last['text'].toString(), endsWith('思考已结束。'));
      expect(bodies.every((body) => !body.containsKey('tools')), isTrue);
    },
  );

  test('actual Cloud prompt regex removes older user messages only', () async {
    final preset = parser.parseSource(
      await File('../../opusdocs/预设与正则/☁️小金的云中梦工作室7.30.json').readAsString(),
      sourceFileName: '☁️小金的云中梦工作室7.30.json',
    );
    final result = await regexProcessor.applyToPromptMessages(
      messages: history,
      scripts: preset.regexScripts,
      authorized: true,
    );

    expect(result.messages.first['content'], '');
    expect(result.messages.last['content'], '请继续故事');
    expect(
      result.traces.any(
        (trace) =>
            trace['scriptName'] == '只发送最新用户消息' &&
            trace['status'] == 'applied' &&
            trace['changed'] == true,
      ),
      isTrue,
    );
  });

  test(
    'actual ARGO display regex renders static card without script',
    () async {
      final preset = parser.parseSource(
        await File('../../opusdocs/预设与正则/ARGO-1.5.json').readAsString(),
        sourceFileName: 'ARGO-1.5.json',
      );
      final result = await regexProcessor.applyToDisplayText(
        text: '<思考>verify</思考>',
        scripts: preset.regexScripts,
        authorized: true,
      );

      expect(result.text, contains('reasoning_content'));
      expect(result.text, contains('verify'));
      expect(result.text.toLowerCase(), isNot(contains('<script')));
    },
  );
}

void _expectNoSupportedMacroLiterals(String rendered) {
  expect(
    rendered,
    isNot(
      matches(
        RegExp(
          r'\{\{\s*(?://|(?:char|user|description|chardescription|scenario|lastusermessage|original|setvar|getvar|random|pick|trim|newline|noop)(?:::|\s*\}\}))',
          caseSensitive: false,
        ),
      ),
    ),
  );
}

Iterable<SillyTavernParameterCompatibility> _topLevelCompatibility(
  SillyTavernPreset preset,
) {
  return preset.parameterCompatibility.where(
    (entry) => !entry.field.startsWith('extensions.'),
  );
}

List<Map<String, dynamic>> _providerBodies(
  SillyTavernPreset preset,
  List<Map<String, dynamic>> messages,
) {
  final options = _options(preset);
  return <Map<String, dynamic>>[
    OpenAIAdapter().buildRequestBody(
      model: 'custom-model',
      messages: messages,
      requestOptions: options,
    ),
    ClaudeAdapter().buildRequestBody(
      model: 'claude-sonnet-4-5',
      messages: messages,
      requestOptions: options,
    ),
    GeminiAdapter().buildRequestBody(
      model: 'gemini-2.5-pro',
      messages: messages,
      requestOptions: options,
    ),
  ];
}

ProviderChatRequestOptions _options(SillyTavernPreset preset) {
  return ProviderChatRequestOptions(
    useSystemPrompt: preset.useSystemPrompt,
    temperature: preset.temperature,
    topP: preset.topP,
    topK: preset.topK,
    minP: preset.minP,
    topA: preset.topA,
    repetitionPenalty: preset.repetitionPenalty,
    frequencyPenalty: preset.frequencyPenalty,
    presencePenalty: preset.presencePenalty,
    seed: preset.seed,
    maxOutputTokens: preset.maxOutputTokens,
    reasoningEffort: preset.reasoningEffort,
  );
}
