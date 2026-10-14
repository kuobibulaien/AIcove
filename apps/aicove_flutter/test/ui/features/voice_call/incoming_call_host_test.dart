// Plan 12 B4: a proactive call rings above every page; declining leaves a
// missed-call bubble, answering hands the call to the app.
import 'package:aicove_flutter/src/core/database/database.dart' as db;
import 'package:aicove_flutter/src/core/database/database_provider.dart';
import 'package:aicove_flutter/src/core/models/message_block.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/incoming_call.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/proactive_call_ledger.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/voice_call/application/voice_call_archiver.dart';
import 'package:aicove_flutter/src/features/voice_call/providers/voice_call_providers.dart';
import 'package:aicove_flutter/src/ui/features/voice_call/widgets/incoming_call_host.dart';
import 'package:aicove_flutter/src/ui/theme/skin_provider.dart';
import 'package:aicove_flutter/src/ui/theme/skins/moetalk_skin.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _conv = Conversation(
  id: 'nahida',
  title: '纳西妲',
  displayName: '纳西妲',
  createdAt: DateTime(2026, 10, 14),
  updatedAt: DateTime(2026, 10, 14),
);

void main() {
  late List<Message> bubbles;
  late ProviderContainer container;

  Future<void> mount(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    bubbles = [];
    var ids = 0;
    final database = db.AppDatabase.forTesting(NativeDatabase.memory());
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
        voiceCallArchiverProvider.overrideWithValue(
          VoiceCallArchiver(
            newId: (prefix) => '${prefix}_${ids++}',
            appendBubble: (_, _) async {},
            appendAssistantBubble: (_, bubble) async => bubbles.add(bubble),
          ),
        ),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await database.close();
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: SkinScope(
          skin: const MoeTalkSkin(),
          child: MaterialApp(
            theme: ThemeData(extensions: [MoeColors.light()]),
            builder: (context, child) =>
                IncomingCallHost(onAccepted: (_, _) {}, child: child!),
            home: const Scaffold(body: Text('聊天页')),
          ),
        ),
      ),
    );
  }

  Future<void> ring() async {
    final now = DateTime.now();
    final until = now.add(const Duration(seconds: 30));
    await container
        .read(proactiveCallLedgerProvider)
        .reserve(
          ProactiveCall(
            triggerId: 't',
            conversationId: _conv.id,
            openingLine: '喂～',
            rangAt: now,
            answerUntil: until,
          ),
        );
    await container.read(proactiveCallLedgerProvider).confirm('t');
    container
        .read(incomingCallProvider.notifier)
        .show(
          IncomingCall(conversation: _conv, openingLine: '喂～', triggerId: 't'),
          until: until,
        );
  }

  testWidgets('rings above the page and declining leaves a missed call', (
    tester,
  ) async {
    await mount(tester);
    expect(find.text('邀请你语音通话…'), findsNothing);

    await tester.runAsync(ring);
    await tester.pump();
    expect(find.text('纳西妲'), findsOneWidget);
    expect(find.text('邀请你语音通话…'), findsOneWidget);
    expect(find.text('聊天页'), findsOneWidget);

    // The ledger is a real SQLite database, so its work runs outside fake time.
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('incoming-call-decline')));
      await container.read(proactiveCallSettlerProvider).settle();
    });
    await tester.pump();

    expect(find.text('邀请你语音通话…'), findsNothing);
    final block = bubbles.single.blocks!.single as CallRecordBlock;
    expect(block.missed, isTrue);
  });
}
