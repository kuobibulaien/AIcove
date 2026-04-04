import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/core/utils/message_formatter.dart';
import 'package:aicove_flutter/src/ui/features/settings/pages/default_model_settings_page.dart';
import 'package:aicove_flutter/src/ui/features/settings/pages/model_list_page.dart';
import 'package:aicove_flutter/src/ui/features/settings/pages/provider_detail_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeAppSettingsNotifier extends AppSettingsNotifier {
  _FakeAppSettingsNotifier(this._settings);

  final AppSettings _settings;

  @override
  Future<AppSettings> build() async => _settings;
}

const _testSettings = AppSettings(
  ttsEnabled: true,
  defaultModelName: 'alpha-chat',
  defaultPersonaPrompt: '',
  modelList: <String>['provider_a:alpha-chat', 'provider_b:beta-chat'],
  allKnownModels: <String>[
    'provider_a:alpha-chat',
    'provider_a:alpha-vision',
    'provider_b:beta-chat',
  ],
  modelDisplayNames: <String, String>{
    'provider_a:alpha-chat': 'Alpha Chat',
    'provider_a:alpha-vision': 'Alpha Vision',
    'provider_b:beta-chat': 'Beta Chat',
  },
  modelTypes: <String, String>{
    'provider_a:alpha-chat': 'chat',
    'provider_a:alpha-vision': 'vision',
    'provider_b:beta-chat': 'chat',
  },
  modelConfigs: <String, ModelConfig>{},
  apiKey: '',
  apiBaseUrl: 'https://api.openai.com/v1',
  imageGenerationEnabled: false,
  maxFileUploadMB: 10,
  historyMessageLimit: 100,
  customModels: <CustomModel>[],
  providers: <ProviderAuth>[
    ProviderAuth(
      id: 'provider_a',
      displayName: 'Provider A',
      apiKeys: <String>['key-a'],
      apiBaseUrl: 'https://provider-a.example.com/v1',
      visibleModels: <String>['alpha-chat', 'alpha-vision'],
      models: <String>['alpha-chat', 'alpha-vision'],
      capabilities: <String>['chat', 'vision'],
    ),
    ProviderAuth(
      id: 'provider_b',
      displayName: 'Provider B',
      apiKeys: <String>['key-b'],
      apiBaseUrl: 'https://provider-b.example.com/v1',
      visibleModels: <String>['beta-chat'],
      models: <String>['beta-chat'],
      capabilities: <String>['chat'],
    ),
  ],
  modelProviderMap: <String, String>{
    'provider_a:alpha-chat': 'provider_a',
    'provider_a:alpha-vision': 'provider_a',
    'provider_b:beta-chat': 'provider_b',
  },
  backendApiKey: '',
  messageChunkingEnabled: true,
  messageFormatConfig: MessageFormatConfig(
    enableChunking: true,
    chunkPunctuations: <String>['。'],
    minSegmentLength: 1,
  ),
  textScaleFactor: 1.0,
  uiScaleFactor: 1.0,
  imagePreviewScale: 1.0,
  autoReplySettings: AutoReplySettings(),
  globalBackgroundColor: GlobalBackgroundColor.white,
  chatBackgroundColor: ChatBackgroundColor.defaultColor,
  isDarkMode: false,
  useSystemTheme: true,
  accentColor: 'FC96AA',
  hideUserAvatar: false,
  defaultChatModels: <String>['provider_a:alpha-chat'],
  defaultVisionModel: 'provider_a:alpha-chat',
  preferVisionAssistant: false,
);

Future<ProviderContainer> _createLoadedContainer() async {
  final container = ProviderContainer(
    overrides: [
      appSettingsProvider.overrideWith(
        () => _FakeAppSettingsNotifier(_testSettings),
      ),
    ],
  );
  await container.read(appSettingsProvider.future);
  return container;
}

Widget _buildTestApp(ProviderContainer container, Widget child) {
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(home: child),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    debugClearProviderDetailWarmCache();
  });

  testWidgets('模型管理页首帧直接显示供应商列表', (tester) async {
    final container = await _createLoadedContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(_buildTestApp(container, const ModelListPage()));
    await tester.pump();

    expect(
      find.byKey(const ValueKey<String>('model_list_deferred_shell')),
      findsNothing,
    );
    expect(find.text('Provider A'), findsOneWidget);
    expect(find.text('Provider B'), findsOneWidget);
  });

  testWidgets('默认模型设置页首帧直接显示模型分组', (tester) async {
    final container = await _createLoadedContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      _buildTestApp(container, const DefaultModelSettingsPage()),
    );
    await tester.pump();

    expect(
      find.byKey(
        const ValueKey<String>('default_model_settings_deferred_shell'),
      ),
      findsNothing,
    );
    expect(find.text('Alpha Chat'), findsWidgets);
    expect(find.text('Beta Chat'), findsWidgets);
  });

  testWidgets('渠道详情页首帧直接显示完整详情', (tester) async {
    final container = await _createLoadedContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      _buildTestApp(
        container,
        const ProviderDetailPage(providerId: 'provider_a'),
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey<String>('provider_detail_deferred_shell')),
      findsNothing,
    );
    expect(find.text('基础配置'), findsOneWidget);
    expect(find.text('高级信息'), findsOneWidget);
  });

  testWidgets('渠道详情页二次进入时仍直接显示完整详情', (tester) async {
    final container = await _createLoadedContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      _buildTestApp(
        container,
        const ProviderDetailPage(providerId: 'provider_a'),
      ),
    );
    await tester.pump();

    expect(find.text('基础配置'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();

    await tester.pumpWidget(
      _buildTestApp(
        container,
        const ProviderDetailPage(providerId: 'provider_a'),
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey<String>('provider_detail_deferred_shell')),
      findsNothing,
    );
    expect(find.text('基础配置'), findsOneWidget);
    expect(find.text('高级信息'), findsOneWidget);
  });
}
