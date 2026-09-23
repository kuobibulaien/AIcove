import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:aicove_flutter/src/features/agent_context/data/silly_tavern_preset_store.dart';
import 'package:aicove_flutter/src/features/agent_context/domain/tavern_compatibility_port.dart';
import 'package:aicove_flutter/src/features/agent_context/providers/preset_recipe_provider.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/auto_reply_trigger.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/auto_reply_trigger_controller.dart';
import 'package:aicove_flutter/src/features/plugins/plugin_providers.dart';
import 'package:aicove_flutter/src/features/plugins/tts/tts_config.dart';
import 'package:aicove_flutter/src/features/plugins/tts/voice_preset_application.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/ui/features/auto_reply/pages/auto_reply_settings_page.dart';
import 'package:aicove_flutter/src/ui/features/settings/pages/context_memory_settings_page.dart';
import 'package:aicove_flutter/src/ui/features/plugins/pages/tavern_plugin_detail_page.dart';
import 'package:aicove_flutter/src/ui/features/plugins/pages/time_awareness_plugin_detail_page.dart';
import 'package:aicove_flutter/src/ui/features/plugins/pages/tts_plugin_detail_page.dart';
import 'package:aicove_flutter/src/ui/features/settings/pages/settings_page.dart';
import 'package:aicove_flutter/src/ui/shared/animations/parallax_slide_page_route.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/index.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/moe_adaptive_shell.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';

class _PreviewSettings extends AppSettingsNotifier {
  @override
  Future<AppSettings> build() async => mapUiModelsToAppSettings({}).copyWith(
    autoReplySettings: const AutoReplySettings(enabled: true),
    providers: [
      const ProviderAuth(
        id: 'a',
        displayName: '示例渠道',
        apiKeys: ['fake'],
        apiBaseUrl: 'https://example.invalid',
        models: ['speech', 'embed'],
        visibleModels: ['speech'],
        capabilities: ['tts'],
        customConfig: {'requestFormat': 'minimax_tts'},
      ),
    ],
    modelList: const ['a:speech', 'a:embed'],
    allKnownModels: const ['a:speech', 'a:embed'],
    modelTypes: const {'a:speech': 'tts', 'a:embed': 'embedding'},
  );
}

class _PreviewTriggerController extends AutoReplyTriggerController {
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

const _write = bool.fromEnvironment('WRITE_SETTINGS_QA');
const _fontFamily = 'SettingsContainerCapture';
const _outDir = '../../.codex-temp/settings-containers-20260916';

final _pages = <String, Widget>{
  'memory': const ContextMemorySettingsPage(),
  'auto-reply': const AutoReplySettingsPage(),
  'tts': const TtsPluginDetailPage(),
  'tavern': const TavernPluginDetailPage(),
  'time': const TimeAwarenessPluginDetailPage(),
};

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 24; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pumpAndSettle();
}

Future<void> _capture(WidgetTester tester, GlobalKey key, String name) async {
  await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 2);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('$_outDir/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(data!.buffer.asUint8List());
    image.dispose();
  });
}

Widget _wrap({
  required Widget child,
  required bool dark,
  required double scale,
}) {
  final colors = dark ? MoeColors.dark() : MoeColors.light();
  return MaterialApp(
    theme: ThemeData(
      brightness: dark ? Brightness.dark : Brightness.light,
      fontFamily: _write ? _fontFamily : null,
      extensions: [colors],
    ),
    builder: (context, child) => MoeGlassTheme(
      enabled: true,
      blurSigma: 16,
      useLiquidGlass: false,
      child: MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
    ),
    home: child,
  );
}

void main() {
  setUpAll(() async {
    if (!_write) return;
    final font = FontLoader(_fontFamily);
    font.addFont(
      File(
        '/System/Library/Fonts/STHeiti Medium.ttc',
      ).readAsBytes().then(ByteData.sublistView),
    );
    await font.load();
    final icons = FontLoader('MaterialIcons');
    icons.addFont(
      File(
        '${Platform.environment['FLUTTER_ROOT']}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
      ).readAsBytes().then(ByteData.sublistView),
    );
    await icons.load();
  });

  late Directory temp;
  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'aicove.plugins.tts.config': jsonEncode(
        TtsConfig(
          presetSchemaVersion: 1,
          voicePresets: [
            for (var i = 0; i < 4; i++)
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
    temp = await Directory.systemTemp.createTemp('settings_preview_');
    addTearDown(() => temp.delete(recursive: true));
  });

  List<Override> overrides({SillyTavernPresetStore? store}) => [
    appSettingsProvider.overrideWith(_PreviewSettings.new),
    autoReplyTriggersProvider.overrideWith(_PreviewTriggerController.new),
    tavernPluginSettingsProvider.overrideWith(
      (ref) async => const TavernPluginSettings(enabled: true),
    ),
    voicePresetReadyProvider.overrideWith((ref) async {
      await ref.read(ttsPluginConfigProvider.notifier).ready;
    }),
    if (store != null)
      sillyTavernPresetStoreProvider.overrideWithValue(store)
    else
      presetRecipeListProvider.overrideWith(
        (ref) async => const <PresetRecipeSummary>[],
      ),
  ];

  Future<SillyTavernPresetStore> seedStore(WidgetTester tester) async {
    final store = SillyTavernPresetStore(
      documentsDirectoryResolver: () async => temp,
    );
    await tester.runAsync(
      () => store.importSource(
        '{"name":"预览预设","prompts":[{"identifier":"main","content":"规则","role":"system"}],"prompt_order":[{"identifier":"main","enabled":true}],"regex":{"scripts":[{"id":"r1","scriptName":"替换","findRegex":"a","replaceString":"b","placement":[1]}]},"entries":{}}',
        sourceFileName: 'p.json',
      ),
    );
    return store;
  }

  for (final dark in [false, true]) {
    for (final entry in _pages.entries) {
      testWidgets('narrow ${entry.key} dark=$dark', (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(360, 800);
        addTearDown(tester.view.reset);
        final store = entry.key == 'tavern' ? await seedStore(tester) : null;
        final key = GlobalKey();
        await tester.pumpWidget(
          ProviderScope(
            overrides: overrides(store: store),
            child: _wrap(
              dark: dark,
              scale: 1.0,
              child: RepaintBoundary(key: key, child: entry.value),
            ),
          ),
        );
        await _settle(tester);
        expect(tester.takeException(), isNull);
        if (_write) {
          await _capture(
            tester,
            key,
            'narrow-${dark ? 'dark' : 'light'}-${entry.key}',
          );
        }
      });
    }
    testWidgets('narrow contact sheet dark=$dark', (tester) async {
      if (!_write) return;
      final mode = dark ? 'dark' : 'light';
      await tester.runAsync(() async {
        final images = <ui.Image>[];
        for (final page in _pages.keys) {
          final file = File('$_outDir/narrow-$mode-$page.png');
          expect(
            file.existsSync(),
            isTrue,
            reason: '缺少已渲染窄图 narrow-$mode-$page.png',
          );
          final codec = await ui.instantiateImageCodec(
            await file.readAsBytes(),
          );
          images.add((await codec.getNextFrame()).image);
        }
        final tileWidth = images.first.width;
        final tileHeight = images.first.height;
        for (final image in images) {
          expect(image.width, tileWidth);
          expect(image.height, tileHeight);
        }
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        var dx = 0.0;
        for (final image in images) {
          canvas.drawImage(image, Offset(dx, 0), Paint());
          dx += tileWidth;
        }
        final combined = await recorder.endRecording().toImage(
          tileWidth * images.length,
          tileHeight,
        );
        final data = await combined.toByteData(format: ui.ImageByteFormat.png);
        await File(
          '$_outDir/contact-narrow-$mode.png',
        ).writeAsBytes(data!.buffer.asUint8List());
        for (final image in images) {
          image.dispose();
        }
        combined.dispose();
      });
    });
  }

  for (final entry in _pages.entries) {
    testWidgets('wide shell ${entry.key} 1280', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 800);
      addTearDown(tester.view.reset);
      final store = entry.key == 'tavern' ? await seedStore(tester) : null;
      final nav = GlobalKey<NavigatorState>();
      final observer = MoeDetailStackObserver();
      final key = GlobalKey();
      await tester.pumpWidget(
        ProviderScope(
          overrides: overrides(store: store),
          child: _wrap(
            dark: false,
            scale: 1.0,
            child: RepaintBoundary(
              key: key,
              child: MoeAdaptiveShell(
                navigatorKey: nav,
                observer: observer,
                primary: const SettingsPage(),
                detail: Navigator(
                  key: nav,
                  observers: [observer],
                  onGenerateRoute: (_) =>
                      ParallaxSlidePageRoute(page: entry.value),
                ),
              ),
            ),
          ),
        ),
      );
      await _settle(tester);
      expect(tester.takeException(), isNull);
      if (_write) {
        await _capture(tester, key, 'wide-shell-${entry.key}');
      }
    });
  }
}
