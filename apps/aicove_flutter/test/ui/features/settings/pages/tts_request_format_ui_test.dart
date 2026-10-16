import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/ui/features/settings/pages/add_provider_sheet.dart';
import 'package:aicove_flutter/src/ui/features/settings/widgets/tts_request_template_editor.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';

const capture = bool.fromEnvironment('WRITE_TTS_FORMAT_PREVIEW');

void main() {
  setUpAll(() async {
    if (!capture) return;
    final font = FontLoader('TtsPreview');
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
    final mono = FontLoader('monospace');
    mono.addFont(
      File(
        '/System/Library/Fonts/Menlo.ttc',
      ).readAsBytes().then(ByteData.sublistView),
    );
    await mono.load();
  });

  Widget wrap(Widget child, {Key? boundaryKey}) => ProviderScope(
    child: RepaintBoundary(
      key: boundaryKey,
      child: MaterialApp(
        theme: ThemeData(
          fontFamily: capture ? 'TtsPreview' : null,
          extensions: [MoeColors.light()],
        ),
        home: Scaffold(body: child),
      ),
    ),
  );

  Future<void> snapshot(WidgetTester tester, GlobalKey key, String name) async {
    if (!capture) return;
    await tester.runAsync(() async {
      final image =
          await (key.currentContext!.findRenderObject()
                  as RenderRepaintBoundary)
              .toImage(pixelRatio: 2);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('../../scratch/tts-format-20261014/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(data!.buffer.asUint8List());
      image.dispose();
    });
  }

  testWidgets('语音分类列出全部语音格式，自定义 REST 显示请求模板且无对话路径', (tester) async {
    tester.view.physicalSize = const Size(390, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final boundary = GlobalKey();
    await tester.pumpWidget(
      wrap(RepaintBoundary(key: boundary, child: const AddProviderSheet())),
    );
    await tester.tap(find.text('语音'));
    await tester.pumpAndSettle();

    for (final label in ['OpenAI', 'MiniMax', '阿里云', 'Fish Audio']) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.text('硅基流动'), findsNothing);
    await tester.dragUntilVisible(
      find.text('自定义 REST'),
      find.byType(SingleChildScrollView).at(1),
      const Offset(-200, 0),
    );
    await tester.tap(find.text('自定义 REST'));
    await tester.pumpAndSettle();

    expect(find.text('API 路径'), findsNothing);
    expect(find.text('请求模板'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await snapshot(tester, boundary, 'add-custom-rest-390');
  });

  testWidgets('请求模板编辑器校验 body 并返回模板', (tester) async {
    tester.view.physicalSize = const Size(390, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    Map<String, dynamic>? result;
    final boundary = GlobalKey();
    await tester.pumpWidget(
      wrap(
        Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await showTtsRequestTemplateEditor(context, const {});
            },
            child: const Text('open'),
          ),
        ),
        boundaryKey: boundary,
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final field = find.byKey(const ValueKey('tts-request-template-json'));
    expect(
      tester.widget<TextField>(field).controller!.text,
      contains('"input": "{text}"'),
    );
    await snapshot(tester, boundary, 'template-editor-390');

    await tester.enterText(field, '{"path": "/a"}');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('缺少 body 对象'), findsOneWidget);

    await tester.enterText(field, '{"path": "/a", "body": {"t": "{text}"}}');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(result, {
      'path': '/a',
      'body': {'t': '{text}'},
    });
  });
}
