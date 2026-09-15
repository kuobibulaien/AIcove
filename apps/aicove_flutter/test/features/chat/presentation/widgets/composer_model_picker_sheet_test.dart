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

  AppSettings _settings;
  final List<List<String>> reorderedQueues = <List<String>>[];
  final List<String> selectedModels = <String>[];

  AppSettings get currentSettings => _settings;

  @override
  Future<AppSettings> build() async => _settings;

  @override
  Future<void> setDefaultChatModels(List<String> models) async {
    reorderedQueues.add(List<String>.from(models));
    final nextDefaultModel =
        models.isNotEmpty ? models.first : _settings.defaultModelName;
    _settings = _settings.copyWith(
      defaultModelName: nextDefaultModel,
      defaultChatModels: List<String>.from(models),
    );
    state = AsyncData(_settings);
  }

  @override
  Future<void> setDefaultModelName(String modelId) async {
    selectedModels.add(modelId);
    final normalized = <String>[modelId];
    for (final existing in _settings.defaultChatModels) {
      if (!normalized.contains(existing)) {
        normalized.add(existing);
      }
    }
    _settings = _settings.copyWith(
      defaultModelName: modelId,
      defaultChatModels: normalized,
    );
    state = AsyncData(_settings);
  }
}

void main() {
  test('composerReorderModelQueue should adjust insertion index correctly', () {
    final reordered = composerReorderModelQueue(
      <String>['openai:model-a', 'openai:model-b', 'openai:model-c'],
      0,
      3,
    );

    expect(
      reordered,
      <String>['openai:model-b', 'openai:model-c', 'openai:model-a'],
    );
  });

  testWidgets('default queue reorder should persist new order', (tester) async {
    final notifier = _FakeAppSettingsNotifier(
      _buildSettings(
        defaultModelName: 'openai:model-a',
        defaultChatModels: const <String>[
          'openai:model-a',
          'openai:model-b',
          'openai:model-c',
        ],
      ),
    );

    await tester.pumpWidget(_buildHost(notifier));
    await _openSheet(tester);

    final reorderable = tester.widget<ReorderableListView>(
      find.byType(ReorderableListView),
    );
    expect(reorderable.onReorder, isNotNull);
    reorderable.onReorder!(2, 0);
    await tester.pumpAndSettle();

    expect(
      notifier.reorderedQueues.single,
      <String>['openai:model-c', 'openai:model-a', 'openai:model-b'],
    );
    expect(
      notifier.currentSettings.defaultChatModels,
      <String>['openai:model-c', 'openai:model-a', 'openai:model-b'],
    );
    expect(notifier.currentSettings.defaultModelName, 'openai:model-c');
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
  });

  testWidgets('tapping other model should promote it to queue head',
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

    await tester.pumpWidget(_buildHost(notifier));
    await _openSheet(tester);

    expect(find.text('其他可用模型'), findsOneWidget);
    await tester.tap(find.text('模型 C'));
    await tester.pumpAndSettle();

    expect(notifier.selectedModels.single, 'openai:model-c');
    expect(
      notifier.currentSettings.defaultChatModels,
      <String>['openai:model-c', 'openai:model-a', 'openai:model-b'],
    );
    expect(notifier.currentSettings.defaultModelName, 'openai:model-c');
    expect(find.text('默认队列'), findsNothing);
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

Widget _buildHost(_FakeAppSettingsNotifier notifier) {
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
                    final selected =
                        await showComposerModelPickerSheet(context);
                    if (selected == null || selected.trim().isEmpty) {
                      return;
                    }
                    final latestSettings =
                        ref.read(appSettingsProvider).valueOrNull ??
                            notifier.currentSettings;
                    if (selected == latestSettings.defaultModelName) {
                      return;
                    }
                    await ref
                        .read(appSettingsProvider.notifier)
                        .setDefaultModelName(selected);
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
