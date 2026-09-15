import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:aicove_flutter/src/ui/features/chat/widgets/chat_share_sheet.dart';
import 'package:aicove_flutter/src/features/chat/presentation/widgets/composer.dart';
import 'package:aicove_flutter/src/ui/features/chat/pages/chat_page.dart';
import 'package:aicove_flutter/src/ui/features/chat/widgets/chat_message_list.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/moe_adaptive_shell.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../tool/chat_segmented_fixture.dart';

void main() {
  setUpAll(() async {
    if (const String.fromEnvironment('PREVIEW_DIR').isEmpty) return;
    for (final entry in {
      'SelectionPreview': '/System/Library/Fonts/STHeiti Medium.ttc',
      'MaterialIcons':
          '${Platform.environment['FLUTTER_ROOT']}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    }.entries) {
      final loader = FontLoader(entry.key);
      loader.addFont(
        File(entry.value).readAsBytes().then(ByteData.sublistView),
      );
      await loader.load();
    }
  });
  for (final width in [360.0, 700.0]) {
    testWidgets('多选保留输入草稿、安全区，返回先退出多选 $width', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 800);
      tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
      tester.view.viewPadding = const FakeViewPadding(top: 24, bottom: 24);
      addTearDown(tester.view.reset);
      final fixture = (await tester.runAsync(
        () => SegmentedChatFixture.create(historyCount: 20),
      ))!;
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: fixture.container,
          child: RepaintBoundary(
            key: const ValueKey("selection-preview"),
            child: MaterialApp(
              navigatorKey: navigator,
              debugShowCheckedModeBanner: false,
              theme: ThemeData(
                fontFamily: const String.fromEnvironment('PREVIEW_DIR').isEmpty
                    ? null
                    : 'SelectionPreview',
                extensions: [MoeColors.light()],
              ),
              home: const Scaffold(body: Text('聊天首页')),
            ),
          ),
        ),
      );
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => MoeWorkspace(
            navigatorKey: navigator,
            isWide: width > 600,
            isDetail: true,
            child: ChatPage(
              conversationId: fixture.conversation.id,
              initialConversation: fixture.conversation,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final input = find.descendant(
        of: find.byType(Composer),
        matching: find.byType(TextField),
      );
      await tester.enterText(input, '选择消息时保留的草稿');
      await tester.longPress(
        find.byKey(const ValueKey('message_bubble_probe_history_19')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('多选'));
      await tester.pumpAndSettle();
      expect(find.text('已选 1 条消息'), findsOneWidget);
      expect(find.byType(Composer), findsNothing);
      expect(find.text('导出'), findsNothing);
      expect(find.text('删除'), findsNothing);
      expect(find.text('分享'), findsNothing);
      final exportRect = tester.getRect(find.byTooltip('分享'));
      final deleteRect = tester.getRect(find.byTooltip('删除'));
      expect(exportRect.size, const Size(48, 48));
      expect(deleteRect.size, const Size(48, 48));
      expect(deleteRect.left, lessThan(exportRect.left));
      expect(exportRect.top, deleteRect.top);
      expect(exportRect.bottom, lessThanOrEqualTo(776));
      if (const String.fromEnvironment('PREVIEW_DIR').isNotEmpty) {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const ValueKey('selection-preview')),
        );
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 1);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            '${const String.fromEnvironment('PREVIEW_DIR')}/selection-${width.toInt()}.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      await tester.tap(find.byTooltip('分享'));
      await tester.pumpAndSettle();
      expect(find.byType(ChatShareSheet), findsOneWidget);
      expect(find.text('导出为图片'), findsOneWidget);
      await navigator.currentState!.maybePop();
      await tester.pumpAndSettle();
      expect(find.byType(ChatShareSheet), findsNothing);
      final list = tester.widget<ChatMessageList>(find.byType(ChatMessageList));
      list.selection!.toggle('probe_history_19');
      await tester.pumpAndSettle();
      expect(find.text('已选 0 条消息'), findsOneWidget);
      expect(
        tester
            .widget<IconButton>(
              find.widgetWithIcon(IconButton, Icons.share_outlined),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<IconButton>(
              find.widgetWithIcon(IconButton, Icons.delete_outline),
            )
            .onPressed,
        isNull,
      );
      list.selection!.toggle('probe_history_19');
      await tester.pumpAndSettle();
      await navigator.currentState!.maybePop();
      await tester.pumpAndSettle();
      expect(find.byType(ChatPage), findsOneWidget);
      expect(tester.widget<TextField>(input).controller!.text, '选择消息时保留的草稿');
      expect(find.text('导出'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      var disposed = false;
      final cleanup = fixture.dispose().then((_) => disposed = true);
      for (var i = 0; i < 100 && !disposed; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
      }
      expect(disposed, isTrue);
      await cleanup;
    });
  }
}
