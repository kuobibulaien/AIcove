import 'dart:io';
import 'dart:ui' as ui;

import 'package:aicove_flutter/src/features/chat/chat_providers.dart';
import 'package:aicove_flutter/src/ui/features/chat/widgets/chat_tool_activity_line.dart';
import 'package:aicove_flutter/src/ui/theme/skin_provider.dart';
import 'package:aicove_flutter/src/ui/theme/skins/moetalk_skin.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const capture = bool.fromEnvironment('WRITE_ACTIVITY_PREVIEW');

  Future<ProviderContainer> mount(
    WidgetTester tester, {
    GlobalKey? boundary,
  }) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: SkinScope(
          skin: const MoeTalkSkin(),
          child: MaterialApp(
            theme: ThemeData(
              fontFamily: capture ? 'Preview' : null,
              extensions: [MoeColors.light()],
            ),
            home: Scaffold(
              body: RepaintBoundary(
                key: boundary,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final id in ['retry', 'tool', 'failed'])
                      ChatToolActivityLine(
                        conversationId: id,
                        documentStyle: false,
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    return container;
  }

  testWidgets('footer prefers retry, then tool activity, then failure', (
    tester,
  ) async {
    final container = await mount(tester);
    expect(find.byType(Text), findsNothing);

    container.read(conversationErrorProvider('retry').notifier).state =
        'HTTP 503: busy';
    container.read(conversationRetryStatusProvider('retry').notifier).state =
        const ModelRetryStatus(attempt: 2, maxAttempts: 3);
    container.read(conversationToolActivityProvider('tool').notifier).state =
        '联网搜索';
    container.read(conversationErrorProvider('failed').notifier).state =
        'HTTP 401: {"error":{"message":"invalid key"}}';
    await tester.pump();

    expect(find.text('请求没成功，正在自动重试（第 2 次，共 3 次）'), findsOneWidget);
    expect(find.text('正在调用 联网搜索'), findsOneWidget);
    expect(find.textContaining('鉴权失败'), findsOneWidget);
    expect(find.textContaining('busy'), findsNothing);
  });

  testWidgets('activity footer rendered preview', (tester) async {
    if (!capture) return;
    tester.view.physicalSize = const Size(390, 160);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      final loader = FontLoader('Preview')
        ..addFont(
          File(
            '/System/Library/Fonts/STHeiti Medium.ttc',
          ).readAsBytes().then(ByteData.sublistView),
        );
      await loader.load();
      final icons = FontLoader('MaterialIcons')
        ..addFont(
          File(
            '${Platform.environment['HOME']}/dev-sdks/flutter-3.44.6/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
          ).readAsBytes().then(ByteData.sublistView),
        );
      await icons.load();
    });
    final key = GlobalKey();
    final container = await mount(tester, boundary: key);
    container.read(conversationRetryStatusProvider('retry').notifier).state =
        const ModelRetryStatus(attempt: 1, maxAttempts: 1);
    container.read(conversationToolActivityProvider('tool').notifier).state =
        '联网搜索';
    container.read(conversationErrorProvider('failed').notifier).state =
        'HTTP 401: {"error":{"message":"invalid key"}}';
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final dir = Directory('../../scratch/previews')
        ..createSync(recursive: true);
      await File(
        '${dir.path}/chat-activity-footer.png',
      ).writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  });
}
