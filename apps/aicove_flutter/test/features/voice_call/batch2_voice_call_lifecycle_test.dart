import 'dart:async';
import 'dart:typed_data';

import 'package:aicove_flutter/src/features/voice_call/application/voice_call_session.dart';
import 'package:flutter_test/flutter_test.dart';

import 'voice_call_fakes.dart';

class _Step {
  Completer<void>? gate;
  var starts = 0;
  var closes = 0;
  final released = Completer<void>();

  Future<void> start() async {
    starts++;
    await gate?.future;
  }
}

class _Tts extends FakeTts {
  final step = _Step();
  @override
  Future<void> open() => step.start();
  @override
  Future<void> close() async {
    step.closes++;
    await super.close();
    step.released.complete();
  }
}

class _Output extends FakeOutput {
  final step = _Step();
  @override
  Future<void> start(int sampleRate) => step.start();
  @override
  Future<void> stop() async {
    step.closes++;
    await super.stop();
    step.released.complete();
  }
}

class _Recognizer extends FakeRecognizer {
  final step = _Step();
  var stops = 0;
  @override
  Future<void> start() => step.start();
  @override
  Future<void> stop() async {
    stops++;
    await super.stop();
  }

  @override
  Future<void> dispose() async {
    step.closes++;
    await super.dispose();
    step.released.complete();
  }
}

class _Input extends FakeInput {
  final step = _Step();
  @override
  Future<Stream<Uint8List>> start() async {
    await step.start();
    return super.start();
  }

  @override
  Future<void> stop() async {
    step.closes++;
    await super.stop();
    step.released.complete();
  }
}

class _Fixture {
  final tts = _Tts();
  final output = _Output();
  final recognizer = _Recognizer();
  final input = _Input();
  final generator = FakeGenerator();
  late final session = VoiceCallSession(
    tts: tts,
    output: output,
    recognizer: recognizer,
    input: input,
    generator: generator,
  );

  List<_Step> get steps => [tts.step, output.step, recognizer.step, input.step];

  void expectReleasedOnce() {
    expect(steps.map((step) => step.closes), everyElement(1));
    expect(recognizer.stops, 1);
    expect(session.phase, VoiceCallPhase.ended);
    expect(session.connectedAt, isNull);
    expect(generator.requests, isEmpty);
  }
}

void main() {
  const names = ['tts', 'output', 'recognizer', 'input'];
  for (var index = 0; index < names.length; index++) {
    for (final fail in [false, true]) {
      test('hang-up returns while ${names[index]} start is pending '
          'and releases once after ${fail ? 'failure' : 'success'}', () async {
        final f = _Fixture();
        final gate = f.steps[index].gate = Completer<void>();
        final starting = f.session.start();
        final started = fail
            ? expectLater(starting, throwsStateError)
            : starting;
        await Future<void>.delayed(Duration.zero);
        expect(f.steps[index].starts, 1);
        var hungUp = false;
        final hanging = f.session.hangUp()..then((_) => hungUp = true);
        try {
          expect(identical(hanging, f.session.hangUp()), isTrue);
          expect(f.session.phase, VoiceCallPhase.ended);
          await Future<void>.delayed(Duration.zero);
          expect(
            hungUp,
            isTrue,
            reason: 'the pending connection must not block hang-up',
          );
          expect(
            f.steps[index].closes,
            0,
            reason: 'do not close a resource before its start settles',
          );
          await Future.wait(
            f.steps.take(index).map((step) => step.released.future),
          ).timeout(const Duration(seconds: 1));
          for (var i = 0; i < index; i++) {
            expect(
              f.steps[i].closes,
              1,
              reason: 'already started resources are released promptly',
            );
          }
        } finally {
          if (fail) {
            gate.completeError(StateError('start failed'));
          } else {
            gate.complete();
          }
          await Future<void>.delayed(Duration.zero);
          await started;
          await hanging;
        }
        f.expectReleasedOnce();
        expect(
          f.steps.skip(index + 1).map((step) => step.starts),
          everyElement(0),
        );
      });
    }

    test(
      'failure in ${names[index]} cleans up without caller hang-up',
      () async {
        final f = _Fixture();
        final gate = f.steps[index].gate = Completer<void>();
        final started = expectLater(f.session.start(), throwsStateError);
        await Future<void>.delayed(Duration.zero);
        gate.completeError(StateError('start failed'));
        await Future<void>.delayed(Duration.zero);
        await started;
        try {
          f.expectReleasedOnce();
        } finally {
          final hanging = f.session.hangUp();
          await Future<void>.delayed(Duration.zero);
          await hanging;
        }
      },
    );
  }

  test('start after hang-up does not open any resource', () async {
    final f = _Fixture();
    final hanging = f.session.hangUp();
    await Future<void>.delayed(Duration.zero);
    await hanging;
    await f.session.start();
    expect(f.steps.map((step) => step.starts), everyElement(0));
    f.expectReleasedOnce();
  });
}
