// ADR0092 pages at narrow and wide widths: the drawing preset editor's
// 「提示词」 group, the pack list, a pack and a section editor. Lays out
// without errors; with --dart-define=WRITE_PROMPT_PREVIEW=true it also
// writes PNGs to .codex-temp/prompt-pack-preview/.
@Tags(['preview'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:aicove_flutter/src/features/plugins/image/drawing_preset.dart';
import 'package:aicove_flutter/src/features/plugins/image/drawing_preset_provider.dart';
import 'package:aicove_flutter/src/features/plugins/image/image_config.dart';
import 'package:aicove_flutter/src/features/plugins/prompts/prompt_pack.dart';
import 'package:aicove_flutter/src/ui/features/plugins/pages/drawing_preset_editor_page.dart';
import 'package:aicove_flutter/src/ui/features/plugins/pages/prompt_pack_pages.dart';
import 'package:aicove_flutter/src/ui/features/plugins/pages/prompt_section_editor_page.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../features/plugins/image/drawing_preset_test.dart'
    show MemoryDrawingStore;

const _capture = bool.fromEnvironment('WRITE_PROMPT_PREVIEW');

const _preset = DrawingPreset(
  id: 'nahida',
  name: '纳西妲 · NovelAI',
  config: ImageConfig(
    selectedProviderId: 'nai',
    selectedModelId: 'nai:nai-diffusion-5-full',
  ),
);

/// A ComfyUI preset still bound to the NovelAI pack, as old presets were.
final _comfyPreset = DrawingPreset(
  id: 'comfy',
  name: 'Modal · Z-Image',
  config: const ImageConfig(
    selectedProviderId: 'comfy',
    selectedModelId: 'comfy:template/zimage_turbo',
  ),
  prompts: const PresetPromptBinding(packId: 'builtin.image.novelai'),
);

void _seed() => SharedPreferences.setMockInitialValues({
  'aicove.ui_models.v1': jsonEncode({
    'providers': [
      {
        'id': 'nai',
        'displayName': 'NovelAI',
        'apiKeys': ['test-key'],
        'apiBaseUrl': 'https://invalid.example',
        'enabled': true,
        'models': ['nai-diffusion-5-full'],
        'visible_models': ['nai-diffusion-5-full'],
        'capabilities': ['image'],
        'custom_config': {'requestFormat': 'novelai'},
      },
      {
        'id': 'comfy',
        'displayName': 'Modal ComfyUI',
        'apiKeys': ['test-key'],
        'apiBaseUrl': 'https://invalid.example',
        'enabled': true,
        'models': ['template/zimage_turbo'],
        'visible_models': ['template/zimage_turbo'],
        'capabilities': ['image'],
        'custom_config': {'requestFormat': 'comfyui'},
      },
    ],
    'model_types': {
      'nai:nai-diffusion-5-full': 'image',
      'comfy:template/zimage_turbo': 'image',
    },
    'image_generation_enabled': true,
  }),
});

void main() {
  final boundary = GlobalKey();

  setUpAll(() async {
    if (!_capture) return;
    final font = FontLoader('PromptPreview')
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

  Future<void> shot(WidgetTester tester, String name) async {
    if (!_capture) return;
    await tester.runAsync(() async {
      final render =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await render.toImage(pixelRatio: 1.5);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('../../.codex-temp/prompt-pack-preview/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  Future<void> mount(WidgetTester tester, Size size, Widget home) async {
    _seed();
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          drawingPresetStoreProvider.overrideWithValue(
            MemoryDrawingStore(
              DrawingPresetCatalog(
                presets: [_preset, _comfyPreset],
                defaultPresetId: _preset.id,
                legacyConfig: const ImageConfig(),
              ),
            ),
          ),
        ],
        child: MaterialApp(
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFFFC96AA),
              primary: const Color(0xFFFC96AA),
            ),
            scaffoldBackgroundColor: moeSurface,
            fontFamily: _capture ? 'PromptPreview' : null,
            extensions: [MoeColors.light()],
          ),
          builder: (context, child) =>
              RepaintBoundary(key: boundary, child: child!),
          home: home,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final size in const [Size(400, 860), Size(1000, 860)]) {
    final tag = size.width.toInt();

    testWidgets('drawing preset editor prompt group $tag', (tester) async {
      await mount(tester, size, const DrawingPresetEditorPage(preset: _preset));
      final group = find.text('提示词包');
      await tester.scrollUntilVisible(
        group,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await Scrollable.ensureVisible(tester.element(group), alignment: 0.15);
      await tester.pumpAndSettle();
      expect(find.textContaining('自动匹配 · NovelAI'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await shot(tester, 'drawing-editor-$tag');
      await tester.tap(find.text('预览最终提示词'));
      await tester.pumpAndSettle();
      expect(find.text('最终提示词'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await shot(tester, 'preview-$tag');
    });

    testWidgets('ComfyUI preset recommends its pack and splits flows $tag', (
      tester,
    ) async {
      await mount(tester, size, DrawingPresetEditorPage(preset: _comfyPreset));
      final group = find.text('提示词包');
      await tester.scrollUntilVisible(
        group,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await Scrollable.ensureVisible(tester.element(group), alignment: 0.1);
      await tester.pumpAndSettle();
      expect(find.text('当前模型推荐「ComfyUI 通用」'), findsOneWidget);
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -200));
      await tester.pumpAndSettle();
      // The fast flow lists only the <image> section.
      await tester.tap(find.text('快速模式'));
      await tester.pumpAndSettle();
      expect(find.text('快速模式说明（NovelAI）'), findsOneWidget);
      expect(find.text('工具说明'), findsNothing);
      await shot(tester, 'comfy-bound-novelai-$tag');

      await tester.tap(find.text('当前模型推荐「ComfyUI 通用」'));
      await tester.pumpAndSettle();
      expect(find.textContaining('自动匹配 · ComfyUI 通用'), findsOneWidget);
      expect(find.text('当前模型推荐「ComfyUI 通用」'), findsNothing);
      expect(find.text('快速模式说明（ComfyUI 通用）'), findsOneWidget);
      await shot(tester, 'comfy-auto-fast-$tag');

      await tester.tap(find.text('调用模式'));
      await tester.pumpAndSettle();
      expect(find.text('快速模式说明（ComfyUI 通用）'), findsNothing);
      expect(find.text('工具说明'), findsOneWidget);
      expect(find.text('提示词参数（ComfyUI 通用）'), findsOneWidget);
      expect(find.text('参数'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await shot(tester, 'comfy-auto-call-$tag');
    });

    testWidgets('pack list, pack and section editor $tag', (tester) async {
      await mount(tester, size, const PromptPackListPage(pluginId: 'tts'));
      expect(find.textContaining('Fish Audio S2'), findsWidgets);
      expect(tester.takeException(), isNull);
      await shot(tester, 'pack-list-$tag');
      await tester.tap(find.textContaining('Fish Audio S2').first);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await shot(tester, 'pack-detail-$tag');
      await tester.pumpWidget(const SizedBox());
      await mount(
        tester,
        size,
        const PromptSectionEditorPage.pack(
          pluginId: 'tts',
          packId: 'builtin.tts.fish_s2',
          sectionId: 'fish_s2.emotion',
        ),
      );
      expect(find.text('编辑提示词'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await shot(tester, 'section-$tag');
    });
  }
}
