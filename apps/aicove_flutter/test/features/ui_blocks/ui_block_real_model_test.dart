// Real-model check for interactive blocks (ADR0073 交互组件, batch U1): with
// the assistant prompt, DeepSeek Flash answers setup and troubleshooting
// questions with `aicove-ui` blocks that parse and compile cleanly, and uses
// the user's values from <ui_state>. Skipped unless DEEPSEEK_API_KEY is set.
import 'dart:io';

import 'package:aicove_flutter/src/core/utils/markdown_fence.dart';
import 'package:aicove_flutter/src/features/assistant/application/assistant_plugin.dart';
import 'package:aicove_flutter/src/features/assistant/application/assistant_toolset.dart';
import 'package:aicove_flutter/src/features/chat/services/api_runner.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_types.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/features/ui_blocks/domain/ui_block.dart';
import 'package:aicove_flutter/src/features/ui_blocks/domain/ui_block_catalog.dart';
import 'package:aicove_flutter/src/features/ui_blocks/domain/ui_state_context.dart';
import 'package:flutter_test/flutter_test.dart';

final String? _apiKey = Platform.environment['DEEPSEEK_API_KEY'];

/// Read-only assistant tools over an empty setup; docs come from the assets.
final _tools = AssistantToolset(
  roles: () async => const [],
  presets: () async => const [],
  previewContext: (_) => throw UnimplementedError(),
  readDoc: (id) async => File('assets/aicove_docs/$id.md').readAsStringSync(),
).tools();

Future<String> _ask(List<Map<String, dynamic>> messages) async =>
    (await createApiRunner(useKernel: true).executeApiCall(
      config: ApiConfig(
        settings: mapUiModelsToAppSettings({}),
        modelFullId: 'openai:deepseek-flash',
        providerApiBase: 'https://api.deepseek.com',
        providerApiKey: _apiKey,
        customConfig: const {},
        modelTemperature: 0.3,
        messages: messages,
        tools: [for (final t in _tools) t.toOpenAISchema()],
        boundTools: _tools,
      ),
      sessionId: 'ui-blocks',
      userText: null,
      turnId: 'ui-blocks',
      responseProcessors: const [],
      maxRounds: 5,
    ))
        .replyText;

List<UiBlock> _blocks(String reply) {
  final blocks = <UiBlock>[];
  for (final fence in scanFencedCodeBlocks(reply)) {
    if (fence.language != kUiBlockFenceLanguage) continue;
    final parsed = UiBlock.parse(fence.code);
    expect(parsed.error, isNull, reason: fence.code);
    final block = parsed.block!;
    expect(
      block.component == 'panel' || kUiCatalogNames.contains(block.component),
      isTrue,
      reason: block.component,
    );
    expect(UiProgram.compile(block).issues, isEmpty, reason: fence.code);
    blocks.add(block);
  }
  return blocks;
}

void main() {
  final system = {
    'role': 'system',
    'content': AssistantRequestScope.promptText,
  };

  test(
    'answers a setup question with a block',
    () async {
      final reply = await _ask([
        system,
        {'role': 'user', 'content': '我想用语音通话，需要先准备哪些东西？带我一步步来'},
      ]);
      // ignore: avoid_print
      print(reply);
      expect(_blocks(reply), isNotEmpty);
    },
    skip: _apiKey == null,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'walks troubleshooting with a decision tree or checklist',
    () async {
      final reply = await _ask([
        system,
        {
          'role': 'user',
          'content': '我的角色一直不画画，先别查我的配置，给我一个能自己点着排查的东西',
        },
      ]);
      // ignore: avoid_print
      print(reply);
      final blocks = _blocks(reply);
      expect(blocks, isNotEmpty);
    },
    skip: _apiKey == null,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'uses the values the user set',
    () async {
      const earlier = '先确认三样：\n```aicove-ui\n'
          '{"component": "checklist", "id": "voice-setup", "title": "语音通话准备", '
          '"items": ["选音色预设", "填语音渠道的 Key", "选识别来源"]}\n```';
      final state = buildUiStateContext(
        {
          uiSavedBlockKey('a1', 'voice-setup'): const UiSavedBlock(
            state: {'done': [0, 1]},
            title: '语音通话准备',
          ),
        },
        ['a1'],
      )!;
      final reply = await _ask([
        system,
        {'role': 'user', 'content': '语音通话要准备什么？'},
        {'role': 'assistant', 'content': earlier},
        {'role': 'user', 'content': '$state\n\n我还差哪一步？'},
      ]);
      // ignore: avoid_print
      print(reply);
      expect(reply, contains('识别'));
    },
    skip: _apiKey == null,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
