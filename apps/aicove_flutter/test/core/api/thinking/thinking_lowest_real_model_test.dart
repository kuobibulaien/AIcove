// Real-model check for the "lowest" thinking level (opt-in).
//
// Sends through AgentApiClient to DeepSeek Flash. Skipped unless
// DEEPSEEK_API_KEY is set; the key is read from the environment only and
// never written anywhere.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:aicove_flutter/src/core/api/agent_api.dart';
import 'package:aicove_flutter/src/core/api/providers/provider_adapter.dart';
import 'package:aicove_flutter/src/core/api/thinking/thinking_fallback.dart';
import 'package:aicove_flutter/src/core/api/thinking/thinking_level_resolver.dart';

final String? _apiKey = Platform.environment['DEEPSEEK_API_KEY'];
const _model = 'openai:deepseek-flash';

Future<SendMessageRichResult> _send(ProviderChatRequestOptions options) {
  return AgentApiClient(timeout: const Duration(seconds: 60)).sendMessageRich(
    agentId: 'real_thinking',
    sessionId: 'real_thinking',
    modelFullId: _model,
    messages: const [
      {'role': 'user', 'content': '用一句话打个招呼。'},
    ],
    userText: '',
    providerApiBase: 'https://api.deepseek.com',
    providerApiKey: _apiKey,
    requestOptions: options,
  );
}

String? _reasoning(SendMessageRichResult result) {
  final choices = result.rawResponse?['choices'];
  if (choices is! List || choices.isEmpty) return null;
  final message = (choices.first as Map)['message'];
  return message is Map ? message['reasoning_content']?.toString() : null;
}

void main() {
  final skip = _apiKey == null ? '未设置 DEEPSEEK_API_KEY' : false;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ThinkingFallbackMemory.instance.resetCache();
  });

  test('software default turns DeepSeek thinking off', () async {
    final effective = resolveEffectiveThinkingLevel(
      providerType: 'openai',
      modelId: 'deepseek-flash',
    );
    final options = effective.applyTo(null);
    expect(options.thinkingScheme, ThinkingScheme.thinkingToggle);
    expect(options.thinkingLevel, ThinkingLevel.off);

    final result = await _send(options);
    expect(result.text.trim(), isNotEmpty);
    expect(_reasoning(result) ?? '', isEmpty);
    expect(await ThinkingFallbackMemory.instance.recall(_model), isNull);
  }, skip: skip, timeout: const Timeout(Duration(minutes: 2)));

  test('generic chain lands on a level DeepSeek accepts', () async {
    const options = ProviderChatRequestOptions(
      thinkingLevel: ThinkingLevel.off,
      thinkingScheme: ThinkingScheme.generic,
      thinkingCandidates: [
        ThinkingLevel.off,
        ThinkingLevel.minimal,
        ThinkingLevel.low,
      ],
    );
    final result = await _send(options);
    expect(result.text.trim(), isNotEmpty);
    final remembered = await ThinkingFallbackMemory.instance.recall(_model);
    // ignore: avoid_print
    print('generic chain remembered: ${remembered?.name ?? '(first try ok)'}');
  }, skip: skip, timeout: const Timeout(Duration(minutes: 2)));
}
