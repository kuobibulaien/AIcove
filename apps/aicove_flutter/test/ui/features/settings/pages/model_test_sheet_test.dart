import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:aicove_flutter/src/core/utils/message_formatter.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/index.dart';
import 'package:aicove_flutter/src/ui/features/settings/widgets/model_test_sheet.dart';

class _Settings extends AppSettingsNotifier {
  final completers = <String, Completer<String>>{};
  var inFlight = 0;
  var maxInFlight = 0;

  @override
  Future<AppSettings> build() async => _testSettings;

  @override
  Future<String> testModel({
    required String providerId,
    required String apiKey,
    required String apiBaseUrl,
    required String modelId,
    Map<String, dynamic>? customConfig,
  }) {
    final completer = Completer<String>();
    completers[modelId] = completer;
    inFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    return completer.future.whenComplete(() => inFlight--);
  }
}

final _models = List.generate(14, (i) => 'model-${i.toString().padLeft(2, '0')}');

final _testSettings = AppSettings(
  ttsEnabled: true,
  defaultModelName: 'provider_a:model-00',
  defaultPersonaPrompt: '',
  modelList: const <String>[],
  allKnownModels: const <String>[],
  modelDisplayNames: const <String, String>{'model-00': 'Alpha Model'},
  modelTypes: const <String, String>{},
  modelConfigs: const <String, ModelConfig>{},
  apiKey: '',
  apiBaseUrl: 'https://api.openai.com/v1',
  imageGenerationEnabled: false,
  maxFileUploadMB: 10,
  contextWindowTokens: 272000,
  customModels: const <CustomModel>[],
  providers: <ProviderAuth>[
    ProviderAuth(
      id: 'provider_a',
      displayName: 'Provider A',
      apiKeys: const <String>['key-a'],
      apiBaseUrl: 'https://provider-a.example.com/v1',
      visibleModels: _models,
      models: _models,
      capabilities: const <String>['chat'],
    ),
  ],
  modelProviderMap: const <String, String>{},
  backendApiKey: '',
  messageChunkingEnabled: true,
  messageFormatConfig: const MessageFormatConfig(
    enableChunking: true,
    chunkPunctuations: <String>['。'],
    minSegmentLength: 1,
  ),
  textScaleFactor: 1.0,
  uiScaleFactor: 1.0,
  imagePreviewScale: 1.0,
  autoReplySettings: const AutoReplySettings(),
  globalBackgroundColor: GlobalBackgroundColor.white,
  chatBackgroundColor: ChatBackgroundColor.defaultColor,
  isDarkMode: false,
  useSystemTheme: true,
  accentColor: 'FC96AA',
  hideUserAvatar: false,
  defaultChatModels: const <String>['provider_a:model-00'],
);

ProviderAuth get _provider => _testSettings.providers.first;

void main() {
  setUpAll(() async {
    if (!const bool.fromEnvironment('WRITE_MODEL_TEST_PREVIEW')) return;
    for (final entry in {
      'Preview': '/System/Library/Fonts/STHeiti Medium.ttc',
      'packages/cupertino_icons/CupertinoIcons':
          'build/unit_test_assets/packages/cupertino_icons/assets/CupertinoIcons.ttf',
      'MaterialIcons':
          '${Platform.environment['FLUTTER_ROOT']}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    }.entries) {
      final loader = FontLoader(entry.key);
      loader.addFont(
        File(entry.value).readAsBytes().then(ByteData.sublistView),
      );
      await loader.load();
    }
  });

  Future<_Settings> pumpSheet(
    WidgetTester tester, {
    bool dark = false,
    double width = 390,
    GlobalKey? capture,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 780);
    addTearDown(tester.view.reset);
    final settings = _Settings();
    final container = ProviderContainer(
      overrides: [appSettingsProvider.overrideWith(() => settings)],
    );
    addTearDown(container.dispose);
    await container.read(appSettingsProvider.future);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            brightness: dark ? Brightness.dark : Brightness.light,
            fontFamily:
                const bool.fromEnvironment('WRITE_MODEL_TEST_PREVIEW')
                    ? 'Preview'
                    : null,
            extensions: [dark ? MoeColors.dark() : MoeColors.light()],
          ),
          builder: capture == null
              ? null
              : (context, child) => RepaintBoundary(key: capture, child: child!),
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) => Center(
                child: TextButton(
                  onPressed: () => showModelTestSheet(
                    context,
                    ref,
                    provider: _provider,
                    apiKey: 'key-a',
                  ),
                  child: const Text('打开测活'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开测活'));
    await tester.pumpAndSettle();
    return settings;
  }

  int loadingCount(WidgetTester tester) => tester
      .widgetList(find.byType(CircularProgressIndicator))
      .length;

  testWidgets('model test sheet scrolls and tests models concurrently', (
    tester,
  ) async {
    final settings = await pumpSheet(tester);

    // 初始只显示视口内的行，底部模型需要滚动
    expect(find.text('model-00'), findsOneWidget);
    expect(find.text('model-13'), findsNothing);
    await tester.drag(
      find.byType(CustomScrollView),
      const Offset(0, -400),
    );
    await tester.pumpAndSettle();
    expect(find.text('model-13'), findsOneWidget);
    await tester.drag(
      find.byType(CustomScrollView),
      const Offset(0, 400),
    );
    await tester.pumpAndSettle();

    // 全部测试并发执行：同时有多个探测在飞，受并发上限约束
    await tester.tap(find.text('全部测试'));
    await tester.pump();
    expect(settings.maxInFlight, 6);
    expect(loadingCount(tester), 6);
    expect(find.byIcon(Icons.schedule), findsWidgets);

    // 释放一个探测，队列自动补位下一个
    settings.completers['model-00']!.complete('ok');
    await tester.pump();
    expect(settings.completers.length, 7);
    expect(settings.inFlight, 6);
    expect(loadingCount(tester), 6);

    // 一个失败、其余全部成功（补位的新探测逐轮放行直到清空）
    settings.completers['model-01']!.completeError(Exception('boom'));
    await tester.pump();
    while (settings.completers.values.any((c) => !c.isCompleted)) {
      for (final completer in settings.completers.values) {
        if (!completer.isCompleted) completer.complete('ok');
      }
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.check_circle), findsWidgets);
    expect(find.byIcon(Icons.cancel), findsOneWidget);
    expect(find.text('已测 14/14 · 成功 13 · 失败 1'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('model test sheet search filters and row tap retests', (
    tester,
  ) async {
    final settings = await pumpSheet(tester);

    // 搜索同时匹配模型 ID 与显示名
    await tester.enterText(find.byType(TextField), 'alpha');
    await tester.pumpAndSettle();
    expect(find.text('Alpha Model'), findsOneWidget);
    expect(find.text('model-01'), findsNothing);
    await tester.enterText(find.byType(TextField), '');
    await tester.pumpAndSettle();

    // 点单行只测该模型
    await tester.tap(find.text('model-01'));
    await tester.pump();
    expect(settings.completers.keys, ['model-01']);
    settings.completers['model-01']!.complete('ok');
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.ancestor(
          of: find.text('model-01'),
          matching: find.byType(MoeSettingsRow),
        ),
        matching: find.byIcon(Icons.check_circle),
      ),
      findsOneWidget,
    );

    // 出结果后再点同一行触发重测
    await tester.tap(find.text('model-01'));
    await tester.pump();
    expect(settings.completers['model-01']!.isCompleted, isFalse);
    expect(tester.takeException(), isNull);
  });

  for (final dark in [false, true]) {
    testWidgets('model test sheet source rendered preview dark=$dark', (
      tester,
    ) async {
      if (!const bool.fromEnvironment('WRITE_MODEL_TEST_PREVIEW')) return;
      final capture = GlobalKey();
      final settings = await pumpSheet(tester, dark: dark, capture: capture);

      // 制造混合状态：成功 + 失败 + 探测中 + 排队中
      await tester.tap(find.text('全部测试'));
      await tester.pump();
      settings.completers['model-00']!.complete('ok');
      settings.completers['model-02']!.complete('ok');
      settings.completers['model-03']!.completeError(Exception('boom'));
      await tester.pump();

      await tester.runAsync(() async {
        final boundary =
            capture.currentContext!.findRenderObject()
                as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 1.5);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File(
          '../../.codex-temp/model-test-sheet/${dark ? 'dark' : 'light'}.png',
        );
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    });
  }
}
