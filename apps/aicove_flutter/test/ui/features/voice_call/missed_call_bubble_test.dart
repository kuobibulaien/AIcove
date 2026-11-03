import 'dart:io';
import 'dart:ui' as ui;

import 'package:aicove_flutter/src/core/models/message_block.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/presentation/widgets/message_bubble.dart';
import 'package:aicove_flutter/src/ui/features/voice_call/widgets/call_record_bubble.dart';
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

  Message bubble(MissedCall kind) {
    final block = CallRecordBlock.missed(
      messageId: 'm_${kind.name}',
      callId: kind.name,
      kind: kind,
    );
    return Message(
      id: block.messageId,
      role: kind == MissedCall.incoming ? 'assistant' : 'user',
      content: block.content,
      blocks: [block],
      createdAt: DateTime(2026, 11, 3, 15, 30),
    );
  }

  Future<void> mount(
    WidgetTester tester, {
    VoidCallback? onCallBack,
    GlobalKey? boundary,
  }) async {
    final list = ListView(
      padding: const EdgeInsets.symmetric(vertical: 16),
      children: [
        for (final kind in MissedCall.values)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: MessageBubble(
              message: bubble(kind),
              isMe: kind != MissedCall.incoming,
              displayName: '纳西妲',
            ),
          ),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        child: SkinScope(
          skin: const MoeTalkSkin(),
          child: MaterialApp(
            theme: ThemeData(
              fontFamily: capture ? 'Preview' : null,
              extensions: [MoeColors.light()],
            ),
            home: RepaintBoundary(
              key: boundary,
              child: Material(
                child: onCallBack == null
                    ? list
                    : CallBackScope(onCallBack: onCallBack, child: list),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('missed calls call back from the chat page', (tester) async {
    var calls = 0;
    await mount(tester, onCallBack: () => calls++);

    expect(find.text('未接来电'), findsOneWidget);
    expect(find.text('点击回拨'), findsOneWidget);
    expect(find.text('已取消'), findsOneWidget);
    expect(find.text('对方未接听'), findsOneWidget);
    expect(find.text('点击重拨'), findsNWidgets(2));

    await tester.tap(find.byKey(const ValueKey('call-record-incoming')));
    await tester.tap(find.byKey(const ValueKey('call-record-cancelled')));
    expect(calls, 2);
  });

  testWidgets('without the chat page there is nothing to tap', (tester) async {
    await mount(tester);

    expect(find.text('未接来电'), findsOneWidget);
    expect(find.text('点击回拨'), findsNothing);
    expect(find.byType(InkWell), findsNothing);
  });

  testWidgets('missed call bubbles source rendered preview', (tester) async {
    if (!capture) return;
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
    tester.view.physicalSize = const Size(390, 300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final key = GlobalKey();
    await mount(tester, onCallBack: () {}, boundary: key);
    await tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final dir = Directory('../../.codex-temp/voice-call/previews')
        ..createSync(recursive: true);
      await File(
        '${dir.path}/missed-call-bubbles.png',
      ).writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  });
}
