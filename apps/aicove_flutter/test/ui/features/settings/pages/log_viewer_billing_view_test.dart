import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:aicove_flutter/src/core/api/providers/token_usage.dart';
import 'package:aicove_flutter/src/core/api_client.dart';
import 'package:aicove_flutter/src/core/api_logger.dart';
import 'package:aicove_flutter/src/core/app_logger.dart';
import 'package:aicove_flutter/src/features/observability/model_request_ledger.dart';
import 'package:aicove_flutter/src/features/observability/token_usage_ledger.dart';
import 'package:aicove_flutter/src/features/observability/trace_store.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/features/settings/provider_detail/provider_detail_support.dart';
import 'package:aicove_flutter/src/ui/features/settings/pages/log_viewer_page.dart';
import 'package:aicove_flutter/src/ui/features/settings/pages/model_list_page.dart';
import 'package:aicove_flutter/src/ui/features/settings/pages/provider_detail_page.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const capturePreview = bool.fromEnvironment('CAPTURE_BILLING_PREVIEW');

  setUpAll(() async {
    if (!capturePreview) return;
    final cjkFile = File('/System/Library/Fonts/STHeiti Medium.ttc');
    if (cjkFile.existsSync()) {
      final fontBytes = await cjkFile.readAsBytes();
      for (final family in ['PreviewCJK', 'monospace']) {
        final loader = FontLoader(family)
          ..addFont(Future.value(ByteData.sublistView(fontBytes)));
        await loader.load();
      }
    }
    final exe = File(Platform.resolvedExecutable);
    for (final candidate in [
      '${exe.parent.parent.parent.path}/material_fonts/MaterialIcons-Regular.otf',
      '${exe.parent.parent.parent.path}/artifacts/material_fonts/MaterialIcons-Regular.otf',
    ]) {
      final iconFile = File(candidate);
      if (iconFile.existsSync()) {
        final icons = FontLoader('MaterialIcons')
          ..addFont(iconFile.readAsBytes().then(ByteData.sublistView));
        await icons.load();
        break;
      }
    }
  });

  setUp(() {
    ApiLogger.clear();
    AppLogger.clear();
    TraceStore.instance.debugResetForTest();
  });

  UsageOverview sampleOverview(UsageGroupBy groupBy) {
    final groups = switch (groupBy) {
      UsageGroupBy.model => const <UsageGroupItem>[
        UsageGroupItem(
          key: 'deepseek:deepseek-chat',
          title: 'DeepSeek V4',
          subtitle: 'DeepSeek',
          providerId: 'deepseek',
          rawModelId: 'deepseek-chat',
          requestCount: 18,
          inputTokens: 96000,
          outputTokens: 28000,
          cachedInputTokens: 64000,
          usdCostMicros: 0,
          cnyCostMicros: 1280000,
          shareRatio: 0.68,
        ),
        UsageGroupItem(
          key: 'openai:gpt-4o-mini',
          title: 'GPT-4o mini',
          subtitle: 'OpenAI',
          providerId: 'openai',
          rawModelId: 'gpt-4o-mini',
          requestCount: 6,
          inputTokens: 24000,
          outputTokens: 8200,
          cachedInputTokens: 12000,
          usdCostMicros: 45000,
          cnyCostMicros: 0,
          shareRatio: 0.18,
        ),
        UsageGroupItem(
          key: 'relay:my-private-rp-v2',
          title: 'my-private-rp-v2',
          subtitle: '自建中转',
          providerId: 'relay',
          rawModelId: 'my-private-rp-v2',
          isUnpricedModel: true,
          requestCount: 3,
          inputTokens: 18000,
          outputTokens: 6800,
          cachedInputTokens: 0,
          usdCostMicros: 0,
          cnyCostMicros: 0,
          shareRatio: 0.14,
        ),
      ],
      UsageGroupBy.conversation => const <UsageGroupItem>[
        UsageGroupItem(
          key: 'conv-nahida',
          title: '纳西妲',
          requestCount: 20,
          inputTokens: 110000,
          outputTokens: 32000,
          cachedInputTokens: 68000,
          usdCostMicros: 30000,
          cnyCostMicros: 1120000,
          shareRatio: 0.78,
        ),
        UsageGroupItem(
          key: 'conv-furina',
          title: '芙宁娜',
          requestCount: 7,
          inputTokens: 28000,
          outputTokens: 11000,
          cachedInputTokens: 8000,
          usdCostMicros: 15000,
          cnyCostMicros: 160000,
          shareRatio: 0.22,
        ),
      ],
      UsageGroupBy.purpose => const <UsageGroupItem>[
        UsageGroupItem(
          key: 'chat',
          title: '日常聊天',
          requestCount: 21,
          inputTokens: 108000,
          outputTokens: 35000,
          cachedInputTokens: 66000,
          usdCostMicros: 45000,
          cnyCostMicros: 1040000,
          shareRatio: 0.79,
        ),
        UsageGroupItem(
          key: 'memory',
          title: '整理长期记忆',
          requestCount: 6,
          inputTokens: 30000,
          outputTokens: 8000,
          cachedInputTokens: 10000,
          usdCostMicros: 0,
          cnyCostMicros: 240000,
          shareRatio: 0.21,
        ),
      ],
      UsageGroupBy.device => const <UsageGroupItem>[
        UsageGroupItem(
          key: 'mac',
          title: '我的 Mac',
          requestCount: 19,
          inputTokens: 98000,
          outputTokens: 31000,
          cachedInputTokens: 56000,
          usdCostMicros: 45000,
          cnyCostMicros: 880000,
          shareRatio: 0.71,
        ),
        UsageGroupItem(
          key: 'phone',
          title: '一加 13T',
          requestCount: 8,
          inputTokens: 40000,
          outputTokens: 12000,
          cachedInputTokens: 20000,
          usdCostMicros: 0,
          cnyCostMicros: 400000,
          shareRatio: 0.29,
        ),
      ],
    };

    return UsageOverview(
      requestCount: 27,
      inputTokens: 138000,
      outputTokens: 43000,
      cachedInputTokens: 76000,
      cacheWriteTokens: 0,
      reasoningTokens: 6400,
      estimatedCount: 2,
      usdCostMicros: 45000,
      cnyCostMicros: 1280000,
      unpricedRequestCount: 3,
      groups: groups,
      availableDevices: const [
        UsageDevice(deviceId: 'mac', deviceName: '我的 Mac', isLocal: true),
        UsageDevice(deviceId: 'phone', deviceName: '一加 13T', isLocal: false),
      ],
    );
  }

  List<UsageEntryView> sampleEntries() {
    final now = DateTime(2026, 11, 18, 10, 24);
    return [
      UsageEntryView(
        isRemote: false,
        conversationTitle: '纳西妲',
        modelDisplayName: 'DeepSeek V4',
        providerDisplayName: 'DeepSeek',
        entry: TokenUsageEntry(
          requestId: 'req-1',
          deviceId: 'mac',
          deviceName: '我的 Mac',
          occurredAtMs: now.millisecondsSinceEpoch,
          providerId: 'deepseek',
          model: 'deepseek:deepseek-chat',
          purpose: 'chat',
          conversationId: 'conv-nahida',
          durationMs: 1420,
          priced: true,
          currency: 'CNY',
          costMicros: 18400,
          usage: const TokenUsage(
            inputTokens: 6800,
            outputTokens: 920,
            cachedInputTokens: 5200,
            reasoningTokens: 310,
          ),
        ),
      ),
      UsageEntryView(
        isRemote: true,
        conversationTitle: '纳西妲',
        modelDisplayName: 'DeepSeek V4',
        providerDisplayName: 'DeepSeek',
        entry: TokenUsageEntry(
          requestId: 'req-2',
          deviceId: 'phone',
          deviceName: '一加 13T',
          occurredAtMs:
              now.subtract(const Duration(minutes: 18)).millisecondsSinceEpoch,
          providerId: 'deepseek',
          model: 'deepseek:deepseek-chat',
          purpose: 'memory',
          conversationId: 'conv-nahida',
          durationMs: 2150,
          priced: true,
          currency: 'CNY',
          costMicros: 9600,
          usage: const TokenUsage(
            inputTokens: 4200,
            outputTokens: 380,
            cachedInputTokens: 2000,
          ),
        ),
      ),
      UsageEntryView(
        isRemote: false,
        conversationTitle: '芙宁娜',
        modelDisplayName: 'my-private-rp-v2',
        providerDisplayName: '自建中转',
        entry: TokenUsageEntry(
          requestId: 'req-3',
          deviceId: 'mac',
          deviceName: '我的 Mac',
          occurredAtMs:
              now.subtract(const Duration(hours: 2)).millisecondsSinceEpoch,
          providerId: 'relay',
          model: 'relay:my-private-rp-v2',
          purpose: 'proactive_reply',
          conversationId: 'conv-furina',
          durationMs: 980,
          priced: false,
          usage: const TokenUsage(
            inputTokens: 3100,
            outputTokens: 460,
            isEstimated: true,
          ),
        ),
      ),
    ];
  }

  Future<void> savePngIfCapturing(
    WidgetTester tester,
    GlobalKey boundaryKey,
    String fileName,
  ) async {
    if (!capturePreview) return;
    final outDir =
        Platform.environment['PREVIEW_OUT_DIR'] ??
        '../../scratch/billing_log_redesign';
    await tester.runAsync(() async {
      final boundary =
          boundaryKey.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 2.0);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('$outDir/$fileName');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  Widget buildTestApp({
    required Widget home,
    required GlobalKey boundaryKey,
    bool dark = false,
    DateTime? lastPricingSyncAt,
    TokenUsageLedger? ledgerOverride,
  }) {
    final moe = dark ? MoeColors.dark() : MoeColors.light();
    return ProviderScope(
      overrides: [
        if (ledgerOverride != null)
          tokenUsageLedgerProvider.overrideWithValue(ledgerOverride),
        tokenUsageOverviewProvider.overrideWith(
          (ref, args) async => sampleOverview(args.groupBy),
        ),
        tokenUsageEntriesProvider.overrideWith(
          (ref, args) async => sampleEntries(),
        ),
        officialPricingSyncTimeProvider.overrideWith(
          (ref) async => lastPricingSyncAt,
        ),
        modelRunsProvider.overrideWith((ref) => Stream.value(const [])),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          brightness: dark ? Brightness.dark : Brightness.light,
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF5B8DEF),
            brightness: dark ? Brightness.dark : Brightness.light,
            surface: moe.surface,
            onSurface: moe.text,
          ),
          scaffoldBackgroundColor: moe.surface,
          fontFamily: capturePreview ? 'PreviewCJK' : null,
          extensions: [moe],
        ),
        builder: (context, child) =>
            RepaintBoundary(key: boundaryKey, child: child!),
        home: home,
      ),
    );
  }

  for (final spec in [
    (width: 390.0, height: 844.0, dark: false, file: 'preview_narrow_billing.png'),
    (width: 1080.0, height: 760.0, dark: false, file: 'preview_wide_billing.png'),
    (width: 390.0, height: 844.0, dark: true, file: null),
  ]) {
    testWidgets(
      'billing view renders overview, ranking, details without overflow (${spec.width}x${spec.height}, dark=${spec.dark})',
      (tester) async {
        SharedPreferences.setMockInitialValues({
          'aicove.cloud.device_id': 'mac',
          'aicove.ui_models.v1': jsonEncode({
            'providers': [
              {
                'id': 'relay',
                'displayName': '自建中转',
                'enabled': true,
                'apiKeys': <String>[],
                'apiBaseUrl': 'https://relay.example/v1',
                'models': ['my-private-rp-v2'],
                'visible_models': ['my-private-rp-v2'],
                'capabilities': ['chat'],
              },
            ],
          }),
        });
        tester.view.physicalSize = Size(spec.width, spec.height);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final boundaryKey = GlobalKey();
        await tester.pumpWidget(
          buildTestApp(
            boundaryKey: boundaryKey,
            dark: spec.dark,
            lastPricingSyncAt: DateTime(2026, 11, 18, 6, 12),
            home: const LogViewerPage(initialSection: LogCenterSection.billing),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('用量与日志'), findsOneWidget);
        expect(find.text('用量账单'), findsOneWidget);
        expect(find.text('运行日志'), findsOneWidget);
        expect(find.byTooltip('更新官方参考价'), findsOneWidget);
        expect(find.text('官方参考单价已于 11-18 06:12 更新'), findsOneWidget);
        expect(find.text('¥1.28 + \$0.045'), findsOneWidget);
        expect(find.text('另有 3 次调用的模型暂未设置单价'), findsOneWidget);
        expect(find.text('7.6 万 (55%)'), findsOneWidget);
        expect(find.text('设单价'), findsOneWidget);

        if (spec.file != null) {
          await savePngIfCapturing(tester, boundaryKey, spec.file!);
        }

        // Switch ranking dimensions cleanly
        await tester.tap(find.text('按角色'));
        await tester.pumpAndSettle();
        expect(find.text('纳西妲'), findsWidgets);

        await tester.tap(find.text('按用途'));
        await tester.pumpAndSettle();
        expect(find.text('整理长期记忆'), findsWidgets);

        await tester.tap(find.text('按模型'));
        await tester.pumpAndSettle();

        // Scroll down on narrow screen to inspect the detail items
        await tester.drag(find.byType(ListView), const Offset(0, -320));
        await tester.pumpAndSettle();
        expect(find.text('来自 一加 13T'), findsOneWidget);
        expect(find.text('估算'), findsOneWidget);

        // Expand detail row to inspect token breakdown
        await tester.tap(find.text('纳西妲 · 日常聊天'));
        await tester.pumpAndSettle();
        expect(find.textContaining('6,800', findRichText: true), findsOneWidget);
        expect(find.textContaining('5,200', findRichText: true), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('tapping 设单价 opens pricing sheet and auto-saves custom model price', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'aicove.cloud.device_id': 'mac',
      'aicove.ui_models.v1': jsonEncode({
        'providers': [
          {
            'id': 'relay',
            'displayName': '自建中转',
            'enabled': true,
            'apiKeys': <String>[],
            'apiBaseUrl': 'https://relay.example/v1',
            'models': ['my-private-rp-v2'],
            'visible_models': ['my-private-rp-v2'],
            'capabilities': ['chat'],
          },
        ],
      }),
    });
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final boundaryKey = GlobalKey();
    await tester.pumpWidget(
      buildTestApp(
        boundaryKey: boundaryKey,
        home: const LogViewerPage(initialSection: LogCenterSection.billing),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('设单价'));
    await tester.pumpAndSettle();
    expect(find.text('设置单价 · my-private-rp-v2'), findsOneWidget);

    await tester.tap(find.text('人民币 ¥'));
    await tester.pumpAndSettle();

    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), '1.5');
    await tester.enterText(fields.at(1), '6');
    await tester.enterText(fields.at(2), '0.3');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    await savePngIfCapturing(
      tester,
      boundaryKey,
      'preview_model_pricing_sheet.png',
    );

    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();

    final checkContainer = ProviderContainer();
    addTearDown(checkContainer.dispose);
    final saved = await checkContainer.read(appSettingsProvider.future);
    final cfg = saved.getModelConfig('relay:my-private-rp-v2');
    expect(cfg.inputPricePerMillion, 1.5);
    expect(cfg.outputPricePerMillion, 6.0);
    expect(cfg.cachedInputPricePerMillion, 0.3);
    expect(cfg.priceCurrency, 'CNY');
    expect(tester.takeException(), isNull);
  });

  testWidgets('simplified logs tab displays token usage and switches cleanly', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'aicove.cloud.device_id': 'mac'});
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    ApiLogger.entries.value = [
      ApiLogEntry(
        time: DateTime(2026, 11, 18, 10, 20, 5),
        method: 'POST',
        url: 'https://api.deepseek.com/v1/chat/completions',
        status: 200,
        durationMs: 1380,
        requestBody: '{"model":"deepseek-chat"}',
        responseBody: '[stream]',
        ok: true,
        sessionId: 'conv-nahida',
        turnId: 'turn-1',
        roundIndex: 1,
        rawAiResponse: '早安呀旅行者，今天想听什么故事？',
        inputTokens: 5420,
        outputTokens: 610,
        cachedInputTokens: 4800,
      ),
    ];
    AppLogger.entries.value = [
      LogEntry(
        time: DateTime(2026, 11, 18, 10, 21, 12),
        level: LogLevel.warning,
        source: 'AgentApiClient',
        message: '主渠道响应超时，已自动切换至备用渠道继续生成',
      ),
    ];

    final boundaryKey = GlobalKey();
    await tester.pumpWidget(
      buildTestApp(
        boundaryKey: boundaryKey,
        home: const LogViewerPage(initialSection: LogCenterSection.logs),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('全部'), findsOneWidget);
    expect(find.text('对话'), findsOneWidget);
    expect(find.text('网络'), findsOneWidget);
    expect(find.text('只看异常'), findsOneWidget);
    expect(find.textContaining('6030 用量'), findsOneWidget);

    await tester.tap(find.text('点开查看详情').first);
    await tester.pumpAndSettle();
    await savePngIfCapturing(tester, boundaryKey, 'preview_narrow_logs.png');
    final expandedText = tester
        .widgetList<SelectableText>(find.byType(SelectableText))
        .map((w) => w.data ?? '')
        .join('\n');
    expect(expandedText, contains('输入 5420（缓存 4800） · 输出 610'));

    await tester.tap(find.text('只看异常'));
    await tester.pumpAndSettle();
    expect(find.textContaining('已自动切换至备用渠道'), findsOneWidget);
    expect(find.textContaining('6030 用量'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('provider detail saves channel price multiplier and model list opens billing', (
    tester,
  ) async {
    debugClearProviderDetailWarmCache();
    SharedPreferences.setMockInitialValues({
      'aicove.cloud.device_id': 'mac',
      'aicove.ui_models.v1': jsonEncode({
        'providers': [
          {
            'id': 'relay',
            'displayName': '优惠中转站',
            'enabled': true,
            'apiKeys': <String>['sk-test'],
            'apiBaseUrl': 'https://relay.example/v1',
            'models': ['gpt-4o'],
            'visible_models': ['gpt-4o'],
            'capabilities': ['chat'],
          },
        ],
      }),
    });
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final boundaryKey = GlobalKey();
    await tester.pumpWidget(
      buildTestApp(
        boundaryKey: boundaryKey,
        home: const ProviderDetailPage(providerId: 'relay'),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('计费倍率'));
    await tester.pumpAndSettle();
    expect(find.text('1.0x（原价）'), findsOneWidget);

    await tester.tap(find.text('计费倍率'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('0.5x'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();

    final checkContainer = ProviderContainer();
    addTearDown(checkContainer.dispose);
    final saved = await checkContainer.read(appSettingsProvider.future);
    expect(resolveProviderPriceMultiplier(saved.getProvider('relay')!), 0.5);

    // Verify ModelListPage billing entry point
    await tester.pumpWidget(
      buildTestApp(boundaryKey: boundaryKey, home: const ModelListPage()),
    );
    await tester.pumpAndSettle();
    expect(find.text('用量与计费'), findsOneWidget);
    await tester.tap(find.text('用量与计费'));
    await tester.pumpAndSettle();
    expect(find.text('预估总花费'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tapping 更新官方参考价 syncs official pricing catalog cleanly', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'aicove.cloud.device_id': 'mac'});
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final fakeLedger = _FakeSyncTokenUsageLedger();
    final boundaryKey = GlobalKey();
    await tester.pumpWidget(
      buildTestApp(
        boundaryKey: boundaryKey,
        ledgerOverride: fakeLedger,
        home: const LogViewerPage(initialSection: LogCenterSection.billing),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('更新官方参考价'));
    await tester.pump();
    expect(fakeLedger.syncCalls, 1);
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}

class _FakeSyncTokenUsageLedger extends TokenUsageLedger {
  int syncCalls = 0;

  @override
  Future<OfficialPricingSyncResult> syncOfficialPricingCatalog({
    ApiClient? apiClient,
  }) async {
    syncCalls += 1;
    return OfficialPricingSyncResult(
      modelCount: 3887,
      syncedAt: DateTime(2026, 11, 18, 6, 20),
    );
  }
}
