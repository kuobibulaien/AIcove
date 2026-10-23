import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/core/api/image_providers/comfyui_workflow.dart';
import 'package:aicove_flutter/src/features/plugins/image/drawing_preset.dart';
import 'package:aicove_flutter/src/features/plugins/image/image_config.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/ui/features/plugins/pages/drawing_preset_editor_page.dart';
import 'package:aicove_flutter/src/ui/features/plugins/pages/image_generation_test_page.dart';
import 'package:aicove_flutter/src/ui/features/settings/pages/add_provider_sheet.dart';
import 'package:aicove_flutter/src/ui/features/settings/pages/provider_detail_page.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:aicove_flutter/src/ui/features/settings/widgets/comfyui_workflow_editor.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/meotalk_dialog.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';

const workflow = <String, dynamic>{
  'comfyWorkflow': {
    '6': {
      'class_type': 'CLIPTextEncode',
      'inputs': {'text': 'cat'},
    },
    '7': {
      'class_type': 'CLIPTextEncode',
      'inputs': {'text': 'bad'},
    },
    '9': {
      'class_type': 'SaveImage',
      'inputs': {
        'images': ['8', 0],
      },
    },
  },
  'comfyBindings': {'prompt': '6.text', 'negative_prompt': '7.text'},
};

const capture = bool.fromEnvironment('WRITE_COMFY_PREVIEW');

void main() {
  setUpAll(() async {
    if (!capture) return;
    final font = FontLoader('ComfyPreview');
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

  Widget wrap(Widget child) => ProviderScope(
    child: MaterialApp(
      theme: ThemeData(
        fontFamily: capture ? 'ComfyPreview' : null,
        extensions: [MoeColors.light()],
      ),
      home: Scaffold(body: child),
    ),
  );

  for (final width in [390.0, 720.0]) {
    testWidgets('workflow editor binds inputs and fits width $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 960);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final boundary = GlobalKey();
      await tester.pumpWidget(
        wrap(
          RepaintBoundary(
            key: boundary,
            child: const ComfyUIWorkflowEditor(config: workflow),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('参数绑定 · 3 个节点'), findsOneWidget);
      expect(find.text('正向提示词'), findsOneWidget);
      expect(tester.takeException(), isNull);
      if (capture) {
        await tester.runAsync(() async {
          final image =
              await (boundary.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage(pixelRatio: 1.5);
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File(
            '../../.codex-temp/comfyui-20260922/workflow-${width.toInt()}.png',
          );
          await file.parent.create(recursive: true);
          await file.writeAsBytes(data!.buffer.asUint8List());
          image.dispose();
        });
      }
      await tester.enterText(
        find.byKey(const ValueKey('comfy-workflow-json')),
        '{"nodes": []}',
      );
      await tester.tap(find.text('保存工作流'));
      await tester.pumpAndSettle();
      expect(find.textContaining('不是画布格式'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('pasting a new workflow and clicking parse re-infers flipped bindings', (
    tester,
  ) async {
    Map<String, dynamic>? result;
    await tester.pumpWidget(
      wrap(
        Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await showComfyUIWorkflowEditor(context, workflow);
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // Paste a new workflow where node 7 is positive and node 6 is negative.
    final flippedGraph = jsonEncode({
      '3': {
        'class_type': 'KSampler',
        'inputs': {
          'seed': 42,
          'steps': 20,
          'cfg': 6.0,
          'sampler_name': 'euler',
          'positive': ['7', 0],
          'negative': ['6', 0],
          'latent_image': ['5', 0],
        },
      },
      '5': {
        'class_type': 'EmptyLatentImage',
        'inputs': {'width': 832, 'height': 1216, 'batch_size': 1},
      },
      '6': {
        'class_type': 'CLIPTextEncode',
        'inputs': {'text': 'now negative'},
      },
      '7': {
        'class_type': 'CLIPTextEncode',
        'inputs': {'text': 'now positive'},
      },
      '8': {
        'class_type': 'VAEDecode',
        'inputs': {
          'samples': ['3', 0],
        },
      },
      '9': {
        'class_type': 'SaveImage',
        'inputs': {
          'images': ['8', 0],
        },
      },
    });
    await tester.enterText(
      find.byKey(const ValueKey('comfy-workflow-json')),
      flippedGraph,
    );
    await tester.tap(find.text('解析粘贴内容'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存工作流'));
    await tester.pumpAndSettle();

    final savedBindings = result?['comfyBindings'] as Map?;
    expect(savedBindings?['prompt'], '7.text');
    expect(savedBindings?['negative_prompt'], '6.text');
    expect(result?['comfyOutputNode'], '9');
  });

  testWidgets('ComfyUI add flow hides chat path, allows optional key, and does not force workflow at import', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 960);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final boundary = GlobalKey();
    await tester.pumpWidget(
      wrap(
        RepaintBoundary(
          key: boundary,
          child: const AddProviderSheet(),
        ),
      ),
    );
    await tester.tap(find.text('绘图'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('ComfyUI'));
    await tester.pumpAndSettle();
    expect(find.text('API 路径'), findsNothing);
    expect(find.text('可选（Bearer Token）'), findsOneWidget);
    expect(find.text('ComfyUI 工作流'), findsNothing);
    expect(find.textContaining('自动拉取基础模型列表'), findsOneWidget);
    expect(find.text('http://127.0.0.1:8188'), findsOneWidget);
    expect(tester.takeException(), isNull);
    if (capture) {
      await tester.runAsync(() async {
        final image =
            await (boundary.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage(pixelRatio: 1.5);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File(
          '../../scratch/comfyui-smart-import/add-provider-390.png',
        );
        await file.parent.create(recursive: true);
        await file.writeAsBytes(data!.buffer.asUint8List());
        image.dispose();
      });
    }
  });

  testWidgets('editor opens as MeoTalkDialog without dimming barrier', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(720, 960);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final boundary = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: wrap(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => showComfyUIWorkflowEditor(context, workflow),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byType(MeoTalkDialog), findsOneWidget);
    expect(find.byType(Dialog), findsNothing);
    final barriers = tester.widgetList<ModalBarrier>(find.byType(ModalBarrier));
    expect(
      barriers.every(
        (barrier) => barrier.color == null || barrier.color!.a == 0,
      ),
      isTrue,
    );
    expect(tester.takeException(), isNull);
    if (capture) {
      await tester.runAsync(() async {
        final image =
            await (boundary.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage(pixelRatio: 1.5);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File('../../scratch/comfyui-dialog/editor-720.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(data!.buffer.asUint8List());
        image.dispose();
      });
    }
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.byType(MeoTalkDialog), findsNothing);
  });

  testWidgets('saving a parsed workflow returns bindings to caller', (
    tester,
  ) async {
    Map<String, dynamic>? result;
    await tester.pumpWidget(
      wrap(
        Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await showComfyUIWorkflowEditor(context, workflow);
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存工作流'));
    await tester.pumpAndSettle();
    expect(result?['comfyBindings'], workflow['comfyBindings']);
    expect(result?['comfyWorkflow'], workflow['comfyWorkflow']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('ComfyUI channel detail only connects and has no workflow import', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({
      'aicove.ui_models.v1': jsonEncode({
        'providers': [
          {
            'id': 'comfy',
            'displayName': 'ComfyUI',
            'apiKeys': <String>[],
            'apiBaseUrl': 'http://127.0.0.1:8188',
            'enabled': true,
            'models': ['illustrious_xl.safetensors'],
            'visible_models': ['illustrious_xl.safetensors'],
            'hidden_models': <String>[],
            'capabilities': ['image'],
            'custom_config': {'requestFormat': 'comfyui'},
          },
        ],
        'model_types': {'comfy:illustrious_xl.safetensors': 'image'},
      }),
    });
    await tester.pumpWidget(
      wrap(const ProviderDetailPage(providerId: 'comfy')),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('基础模型从服务端自动拉取'), findsOneWidget);
    expect(find.text('工作流与参数绑定'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('drawing preset editor shows ComfyUI LoRA and custom workflow options and passes fresh LoRA to test page', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 960);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final settings = mapUiModelsToAppSettings({
      'providers': [
        {
          'id': 'comfy',
          'displayName': '魔搭 ComfyUI',
          'apiKeys': <String>[],
          'apiBaseUrl': 'http://127.0.0.1:8188',
          'enabled': true,
          'models': ['illustrious_xl.safetensors', 'comfyui-workflow'],
          'visible_models': ['illustrious_xl.safetensors', 'comfyui-workflow'],
          'capabilities': ['image'],
          'custom_config': {'requestFormat': 'comfyui'},
        },
      ],
      'model_types': {
        'comfy:illustrious_xl.safetensors': 'image',
        'comfy:comfyui-workflow': 'image',
      },
      'image_generation_enabled': true,
    });
    const preset = DrawingPreset(
      id: 'comfy-preset',
      name: '二次元+LoRA预设',
      config: ImageConfig(
        selectedProviderId: 'comfy',
        selectedModelId: 'comfy:illustrious_xl.safetensors',
        comfyLoraName: 'kokomi_lora.safetensors',
        comfyLoraStrength: 0.85,
        comfyWorkflowMode: ComfyUIWorkflow.standardMode,
      ),
    );
    final boundary = GlobalKey();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appSettingsProvider.overrideWith(() => _PresetSettings(settings)),
        ],
        child: MaterialApp(
          theme: ThemeData(
            fontFamily: capture ? 'ComfyPreview' : null,
            extensions: [MoeColors.light()],
          ),
          home: RepaintBoundary(
            key: boundary,
            child: const DrawingPresetEditorPage(preset: preset),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('ComfyUI 工作流'), findsOneWidget);
    expect(find.text('工作流模式'), findsOneWidget);
    expect(find.text('从服务端选择 LoRA'), findsOneWidget);
    expect(find.text('kokomi_lora.safetensors'), findsWidgets);
    expect(find.text('采样器'), findsOneWidget);
    expect(find.text('默认（euler）'), findsOneWidget);
    expect(find.text('调度器'), findsOneWidget);
    expect(find.text('默认（normal）'), findsOneWidget);
    expect(tester.takeException(), isNull);
    if (capture) {
      await tester.runAsync(() async {
        final image =
            await (boundary.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage(pixelRatio: 1.5);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File(
          '../../scratch/comfyui-smart-import/preset-editor-390.png',
        );
        await file.parent.create(recursive: true);
        await file.writeAsBytes(data!.buffer.asUint8List());
        image.dispose();
      });
    }

    // Update LoRA name and strength, then open test page via top action button.
    await tester.enterText(
      find.widgetWithText(TextField, 'kokomi_lora.safetensors'),
      'nahida_v2.safetensors',
    );
    await tester.enterText(
      find.widgetWithText(TextField, '0.85'),
      '0.65',
    );
    await tester.tap(find.byTooltip('生图测试'));
    await tester.pumpAndSettle();

    final testPage = tester.widget<ImageGenerationTestPage>(
      find.byType(ImageGenerationTestPage),
    );
    expect(testPage.drawingConfig?.comfyLoraName, 'nahida_v2.safetensors');
    expect(testPage.drawingConfig?.comfyLoraStrength, 0.65);
  });

  testWidgets('gateway template preset hides template-owned sampling settings', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final settings = mapUiModelsToAppSettings({
      'providers': [
        {
          'id': 'modal',
          'displayName': 'Modal ComfyUI',
          'apiKeys': <String>['gw-key'],
          'apiBaseUrl': 'https://gw.modal.run',
          'enabled': true,
          'models': ['template/zimage_turbo', 'comfyui-workflow'],
          'visible_models': ['template/zimage_turbo', 'comfyui-workflow'],
          'capabilities': ['image'],
          'custom_config': {'requestFormat': 'comfyui'},
        },
      ],
      'model_types': {
        'modal:template/zimage_turbo': 'image',
        'modal:comfyui-workflow': 'image',
      },
      'image_generation_enabled': true,
    });
    const preset = DrawingPreset(
      id: 'modal-preset',
      name: 'Z-Image',
      config: ImageConfig(
        selectedProviderId: 'modal',
        selectedModelId: 'modal:template/zimage_turbo',
        comfyWorkflowMode: ComfyUIWorkflow.standardMode,
      ),
    );
    final boundary = GlobalKey();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appSettingsProvider.overrideWith(() => _PresetSettings(settings)),
        ],
        child: MaterialApp(
          theme: ThemeData(
            fontFamily: capture ? 'ComfyPreview' : null,
            extensions: [MoeColors.light()],
          ),
          home: RepaintBoundary(
            key: boundary,
            child: const DrawingPresetEditorPage(preset: preset),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('服务端模板 zimage_turbo'), findsOneWidget);
    expect(find.text('从服务端选择 LoRA'), findsOneWidget);
    expect(find.text('采样器'), findsNothing);
    expect(find.text('调度器'), findsNothing);
    expect(find.text('步数（1–100）'), findsNothing);
    expect(find.text('提示词强度（0–10）'), findsNothing);
    expect(tester.takeException(), isNull);
    if (capture) {
      await tester.runAsync(() async {
        final image =
            await (boundary.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage(pixelRatio: 1.5);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File('../../scratch/comfyui-gateway/preset-template-390.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(data!.buffer.asUint8List());
        image.dispose();
      });
    }
  });

  testWidgets('restoring standard mode switches away from placeholder model and custom mode ignores invalid hidden LoRA draft', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 960);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final settings = mapUiModelsToAppSettings({
      'providers': [
        {
          'id': 'comfy',
          'displayName': '魔搭 ComfyUI',
          'apiKeys': <String>[],
          'apiBaseUrl': 'http://127.0.0.1:8188',
          'enabled': true,
          'models': ['illustrious_xl.safetensors', 'comfyui-workflow'],
          'visible_models': ['illustrious_xl.safetensors', 'comfyui-workflow'],
          'capabilities': ['image'],
          'custom_config': {'requestFormat': 'comfyui'},
        },
      ],
      'model_types': {
        'comfy:illustrious_xl.safetensors': 'image',
        'comfy:comfyui-workflow': 'image',
      },
      'image_generation_enabled': true,
    });
    const preset = DrawingPreset(
      id: 'comfy-custom',
      name: '自定义工作流预设',
      config: ImageConfig(
        selectedProviderId: 'comfy',
        selectedModelId: 'comfy:comfyui-workflow',
        comfyLoraName: 'draft_lora.safetensors',
        comfyLoraStrength: 9.9, // Out of range draft, hidden in custom mode
        comfyWorkflowConfig: workflow,
        comfyWorkflowMode: ComfyUIWorkflow.customMode,
      ),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appSettingsProvider.overrideWith(() => _PresetSettings(settings)),
        ],
        child: MaterialApp(
          theme: ThemeData(extensions: [MoeColors.light()]),
          home: const DrawingPresetEditorPage(preset: preset),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('恢复标准模型模式'), findsOneWidget);
    expect(find.text('沿用工作流'), findsNWidgets(2));

    // Restoring standard mode automatically switches model from placeholder to first checkpoint.
    await tester.tap(find.text('恢复标准模型模式'));
    await tester.pumpAndSettle();
    expect(find.textContaining('illustrious_xl.safetensors'), findsOneWidget);
    expect(find.text('从服务端选择 LoRA'), findsOneWidget);
  });
}

class _PresetSettings extends AppSettingsNotifier {
  _PresetSettings(this.settings);
  final AppSettings settings;
  @override
  Future<AppSettings> build() async => settings;
}
