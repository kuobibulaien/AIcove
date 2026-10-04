import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/ui/features/settings/pages/add_provider_sheet.dart';
import 'package:aicove_flutter/src/ui/features/settings/widgets/comfyui_workflow_editor.dart';
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

  testWidgets('ComfyUI add flow hides chat path and allows optional key', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 960);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(wrap(const AddProviderSheet()));
    await tester.tap(find.text('绘图'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('ComfyUI'));
    await tester.pumpAndSettle();
    expect(find.text('API 路径'), findsNothing);
    expect(find.text('可选（Bearer Token）'), findsOneWidget);
    expect(find.text('ComfyUI 工作流'), findsOneWidget);
    expect(find.text('http://127.0.0.1:8188'), findsOneWidget);
    expect(tester.takeException(), isNull);
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
}
