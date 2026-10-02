import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:aicove_flutter/src/features/agent_context/domain/silly_tavern_preset_parser.dart';
import 'package:aicove_flutter/src/features/agent_context/domain/silly_tavern_preset.dart';
import 'package:aicove_flutter/src/features/agent_context/domain/tavern_compatibility_port.dart';
import 'package:aicove_flutter/src/features/agent_context/providers/preset_recipe_provider.dart';
import 'package:aicove_flutter/src/ui/features/character/widgets/character_plugins_section.dart';
import 'package:aicove_flutter/src/ui/features/plugins/widgets/tavern_common.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/index.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';

Widget _host({
  required String? selectedRecipeId,
  required ValueChanged<String?> onChanged,
  List<PresetRecipeSummary> presets = const <PresetRecipeSummary>[
    PresetRecipeSummary(
      id: 'st_preset_aaaaaaaaaaaaaaaaaaaaaaaa',
      name: '酒馆测试预设',
      description: '4 个启用节点 · 顺序组 1',
      warningCount: 1,
    ),
  ],
}) {
  return ProviderScope(
    overrides: [
      presetRecipeListProvider.overrideWith((ref) async => presets),
      tavernPluginSettingsProvider.overrideWith(
        (ref) async => const TavernPluginSettings(enabled: true),
      ),
    ],
    child: MaterialApp(
      theme: ThemeData(
        extensions: <ThemeExtension<dynamic>>[MoeColors.light()],
      ),
      home: Scaffold(
        body: SingleChildScrollView(
          child: CharacterPluginsSection(
            selectedPluginIds: const {},
            boundVoiceId: null,
            voicePresets: const [],
            drawingPersonaPrompt: '',
            selectedRecipeId: selectedRecipeId,
            memoryDocAvailable: false,
            onOpenMemoryDoc: null,
            onPluginIdsChanged: (_) {},
            onVoiceChanged: (_) {},
            onDrawingPresetChanged: (_) {},
            onRecipeChanged: onChanged,
          ),
        ),
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  for (final size in <Size>[const Size(390, 844), const Size(1200, 900)]) {
    testWidgets(
      'renders bound preset without overflow at width ${size.width}',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(
          _host(
            selectedRecipeId: 'st_preset_aaaaaaaaaaaaaaaaaaaaaaaa',
            onChanged: (_) {},
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('酒馆'), findsOneWidget);
        expect(find.text('酒馆测试预设'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('renders actual preset info at width ${size.width}', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final preset = const SillyTavernPresetParser().parseSource(
        File('../../opusdocs/预设与正则/ARGO-1.5.json').readAsStringSync(),
        sourceFileName: 'ARGO-1.5.json',
      );
      final topLevelClassified = SillyTavernParameterStatus.values.fold<int>(
        0,
        (count, status) =>
            count + preset.parameterStatusCount(status, topLevelOnly: true),
      );
      expect(topLevelClassified, 47);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            extensions: <ThemeExtension<dynamic>>[MoeColors.light()],
          ),
          home: Scaffold(
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: SingleChildScrollView(
                  child: TavernPresetInfo(preset: preset),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.textContaining('47 个顶层字段'), findsOneWidget);
      expect(find.textContaining('生效 12 · 不适用 35'), findsOneWidget);
      expect(find.text('参数生效情况'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('picker can clear binding back to AIcove default', (
    tester,
  ) async {
    String? changed = 'unchanged';
    await tester.pumpWidget(
      _host(
        selectedRecipeId: 'st_preset_aaaaaaaaaaaaaaaaaaaaaaaa',
        onChanged: (value) => changed = value,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('酒馆测试预设'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('跟随默认酒馆预设').last);
    await tester.pumpAndSettle();

    expect(changed, isNull);
  });

  testWidgets('picker selection immediately replaces AIcove default label', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    String? selectedRecipeId;
    late StateSetter setHostState;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          presetRecipeListProvider.overrideWith(
            (ref) async => const <PresetRecipeSummary>[
              PresetRecipeSummary(
                id: 'st_preset_aaaaaaaaaaaaaaaaaaaaaaaa',
                name: '酒馆测试预设',
                description: '4 个启用节点 · 顺序组 1',
              ),
            ],
          ),
          tavernPluginSettingsProvider.overrideWith(
            (ref) async => const TavernPluginSettings(enabled: true),
          ),
        ],
        child: MaterialApp(
          theme: ThemeData(
            extensions: <ThemeExtension<dynamic>>[MoeColors.light()],
          ),
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                setHostState = setState;
                return SingleChildScrollView(
                  child: CharacterPluginsSection(
                    selectedPluginIds: const {},
                    boundVoiceId: null,
                    voicePresets: const [],
                    drawingPersonaPrompt: '',
                    selectedRecipeId: selectedRecipeId,
                    memoryDocAvailable: false,
                    onOpenMemoryDoc: null,
                    onPluginIdsChanged: (_) {},
                    onVoiceChanged: (_) {},
                    onDrawingPresetChanged: (_) {},
                    onRecipeChanged: (value) {
                      setHostState(() => selectedRecipeId = value);
                    },
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('跟随默认酒馆预设'), findsOneWidget);
    await tester.tap(find.text('跟随默认酒馆预设'));
    await tester.pumpAndSettle();
    final importedPresetTile = find.ancestor(
      of: find.text('酒馆测试预设'),
      matching: find.byType(MoeListTile),
    );
    expect(importedPresetTile, findsOneWidget);
    expect(
      tester.getRect(importedPresetTile).bottom,
      lessThanOrEqualTo(844 - 24),
    );
    await tester.tap(find.text('酒馆测试预设'));
    await tester.pumpAndSettle();

    expect(selectedRecipeId, 'st_preset_aaaaaaaaaaaaaaaaaaaaaaaa');
    expect(find.text('酒馆测试预设'), findsOneWidget);
    expect(find.text('跟随默认酒馆预设'), findsNothing);
  });

  testWidgets('empty preset library shows follow-default label', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        selectedRecipeId: null,
        onChanged: (_) {},
        presets: const <PresetRecipeSummary>[],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('跟随默认酒馆预设'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
