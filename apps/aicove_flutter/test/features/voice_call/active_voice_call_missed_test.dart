import 'dart:async';

import 'package:aicove_flutter/src/core/models/message_block.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/voice_call/application/active_voice_call.dart';
import 'package:aicove_flutter/src/features/voice_call/application/voice_call_archiver.dart';
import 'package:aicove_flutter/src/features/voice_call/application/voice_call_session.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late List<Message> bubbles;

  ActiveVoiceCall call(
    Future<VoiceCallSession> Function() createSession, {
    bool outgoing = true,
  }) => ActiveVoiceCall(
    conversationId: 'nahida',
    createSession: createSession,
    archiver: VoiceCallArchiver(
      newId: (prefix) => prefix,
      appendBubble: (_, bubble) async => bubbles.add(bubble),
    ),
    describeError: (e) => '$e',
    outgoing: outgoing,
  );

  setUp(() => bubbles = []);

  test('hanging up an outgoing call before it connects is cancelled', () async {
    final pending = Completer<VoiceCallSession>();
    final c = call(() => pending.future);
    unawaited(c.connect());
    await c.hangUp();

    final block = bubbles.single.blocks!.single as CallRecordBlock;
    expect(block.missedCall, MissedCall.cancelled);
    expect(bubbles.single.role, 'user');
  });

  test('a call that fails to connect leaves no bubble', () async {
    final c = call(() async => throw StateError('没有识别来源'));
    await c.connect();
    await c.hangUp();

    expect(c.error, isNotNull);
    expect(bubbles, isEmpty);
  });

  test('hanging up an answered incoming call while connecting', () async {
    final pending = Completer<VoiceCallSession>();
    final c = call(() => pending.future, outgoing: false);
    unawaited(c.connect());
    await c.hangUp();

    expect(bubbles, isEmpty);
  });
}
