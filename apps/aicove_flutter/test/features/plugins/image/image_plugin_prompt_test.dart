import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:aicove_flutter/src/core/utils/message_formatter.dart';
import 'package:aicove_flutter/src/features/plugins/image/image_config.dart';
import 'package:aicove_flutter/src/features/plugins/image/image_plugin.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/ui/features/plugins/pages/image_plugin_detail_page.dart';

class _FakeAppSettingsNotifier extends AppSettingsNotifier {
  _FakeAppSettingsNotifier(this._settings);

  final AppSettings _settings;

  @override
  Future<AppSettings> build() async => _settings;
}

AppSettings _buildImageSettings({
  CallFlowMode mode = CallFlowMode.auto,
}) {
  const modelRef = 'openai:test-image-model';
  return AppSettings(
    ttsEnabled: false,
    defaultModelName: modelRef,
    defaultPersonaPrompt: '',
    modelList: <String>[modelRef],
    allKnownModels: <String>[modelRef],
    modelDisplayNames: <String, String>{},
    modelTypes: <String, String>{
      modelRef: 'image',
      'test-image-model': 'image',
    },
    modelConfigs: <String, ModelConfig>{},
    apiKey: '',
    apiBaseUrl: 'https://api.openai.com/v1',
    imageGenerationEnabled: true,
    maxFileUploadMB: 10,
    historyMessageLimit: 100,
    customModels: <CustomModel>[],
    providers: <ProviderAuth>[
      const ProviderAuth(
        id: 'openai',
        apiKeys: <String>['test-key'],
        apiBaseUrl: 'https://api.openai.com/v1',
        models: <String>['test-image-model'],
        visibleModels: <String>['test-image-model'],
        capabilities: <String>['image'],
      ),
    ],
    modelProviderMap: <String, String>{
      modelRef: 'openai',
      'test-image-model': 'openai',
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
    defaultChatModels: <String>[modelRef],
    callFlowSettings: CallFlowSettings(mode: mode),
  );
}

AppSettings _buildHiddenOnlyImageSettings() {
  const modelRef = 'openai:hidden-image-model';
  return const AppSettings(
    ttsEnabled: false,
    defaultModelName: modelRef,
    defaultPersonaPrompt: '',
    modelList: <String>[modelRef],
    allKnownModels: <String>[modelRef],
    modelDisplayNames: <String, String>{},
    modelTypes: <String, String>{
      modelRef: 'image',
      'hidden-image-model': 'image',
    },
    modelConfigs: <String, ModelConfig>{},
    apiKey: '',
    apiBaseUrl: 'https://api.openai.com/v1',
    imageGenerationEnabled: true,
    maxFileUploadMB: 10,
    historyMessageLimit: 100,
    customModels: <CustomModel>[],
    providers: <ProviderAuth>[
      ProviderAuth(
        id: 'openai',
        apiKeys: <String>['test-key'],
        apiBaseUrl: 'https://api.openai.com/v1',
        models: <String>['hidden-image-model'],
        visibleModels: <String>[],
        hiddenModels: <String>['hidden-image-model'],
        capabilities: <String>['image'],
      ),
    ],
    modelProviderMap: <String, String>{
      modelRef: 'openai',
      'hidden-image-model': 'openai',
    },
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
    defaultChatModels: <String>[modelRef],
    callFlowSettings: CallFlowSettings(mode: CallFlowMode.auto),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('image plugin should not inject hidden routing system prompt', () async {
    const config = ImageConfig();
    final container = ProviderContainer(
      overrides: [
        appSettingsProvider.overrideWith(
            () => _FakeAppSettingsNotifier(_buildImageSettings())),
      ],
    );
    addTearDown(container.dispose);
    await container.read(appSettingsProvider.future);

    final pluginProvider = Provider<ImagePlugin>((ref) {
      return ImagePlugin(config, ref);
    });
    final plugin = container.read(pluginProvider);

    final prompt = await plugin.getSystemPrompt(
      userMessage: '画一张自拍',
      supportsToolCalling: true,
    );

    expect(prompt, isNull);
    expect(plugin.getTools().map((tool) => tool.name), contains('draw_image'));
  });

  test('image plugin should inject inline <image> prompt in fast mode',
      () async {
    const config = ImageConfig();
    final container = ProviderContainer(
      overrides: [
        appSettingsProvider.overrideWith(
          () => _FakeAppSettingsNotifier(
            _buildImageSettings(mode: CallFlowMode.fast),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    await container.read(appSettingsProvider.future);

    final pluginProvider = Provider<ImagePlugin>((ref) {
      return ImagePlugin(config, ref);
    });
    final plugin = container.read(pluginProvider);

    final prompt = await plugin.getSystemPrompt(
      userMessage: '画一张自拍',
      supportsToolCalling: true,
    );

    expect(prompt, isNotNull);
    expect(prompt, contains('<image>英文正向提示词</image>'));
    expect(prompt, contains('NovelAI'));
    expect(plugin.getTools(), isEmpty);
  });

  test('image plugin should parse non-empty <image> tag into generation event',
      () async {
    const config = ImageConfig();
    final container = ProviderContainer(
      overrides: [
        appSettingsProvider.overrideWith(
          () => _FakeAppSettingsNotifier(
            _buildImageSettings(mode: CallFlowMode.fast),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    await container.read(appSettingsProvider.future);

    final pluginProvider = Provider<ImagePlugin>((ref) {
      return ImagePlugin(config, ref);
    });
    final plugin = container.read(pluginProvider);

    final result = await plugin.processResponse(
      '前文 <image>1girl, cat ears, masterpiece</image> 后文',
    );

    expect(result.processedText, '前文 后文');
    expect(result.events, hasLength(1));
    expect(result.events.single.type, 'image_generate');
    expect(result.events.single.data['prompt'], '1girl, cat ears, masterpiece');

    final emptyTagResult = await plugin.processResponse('<image></image>');
    expect(emptyTagResult.events, isEmpty);
    expect(emptyTagResult.processedText, '<image></image>');
  });

  test('image plugin should use independent fast prompt preset in fast mode',
      () async {
    final stablePreset = DrawingPromptPreset(
      name: '稳定预设',
      content: ImageConfig.encodeToolDescriptionBlocks(
        const DrawImageToolDescriptionBlocks(
          promptDescription: '稳定模式专用规则',
        ),
      ),
    );
    const fastPreset = DrawingPromptPreset(
      name: '快速预设',
      content: '快速模式独立规则：只在需要时输出 <image>英文提示词</image>',
    );
    final config = ImageConfig(
      systemPromptPresets: <DrawingPromptPreset>[stablePreset],
      selectedSystemPromptPresetName: stablePreset.name,
      fastPromptPresets: const <DrawingPromptPreset>[fastPreset],
      selectedFastPromptPresetName: fastPreset.name,
    );
    final container = ProviderContainer(
      overrides: [
        appSettingsProvider.overrideWith(
          () => _FakeAppSettingsNotifier(
            _buildImageSettings(mode: CallFlowMode.fast),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    await container.read(appSettingsProvider.future);

    final pluginProvider = Provider<ImagePlugin>((ref) {
      return ImagePlugin(config, ref);
    });
    final plugin = container.read(pluginProvider);

    final prompt = await plugin.getSystemPrompt(
      userMessage: '画一张自拍',
      supportsToolCalling: true,
    );

    expect(prompt, contains('快速模式独立规则'));
    expect(prompt, isNot(contains('稳定模式专用规则')));
  });

  test('image config should preserve fast prompt preset selection', () {
    const preset = DrawingPromptPreset(
      name: '快速预设',
      content: '快速模式模板内容',
    );
    final config = ImageConfig(
      fastPromptPresets: const <DrawingPromptPreset>[preset],
      selectedFastPromptPresetName: preset.name,
    );

    final restored = ImageConfig.fromJson(config.toJson());

    expect(restored.fastPromptPresets, hasLength(1));
    expect(restored.selectedFastPromptPreset?.name, preset.name);
    expect(restored.effectiveInlinePromptTemplate, '快速模式模板内容');
  });

  test('image plugin should ignore hidden image models when resolving tools',
      () async {
    const config = ImageConfig();
    final container = ProviderContainer(
      overrides: [
        appSettingsProvider.overrideWith(
          () => _FakeAppSettingsNotifier(_buildHiddenOnlyImageSettings()),
        ),
      ],
    );
    addTearDown(container.dispose);
    await container.read(appSettingsProvider.future);

    final pluginProvider = Provider<ImagePlugin>(
      (ref) => ImagePlugin(config, ref),
    );
    final plugin = container.read(pluginProvider);

    expect(plugin.getTools(), isEmpty);
  });

  testWidgets(
      'image settings page should only list visible image-tagged models',
      (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'aicove.ui_models.v1': jsonEncode(<String, dynamic>{
        'providers': [
          {
            'id': 'mixed',
            'displayName': '混合渠道',
            'apiKeys': <String>['test-key'],
            'apiBaseUrl': 'https://example.com/v1',
            'enabled': true,
            'models': <String>['chat-model', 'visible-image', 'hidden-image'],
            'visible_models': <String>['chat-model', 'visible-image'],
            'hidden_models': <String>['hidden-image'],
            'capabilities': <String>['chat', 'image'],
          },
        ],
        'model_types': <String, String>{
          'mixed:visible-image': 'image',
          'mixed:hidden-image': 'image',
        },
        'model_display_names': <String, String>{
          'mixed:chat-model': '对话模型',
          'mixed:visible-image': '可用生图模型',
          'mixed:hidden-image': '隐藏生图模型',
        },
        'default_model': 'mixed:chat-model',
        'default_chat_models': <String>['mixed:chat-model'],
        'visible_models': <String>['mixed:chat-model'],
        'image_generation_enabled': true,
      }),
      'aicove.plugins.image.config': jsonEncode(<String, dynamic>{
        'selectedModelId': 'mixed:hidden-image',
      }),
    });

    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: ImagePluginDetailPage(),
        ),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('当前模型已不可用'), findsOneWidget);

    await tester.tap(find.text('当前模型已不可用'));
    await tester.pumpAndSettle();

    expect(find.text('可用生图模型'), findsOneWidget);
    expect(find.text('隐藏生图模型'), findsNothing);
    expect(find.text('对话模型'), findsNothing);
  });
}
