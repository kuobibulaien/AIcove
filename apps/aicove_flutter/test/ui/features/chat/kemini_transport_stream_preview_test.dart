import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/features/chat/application/active_stream_projection.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/ui/features/chat/widgets/chat_message_list.dart';
import 'package:aicove_flutter/src/ui/features/chat/widgets/chat_viewport_controller.dart';
import 'package:aicove_flutter/src/ui/theme/skin_provider.dart';
import 'package:aicove_flutter/src/ui/theme/skins/moetalk_skin.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import '../../../../tool/chat_segmented_fixture.dart';

void main() {
  const write = bool.fromEnvironment('WRITE_KEMINI_PREVIEW');
  setUpAll(() async {
    if (!write) return;
    final font = FontLoader('KeminiPreview')..addFont(
      File('/System/Library/Fonts/STHeiti Medium.ttc').readAsBytes().then(ByteData.sublistView),
    );
    await font.load();
  });
  for (final width in [360.0, 1000.0]) {
    testWidgets('transport tail grows in the native bubble: $width', (tester) async {
      tester.view.physicalSize = Size(width, 330);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final fixture = (await tester.runAsync(() => SegmentedChatFixture.create(historyCount: 0)))!;
      final viewport = ChatViewportController();
      final boundaryKey = GlobalKey();
      await tester.pumpWidget(UncontrolledProviderScope(
        container: fixture.container,
        child: SkinScope(skin: const MoeTalkSkin(), child: RepaintBoundary(
          key: boundaryKey,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData(fontFamily: write ? 'KeminiPreview' : null, extensions: [MoeColors.light()]),
            home: Scaffold(body: ChatMessageList(
              conversationId: fixture.conversation.id,
              messages: [
                Message.text(id: 'question', role: 'user', content: '写一段清晨花园的景色', createdAt: DateTime(2026, 9, 29)),
                Message.text(id: 'tail', role: 'assistant', content: '清晨', status: 'sending', createdAt: DateTime(2026, 9, 29, 0, 1)),
              ],
              displayName: 'Kemini', viewportController: viewport, hasMoreMessages: false,
            )),
          ),
        )),
      ));
      final prefixes = ['清晨的花园', '清晨的花园里，露珠沿着叶脉缓缓滑落', '清晨的花园里，露珠沿着叶脉缓缓滑落，阳光照亮了每一片嫩叶。'];
      for (var i = 0; i < prefixes.length; i++) {
        fixture.container.read(activeStreamProjectionsProvider.notifier).publish(ActiveStreamProjection(
          conversationId: fixture.conversation.id, generationSeq: 1, writeEpoch: 0,
          tailMessageId: 'tail', tailText: prefixes[i], phase: ActiveStreamPhase.streamingTail,
        ));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 220));
        expect(find.text(prefixes[i]), findsOneWidget);
        expect(tester.takeException(), isNull);
        if (write) {
          await tester.runAsync(() async {
            final image = await (boundaryKey.currentContext!.findRenderObject() as RenderRepaintBoundary).toImage(pixelRatio: 1.5);
            final data = await image.toByteData(format: ui.ImageByteFormat.png);
            final file = File('../../.codex-temp/kemini-stream-2026-09-29/preview-${width.toInt()}-$i.png');
            await file.parent.create(recursive: true);
            await file.writeAsBytes(data!.buffer.asUint8List());
            image.dispose();
          });
        }
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      viewport.dispose();
      await tester.runAsync(fixture.dispose);
    });
  }
}
