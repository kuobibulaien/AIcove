// Real-model check for interactive blocks (ADR0073 交互组件, batch U1): with
// the assistant prompt, DeepSeek Flash answers setup and troubleshooting
// questions with `aicove-ui` blocks that parse and compile cleanly, and uses
// the user's values from <ui_state>. Skipped unless DEEPSEEK_API_KEY is set.
@Tags(['real_model'])
library;

import 'dart:io';

import 'package:aicove_flutter/src/core/utils/markdown_fence.dart';
import 'package:aicove_flutter/src/features/assistant/application/assistant_plugin.dart';
import 'package:aicove_flutter/src/features/assistant/application/assistant_settings.dart';
import 'package:aicove_flutter/src/features/assistant/application/assistant_toolset.dart';
import 'package:aicove_flutter/src/features/assistant/domain/aicove_docs.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/features/chat/domain/persona_prompt_codec.dart';
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
  roles: () async => [
    Conversation(
      id: 'preset_nahida',
      title: '纳西妲',
      displayName: '纳西妲',
      description: '须弥的草神',
      personaPrompt: PersonaPromptCodec.compose(
        userPrompt: '你是纳西妲。',
        drawingPresetId: 'drawing_default',
      ),
      createdAt: DateTime(2026, 10, 19),
      updatedAt: DateTime(2026, 10, 19),
    ),
    Conversation(
      id: 'role_xiaoxue',
      title: '小雪',
      displayName: '小雪',
      createdAt: DateTime(2026, 10, 19),
      updatedAt: DateTime(2026, 10, 19),
    ),
  ],
  presets: () async => const [],
  previewContext: (_) => throw UnimplementedError(),
  readDoc: (id) async => id == kAicoveSettingsDocId
      ? assistantSettingsDoc()
      : File('assets/aicove_docs/$id.md').readAsStringSync(),
).tools();

Future<String> _ask(List<Map<String, dynamic>> messages) async =>
    (await createApiRunner().executeApiCall(
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
    )).replyText;

List<UiBlock> _blocks(String reply) {
  final blocks = <UiBlock>[];
  for (final fence in scanFencedCodeBlocks(reply)) {
    if (fence.language != kUiBlockFenceLanguage) continue;
    final parsed = UiBlock.parse(fence.code);
    expect(parsed.error, isNull, reason: fence.code);
    final block = parsed.block!;
    expect(
      block.component == 'panel' ||
          kUiCatalogNames.contains(block.component) ||
          kUiActionComponents.contains(block.component),
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
        {'role': 'user', 'content': '我的角色一直不画画，先别查我的配置，给我一个能自己点着排查的东西'},
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
      const earlier =
          '先确认三样：\n```aicove-ui\n'
          '{"component": "checklist", "id": "voice-setup", "title": "语音通话准备", '
          '"items": ["选音色预设", "填语音渠道的 Key", "选识别来源"]}\n```';
      final state = buildUiStateContext(
        {
          uiSavedBlockKey('a1', 'voice-setup'): const UiSavedBlock(
            state: {
              'done': [0, 1],
            },
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

  // ADR0094 quick panels: a vague request about a role's drawing preset
  // gets a live panel focused on that role, not a hand-written list.
  test(
    'a vague drawing preset request gets a quick panel for that role',
    () async {
      final reply = await _ask([
        system,
        {'role': 'user', 'content': '帮我改一下纳西妲的绘图预设'},
      ]);
      // ignore: avoid_print
      print(reply);
      final panels = [
        for (final block in _blocks(reply))
          if (kUiActionComponents.contains(block.component)) block,
      ];
      expect(panels, isNotEmpty);
      final panel = panels.first;
      final props = panel.root.props;
      expect(
        (panel.component == 'drawing-presets' &&
                props['role'] == 'preset_nahida') ||
            (panel.component == 'roles' && props['purpose'] == 'drawing'),
        isTrue,
        reason: '${panel.component} $props',
      );
    },
    skip: _apiKey == null,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'a request to tweak settings by hand gets a settings panel with real keys',
    () async {
      final reply = await _ask([
        system,
        {'role': 'user', 'content': '我想自己调一下字号和深浅色，给我个能直接调的地方'},
      ]);
      // ignore: avoid_print
      print(reply);
      final panel = _blocks(
        reply,
      ).where((b) => b.component == 'settings').firstOrNull;
      expect(panel, isNotNull);
      final keys = [for (final k in panel!.root.props['keys'] as List) '$k'];
      expect(keys, containsAll(['appearance.text_scale', 'appearance.theme']));
    },
    skip: _apiKey == null,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
