import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/core/utils/message_formatter.dart';
import 'package:aicove_flutter/src/features/chat/presentation/widgets/composer_model_picker_sheet.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/ui/theme/skin_provider.dart';
import 'package:aicove_flutter/src/ui/theme/skins/moetalk_skin.dart';

class _FakeAppSettingsNotifier extends AppSettingsNotifier {
  _FakeAppSettingsNotifier(this._settings);

  final AppSettings _settings;
  final List<List<String>> reorderedQueues = <List<String>>[];
  final List<String> selectedModels = <String>[];

  AppSettings get currentSettings => _settings;

  @override
  Future<AppSettings> build() async => _settings;

  @override
  Future<void> setDefaultChatModels(List<String> models) async {
    reorderedQueues.add(List<String>.from(models));
  }

  @override
  Future<void> setDefaultModelName(String modelId) async {
    selectedModels.add(modelId);
  }
}

void main() {
  test('composerGroupModelsByProvider groups visible models by provider', () {
    final settings = _buildSettings(
      defaultModelName: 'openai:model-a',
      defaultChatModels: const <String>['openai:model-a'],
    );
    final groups = composerGroupModelsByProvider(settings);
    expect(groups, hasLength(1));
    expect(groups.single.providerId, 'openai');
    expect(groups.single.providerName, 'OpenAI');
    expect(
      groups.single.models,
      <String>['openai:model-a', 'openai:model-b', 'openai:model-c'],
    );
  });

  testWidgets('tapping a model picks it for this session only without global queue editor',
      (tester) async {
    final notifier = _FakeAppSettingsNotifier(
      _buildSettings(
        defaultModelName: 'openai:model-a',
        defaultChatModels: const <String>[
          'openai:model-a',
          'openai:model-b',
        ],
      ),
    );
    final results = <ComposerModelSelection?>[];

    await tester.pumpWidget(_buildHost(notifier, results: results));
    await _openSheet(tester);

    expect(find.byType(ReorderableListView), findsNothing);
    expect(find.text('默认队列'), findsNothing);
    expect(find.text('其他可用模型'), findsNothing);
    expect(find.text('OpenAI'), findsOneWidget);

    await tester.tap(find.text('模型 C'));
    await tester.pumpAndSettle();

    expect(results.single?.modelRef, 'openai:model-c');
    expect(notifier.selectedModels, isEmpty);
    expect(notifier.reorderedQueues, isEmpty);
    expect(notifier.currentSettings.defaultModelName, 'openai:model-a');
  });

  testWidgets('session model is marked and follow-default clears it',
      (tester) async {
    final notifier = _FakeAppSettingsNotifier(
      _buildSettings(
        defaultModelName: 'openai:model-a',
        defaultChatModels: const <String>[
          'openai:model-a',
          'openai:model-b',
        ],
      ),
    );
    final results = <ComposerModelSelection?>[];

    await tester.pumpWidget(
      _buildHost(notifier, sessionModel: 'openai:model-b', results: results),
    );
    await _openSheet(tester);

    final followTile = find.byKey(const ValueKey<String>('follow_default_queue'));
    expect(
      find.descendant(
        of: followTile,
        matching: find.byIcon(Icons.radio_button_unchecked),
      ),
      findsOneWidget,
    );
    expect(find.text('当前默认：模型 A（OpenAI）'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('model_openai:model-b')),
        matching: find.byIcon(Icons.radio_button_checked),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('model_openai:model-a')),
        matching: find.byIcon(Icons.radio_button_checked),
      ),
      findsNothing,
    );

    await tester.tap(find.text('跟随默认模型'));
    await tester.pumpAndSettle();

    expect(results.single, isNotNull);
    expect(results.single!.modelRef, isNull);
    expect(notifier.selectedModels, isEmpty);
  });

  testWidgets('stale session model shows unavailable notice and can be cleared',
      (tester) async {
    final notifier = _FakeAppSettingsNotifier(
      _buildSettings(
        defaultModelName: 'openai:model-a',
        defaultChatModels: const <String>['openai:model-a'],
      ),
    );
    final results = <ComposerModelSelection?>[];

    await tester.pumpWidget(
      _buildHost(notifier, sessionModel: 'openai:hidden-model', results: results),
    );
    await _openSheet(tester);

    expect(
      find.byKey(const ValueKey<String>('stale_session_model')),
      findsOneWidget,
    );
    expect(
      find.text('原选模型：hidden-model（OpenAI）'),
      findsOneWidget,
    );
    expect(
      find.text('该模型已隐藏或渠道已关闭，当前暂按默认模型回复'),
      findsOneWidget,
    );
    final followTile = find.byKey(const ValueKey<String>('follow_default_queue'));
    expect(
      find.descendant(
        of: followTile,
        matching: find.byIcon(Icons.radio_button_unchecked),
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('跟随默认模型'));
    await tester.pumpAndSettle();

    expect(results.single, isNotNull);
    expect(results.single!.modelRef, isNull);
  });
}

AppSettings _buildSettings({
  required String defaultModelName,
  required List<String> defaultChatModels,
}) {
  const models = <String>[
    'openai:model-a',
    'openai:model-b',
    'openai:model-c',
  ];

  return AppSettings(
    ttsEnabled: true,
    defaultModelName: defaultModelName,
    defaultPersonaPrompt: '',
    modelList: models,
    allKnownModels: models,
    modelDisplayNames: const <String, String>{
      'openai:model-a': '模型 A',
      'openai:model-b': '模型 B',
      'openai:model-c': '模型 C',
    },
    modelTypes: const <String, String>{},
    modelConfigs: const <String, ModelConfig>{},
    apiKey: '',
    apiBaseUrl: 'https://api.openai.com/v1',
    imageGenerationEnabled: false,
    maxFileUploadMB: 10,
    contextWindowTokens: 272000,
    customModels: const <CustomModel>[],
    providers: const <ProviderAuth>[
      ProviderAuth(
        id: 'openai',
        displayName: 'OpenAI',
        apiKeys: <String>[],
        apiBaseUrl: 'https://api.openai.com/v1',
        models: <String>['model-a', 'model-b', 'model-c'],
        visibleModels: <String>['model-a', 'model-b', 'model-c'],
      ),
    ],
    modelProviderMap: const <String, String>{
      'openai:model-a': 'openai',
      'openai:model-b': 'openai',
      'openai:model-c': 'openai',
      'model-a': 'openai',
      'model-b': 'openai',
      'model-c': 'openai',
    },
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
    defaultChatModels: defaultChatModels,
    streamSegmentDelaySeconds: 0,
  );
}

Widget _buildHost(
  _FakeAppSettingsNotifier notifier, {
  String? sessionModel,
  List<ComposerModelSelection?>? results,
}) {
  return ProviderScope(
    overrides: [
      appSettingsProvider.overrideWith(() => notifier),
    ],
    child: SkinScope(
      skin: const MoeTalkSkin(),
      child: MaterialApp(
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) {
              return Center(
                child: TextButton(
                  onPressed: () async {
                    final selection = await showComposerModelPickerSheet(
                      context,
                      sessionModel: sessionModel,
                    );
                    results?.add(selection);
                  },
                  child: const Text('open'),
                ),
              );
            },
          ),
        ),
      ),
    ),
  );
}

Future<void> _openSheet(WidgetTester tester) async {
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}
