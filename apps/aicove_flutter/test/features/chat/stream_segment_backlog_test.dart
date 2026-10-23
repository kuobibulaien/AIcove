import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/features/chat/chat_actions.dart';
import 'package:aicove_flutter/src/features/chat/application/active_stream_projection.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_history_store.dart';
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
    final segments = List.generate(20, (index) => '第 $index 段尚未显示完毕的正文。');
    fixture.add(segments.join());
    final finishing = fixture.finish();
    await fixture.waitUntil(() => fixture.bubbles.isNotEmpty);
    final visible = fixture.bubbles.map((m) => m.displayText).toList();
    expect(visible.length, lessThan(segments.length));
    expect(visible, segments.take(visible.length).toList());
    final actions = fixture.container.read(chatActionsProvider);
    expect(
      await actions.interruptCurrentGeneration(convId: fixture.conversation.id),
      isTrue,
    );
    expect(
      await actions.interruptCurrentGeneration(convId: fixture.conversation.id),
      isFalse,
    );
    final history = fixture.container.read(chatHistoryStoreProvider);
    final saved = (await history.loadAllRawMessages(
      fixture.conversation.id,
    )).where((m) => m.role == 'assistant').single;
    expect(saved.content, visible.join());
    expect(saved.rawPayload?['runStatus'], 'cancelled');
    final savedIds = fixture.bubbles.map((m) => m.id).toList();
    await finishing.timeout(const Duration(seconds: 5));
    // Wait beyond every remaining reveal slot and the 180ms flush interval.
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    final reloaded = (await history.loadAllRawMessages(
      fixture.conversation.id,
    )).where((m) => m.role == 'assistant').toList();
    expect(reloaded.map((m) => m.id), [saved.id]);
    expect(reloaded.single.content, visible.join());
    expect(fixture.bubbles.map((m) => m.displayText).join(), visible.join());
    expect(fixture.bubbles.map((m) => m.id), savedIds);
    expect(fixture.bubbles.last.rawPayload?['runStatus'], 'cancelled');
    expect(
      fixture.timeline.value.where(
        (m) =>
            m.role == 'assistant' &&
            (m.status == 'sending' || m.displayText == '生成中...'),
      ),
      isEmpty,
    );
    expect(fixture.container.read(activeStreamProjectionsProvider), isEmpty);
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
