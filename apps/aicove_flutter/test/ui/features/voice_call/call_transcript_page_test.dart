import 'dart:io';
import 'dart:ui' as ui;

import 'package:aicove_flutter/src/core/models/message_block.dart';
import 'package:aicove_flutter/src/features/chat/conversation_providers.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/features/chat/presentation/widgets/message_bubble.dart';
import 'package:aicove_flutter/src/ui/features/voice_call/pages/call_transcript_page.dart';
import 'package:aicove_flutter/src/ui/theme/skin_provider.dart';
import 'package:aicove_flutter/src/ui/theme/skins/moetalk_skin.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const capture = bool.fromEnvironment('WRITE_VOICE_CALL_PREVIEW');

  testWidgets('transcript comes from the bubble and shows the avatar', (
    tester,
  ) async {
    if (capture) {
      await tester.runAsync(() async {
        final loader = FontLoader('Preview')
          ..addFont(
            File(
              '/System/Library/Fonts/STHeiti Medium.ttc',
            ).readAsBytes().then(ByteData.sublistView),
          );
        await loader.load();
      });
      tester.view.physicalSize = const Size(390, 520);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    }
    final boundary = GlobalKey();
    final conv = Conversation(
      id: 'nahida',
      title: '纳西妲',
      displayName: '纳西妲',
      avatarUrl: 'assets/wallpapers/catnap_light.webp',
      createdAt: DateTime(2026, 10, 12),
      updatedAt: DateTime(2026, 10, 12),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [activeConversationProvider.overrideWithValue(conv)],
        child: SkinScope(
          skin: const MoeTalkSkin(),
          child: MaterialApp(
            theme: ThemeData(
              fontFamily: capture ? 'Preview' : null,
              extensions: [MoeColors.light()],
            ),
            builder: (context, child) =>
                RepaintBoundary(key: boundary, child: child),
            home: CallTranscriptPage(
              record: CallRecordBlock(
                messageId: 'm',
                callId: 'c',
                duration: const Duration(minutes: 1),
                turns: const [
                  CallTurn(role: 'user', text: '我在地铁上'),
                  CallTurn(role: 'assistant', text: '那我小声点说。'),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    final bubbles = tester
        .widgetList<MessageBubble>(find.byType(MessageBubble))
        .toList();
    expect(bubbles.map((b) => b.message.content), ['我在地铁上', '那我小声点说。']);
    expect(bubbles.last.avatarUrl, conv.avatarUrl);
    expect(bubbles.first.avatarUrl, isNull);
    if (!capture) return;
    await tester.runAsync(
      () => precacheImage(
        const AssetImage('assets/wallpapers/catnap_light.webp'),
        tester.element(find.byType(CallTranscriptPage)),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.runAsync(() async {
      final render =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await render.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File(
        '../../.codex-temp/voice-call/previews/call-transcript-390.png',
      ).writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  });
}
