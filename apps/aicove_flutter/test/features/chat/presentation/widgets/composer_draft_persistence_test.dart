import 'dart:convert';
import 'dart:io';

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
            onFileSelected: (_) {},
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

  testWidgets('scoped draft restores text when attachment metadata exists',
      (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'composer_draft_v2:conv_a': jsonEncode(<String, Object?>{
        'version': 1,
        'text': '会话 A 草稿',
        'attachment': <String, Object?>{
          'path': r'C:\missing\composer-draft.png',
          'type': 'image',
        },
      }),
    });
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('composer_draft_v2:conv_a'), isNotNull);

    await tester.pumpWidget(
      _buildHost(conversation: _buildConversation('conv_a')),
    );
    await _pumpComposerReady(tester);

    final editable = tester.widget<EditableText>(find.byType(EditableText));
    expect(editable.controller.text, '会话 A 草稿');

    await _disposeComposer(tester);
  });

  testWidgets('scoped drafts stay isolated per conversation', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'composer_draft_v2:conv_a': jsonEncode(<String, Object?>{
        'version': 1,
        'text': '会话 A 草稿',
      }),
      'composer_draft_v2:conv_b': jsonEncode(<String, Object?>{
        'version': 1,
        'text': '会话 B 草稿',
      }),
    });

    await tester.pumpWidget(
      _buildHost(conversation: _buildConversation('conv_a')),
    );
    await _pumpComposerReady(tester);

    expect(find.text('会话 A 草稿'), findsOneWidget);
    expect(find.text('会话 B 草稿'), findsNothing);

    await tester.pumpWidget(
      _buildHost(conversation: _buildConversation('conv_b')),
    );
    await _pumpComposerReady(tester);

    expect(find.text('会话 A 草稿'), findsNothing);
    expect(find.text('会话 B 草稿'), findsOneWidget);

    await _disposeComposer(tester);
  });

  testWidgets('legacy text draft key still restores', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'composer_draft_text': '旧版草稿',
    });

    await tester.pumpWidget(
      _buildHost(conversation: _buildConversation('legacy_conv')),
    );
    await _pumpComposerReady(tester);

    expect(find.text('旧版草稿'), findsOneWidget);

    await _disposeComposer(tester);
  });

  test('image draft attachment decodes and restores when file exists',
      () async {
    final directory = await Directory.systemTemp.createTemp(
      'aicove_composer_draft_attachment',
    );
    final imageFile = File('${directory.path}\\draft.png');
    await imageFile.writeAsBytes(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO7Z0ioAAAAASUVORK5CYII=',
      ),
    );

    final attachment = composerDecodeDraftAttachment(<String, Object?>{
      'path': imageFile.path,
      'type': 'image',
    });
    final restored = await composerResolveRestorableDraftAttachment(
      attachment,
    );

    expect(attachment, isNotNull);
    expect(attachment!.type.name, 'image');
    expect(restored?.path, imageFile.path);
  });

  test('image draft attachment drops when file is missing', () async {
    final attachment = composerDecodeDraftAttachment(<String, Object?>{
      'path': r'C:\missing\composer-draft.png',
      'type': 'image',
    });
    final restored = await composerResolveRestorableDraftAttachment(
      attachment,
    );

    expect(attachment, isNotNull);
    expect(restored, isNull);
  });
}

Future<void> _pumpComposerReady(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump(const Duration(milliseconds: 100));
}

Future<void> _disposeComposer(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 50));
}
