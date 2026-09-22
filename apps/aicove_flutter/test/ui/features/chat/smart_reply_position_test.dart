import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/ui/features/chat/widgets/chat_message_list.dart';
import 'package:aicove_flutter/src/ui/features/chat/widgets/chat_viewport_controller.dart';
import 'package:aicove_flutter/src/ui/theme/skin_provider.dart';
import 'package:aicove_flutter/src/ui/theme/skins/moetalk_skin.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import '../../../../tool/chat_segmented_fixture.dart';

void main() {
  const write = bool.fromEnvironment('WRITE_SMART_REPLY_PREVIEW');
  setUpAll(() async {
    if (!write) return;
    final font = FontLoader('PositionPreview')
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
  for (final width in [360.0, 1000.0]) {
    testWidgets('badge occupies bottom-right until jump button appears: $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 500);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final fixture = (await tester.runAsync(
        () => SegmentedChatFixture.create(
          historyCount: 0,
          settings: segmentedProbeSettings.copyWith(smartReplyEnabled: true),
        ),
      ))!;
      final viewport = ChatViewportController();
      final boundaryKey = GlobalKey();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: fixture.container,
          child: SkinScope(
            skin: const MoeTalkSkin(),
            child: RepaintBoundary(
              key: boundaryKey,
              child: MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: ThemeData(
                  fontFamily: write ? 'PositionPreview' : null,
                  extensions: [MoeColors.light()],
                ),
                home: Scaffold(
                  body: ChatMessageList(
                    conversationId: fixture.conversation.id,
                    messages: List.generate(
                      25,
                      (i) => Message.text(
                        id: 'preview_$i',
                        role: i.isEven ? 'user' : 'assistant',
                        content: i.isEven ? '今天想和你聊一会儿。' : '我在，慢慢说就好。',
                        createdAt: DateTime(2026, 9, 22, 12, i),
                      ),
                    ),
                    displayName: '预览',
                    viewportController: viewport,
                    hasMoreMessages: false,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final badge = find.byKey(const ValueKey('smart_reply_badge'));
      final jump = find.byKey(const ValueKey('chat_jump_to_latest_badge'));
      Future<void> capture(String state) async {
        if (!write) return;
        await tester.runAsync(() async {
          final image =
              await (boundaryKey.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage(pixelRatio: 1.5);
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File(
            '../../.codex-temp/smart-reply/position-$state-${width.toInt()}.png',
          );
          await file.parent.create(recursive: true);
          await file.writeAsBytes(data!.buffer.asUint8List());
          image.dispose();
        });
      }

      expect(jump, findsNothing);
      final original = tester.getRect(badge);
      expect(original.right, closeTo(width - 14, 0.1));
      await capture('alone');
      await tester.drag(find.byType(CustomScrollView), const Offset(0, 300));
      await tester.pumpAndSettle();
      expect(jump, findsOneWidget);
      final jumpRect = tester.getRect(jump);
      final moved = tester.getRect(badge);
      expect(jumpRect.right, closeTo(original.right, 0.1));
      expect(moved.right, closeTo(jumpRect.left - 10, 0.1));
      expect(moved.bottom, closeTo(jumpRect.bottom, 0.1));
      expect(moved.size, jumpRect.size);
      await capture('beside');
      await tester.tap(jump);
      await tester.pumpAndSettle();
      expect(jump, findsNothing);
      expect(tester.getRect(badge), original);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      viewport.dispose();
      await tester.runAsync(fixture.dispose);
    });
  }
}
