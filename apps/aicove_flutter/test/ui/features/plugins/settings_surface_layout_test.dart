import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:aicove_flutter/src/core/services/android_keep_alive_manager.dart';
import 'package:aicove_flutter/src/features/agent_context/data/silly_tavern_preset_store.dart';
import 'package:aicove_flutter/src/features/agent_context/providers/preset_recipe_provider.dart';
import 'package:aicove_flutter/src/features/agent_context/domain/tavern_compatibility_port.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/auto_reply_trigger.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/auto_reply_trigger_controller.dart';
import 'package:aicove_flutter/src/features/plugins/plugin_providers.dart';
import 'package:aicove_flutter/src/features/plugins/tts/tts_config.dart';
import 'package:aicove_flutter/src/features/plugins/tts/voice_preset_application.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/ui/features/auto_reply/pages/auto_reply_history_log_page.dart';
import 'package:aicove_flutter/src/ui/features/auto_reply/pages/auto_reply_settings_page.dart';
import 'package:aicove_flutter/src/ui/features/auto_reply/pages/auto_reply_advanced_settings_page.dart';
import 'package:aicove_flutter/src/ui/features/auto_reply/pages/auto_reply_trigger_list_page.dart';
import 'package:aicove_flutter/src/ui/features/auto_reply/widgets/auto_reply_settings_cards.dart';
import 'package:aicove_flutter/src/ui/features/plugins/pages/image_plugin_detail_page.dart';
import 'package:aicove_flutter/src/ui/features/settings/pages/context_memory_settings_page.dart';
import 'package:aicove_flutter/src/ui/features/plugins/pages/time_awareness_plugin_detail_page.dart';
import 'package:aicove_flutter/src/ui/features/plugins/pages/tts_plugin_detail_page.dart';
import 'package:aicove_flutter/src/ui/features/plugins/pages/tavern_plugin_detail_page.dart';
import 'package:aicove_flutter/src/ui/features/settings/pages/chat_plugin_settings_page.dart';
import 'package:aicove_flutter/src/ui/features/settings/pages/ui_settings_page.dart';
import 'package:aicove_flutter/src/ui/shared/animations/parallax_slide_page_route.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/index.dart';

class _Settings extends AppSettingsNotifier {
  _Settings({this.embedding = true});
  final bool embedding;
  @override
  Future<AppSettings> build() async => mapUiModelsToAppSettings({}).copyWith(
    autoReplySettings: const AutoReplySettings(),
    providers: [
      ProviderAuth(
        id: 'a',
        displayName: '渠道a',
        apiKeys: const ['fake'],
        apiBaseUrl: 'https://example.invalid',
        models: ['speech', if (embedding) 'embed'],
        visibleModels: const ['speech'],
        capabilities: const ['tts'],
        customConfig: const {'requestFormat': 'minimax_tts'},
      ),
    ],
    modelList: ['a:speech', if (embedding) 'a:embed'],
    allKnownModels: ['a:speech', if (embedding) 'a:embed'],
    modelTypes: {'a:speech': 'tts', if (embedding) 'a:embed': 'embedding'},
  );
}

class _FakeTriggerController extends AutoReplyTriggerController {
  @override
  Future<List<AutoReplyTrigger>> build() async => [
    AutoReplyTrigger(
      id: 't1',
      title: '早安问候',
      type: AutoReplyTriggerType.delay,
      status: AutoReplyTriggerStatus.pending,
      createdAt: DateTime(2026, 9, 15, 8),
      nextFireAt: DateTime(2026, 9, 16, 8),
      allowNight: false,
      requireExact: false,
      delayMinutes: 480,
      manual: false,
      conversationId: 'c1',
    ),
  ];
}

double _expectedContentWidth(double panelWidth) {
  final inset = (panelWidth * 0.04).clamp(12.0, 32.0);
  return math.min(760.0, math.max(0.0, panelWidth - 2 * inset));
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 24; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pumpAndSettle();
}

void _expectUnifiedSurfaceWidth(WidgetTester tester) {
  final panels = tester
      .widgetList<MoeSettingsContent>(find.byType(MoeSettingsContent))
      .map((w) => tester.getRect(find.byWidget(w)))
      .toList();
  expect(panels, isNotEmpty, reason: '页面应使用 MoeSettingsContent');
  final surfaces = _groupCardRects(tester);
  expect(surfaces, isNotEmpty, reason: '页面应包含分组卡片');
  for (final rect in surfaces) {
    final panel = panels.firstWhere(
      (p) => rect.left >= p.left - 0.5 && rect.right <= p.right + 0.5,
      orElse: () => panels.first,
    );
    final expected = _expectedContentWidth(panel.width);
    expect(rect.width, closeTo(expected, 0.5), reason: '卡片宽应等于内容列宽');
    expect(
      rect.left,
      closeTo(panel.left + (panel.width - expected) / 2, 0.5),
      reason: '卡片应在内容列内居中，无双重边距',
    );
  }
}

List<Rect> _groupCardRects(WidgetTester tester) {
  return tester
      .widgetList<MoeSettingsGroup>(find.byType(MoeSettingsGroup))
      .map(
        (group) => tester.getRect(
          find
              .descendant(
                of: find.byWidget(group),
                matching: find.byType(MoeContentSurface),
              )
              .first,
        ),
      )
      .toList();
}

Future<void> _mount(
  WidgetTester tester,
  Widget page, {
  Size size = const Size(360, 800),
  double scale = 1.0,
  bool embedding = true,
  int voicePresetCount = 3,
  SillyTavernPresetStore? store,
  List<Override> extra = const [],
  Map<String, Object> prefs = const {},
}) async {
  SharedPreferences.setMockInitialValues({
    ...prefs,
    'aicove.plugins.tts.config': jsonEncode(
      TtsConfig(
        presetSchemaVersion: 1,
        voicePresets: [
          for (var i = 0; i < voicePresetCount; i++)
            VoicePreset(
              id: 'p$i',
              name: '预设${i.toString().padLeft(4, '0')}',
              synthesis: VoiceSynthesisSettings(
                providerId: 'a',
                modelId: 'speech',
                voiceId: 'remote$i',
              ),
            ),
        ],
      ).toJson(),
    ),
  });
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appSettingsProvider.overrideWith(() => _Settings(embedding: embedding)),
        autoReplyTriggersProvider.overrideWith(_FakeTriggerController.new),
        if (store == null)
          presetRecipeListProvider.overrideWith(
            (ref) async => const <PresetRecipeSummary>[],
          ),
        tavernPluginSettingsProvider.overrideWith(
          (ref) async => const TavernPluginSettings(enabled: true),
        ),
        voicePresetReadyProvider.overrideWith((ref) async {
          await ref.read(ttsPluginConfigProvider.notifier).ready;
        }),
        if (store != null)
          sillyTavernPresetStoreProvider.overrideWithValue(store),
        ...extra,
      ],
      child: MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: page,
      ),
    ),
  );
  await _settle(tester);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('窄屏与大字号', () {
    final pages = <String, Widget>{
      'memory': const ContextMemorySettingsPage(),
      'auto-reply': const AutoReplySettingsPage(),
      'auto-reply-advanced': const AutoReplyAdvancedSettingsPage(),
      'tts': const TtsPluginDetailPage(),
      'tavern': const TavernPluginDetailPage(),
      'time': const TimeAwarenessPluginDetailPage(),
      'chat-plugins': const ChatPluginSettingsPage(),
      'ui-settings': const UiSettingsPage(),
      'image': const ImagePluginDetailPage(),
    };
    for (final entry in pages.entries) {
      for (final size in [
        const Size(360, 800),
        const Size(420, 800),
        const Size(320, 568),
      ]) {
        for (final scale in [1.0, 1.8]) {
          testWidgets('${entry.key} $size scale=$scale 统一列宽无溢出', (
            tester,
          ) async {
            await _mount(tester, entry.value, size: size, scale: scale);
            expect(tester.takeException(), isNull);
            _expectUnifiedSurfaceWidth(tester);
            final scroll = find.byType(Scrollable).first;
            for (var i = 0; i < 4; i++) {
              await tester.drag(scroll, const Offset(0, -300));
              await tester.pumpAndSettle();
              expect(tester.takeException(), isNull);
            }
          });
        }
      }
    }
  });

  group('宽屏自适应壳', () {
    for (final width in [1000.0, 1280.0]) {
      for (final entry in <String, Widget>{
        'memory': const ContextMemorySettingsPage(),
        'auto-reply': const AutoReplySettingsPage(),
        'tts': const TtsPluginDetailPage(),
        'tavern': const TavernPluginDetailPage(),
        'time': const TimeAwarenessPluginDetailPage(),
      }.entries) {
        testWidgets('${entry.key} in shell $width', (tester) async {
          await tester.binding.setSurfaceSize(Size(width, 800));
          addTearDown(() => tester.binding.setSurfaceSize(null));
          SharedPreferences.setMockInitialValues({
            'aicove.plugins.tts.config': jsonEncode(
              TtsConfig(
                presetSchemaVersion: 1,
                voicePresets: [
                  VoicePreset(
                    id: 'p0',
                    name: '预设0000',
                    synthesis: const VoiceSynthesisSettings(
                      providerId: 'a',
                      modelId: 'speech',
                      voiceId: 'r0',
                    ),
                  ),
                ],
              ).toJson(),
            ),
          });
          final nav = GlobalKey<NavigatorState>();
          final observer = MoeDetailStackObserver();
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                appSettingsProvider.overrideWith(() => _Settings()),
                autoReplyTriggersProvider.overrideWith(
                  _FakeTriggerController.new,
                ),
                presetRecipeListProvider.overrideWith(
                  (ref) async => const <PresetRecipeSummary>[],
                ),
                tavernPluginSettingsProvider.overrideWith(
                  (ref) async => const TavernPluginSettings(enabled: true),
                ),
                voicePresetReadyProvider.overrideWith((ref) async {
                  await ref.read(ttsPluginConfigProvider.notifier).ready;
                }),
              ],
              child: MaterialApp(
                home: MoeAdaptiveShell(
                  navigatorKey: nav,
                  observer: observer,
                  primary: const Scaffold(body: Text('一级')),
                  detail: Navigator(
                    key: nav,
                    observers: [observer],
                    onGenerateRoute: (_) =>
                        ParallaxSlidePageRoute(page: entry.value),
                  ),
                ),
              ),
            ),
          );
          await _settle(tester);
          expect(tester.takeException(), isNull);
          _expectUnifiedSurfaceWidth(tester);
          final surfaces = _groupCardRects(tester);
          expect(
            surfaces.every((r) => r.width <= 760.5),
            isTrue,
            reason: '宽屏内容列封顶 760',
          );
        });
      }
    }
  });

  testWidgets('主动关怀首页无总开关，全部分组同列等宽', (tester) async {
    await _mount(tester, const AutoReplySettingsPage());
    for (final label in ['待发送的消息', '让 AI 帮你记提醒', '打扰程度', '更多设置']) {
      expect(find.text(label), findsWidgets, reason: label);
    }
    expect(find.text('主动回复'), findsNothing);
    expect(find.byType(Switch), findsNWidgets(2));
    _expectUnifiedSurfaceWidth(tester);
  });

  testWidgets('主动关怀更多设置全部分组同列等宽', (tester) async {
    await _mount(tester, const AutoReplyAdvancedSettingsPage());
    for (final label in ['判断时机', '使用的模型', '判断提示词', '更准时', '历史记录']) {
      expect(find.text(label), findsWidgets, reason: label);
    }
    _expectUnifiedSurfaceWidth(tester);
  });

  testWidgets('Android 保活清单注入既有 fixture 后同宽', (tester) async {
    const status = AndroidKeepAliveStatus(
      guardEnabled: true,
      generationActive: true,
      serviceRunning: true,
      batteryOptimizationIgnored: false,
      canScheduleExactAlarms: true,
      notificationPermissionGranted: true,
      notificationsEnabled: true,
      guardNotificationChannelEnabled: true,
      notificationVisibleInDrawer: true,
      lastStartError: '',
      manufacturer: 'xiaomi',
      brand: 'redmi',
      model: 'test',
    );
    await _mount(
      tester,
      Scaffold(
        body: MoeSettingsContent(
          child: ListView(
            children: [
              AutoReplyKeepAliveSection(
                status: status,
                loading: false,
                onRefresh: () {},
                onNotificationTap: () {},
                onBatteryTap: () {},
                onAutoStartTap: () {},
                onBackgroundProtectionTap: () {},
                onExactAlarmTap: () {},
              ),
            ],
          ),
        ),
      ),
    );
    expect(find.text('后台运行'), findsOneWidget);
    _expectUnifiedSurfaceWidth(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('语音设置 1000 项懒构建且空态也有分组卡片', (tester) async {
    await _mount(tester, const TtsPluginDetailPage(), voicePresetCount: 1000);
    expect(tester.takeException(), isNull);
    expect(
      find.byType(ListTile).evaluate().length,
      lessThan(25),
      reason: '列表必须保持懒构建',
    );
    _expectUnifiedSurfaceWidth(tester);
  });

  testWidgets('语音设置空预设也有分组卡片而非裸空白', (tester) async {
    await _mount(tester, const TtsPluginDetailPage(), voicePresetCount: 0);
    expect(tester.takeException(), isNull);
    expect(find.textContaining('还没有音色预设'), findsOneWidget);
    _expectUnifiedSurfaceWidth(tester);
  });

  group('酒馆插件真实 store', () {
    testWidgets('主页与预设详情四个分区同宽', (tester) async {
      final temp = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('tavern_layout_'),
      ))!;
      addTearDown(() => temp.delete(recursive: true));
      final store = SillyTavernPresetStore(
        documentsDirectoryResolver: () async => temp,
      );
      await tester.runAsync(() async {
        await store.importSource(
          '{"name":"布局预设","prompts":[{"identifier":"main","content":"规则","role":"system"}],"prompt_order":[{"identifier":"main","enabled":true}],"regex":{"scripts":[{"id":"r1","scriptName":"替换","findRegex":"a","replaceString":"b","placement":[1]}]},"entries":{}}',
          sourceFileName: 'p.json',
        );
      });
      await _mount(tester, const TavernPluginDetailPage(), store: store);
      expect(find.text('布局预设'), findsOneWidget);
      _expectUnifiedSurfaceWidth(tester);

      await tester.tap(find.text('布局预设'));
      await _settle(tester);
      expect(tester.takeException(), isNull);
      for (final tab in ['提示词', '正则', '世界书', '标签']) {
        await tester.tap(
          find.descendant(
            of: find.byWidgetPredicate((w) => w is MoeToggleBar),
            matching: find.text(tab),
          ),
        );
        await _settle(tester);
        expect(tester.takeException(), isNull);
        _expectUnifiedSurfaceWidth(tester);
      }
    });
  });

  testWidgets('时间感知两个开关分别回写配置且互不影响', (tester) async {
    await _mount(tester, const TimeAwarenessPluginDetailPage());
    _expectUnifiedSurfaceWidth(tester);
    final element = tester.element(find.byType(TimeAwarenessPluginDetailPage));
    final container = ProviderScope.containerOf(element);
    Future<bool> timestamp() async => container
        .read(timeAwarenessPluginConfigProvider)
        .includeMessageTimestamp;
    Future<bool> currentTime() async =>
        container.read(timeAwarenessPluginConfigProvider).includeCurrentTime;
    final timestampBefore = await timestamp();
    final currentBefore = await currentTime();

    await tester.tap(find.text('历史消息时间戳'));
    await tester.pumpAndSettle();
    expect(await timestamp(), isNot(timestampBefore));
    expect(await currentTime(), currentBefore);

    await tester.tap(find.text('当前时间注入'));
    await tester.pumpAndSettle();
    expect(await currentTime(), isNot(currentBefore));
    expect(await timestamp(), isNot(timestampBefore));
    expect(tester.takeException(), isNull);
  });

  testWidgets('语音搜索滚出卸载后回来仍保持查询与过滤', (tester) async {
    await _mount(tester, const TtsPluginDetailPage(), voicePresetCount: 1000);
    final search = find.byKey(const ValueKey('voice-preset-search'));
    await tester.enterText(search, '预设');
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('voice-preset-p0')),
      findsOneWidget,
      reason: '过滤后首条应可见',
    );
    final scrollable = find.descendant(
      of: find.byType(CustomScrollView),
      matching: find.byType(Scrollable),
    );
    for (var i = 0; i < 10; i++) {
      await tester.drag(scrollable.first, const Offset(0, -800));
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(search, findsNothing, reason: '搜索栏应已滚出屏幕并卸载');
    await tester.dragUntilVisible(
      search,
      scrollable.first,
      const Offset(0, 400),
    );
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: search, matching: find.text('预设')),
      findsOneWidget,
      reason: '搜索栏重建后应保留原查询文本',
    );
    expect(
      find.byKey(const ValueKey('voice-preset-p0')),
      findsOneWidget,
      reason: '过滤结果应与滚出前一致',
    );
    await tester.enterText(search, '预设0999');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('voice-preset-p999')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final (label, page) in [
    ('触发器列表', const AutoReplyTriggerListPage()),
    ('历史日志', const AutoReplyHistoryLogPage()),
  ]) {
    for (final size in [const Size(360, 800), const Size(1000, 800)]) {
      for (final scale in [1.0, 1.8]) {
        testWidgets('主动回复$label $size scale=$scale 卡片同宽无溢出', (tester) async {
          await _mount(tester, page, size: size, scale: scale);
          expect(tester.takeException(), isNull);
          _expectUnifiedSurfaceWidth(tester);
          final scroll = find.byType(Scrollable).first;
          for (var i = 0; i < 3; i++) {
            await tester.drag(scroll, const Offset(0, -300));
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
          }
        });
      }
    }
  }
}
