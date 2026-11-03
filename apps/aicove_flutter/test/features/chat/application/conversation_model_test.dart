import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/core/utils/message_formatter.dart';
import 'package:aicove_flutter/src/features/chat/application/conversation_model.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';

void main() {
  final settings = _settings();

  Conversation conv(String? model) => Conversation(
        id: 'c1',
        title: 'c1',
        displayName: 'c1',
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
        messages: const [],
        sessionProvider: model,
      );

  test('no session model follows the default queue', () {
    expect(conversationModelOverride(settings, conv(null)), isNull);
    expect(conversationPrimaryModel(settings, conv(null)), 'openai:a');
    expect(
      conversationChatModels(settings, conv(null)),
      ['openai:a', 'openai:b'],
    );
  });

  test('session model goes first and the queue stays as fallback', () {
    expect(conversationPrimaryModel(settings, conv('openai:c')), 'openai:c');
    expect(
      conversationChatModels(settings, conv('openai:b')),
      ['openai:b', 'openai:a'],
    );
    expect(
      conversationChatModels(
        settings,
        conv('openai:c'),
        base: const ['openai:b'],
      ),
      ['openai:c', 'openai:b'],
    );
  });

  test('a session model no longer visible is ignored', () {
    expect(conversationModelOverride(settings, conv('openai:gone')), isNull);
    expect(conversationPrimaryModel(settings, conv('openai:gone')), 'openai:a');
  });
}

AppSettings _settings() {
  const models = ['openai:a', 'openai:b', 'openai:c'];
  return AppSettings(
    ttsEnabled: false,
    defaultModelName: 'openai:a',
    defaultChatModels: const ['openai:a', 'openai:b'],
    defaultPersonaPrompt: '',
    modelList: models,
    allKnownModels: models,
    modelDisplayNames: const {},
    modelTypes: const {},
    modelConfigs: const {},
    apiKey: '',
    apiBaseUrl: '',
    imageGenerationEnabled: false,
    maxFileUploadMB: 10,
    contextWindowTokens: 1000,
    customModels: const [],
    providers: const [],
    modelProviderMap: const {},
    backendApiKey: '',
    messageChunkingEnabled: false,
    messageFormatConfig: const MessageFormatConfig(),
    textScaleFactor: 1.0,
    uiScaleFactor: 1.0,
    autoReplySettings: const AutoReplySettings(),
    globalBackgroundColor: GlobalBackgroundColor.white,
    chatBackgroundColor: ChatBackgroundColor.defaultColor,
    isDarkMode: false,
    useSystemTheme: true,
    accentColor: 'FC96AA',
  );
}
