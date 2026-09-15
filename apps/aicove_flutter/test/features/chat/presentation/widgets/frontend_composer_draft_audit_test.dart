import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:aicove_flutter/src/core/utils/message_formatter.dart';
import 'package:aicove_flutter/src/features/chat/conversation_providers.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/features/chat/presentation/widgets/composer.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/ui/theme/skin_provider.dart';
import 'package:aicove_flutter/src/ui/theme/skins/moetalk_skin.dart';

class _FakeAppSettingsNotifier extends AppSettingsNotifier {
  _FakeAppSettingsNotifier(this._settings);

  final AppSettings _settings;

  @override
  Future<AppSettings> build() async => _settings;
}

AppSettings _buildSettings() {
  const defaultModelRef = 'openai:gpt-4o-mini';
  return const AppSettings(
    ttsEnabled: true,
    defaultModelName: defaultModelRef,
    defaultPersonaPrompt: '',
    modelList: <String>[defaultModelRef],
    allKnownModels: <String>[defaultModelRef],
    modelDisplayNames: <String, String>{},
    modelTypes: <String, String>{},
    modelConfigs: <String, ModelConfig>{},
    apiKey: '',
    apiBaseUrl: 'https://api.openai.com/v1',
    imageGenerationEnabled: false,
    maxFileUploadMB: 10,
    contextWindowTokens: 272000,
    customModels: <CustomModel>[],
    providers: <ProviderAuth>[],
    modelProviderMap: <String, String>{},
    backendApiKey: '',
    messageChunkingEnabled: false,
    messageFormatConfig: MessageFormatConfig(),
    textScaleFactor: 1.0,
    uiScaleFactor: 1.0,
    imagePreviewScale: 1.0,
    autoReplySettings: AutoReplySettings(),
    globalBackgroundColor: GlobalBackgroundColor.white,
    chatBackgroundColor: ChatBackgroundColor.defaultColor,
    isDarkMode: false,
    useSystemTheme: true,
    accentColor: 'FC96AA',
    hideUserAvatar: true,
    defaultChatModels: <String>[defaultModelRef],
    streamSegmentDelaySeconds: 0,
  );
}

Conversation _buildConversation(String id) {
  final now = DateTime(2026, 3, 23, 21, 0, 0);
  return Conversation(
    id: id,
    title: id,
    displayName: id,
    createdAt: now,
    updatedAt: now,
    lastMessageTime: now,
  );
}

Widget _buildHost({
  required Conversation conversation,
}) {
  final settings = _buildSettings();
  return ProviderScope(
    key: ValueKey<String>('composer_scope_${conversation.id}'),
    overrides: [
      appSettingsProvider.overrideWith(
        () => _FakeAppSettingsNotifier(settings),
      ),
      activeConversationProvider.overrideWith((ref) => conversation),
    ],
    child: SkinScope(
      skin: const MoeTalkSkin(),
      child: MaterialApp(
        home: Scaffold(
          body: Composer(
            onSend: (_) {},
            onImageSelected: (_, {String? text}) {},
            onFileSelected: (_, {String? text}) {},
          ),
        ),
      ),
    ),
  );
}

void main() {
  for (final delay in [Duration.zero, const Duration(milliseconds: 650)]) {
    testWidgets('composer draft survives removal after $delay', (tester) async {
      SharedPreferences.setMockInitialValues({});
      await tester
          .pumpWidget(_buildHost(conversation: _buildConversation('audit')));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byType(TextField).first, 'synthetic unsent draft');
      await tester.pump(delay);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 700));
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(composerDraftStorageKey('audit'));
      expect(raw, isNotNull,
          reason: 'removing composer must retain unsent text');
      expect((jsonDecode(raw!) as Map)['text'], 'synthetic unsent draft');
    });
  }
}
