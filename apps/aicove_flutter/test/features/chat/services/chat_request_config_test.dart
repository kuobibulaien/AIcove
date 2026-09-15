import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/core/utils/message_formatter.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_request_config.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/features/settings/mcp_api.dart';
import 'package:aicove_flutter/src/features/settings/provider_detail/provider_detail_support.dart';

void main() {
  test('用尽策略沿用当前 Key，当前 Key 错误后切到下一个可用 Key', () async {
    final builder = _NoMcpChatRequestConfigBuilder();

    final initial = await builder.buildRequestConfig(
      _buildSettings(
        roundRobinIndex: 0,
        firstStatus: 'normal',
      ),
    );
    expect(initial.providerApiKey, 'sk-one');
    expect(initial.providerApiKeyItemId, 'mk_1');
    expect(initial.providerApiKeyItemIndex, 0);
    expect(initial.providerApiKeyStrategy, providerMultiKeyStrategyExhaust);

    final afterFailure = await builder.buildRequestConfig(
      _buildSettings(
        roundRobinIndex: 1,
        firstStatus: 'error',
      ),
    );
    expect(afterFailure.providerApiKey, 'sk-two');
    expect(afterFailure.providerApiKeyItemId, 'mk_2');
    expect(afterFailure.providerApiKeyItemIndex, 1);
  });

  test('模型默认思考档位从 ModelConfig 读出', () async {
    final builder = _NoMcpChatRequestConfigBuilder();

    final withLevel = await builder.buildRequestConfig(
      _buildSettings(
        roundRobinIndex: 0,
        firstStatus: 'normal',
        modelConfigs: const <String, ModelConfig>{
          'openai:gpt-4o-mini': ModelConfig(thinkingLevel: ThinkingLevel.high),
        },
      ),
    );
    expect(withLevel.modelThinkingLevel, ThinkingLevel.high);

    final without = await builder.buildRequestConfig(
      _buildSettings(roundRobinIndex: 0, firstStatus: 'normal'),
    );
    expect(without.modelThinkingLevel, isNull);
  });
}

class _NoMcpChatRequestConfigBuilder extends ChatRequestConfigBuilder {
  @override
  Future<McpConfigDto?> getMcpConfig() async => null;
}

AppSettings _buildSettings({
  required int roundRobinIndex,
  required String firstStatus,
  Map<String, ModelConfig> modelConfigs = const <String, ModelConfig>{},
}) {
  return AppSettings(
    ttsEnabled: false,
    defaultModelName: 'openai:gpt-4o-mini',
    temperature: 0.7,
    defaultPersonaPrompt: '',
    modelList: const <String>['openai:gpt-4o-mini'],
    allKnownModels: const <String>['openai:gpt-4o-mini'],
    modelDisplayNames: const <String, String>{},
    modelTypes: const <String, String>{},
    modelConfigs: modelConfigs,
    apiKey: '',
    apiBaseUrl: 'https://api.example.com/v1',
    imageGenerationEnabled: false,
    maxFileUploadMB: 10,
    contextWindowTokens: 272000,
    customModels: const <CustomModel>[],
    providers: <ProviderAuth>[
      ProviderAuth(
        id: 'openai',
        displayName: 'OpenAI',
        apiKeys: const <String>['sk-one', 'sk-two'],
        apiBaseUrl: 'https://api.example.com/v1',
        models: const <String>['gpt-4o-mini'],
        visibleModels: const <String>['gpt-4o-mini'],
        customConfig: <String, dynamic>{
          providerMultiKeyEnabledField: true,
          providerMultiKeyStrategyField: providerMultiKeyStrategyExhaust,
          providerMultiKeyRoundRobinIndexField: roundRobinIndex,
          providerMultiKeyItemsField: <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'mk_1',
              'key': 'sk-one',
              'enabled': true,
              'status': firstStatus,
              'updated_at': 1,
            },
            <String, dynamic>{
              'id': 'mk_2',
              'key': 'sk-two',
              'enabled': true,
              'status': 'normal',
              'updated_at': 2,
            },
          ],
        },
      ),
    ],
    modelProviderMap: const <String, String>{
      'gpt-4o-mini': 'openai',
      'openai:gpt-4o-mini': 'openai',
    },
    backendApiKey: '',
    messageChunkingEnabled: false,
    messageFormatConfig: const MessageFormatConfig(),
    textScaleFactor: 1,
    uiScaleFactor: 1,
    autoReplySettings: const AutoReplySettings(),
    globalBackgroundColor: GlobalBackgroundColor.white,
    chatBackgroundColor: ChatBackgroundColor.defaultColor,
    isDarkMode: false,
    useSystemTheme: false,
    accentColor: 'pink',
    defaultChatModels: const <String>['openai:gpt-4o-mini'],
  );
}
