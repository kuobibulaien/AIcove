// Real-model check for ADR0098 acceptance gate 1 (opt-in).
//
// DeepSeek Flash reads a PNG from a workspace through the kernel runner,
// once as a vision model (OpenAI format: image in a user message after the
// tool results) and once marked text-only (no image sent; the model should
// tell the user it cannot see it and suggest another model). Skipped unless
// DEEPSEEK_API_KEY is set; the key is read from the environment only.
@Tags(['real_model'])
library;

import 'dart:io';

import 'package:aicove_flutter/src/features/chat/services/api_runner.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_types.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/features/workspace/application/workspace_toolset.dart';
import 'package:aicove_flutter/src/features/workspace/data/workspace_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

final String? _apiKey = Platform.environment['DEEPSEEK_API_KEY'];
const _model = 'openai:deepseek-flash';

Future<(List<String>, String)> _ask({required bool vision}) async {
  final root = await Directory.systemTemp.createTemp('ws_image_real');
  final store = await WorkspaceStore.open(root);
  try {
    final ws = await store.create(name: '相册');
    final picture = img.Image(width: 64, height: 64)
      ..clear(img.ColorRgb8(240, 120, 40));
    await store.write(ws.id, 'cat.png', img.encodePng(picture), runId: 'seed');
    final tools = WorkspaceToolset(
      store: store,
      workspaceIds: {ws.id},
      runId: 'real',
    ).tools();
    final base = mapUiModelsToAppSettings({});
    final settings = vision
        ? base
        : base.copyWith(
            modelConfigs: {
              ...base.modelConfigs,
              _model: const ModelConfig(chatCapabilities: ['tools']),
            },
          );
    const question = '帮我看看工作区里的 cat.png 画的是什么，一两句话回答。';
    final result = await createApiRunner().executeApiCall(
      config: ApiConfig(
        settings: settings,
        modelFullId: _model,
        providerApiBase: 'https://api.deepseek.com',
        providerApiKey: _apiKey,
        customConfig: const {},
        modelTemperature: 0,
        messages: [
          {
            'role': 'system',
            'content': '你是用户的助手。工作区 ID 是 ${ws.id}，需要看文件时用 workspace_read。',
          },
          {'role': 'user', 'content': question},
        ],
        tools: [for (final tool in tools) tool.toOpenAISchema()],
        boundTools: tools,
      ),
      sessionId: 'ws_image_real',
      userText: question,
      responseProcessors: const [],
      availableTools: tools,
    );
    final reply = result.processedText.trim().isNotEmpty
        ? result.processedText
        : result.replyText;
    return ([for (final c in result.toolCalls) c.name], reply);
  } finally {
    await store.close();
    await root.delete(recursive: true);
  }
}

void main() {
  final skip = _apiKey == null ? '未设置 DEEPSEEK_API_KEY' : false;

  test(
    'vision model sees the image read from a workspace',
    () async {
      final (calls, reply) = await _ask(vision: true);
      // ignore: avoid_print
      print('vision calls: $calls\nvision reply: $reply');
      expect(calls, contains('workspace_read'));
      expect(reply, contains('橙'));
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'text-only model says it cannot see and suggests another model',
    () async {
      final (calls, reply) = await _ask(vision: false);
      // ignore: avoid_print
      print('text-only calls: $calls\ntext-only reply: $reply');
      expect(calls, contains('workspace_read'));
      expect(reply, isNot(contains('橙')));
      expect(reply, contains('模型'));
      expect(reply, contains('换'));
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
