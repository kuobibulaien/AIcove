import 'dart:async';
import 'dart:typed_data';

import 'package:aicove_flutter/src/features/voice_call/application/call_reply_segmenter.dart';
import 'package:aicove_flutter/src/features/voice_call/application/voice_call_session.dart';
import 'package:aicove_flutter/src/features/voice_call/domain/speech_recognizer_port.dart';
import 'package:aicove_flutter/src/features/voice_call/domain/voice_call_ports.dart';
import 'package:flutter_test/flutter_test.dart';

import 'voice_call_fakes.dart';

void main() {
  late FakeRecognizer recognizer;
  late FakeTts tts;
  late FakeInput input;
  late FakeOutput output;
  late FakeGenerator generator;

  VoiceCallSession build({
    bool allowBargeIn = false,
    Duration synthesisTimeout = const Duration(seconds: 8),
  }) => VoiceCallSession(
    recognizer: recognizer,
    tts: tts,
    input: input,
    output: output,
    generator: generator,
    greetOnConnect: false,
    allowBargeIn: allowBargeIn,
    synthesisTimeout: synthesisTimeout,
    turnEndQuiet: const Duration(milliseconds: 40),
    userTurnGap: Duration.zero,
    pollInterval: const Duration(milliseconds: 10),
  );

  Future<void> settle([int ms = 5]) =>
      Future<void>.delayed(Duration(milliseconds: ms));

  setUp(() {
    recognizer = FakeRecognizer();
    tts = FakeTts();
    input = FakeInput();
    output = FakeOutput();
    generator = FakeGenerator();
  });

  test('the character greets first right after connecting', () async {
    final session = VoiceCallSession(
      recognizer: recognizer,
      tts: tts,
      input: input,
      output: output,
      generator: generator,
      turnEndQuiet: const Duration(milliseconds: 40),
      pollInterval: const Duration(milliseconds: 10),
    );
    await session.start();
    expect(session.phase, VoiceCallPhase.thinking);
    expect(generator.requests.single, isEmpty);

    generator.current!.add('[轻快]喂？在干嘛呀');
    await generator.current!.close();
    await settle();
    output.playAll();
    await settle(80);
    expect(session.phase, VoiceCallPhase.listening);
    expect(session.transcript.single.spokenText, '喂？在干嘛呀');
    await session.hangUp();
  });

  test(
    'one full turn: speech final -> reply streamed by segments -> listening',
    () async {
      final session = build();
      final phases = <VoiceCallPhase>[];
      session.phases.listen(phases.add);
      await session.start();

      recognizer.emit(const SpeechFinal('我今天去面试了'));
      await settle();
      expect(session.phase, VoiceCallPhase.thinking);
      expect(generator.requests.single.single.text, '我今天去面试了');

      generator.current!
        ..add('诶？面试')
        ..add('怎么样啊？紧不紧张');
      await settle();
      expect(tts.spoken, ['诶？', '面试怎么样啊？']);
      expect(session.phase, VoiceCallPhase.speaking);

      await generator.current!.close();
      await settle();
      expect(tts.spoken.last, '紧不紧张');

      output.playAll();
      await settle(80);
      expect(session.phase, VoiceCallPhase.listening);
      expect(session.transcript.map((t) => (t.role, t.text)), [
        ('user', '我今天去面试了'),
        ('assistant', '诶？面试怎么样啊？紧不紧张'),
      ]);
      expect(phases, [
        VoiceCallPhase.listening,
        VoiceCallPhase.thinking,
        VoiceCallPhase.speaking,
        VoiceCallPhase.listening,
      ]);
      await session.hangUp();
    },
  );

  test('typed text replaces the mic and joins the same transcript', () async {
    final session = build();
    await session.start();
    expect(session.sendText('  '), isFalse);

    session.typing = true;
    input.mic.add(Uint8List(320));
    await settle();
    // 打字期间话筒不送识别，避免两种输入同时进来。
    expect(recognizer.received, isEmpty);

    expect(session.sendText('我在地铁上，不方便说话'), isTrue);
    await settle();
    expect(session.phase, VoiceCallPhase.thinking);
    expect(generator.requests.single.single.text, '我在地铁上，不方便说话');

    generator.current!.add('好呀，那你打字，我说给你听。');
    await generator.current!.close();
    await settle();
    output.playAll();
    await settle(80);
    expect(session.transcript.map((t) => (t.role, t.text)), [
      ('user', '我在地铁上，不方便说话'),
      ('assistant', '好呀，那你打字，我说给你听。'),
    ]);

    // 回到语音：话筒恢复。
    session.typing = false;
    input.mic.add(Uint8List(320));
    await settle();
    expect(recognizer.received, hasLength(1));
    await session.hangUp();
  });

  test('typing while the character speaks interrupts the reply', () async {
    final session = build();
    await session.start();
    session.typing = true;
    session.sendText('讲个故事');
    await settle();
    generator.current!.add('从前有座山，山里有座庙。');
    await settle();
    expect(session.phase, VoiceCallPhase.speaking);

    output.playedMs = output.pushedMs ~/ 2;
    session.sendText('换一个');
    await settle();
    expect(session.phase, VoiceCallPhase.thinking);
    expect(output.clears, 1);
    expect(session.transcript.map((t) => t.role), [
      'user',
      'assistant',
      'user',
    ]);
    expect(session.transcript[1].interrupted, isTrue);
    expect(session.transcript.last.text, '换一个');
    await session.hangUp();
  });

  test(
    'without barge-in the mic is not sent to the recognizer while busy',
    () async {
      final session = build();
      await session.start();
      input.mic.add(Uint8List(10));
      await settle();
      expect(recognizer.received, hasLength(1));

      recognizer.emit(const SpeechFinal('你好'));
      await settle();
      input.mic.add(Uint8List(10));
      await settle();
      expect(recognizer.received, hasLength(1));
      await session.hangUp();
    },
  );

  test('barge-in stops playback and records only the spoken part', () async {
    final session = build(allowBargeIn: true);
    await session.start();
    recognizer.emit(const SpeechFinal('讲个故事'));
    await settle();
    generator.current!.add('从前有座山。山里有座庙。');
    await settle();
    expect(tts.spoken, ['从前有座山。', '山里有座庙。']);

    // 12 个字的音频播了一半。
    output.playedMs = output.pushedMs ~/ 2;
    recognizer.emit(const SpeechStarted());
    await settle();

    expect(tts.interrupts, 1);
    expect(output.clears, 1);
    expect(session.phase, VoiceCallPhase.listening);
    final last = session.transcript.last;
    expect(last.interrupted, isTrue);
    expect(last.text, '从前有座山。');

    // 被打断的那轮之后的文字不会再送去合成。
    generator.current?.add('庙里有个老和尚。');
    await settle();
    expect(tts.spoken, hasLength(2));
    await session.hangUp();
  });

  test('a reply that never produced audio is not recorded as spoken', () async {
    final session = build();
    await session.start();
    recognizer.emit(const SpeechFinal('在吗'));
    await settle();
    generator.current!.addError(StateError('network'));
    await settle(80);
    expect(session.phase, VoiceCallPhase.listening);
    expect(session.transcript.map((t) => t.role), ['user']);
    await session.hangUp();
  });

  group('CallReplySegmenter', () {
    test('cuts at sentence ends and at commas once long enough', () {
      final s = CallReplySegmenter();
      expect(s.push('诶？'), ['诶？']);
      expect(s.push('好，'), isEmpty); // 太短，不在逗号处切
      expect(s.push('那你明天还去吗，我陪你'), ['好，那你明天还去吗，']);
      expect(s.drain(), '我陪你');
      expect(s.drain(), '');
    });

    test('never cuts inside a bracketed speech tag', () {
      final s = CallReplySegmenter();
      expect(s.push('[愣了一下，然后笑出声]诶？'), ['[愣了一下，然后笑出声]诶？']);
      expect(s.push('[小声]真的吗'), isEmpty);
      expect(s.drain(), '[小声]真的吗');
    });
  });

  test('speech tags do not count toward the minimum speech length', () {
    expect(minSpeechMs('[笑着说]好呀'), minSpeechMs('好呀'));
  });

  test('spoken text hides speech tags, including a half-cut one', () {
    expect(
      const CallTurn(role: 'assistant', text: '[轻笑]好呀[短停顿]那走吧').spokenText,
      '好呀那走吧',
    );
    expect(
      const CallTurn(
        role: 'assistant',
        text: '好呀[轻',
        interrupted: true,
      ).spokenText,
      '好呀',
    );
    expect(const CallTurn(role: 'user', text: '[原话]').spokenText, '[原话]');
  });
  test('segments split by short pauses merge into one user turn', () async {
    final session = VoiceCallSession(
      recognizer: recognizer,
      tts: tts,
      input: input,
      output: output,
      generator: generator,
      greetOnConnect: false,
      turnEndQuiet: const Duration(milliseconds: 40),
      userTurnGap: const Duration(milliseconds: 30),
      pollInterval: const Duration(milliseconds: 10),
    );
    await session.start();

    recognizer.emit(const SpeechFinal('我今天下午'));
    await settle(10);
    expect(session.phase, VoiceCallPhase.listening);
    // 用户接着说：间隔计时作废，麦克风仍在送识别。
    recognizer.emit(const SpeechStarted());
    await settle(50);
    expect(session.phase, VoiceCallPhase.listening);
    input.mic.add(Uint8List(4));
    await settle();
    expect(recognizer.received, hasLength(1));

    recognizer.emit(const SpeechFinal('去面试了。'));
    recognizer.emit(const SpeechFinal('好紧张'));
    await settle(50);
    expect(session.phase, VoiceCallPhase.thinking);
    expect(generator.requests.single.single.text, '我今天下午，去面试了。好紧张');
    await session.hangUp();
  });

  test(
    'hanging up keeps an unfinished user sentence without replying',
    () async {
      final session = VoiceCallSession(
        recognizer: recognizer,
        tts: tts,
        input: input,
        output: output,
        generator: generator,
        greetOnConnect: false,
        userTurnGap: const Duration(seconds: 5),
      );
      await session.start();
      recognizer.emit(const SpeechFinal('那我先挂了'));
      await settle();
      await session.hangUp();
      expect(session.transcript.single.text, '那我先挂了');
      expect(generator.requests, isEmpty);
    },
  );
  group('review fixes', () {
    test('hanging up while connecting stops late-started resources', () async {
      recognizer.startGate = Completer<void>();
      final session = build();
      final starting = session.start();
      final hanging = session.hangUp();
      recognizer.startGate!.complete();
      await starting;
      await hanging;
      expect(session.phase, VoiceCallPhase.ended);
      // 识别器建连完成时已在挂断：不再打开麦克风，识别器也被释放。
      expect(input.started, isFalse);
      expect(recognizer.disposed, isTrue);
      expect(tts.closed, isTrue);
    });

    test('a failing playback device does not block hang-up cleanup', () async {
      final session = build();
      await session.start();
      recognizer.emit(const SpeechFinal('你好'));
      await settle();
      generator.current!.add('诶？你好呀。');
      await settle();
      expect(session.phase, VoiceCallPhase.speaking);
      output.failClear = true;
      await session.hangUp();
      expect(session.phase, VoiceCallPhase.ended);
      expect(input.stopped, isTrue);
      expect(recognizer.disposed, isTrue);
      expect(tts.closed, isTrue);
      expect(output.stopped, isTrue);
    });

    test('slow synthesis does not end the turn before audio arrives', () async {
      tts.autoAudio = false;
      final session = build();
      await session.start();
      recognizer.emit(const SpeechFinal('你好'));
      await settle();
      generator.current!.add('你好呀。');
      await generator.current!.close();
      await settle(120);
      // 模型早写完了，但这段的音频还没到：不能判定说完。
      expect(session.phase, VoiceCallPhase.thinking);
      tts.deliver('你好呀。');
      await settle();
      output.playAll();
      await settle(120);
      expect(session.phase, VoiceCallPhase.listening);
      expect(session.transcript.last.text, '你好呀。');
      await session.hangUp();
    });

    test('spoken prefix only counts playback of the current reply', () async {
      final session = build();
      await session.start();
      recognizer.emit(const SpeechFinal('第一句'));
      await settle();
      generator.current!.add('第一轮回复说完了。');
      await generator.current!.close();
      output.playAll();
      await settle(120);
      expect(session.phase, VoiceCallPhase.listening);

      recognizer.emit(const SpeechFinal('第二句'));
      await settle();
      generator.current!.add('第二轮还没播。');
      await settle();
      // 第二轮音频已收到但一点没播就挂断：不能借第一轮的播放时长记成说过。
      await session.hangUp();
      expect(session.transcript.map((t) => t.text), [
        '第一句',
        '第一轮回复说完了。',
        '第二句',
      ]);
    });

    test(
      'the sentence flushed on hang-up is archived without a reply',
      () async {
        recognizer.flushText = '那我先挂啦';
        final session = build();
        await session.start();
        await session.hangUp();
        expect(session.transcript.single.text, '那我先挂啦');
        expect(generator.requests, isEmpty);
      },
    );

    test(
      'an empty segment after a pause resumes committing the turn',
      () async {
        final session = VoiceCallSession(
          recognizer: recognizer,
          tts: tts,
          input: input,
          output: output,
          generator: generator,
          greetOnConnect: false,
          userTurnGap: const Duration(milliseconds: 30),
          pollInterval: const Duration(milliseconds: 10),
        );
        await session.start();
        recognizer.emit(const SpeechFinal('前半句'));
        recognizer.emit(const SpeechStarted());
        // 咳了一声：这段结束了但没识别出字。
        recognizer.emit(const SpeechEnded());
        await settle(80);
        expect(session.phase, VoiceCallPhase.thinking);
        expect(generator.requests.single.single.text, '前半句');
        await session.hangUp();
      },
    );
  });

  group('second review fixes', () {
    test('an early segment\'s late audio does not end the turn', () async {
      tts.autoAudio = false;
      final session = build();
      await session.start();
      recognizer.emit(const SpeechFinal('你好'));
      await settle();
      generator.current!.add('第一段。');
      generator.current!.add('第二段话要长一些才行。');
      await generator.current!.close();
      await settle();
      expect(tts.spoken, hasLength(2));
      // 第一段的音频在第二段发出之后才到，第二段还在合成。
      tts.deliver('第一段。');
      await settle();
      output.playAll();
      await settle(150);
      expect(session.phase, VoiceCallPhase.speaking);
      tts.deliver('第二段话要长一些才行。');
      await settle();
      output.playAll();
      await settle(150);
      expect(session.phase, VoiceCallPhase.listening);
      expect(session.transcript.last.text, '第一段。第二段话要长一些才行。');
      await session.hangUp();
    });

    test(
      'a synthesis timeout records only what was heard and drops late audio',
      () async {
        tts.autoAudio = false;
        final session = build(
          synthesisTimeout: const Duration(milliseconds: 150),
        );
        await session.start();
        recognizer.emit(const SpeechFinal('你好'));
        await settle();
        generator.current!.add('第一段。');
        generator.current!.add('第二段话要长一些才行。');
        await generator.current!.close();
        await settle();
        tts.deliver('第一段。');
        await settle();
        output.playAll();
        await settle(300);
        expect(session.phase, VoiceCallPhase.listening);
        final last = session.transcript.last;
        expect(last.interrupted, isTrue);
        expect('第一段。第二段话要长一些才行。'.startsWith(last.text), isTrue);
        expect(last.text.length, lessThan('第一段。第二段话要长一些才行。'.length));
        // 换了合成连接，迟到的音频不会混进下一轮。
        expect(tts.interrupts, greaterThan(0));
        await session.hangUp();
      },
    );

    test(
      'hanging up silences playback before the recognizer finishes',
      () async {
        final session = build();
        await session.start();
        recognizer.emit(const SpeechFinal('你好'));
        await settle();
        generator.current!.add('一段很长的回复还在播。');
        await settle();
        recognizer.stopGate = Completer<void>();
        final hangingUp = session.hangUp();
        await settle();
        expect(output.stopped, isTrue);
        recognizer.stopGate!.complete();
        await hangingUp;
      },
    );
  });
}
