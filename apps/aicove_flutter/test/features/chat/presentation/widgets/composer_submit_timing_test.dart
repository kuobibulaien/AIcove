import 'dart:async';

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
  return AppSettings(
    ttsEnabled: true,
    defaultModelName: defaultModelRef,
    defaultPersonaPrompt: '',
    modelList: const <String>[defaultModelRef],
    allKnownModels: const <String>[defaultModelRef],
    modelDisplayNames: const <String, String>{},
    modelTypes: const <String, String>{},
    modelConfigs: const <String, ModelConfig>{},
    apiKey: '',
    apiBaseUrl: 'https://api.openai.com/v1',
    imageGenerationEnabled: false,
    maxFileUploadMB: 10,
    historyMessageLimit: 100,
    customModels: const <CustomModel>[],
    providers: const <ProviderAuth>[],
    modelProviderMap: const <String, String>{},
    backendApiKey: '',
    messageChunkingEnabled: false,
    messageFormatConfig: const MessageFormatConfig(),
    textScaleFactor: 1.0,
    uiScaleFactor: 1.0,
    imagePreviewScale: 1.0,
    autoReplySettings: const AutoReplySettings(),
    globalBackgroundColor: GlobalBackgroundColor.white,
    chatBackgroundColor: ChatBackgroundColor.defaultColor,
    isDarkMode: false,
    useSystemTheme: true,
    accentColor: 'FC96AA',
    hideUserAvatar: true,
    defaultChatModels: const <String>[defaultModelRef],
    streamSegmentDelaySeconds: 0,
  );
}

Conversation _buildConversation(String id) {
  final now = DateTime(2026, 3, 24, 10, 0, 0);
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
  required Future<void> Function(String text) onSend,
  required ValueChanged<double> onHeightChanged,
}) {
  final settings = _buildSettings();
  return ProviderScope(
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
            onSend: onSend,
            onImageSelected: (_, {String? text}) async {},
            onFileSelected: (_, {String? text}) async {},
            onHeightChanged: onHeightChanged,
          ),
        ),
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('pending send callback should keep text and height stable',
      (tester) async {
    final sendCompleter = Completer<void>();
    final reportedHeights = <double>[];

    await tester.pumpWidget(
      _buildHost(
        conversation: _buildConversation('conv_submit_timing'),
        onSend: (_) => sendCompleter.future,
        onHeightChanged: reportedHeights.add,
      ),
    );
    await _pumpComposerReady(tester);

    const draftText = '第一行\n第二行\n第三行';
    await tester.enterText(find.byType(TextField), draftText);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));

    final heightBeforeSend = reportedHeights.isEmpty ? 0 : reportedHeights.last;
    final heightCountBeforeSend = reportedHeights.length;

    await tester.tap(find.byTooltip('发送'));
    await tester.pump();

    final editableBeforeComplete =
        tester.widget<EditableText>(find.byType(EditableText));
    expect(editableBeforeComplete.controller.text, draftText);
    expect(reportedHeights.length, heightCountBeforeSend);
    if (reportedHeights.isNotEmpty) {
      expect(reportedHeights.last, heightBeforeSend);
    }

    sendCompleter.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));

    final editableAfterComplete =
        tester.widget<EditableText>(find.byType(EditableText));
    expect(editableAfterComplete.controller.text, isEmpty);
    expect(reportedHeights.length, greaterThan(heightCountBeforeSend));
    expect(reportedHeights.last, lessThan(heightBeforeSend));
  });
}

Future<void> _pumpComposerReady(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump(const Duration(milliseconds: 100));
}
