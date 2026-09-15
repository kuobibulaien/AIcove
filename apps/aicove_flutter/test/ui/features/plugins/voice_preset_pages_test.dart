import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/features/plugins/plugin_providers.dart';
import 'package:aicove_flutter/src/features/plugins/tts/tts_config.dart';
import 'package:aicove_flutter/src/features/plugins/tts/providers/tts_voice_provider.dart';
import 'package:aicove_flutter/src/features/plugins/tts/voice_preset_application.dart';
import 'package:aicove_flutter/src/ui/features/plugins/pages/tts_plugin_detail_page.dart';
import 'package:aicove_flutter/src/ui/features/plugins/pages/voice_preset_editor_page.dart';
import 'package:aicove_flutter/src/ui/features/plugins/widgets/voice_preset_list.dart';
import 'package:aicove_flutter/src/features/agent_context/providers/preset_recipe_provider.dart';
import 'package:aicove_flutter/src/features/agent_context/domain/tavern_compatibility_port.dart';
import 'package:aicove_flutter/src/ui/features/character/widgets/character_plugins_section.dart';

class _Settings extends AppSettingsNotifier {
  @override
  Future<AppSettings> build() async => mapUiModelsToAppSettings({}).copyWith(
    providers: [
      for (final id in ['a', 'b'])
        ProviderAuth(
          id: id,
          displayName: '渠道$id',
          apiKeys: ['fake'],
          apiBaseUrl: 'https://example.invalid',
          models: const ['speech'],
          visibleModels: const ['speech'],
          capabilities: const ['tts'],
          customConfig: const {'requestFormat': 'minimax_tts'},
        ),
    ],
    modelList: const ['a:speech', 'b:speech'],
    allKnownModels: const ['a:speech', 'b:speech'],
    modelTypes: const {'a:speech': 'tts', 'b:speech': 'tts'},
  );
}

class _Port implements VoicePresetApplicationPort {
  VoicePreset? saved;
  final remote = Completer<VoiceListResult>();
  @override
  Future<void> initialize() async {}
  @override
  Future<List<String>> references(String id) async => [];
  @override
  Future<void> save(VoicePreset preset) async {
    saved = preset;
  }

  @override
  Future<VoiceListResult> catalog(String providerId, String modelId) =>
      remote.future;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  VoicePreset preset(int i) => VoicePreset(
    id: 'p$i',
    name: '预设${i.toString().padLeft(4, '0')}',
    synthesis: VoiceSynthesisSettings(
      providerId: i.isEven ? 'a' : 'b',
      modelId: 'speech',
      voiceId: 'remote$i',
    ),
  );
  Future<void> mount(
    WidgetTester tester,
    Widget page,
    Size size, {
    double scale = 1.8,
    _Port? port,
    int count = 1000,
  }) async {
    SharedPreferences.setMockInitialValues({
      'aicove.plugins.tts.config': jsonEncode(
        TtsConfig(
          presetSchemaVersion: 1,
          voicePresets: [for (var i = 0; i < count; i++) preset(i)],
        ).toJson(),
      ),
    });
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appSettingsProvider.overrideWith(_Settings.new),
          presetRecipeListProvider
              .overrideWith((ref) async => const <PresetRecipeSummary>[]),
          tavernPluginSettingsProvider.overrideWith(
              (ref) async => const TavernPluginSettings(enabled: true)),
          if (port != null)
            voicePresetApplicationProvider.overrideWithValue(port),
          voicePresetReadyProvider.overrideWith((ref) async {
            await ref.read(ttsPluginConfigProvider.notifier).ready;
          }),
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
    await tester.pumpAndSettle();
  }

  for (final size in [const Size(320, 568), const Size(1000, 768)]) {
    testWidgets(
      'complete grouped library with 1000 entries and large text $size',
      (tester) async {
        await mount(tester, const TtsPluginDetailPage(), size);
        expect(tester.takeException(), isNull);
        expect(find.byType(ListTile).evaluate().length, lessThan(25));
        await tester.enterText(
          find.byKey(const ValueKey('voice-preset-search')),
          '预设0999',
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('voice-preset-p999')), findsOneWidget);
        expect(find.text('渠道b'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
    testWidgets('editor scrolls through every field and saves preset $size', (
      tester,
    ) async {
      final port = _Port();
      await mount(
        tester,
        VoicePresetEditorPage(preset: preset(1)),
        size,
        port: port,
        count: 2,
      );
      await tester.enterText(find.byType(TextFormField).first, '自动保存音色');
      await tester.pump(const Duration(milliseconds: 500));
      final scroll = find.byType(ListView).first;
      for (var i = 0; i < 9; i++) {
        await tester.drag(scroll, const Offset(0, -300));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
      expect(find.text('保存预设'), findsNothing);
      expect(port.saved?.name, '自动保存音色');
      expect(port.saved?.synthesis?.providerId, 'b');
      expect(port.saved?.synthesis?.voiceId, 'remote1');
    });
  }

  testWidgets('remote directory response after closing editor is ignored', (
    tester,
  ) async {
    final port = _Port();
    await mount(
      tester,
      VoicePresetEditorPage(preset: preset(0)),
      const Size(400, 800),
      port: port,
      count: 2,
      scale: 1,
    );
    await tester.ensureVisible(find.text('浏览此供应商的音色'));
    await tester.tap(find.text('浏览此供应商的音色'));
    await tester.pump();
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    port.remote.complete(
      const VoiceListResult(presetVoices: [], userVoices: []),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'actual role editor binds the chosen complete preset on a narrow screen',
    (tester) async {
      String? selected;
      await mount(
        tester,
        Scaffold(
          body: SingleChildScrollView(
            child: CharacterPluginsSection(
              selectedPluginIds: const {'tts'},
              boundVoiceId: null,
              voicePresets: [preset(0), preset(1)],
              drawingPersonaPrompt: '',
              selectedRecipeId: null,
              memoryDocAvailable: false,
              onOpenMemoryDoc: null,
              onPluginIdsChanged: (_) {},
              onVoiceChanged: (value) => selected = value,
              onDrawingPresetChanged: (_) {},
              onRecipeChanged: (_) {},
            ),
          ),
        ),
        const Size(320, 568),
        count: 2,
      );
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('音色配置包'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('voice-preset-search')),
        '预设0001',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('voice-preset-p1')));
      await tester.pumpAndSettle();
      expect(selected, 'p1');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'role picker lists both providers and explicitly selects one preset',
    (tester) async {
      VoicePreset? selected;
      await mount(
        tester,
        Scaffold(
          body: VoicePresetList(
            presets: [preset(0), preset(1)],
            providerNames: const {'a': '渠道a', 'b': '渠道b'},
            allowDefault: true,
            onSelect: (value) => selected = value,
          ),
        ),
        const Size(400, 800),
        scale: 1,
      );
      expect(find.text('渠道a'), findsOneWidget);
      expect(find.text('渠道b'), findsOneWidget);
      await tester.tap(find.text('预设0001'));
      expect(selected?.id, 'p1');
      await tester.tap(find.text('使用默认预设'));
      expect(selected, isNull);
    },
  );
}
