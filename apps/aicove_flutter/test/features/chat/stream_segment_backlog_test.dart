import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/features/chat/chat_actions.dart';
import 'package:flutter/services.dart';

import '../../../tool/chat_segmented_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  setUpAll(
    () => messenger.setMockMethodCallHandler(
      channel,
      (_) async => Directory.systemTemp.path,
    ),
  );
  tearDownAll(() => messenger.setMockMethodCallHandler(channel, null));

  test('interrupt during final backlog prevents late messages', () async {
    final fixture = await SegmentedChatFixture.create(
      historyCount: 0,
      settings: segmentedProbeSettings.copyWith(streamSegmentDelaySeconds: .05),
    );
    addTearDown(fixture.dispose);
    await fixture.start();
    fixture.add(List.filled(20, '尚未显示完毕的正文段落。').join());
    final finishing = fixture.finish();
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(
      await fixture.container
          .read(chatActionsProvider)
          .interruptCurrentGeneration(convId: fixture.conversation.id),
      isTrue,
    );
    await finishing.timeout(const Duration(seconds: 5));
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(
      fixture.timeline.value.where((message) => message.role == 'assistant'),
      isEmpty,
    );
  });

  for (final tail in ['', '这是没有结束标点的最后一段']) {
    test(
      'completion reveals backlog individually, including tail: $tail',
      () async {
        final fixture = await SegmentedChatFixture.create(
          historyCount: 0,
          settings: segmentedProbeSettings.copyWith(
            streamSegmentDelaySeconds: .02,
          ),
        );
        addTearDown(fixture.dispose);
        await fixture.start();
        const sentence = '这是一段完整的离线分段测试正文。';
        fixture.add(List.filled(12, sentence).join() + tail);
        await Future<void>.delayed(const Duration(milliseconds: 250));
        var previousCount = fixture.bubbles.length;
        var maxJump = 0;
        void observe() {
          final count = fixture.bubbles.length;
          final jump = count - previousCount;
          if (jump > maxJump) maxJump = jump;
          previousCount = count;
        }

        fixture.timeline.addListener(observe);
        await fixture.finish().timeout(const Duration(seconds: 10));
        fixture.timeline.removeListener(observe);
        expect(fixture.bubbles.map((message) => message.displayText), [
          ...List.filled(12, sentence),
          if (tail.isNotEmpty) tail,
        ]);
        expect(
          maxJump,
          lessThanOrEqualTo(1),
          reason: 'Finishing must preserve the configured reveal interval.',
        );
      },
    );
  }
}
