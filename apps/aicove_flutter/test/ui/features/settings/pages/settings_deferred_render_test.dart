import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
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
  contextWindowTokens: 272000,
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

  setUpAll(() async {
    if (!const bool.fromEnvironment('WRITE_MODEL_QA')) return;
    final font = FontLoader('ModelCapture');
    font.addFont(File('/System/Library/Fonts/STHeiti Medium.ttc').readAsBytes().then(ByteData.sublistView));
    await font.load();
    final icons = FontLoader('MaterialIcons');
    icons.addFont(File('build/unit_test_assets/fonts/MaterialIcons-Regular.otf').readAsBytes().then(ByteData.sublistView));
    await icons.load();
  });
  for (final width in [390.0, 1000.0]) {
    testWidgets('default models has no assistant section at $width', (tester) async {
      await tester.binding.setSurfaceSize(Size(width, 720));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final container = await _createLoadedContainer();
      addTearDown(container.dispose);
      final capture = GlobalKey();
      await tester.pumpWidget(UncontrolledProviderScope(container: container, child: MaterialApp(
        theme: ThemeData(fontFamily: const bool.fromEnvironment('WRITE_MODEL_QA') ? 'ModelCapture' : null),
        home: RepaintBoundary(key: capture, child: const DefaultModelSettingsPage()),
      )));
      await tester.pumpAndSettle();
      expect(find.text('多模态辅助模型'), findsNothing);
      expect(find.text('优先使用辅助模型'), findsNothing);
      expect(find.text('默认聊天模型'), findsOneWidget);
      expect(find.text('上下文窗口'), findsOneWidget);
      expect(find.text('Alpha Chat'), findsOneWidget);
      expect(tester.takeException(), isNull);
      if (const bool.fromEnvironment('WRITE_MODEL_QA')) {
        await tester.runAsync(() async {
          final boundary = capture.currentContext!.findRenderObject() as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: 1.5);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File('../../.codex-temp/context-window/default-models-${width.toInt()}.png');
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
    });
  }

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
