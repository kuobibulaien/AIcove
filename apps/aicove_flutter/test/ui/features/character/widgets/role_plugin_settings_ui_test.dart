import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:aicove_flutter/src/features/plugins/image/drawing_preset.dart';
import 'package:aicove_flutter/src/features/plugins/image/drawing_preset_provider.dart';
import 'package:aicove_flutter/src/features/plugins/image/image_config.dart';
import 'package:aicove_flutter/src/features/chat/domain/persona_prompt_codec.dart';
import 'package:aicove_flutter/src/features/agent_context/domain/tavern_compatibility_port.dart';
import 'package:aicove_flutter/src/features/agent_context/providers/preset_recipe_provider.dart';
import 'package:aicove_flutter/src/ui/features/character/widgets/character_plugins_section.dart';
import 'package:aicove_flutter/src/ui/features/settings/pages/chat_plugin_settings_page.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/index.dart';
import '../../../../features/plugins/image/drawing_preset_test.dart'
    show MemoryDrawingStore;

Widget _section({
  Set<String>? selectedPluginIds,
  String? boundVoiceId,
  String drawingPersonaPrompt = '',
  String? selectedRecipeId,
  ValueChanged<Set<String>>? onPluginIdsChanged,
  ValueChanged<String?>? onVoiceChanged,
  ValueChanged<String?>? onDrawingPresetChanged,
  ValueChanged<String?>? onRecipeChanged,
}) {
  return CharacterPluginsSection(
    selectedPluginIds: selectedPluginIds ?? const {},
    boundVoiceId: boundVoiceId,
    voicePresets: const [],
    drawingPersonaPrompt: drawingPersonaPrompt,
    selectedRecipeId: selectedRecipeId,
    memoryDocAvailable: true,
    onOpenMemoryDoc: () {},
    onPluginIdsChanged: onPluginIdsChanged ?? (_) {},
    onVoiceChanged: onVoiceChanged ?? (_) {},
    onDrawingPresetChanged: onDrawingPresetChanged ?? (_) {},
    onRecipeChanged: onRecipeChanged ?? (_) {},
  );
}

Widget _app(Widget child, {List<Override> overrides = const []}) {
  return ProviderScope(
    overrides: [
      presetRecipeListProvider.overrideWith((ref) async => []),
      tavernPluginSettingsProvider.overrideWith(
        (ref) async => const TavernPluginSettings(enabled: true),
      ),
      ...overrides,
    ],
    child: MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: const TextScaler.linear(1.8)),
        child: child!,
      ),
      home: Scaffold(body: SingleChildScrollView(child: child)),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final width in [360.0, 1000.0]) {
    testWidgets('consistent role plugin rows and drawing picker $width',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = Size(width, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final choices = <String?>[];
      await tester.pumpWidget(_app(
        _section(
          selectedPluginIds: {
            for (final item in conversationScopedChatPluginItems) item.id,
          },
          onDrawingPresetChanged: choices.add,
        ),
        overrides: [
          drawingPresetStoreProvider.overrideWithValue(MemoryDrawingStore(
              DrawingPresetCatalog(presets: const [
            DrawingPreset(id: 'one', name: '默认绘图', config: ImageConfig())
          ], defaultPresetId: 'one', legacyConfig: const ImageConfig()))),
        ],
      ));
      await tester.pumpAndSettle();
      expect(find.byType(MoeSettingsGroup), findsAtLeastNWidgets(1));
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('绘图配置包'));
      await tester.tap(find.text('绘图配置包'));
      await tester.pumpAndSettle();
      expect(find.byType(MoeBottomSheet), findsOneWidget);
      await tester.tap(find.text('跟随默认绘图配置包'));
      await tester.pumpAndSettle();
      expect(choices, [null]);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('legacy drawing binding is not labelled as following default',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final persona = PersonaPromptCodec.compose(
        userPrompt: '', drawingArtistPresetName: '旧画师');
    await tester.pumpWidget(_app(
      _section(
        selectedPluginIds: const {'image'},
        drawingPersonaPrompt: persona,
      ),
      overrides: [
        drawingPresetStoreProvider.overrideWithValue(MemoryDrawingStore(
            DrawingPresetCatalog(presets: const [
          DrawingPreset(id: 'one', name: '默认绘图', config: ImageConfig())
        ], defaultPresetId: 'one', legacyConfig: const ImageConfig()))),
        roleDrawingPresetProvider(persona).overrideWith((ref) async =>
            const DrawingPreset(
                id: 'legacy', name: '旧配置 · 旧画师', config: ImageConfig())),
      ],
    ));
    await tester.pumpAndSettle();
    expect(find.text('旧配置 · 旧画师'), findsOneWidget);
    expect(find.textContaining('跟随默认绘图'), findsNothing);
  });
}
