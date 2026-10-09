import 'dart:io';
import 'dart:ui' as ui;

import 'package:aicove_flutter/src/features/agent_context/domain/tavern_compatibility_port.dart';
import 'package:aicove_flutter/src/features/agent_context/providers/preset_recipe_provider.dart';
import 'package:aicove_flutter/src/ui/features/character/widgets/character_plugins_section.dart';
import 'package:aicove_flutter/src/ui/features/settings/pages/chat_plugin_settings_page.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 源码渲染预览：角色插件列表里的「MVU 变量」行（ADR0071）。
/// 用 `--dart-define=MVU_PREVIEW_OUT=<目录>` 运行时写出 PNG。
void main() {
  const out = String.fromEnvironment('MVU_PREVIEW_OUT');
  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    if (out.isEmpty) return;
    final font = FontLoader('MaterialPreview')
      ..addFont(
        File(
          '/System/Library/Fonts/STHeiti Medium.ttc',
        ).readAsBytes().then(ByteData.sublistView),
      );
    await font.load();
    final icons = FontLoader('MaterialIcons')
      ..addFont(
        File(
          '${Platform.environment['FLUTTER_ROOT']}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
        ).readAsBytes().then(ByteData.sublistView),
      );
    await icons.load();
  });

  testWidgets('角色插件列表出现 MVU 变量行', (tester) async {
    addTearDown(tester.view.reset);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 900);
    final key = GlobalKey();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          presetRecipeListProvider.overrideWith((ref) async => const []),
          tavernPluginSettingsProvider.overrideWith(
            (ref) async => const TavernPluginSettings(enabled: true),
          ),
        ],
        child: MaterialApp(
          theme: ThemeData(
            fontFamily: out.isEmpty ? null : 'MaterialPreview',
            extensions: [MoeColors.light()],
          ),
          home: RepaintBoundary(
            key: key,
            child: Scaffold(
              body: SingleChildScrollView(
                padding: const EdgeInsets.all(12),
                child: CharacterPluginsSection(
                  selectedPluginIds: {
                    for (final item in conversationScopedChatPluginItems)
                      item.id,
                  },
                  boundVoiceId: null,
                  voicePresets: const [],
                  drawingPersonaPrompt: '',
                  selectedRecipeId: null,
                  memoryDocAvailable: true,
                  onOpenMemoryDoc: () {},
                  onPluginIdsChanged: (_) {},
                  onVoiceChanged: (_) {},
                  onDrawingPresetChanged: (_) {},
                  onRecipeChanged: (_) {},
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('enabled-plugin-mvu')), findsOneWidget);
    expect(find.text('MVU 变量'), findsOneWidget);
    if (out.isEmpty) return;
    await tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File(
        '$out/mvu-plugin-row.png',
      ).writeAsBytes(bytes!.buffer.asUint8List());
    });
  });
}
