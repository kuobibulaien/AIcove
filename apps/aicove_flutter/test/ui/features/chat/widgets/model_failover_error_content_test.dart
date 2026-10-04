import 'dart:io';
import 'dart:ui' as ui;

import 'package:aicove_flutter/src/features/chat/chat_providers.dart';
import 'package:aicove_flutter/src/ui/features/chat/widgets/model_failover_error_content.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/meotalk_dialog.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _preview = bool.fromEnvironment('WRITE_FAILOVER_PREVIEW');

ModelFailoverPromptRequest _request() => ModelFailoverPromptRequest(
      requestId: 1,
      conversationId: 'conv',
      failedModelName: 'DeepSeek Flash',
      nextModelName: 'Claude Sonnet',
      errorMessage:
          'Exception: HTTP 401: {"error":{"message":"Invalid API key provided"}}',
      errorDetail: '_Exception: HTTP 401 ...\n\n#0 stack',
      roundStartedAt: DateTime(2026, 10, 4),
      failedAt: DateTime(2026, 10, 4, 0, 0, 3),
    );

void main() {
  setUpAll(() async {
    if (!_preview) return;
    for (final entry in {
      'Preview': '/System/Library/Fonts/STHeiti Medium.ttc',
      'MaterialIcons':
          '${Platform.environment['FLUTTER_ROOT']}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    }.entries) {
      final loader = FontLoader(entry.key);
      loader.addFont(File(entry.value).readAsBytes().then(ByteData.sublistView));
      await loader.load();
    }
  });

  Future<void> pumpDialog(WidgetTester tester,
      {bool dark = false, GlobalKey? capture}) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 780);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: dark ? Brightness.dark : Brightness.light,
        fontFamily: _preview ? 'Preview' : null,
        extensions: [dark ? MoeColors.dark() : MoeColors.light()],
      ),
      builder: capture == null
          ? null
          : (context, child) => RepaintBoundary(key: capture, child: child!),
      home: Builder(
        builder: (context) => Scaffold(
          backgroundColor: dark ? Colors.black : const Color(0xFFEDEDED),
          body: Center(
            child: TextButton(
              onPressed: () => showMeoTalkDialog(
                context: context,
                title: '模型请求失败',
                titleActionText: '取消',
                onTitleAction: () {},
                cancelText: '重试当前模型',
                confirmText: '尝试下一个模型',
                // 弹窗内容的 DefaultTextStyle 不继承主题字体，预览时补上。
                content: DefaultTextStyle.merge(
                  style: TextStyle(fontFamily: _preview ? 'Preview' : null),
                  child: ModelFailoverErrorContent(request: _request()),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('shows main reason and copies full round log', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));

    await pumpDialog(tester);
    expect(
      find.text('HTTP 401 鉴权失败，请检查 API Key：Invalid API key provided'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('model_failover_copy_log')));
    await tester.pump();
    expect(copied, contains('AIcove 模型请求报错日志（本轮）'));
    expect(copied, contains('#0 stack'));
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
  });

  for (final dark in [false, true]) {
    testWidgets('failover dialog source rendered preview dark=$dark',
        (tester) async {
      if (!_preview) return;
      final capture = GlobalKey();
      await pumpDialog(tester, dark: dark, capture: capture);
      await tester.runAsync(() async {
        final boundary =
            capture.currentContext!.findRenderObject() as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 1.5);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File(
            '../../.codex-temp/model-failover-dialog/${dark ? 'dark' : 'light'}.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    });
  }
}
