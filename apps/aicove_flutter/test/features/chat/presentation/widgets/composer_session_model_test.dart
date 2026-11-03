import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:aicove_flutter/src/core/utils/message_formatter.dart';
import 'package:aicove_flutter/src/features/chat/conversation_providers.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/features/chat/presentation/widgets/composer.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';

class _FakeAppSettingsNotifier extends AppSettingsNotifier {
  _FakeAppSettingsNotifier(this._settings);

  final AppSettings _settings;
  final List<String> defaultModelWrites = <String>[];

  @override
  Future<AppSettings> build() async => _settings;

  @override
  Future<void> setDefaultModelName(String modelId) async {
    defaultModelWrites.add(modelId);
  }
}

class _FakeConversationsNotifier extends ConversationsNotifier {
  _FakeConversationsNotifier(this._seed);

  final List<Conversation> _seed;

  @override
  Future<List<Conversation>> build() async => _seed;

  @override
  Future<void> setAll(List<Conversation> list, {bool persist = true}) async {
    state = AsyncValue.data(list);
  }

  @override
  Future<void> saveOne(Conversation conv) async {}
}

const _models = <String>['openai:a', 'openai:b', 'openai:c'];

AppSettings _buildSettings() {
  return const AppSettings(
    ttsEnabled: true,
    defaultModelName: 'openai:a',
    defaultPersonaPrompt: '',
    modelList: _models,
    allKnownModels: _models,
    modelDisplayNames: <String, String>{
      'openai:a': '模型 A',
      'openai:b': '模型 B',
      'openai:c': '模型 C',
    },
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
    defaultChatModels: <String>['openai:a', 'openai:b'],
    streamSegmentDelaySeconds: 0,
  );
}

Conversation _conv(String id, {String? sessionModel}) {
  final now = DateTime(2026, 10, 23);
  return Conversation(
    id: id,
    title: id,
    displayName: id,
    createdAt: now,
    updatedAt: now,
    lastMessageTime: now,
    sessionProvider: sessionModel,
  );
}

Future<ProviderContainer> _pumpComposer(
  WidgetTester tester, {
  required List<Conversation> conversations,
  required _FakeAppSettingsNotifier settings,
}) async {
  tester.view.physicalSize = const Size(800, 1600);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [
      appSettingsProvider.overrideWith(() => settings),
      conversationsProvider.overrideWith(
        () => _FakeConversationsNotifier(conversations),
      ),
      activeConversationProvider.overrideWith((ref) {
        final list = ref.watch(conversationsProvider).valueOrNull;
        return list?.first;
      }),
    ],
  );
  addTearDown(container.dispose);
  await container.read(conversationsProvider.future);
  await container.read(appSettingsProvider.future);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: ThemeData(
          platform: TargetPlatform.macOS,
          extensions: [MoeColors.light()],
        ),
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: Composer(
              onSend: (_) async {},
              onImageSelected: (_, {String? text}) async {},
              onFileSelected: (_, {String? text}) async {},
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

Future<void> _openModelPicker(WidgetTester tester) async {
  await tester.tap(find.byType(IconButton).first);
  await tester.pumpAndSettle();
  await tester.tap(find.text('模型'));
  await tester.pumpAndSettle();
}

Future<void> _drainToast(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 5));
  await tester.pumpAndSettle();
}

Conversation _stored(ProviderContainer container, String id) {
  return container
      .read(conversationsProvider)
      .requireValue
      .firstWhere((c) => c.id == id);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('picking a model saves it on this conversation only',
      (tester) async {
    final settings = _FakeAppSettingsNotifier(_buildSettings());
    final container = await _pumpComposer(
      tester,
      conversations: [_conv('a'), _conv('b', sessionModel: 'openai:b')],
      settings: settings,
    );

    await _openModelPicker(tester);
    await tester.tap(find.text('模型 C'));
    await tester.pumpAndSettle();

    expect(_stored(container, 'a').sessionProvider, 'openai:c');
    expect(_stored(container, 'b').sessionProvider, 'openai:b');
    expect(settings.defaultModelWrites, isEmpty);
    await _drainToast(tester);
  });

  testWidgets('follow default clears a choice that is no longer visible',
      (tester) async {
    final settings = _FakeAppSettingsNotifier(_buildSettings());
    final container = await _pumpComposer(
      tester,
      conversations: [_conv('a', sessionModel: 'openai:hidden')],
      settings: settings,
    );

    await _openModelPicker(tester);
    expect(find.textContaining('原选模型：'), findsOneWidget);
    await tester.tap(find.text('跟随默认模型'));
    await tester.pumpAndSettle();

    expect(_stored(container, 'a').sessionProvider, isNull);
    expect(settings.defaultModelWrites, isEmpty);
    await _drainToast(tester);
  });
}
