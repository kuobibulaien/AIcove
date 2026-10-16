import 'dart:async';

import 'package:aicove_flutter/src/features/voice_call/application/active_voice_call.dart';
import 'package:aicove_flutter/src/features/voice_call/application/voice_call_archiver.dart';
import 'package:aicove_flutter/src/features/voice_call/application/voice_call_session.dart';
import 'package:aicove_flutter/src/features/voice_call/domain/speech_recognizer_port.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/ui/features/voice_call/window/voice_call_window_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../features/voice_call/voice_call_fakes.dart';

void main() {
  late FakeRecognizer recognizer;
  late FakeGenerator generator;
  late VoiceCallSession session;
  late ActiveVoiceCall call;
  late List<Message> bubbles;

  setUp(() {
    bubbles = [];
    recognizer = FakeRecognizer();
    generator = FakeGenerator();
    session = VoiceCallSession(
      recognizer: recognizer,
      tts: FakeTts(),
      input: FakeInput(),
      output: FakeOutput(),
      generator: generator,
      greetOnConnect: false,
      userTurnGap: Duration.zero,
      turnEndQuiet: const Duration(milliseconds: 20),
      pollInterval: const Duration(milliseconds: 5),
    );
    call = ActiveVoiceCall(
      conversationId: 'nahida',
      createSession: () async => session,
      archiver: VoiceCallArchiver(
        newId: (prefix) => prefix,
        appendBubble: (_, bubble) async => bubbles.add(bubble),
      ),
      describeError: (e) => '$e',
    );
  });

  Future<void> settle([int ms = 20]) =>
      Future<void>.delayed(Duration(milliseconds: ms));

  /// 两个窗口之间的通道换成内存里的直接调用；方法名和参数照真实通道走。
  (VoiceCallWindowLink, RemoteVoiceCall, List<String>) wire() {
    final toWindow = <String>[];
    late RemoteVoiceCall remote;
    late VoiceCallWindowLink link;
    link = VoiceCallWindowLink(
      call: call,
      closeDelay: const Duration(milliseconds: 10),
      send: (method, [arguments]) async {
        toWindow.add(method);
        switch (method) {
          case VoiceCallWindowMethods.state:
            remote.apply(arguments! as Map);
          case VoiceCallWindowMethods.elapsed:
            remote.applyElapsed(arguments);
        }
      },
    );
    remote = RemoteVoiceCall((method, [arguments]) async {
      await link.handle(method);
    });
    return (link, remote, toWindow);
  }

  test('the call window mirrors the call and forwards its buttons', () async {
    final (link, remote, _) = wire();
    await call.connect();
    await link.handle(VoiceCallWindowMethods.ready);
    expect(remote.phase, VoiceCallPhase.listening);
    expect(remote.connected, isTrue);

    recognizer.emit(const SpeechFinal('喂，听得到吗'));
    await settle();
    expect(remote.transcript.single.text, '喂，听得到吗');
    expect(remote.phase, VoiceCallPhase.thinking);

    // 小窗的按钮作用在主窗口的这通电话上，状态再推回来。
    remote.toggleMute();
    await settle();
    expect(call.muted, isTrue);
    expect(session.muted, isTrue);
    expect(remote.muted, isTrue);
    remote.toggleSpeaker();
    await settle();
    expect(call.speakerOff, isTrue);
    expect(remote.speakerOff, isTrue);

    await remote.hangUp();
    for (var i = 0; i < 50 && bubbles.isEmpty; i++) {
      await settle(5);
    }
    expect(call.phase, VoiceCallPhase.ended);
    expect(remote.phase, VoiceCallPhase.ended);
    expect(bubbles, hasLength(1));
  });

  test(
    'closing the call window hangs up; the window closes after a hang-up',
    () async {
      final (link, _, toWindow) = wire();
      await call.connect();
      // 用户在主窗口挂断：小窗显示通话已结束，片刻后被关掉。
      unawaited(call.hangUp());
      for (
        var i = 0;
        i < 50 && !toWindow.contains(VoiceCallWindowMethods.close);
        i++
      ) {
        await settle(5);
      }
      expect(toWindow, contains(VoiceCallWindowMethods.close));

      // 另一通：用户直接关小窗，主窗口挂断。
      final other = ActiveVoiceCall(
        conversationId: 'nahida',
        createSession: () async => VoiceCallSession(
          recognizer: FakeRecognizer(),
          tts: FakeTts(),
          input: FakeInput(),
          output: FakeOutput(),
          generator: FakeGenerator(),
          greetOnConnect: false,
        ),
        archiver: VoiceCallArchiver(
          newId: (prefix) => prefix,
          appendBubble: (_, _) async {},
        ),
        describeError: (e) => '$e',
      );
      final closed = VoiceCallWindowLink(call: other, send: (_, [_]) async {});
      await other.connect();
      await closed.handle(VoiceCallWindowMethods.closed);
      expect(other.ending, isTrue);
      link.dispose();
    },
  );

  test('a call shown in the window stays out of the chat page', () async {
    call.showInWindow();
    expect(call.inWindow, isTrue);
    expect(call.minimized, isTrue);
    // 在小窗里时不会被「回到通话视图」拉回聊天页。
    call.restore();
    expect(call.minimized, isTrue);
    // 小窗没打开：退回聊天页里的通话视图。
    call.leaveWindow();
    expect(call.inWindow, isFalse);
    expect(call.minimized, isFalse);
  });
}
