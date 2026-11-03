import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:aicove_flutter/src/core/api/providers/provider_adapter.dart';
import 'package:aicove_flutter/src/core/api/thinking/thinking_level.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/auto_reply_agent_helpers.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/auto_reply_request_config.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_types.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/features/voice_call/data/api_runner_call_reply_generator.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  final settings = mapUiModelsToAppSettings(const {}).copyWith(
    modelList: const ['openai:a', 'openai:b'],
    allKnownModels: const ['openai:a', 'openai:b'],
    defaultModelName: 'openai:a',
    defaultChatModels: const ['openai:a'],
  );
  final now = DateTime(2026, 10, 23);
  Conversation conv(String? model) => Conversation(
        id: 'c',
        title: 'c',
        displayName: 'c',
        createdAt: now,
        updatedAt: now,
        sessionProvider: model,
      );

  test('background precheck accepts enabled multi-key items, not apiKeys.first', () async {
    final multi = settings.copyWith(providers: const [ProviderAuth(
      id: 'openai', apiKeys: [''], apiBaseUrl: 'https://model.invalid',
      customConfig: {'multi_key_enabled': true, 'multi_key_items': [
        {'id': 'disabled', 'key': 'disabled', 'enabled': false},
        {'id': 'active', 'key': 'active-key', 'enabled': true},
      ]},
    )]);
    final request = await resolveAutoReplyRequestConfig(multi);
    expect(request.providerApiKey, 'active-key');
  });

  test('proactive reply and voice call use the role model', () {
    expect(resolveAutoReplyAgentModelRef(settings, conv('openai:b')),
        'openai:b');
    expect(resolveAutoReplyAgentModelRef(settings, conv(null)), 'openai:a');
    expect(voiceCallModelRef(settings, conv('openai:b')), 'openai:b');
    expect(voiceCallModelRef(settings, conv('openai:gone')), 'openai:a');
  });

  test('background config resolves the stored session model', () async {
    final session = await resolveAutoReplyRequestConfig(
      settings,
      sessionModel: 'openai:b',
    );
    final fallback = await resolveAutoReplyRequestConfig(settings);
    expect(session.modelFullId, endsWith(':b'));
    expect(fallback.modelFullId, endsWith(':a'));
  });

  test('auto reply wrappers keep the resolved thinking options', () {
    final config = ApiConfig(
      settings: settings,
      modelFullId: 'openai:b',
      providerApiBase: '',
      providerApiKey: null,
      customConfig: const <String, dynamic>{},
      messages: const <Map<String, dynamic>>[
        {'role': 'user', 'content': 'hi'},
      ],
      tools: const <Map<String, dynamic>>[
        {'type': 'function'},
      ],
      enabledPluginIds: null,
      modelTemperature: null,
      modelTopP: null,
      modelContextMessageLimit: null,
      providerRequestOptions: const ProviderChatRequestOptions(
        thinkingLevel: ThinkingLevel.high,
      ),
    );

    final noTools = disableNativeToolCallsForAutoReplyGeneration(config);
    expect(noTools.tools, isNull);
    expect(noTools.modelTemperature, 0.7);
    expect(noTools.providerRequestOptions?.thinkingLevel, ThinkingLevel.high);

    final reminded = appendAutoReplyReminderAsLastUser(noTools, '提醒');
    expect(reminded.messages.length, greaterThan(config.messages.length));
    expect(reminded.providerRequestOptions?.thinkingLevel, ThinkingLevel.high);
    expect(reminded.modelTemperature, 0.7);

    final warm = config.copyWith(modelTemperature: 1.2);
    expect(warm.copyWith().modelTemperature, 1.2);
    expect(
      appendAutoReplyReminderAsLastUser(
        disableNativeToolCallsForAutoReplyGeneration(warm),
        '提醒',
      ).modelTemperature,
      1.2,
    );
  });
}
