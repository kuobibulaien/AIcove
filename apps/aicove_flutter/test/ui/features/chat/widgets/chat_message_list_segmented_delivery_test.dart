import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/ui/features/chat/widgets/animated_message_item.dart';
import 'package:aicove_flutter/src/ui/features/chat/widgets/chat_message_list.dart';
import 'package:aicove_flutter/src/ui/features/chat/widgets/chat_viewport_controller.dart';
import 'package:aicove_flutter/src/ui/theme/skin_provider.dart';
import 'package:aicove_flutter/src/ui/theme/skins/moetalk_skin.dart';

import '../../../../../tool/chat_segmented_fixture.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}

Future<void> _settle(WidgetTester tester) async {
  // 生成占位符一直动画，不使用 pumpAndSettle。
  for (var i = 0; i < 24; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

Widget _host(SegmentedChatFixture fixture, ChatViewportController viewport) =>
    UncontrolledProviderScope(
      container: fixture.container,
      child: SkinScope(
        skin: const MoeTalkSkin(),
        child: MaterialApp(
            home: Scaffold(
                body: ValueListenableBuilder<List<Message>>(
          valueListenable: fixture.timeline,
          builder: (context, messages, _) => ChatMessageList(
            conversationId: fixture.conversation.id,
            messages: messages,
            displayName: '真实分段测试',
            viewportController: viewport,
            hasMoreMessages: false,
          ),
        ))),
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final originalPaths = PathProviderPlatform.instance;
  late Directory directory;
  setUpAll(() {
    directory = Directory.systemTemp.createTempSync('segmented_scroll_');
    PathProviderPlatform.instance = _Paths(directory.path);
  });
  tearDownAll(() async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    PathProviderPlatform.instance = originalPaths;
    directory.deleteSync(recursive: true);
  });
  for (final width in [360.0, 1000.0]) {
    for (final delay in [0.0, 0.3]) {
      testWidgets('真实分段 $width px / 延迟 $delay s：连续新增气泡不抢手势且回底恢复',
          (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(width, 640);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final fixture =
            (await tester.runAsync(() => SegmentedChatFixture.create(
                  settings: segmentedProbeSettings.copyWith(
                      streamSegmentDelaySeconds: delay),
                )))!;
        final viewport = ChatViewportController();
        await tester.pumpWidget(_host(fixture, viewport));
        await _settle(tester);
        await tester.runAsync(fixture.start);
        addTearDown(() async {
          await fixture.dispose();
          viewport.dispose();
        });
        viewport.onUserSend();
        fixture.add('第一段正文已经生成完成。');
        await tester.runAsync(
            () => fixture.waitUntil(() => fixture.bubbles.length == 1));
        await _settle(tester);
        final list = find.byType(CustomScrollView);
        expect(tester.getSize(list).width, width);
        final scroll = tester.widget<CustomScrollView>(list).controller!;
        final firstId = fixture.bubbles.first.id;
        final first = find.byKey(ValueKey('message_bubble_$firstId'));
        expect(first, findsOneWidget);
        final originalElement = tester.element(first);
        final gesture = await tester.startGesture(tester.getCenter(list));
        await gesture.moveBy(const Offset(0, 40));
        await tester.pump();
        expect(viewport.isDetached, isTrue);
        final sourceId = fixture.bubbles.first.sourceMessageId;
        expect(sourceId, isNotNull);

        // 完整经过 ChatActions 的 180ms flush / 分段等待 / 时间线物化。
        // 不是手造两个尾壳，也不直接 publish ActiveStreamProjection。
        for (var segment = 2; segment <= 9; segment++) {
          final top = tester.getTopLeft(first).dy;
          final pixels = scroll.position.pixels;
          fixture.add('第$segment段正文实时分成新的独立气泡。');
          await tester.runAsync(
              () => fixture.waitUntil(() => fixture.bubbles.length == segment));
          await gesture.moveBy(const Offset(0, 3));
          await tester.pump();
          expect(
              find.ancestor(
                  of: first, matching: find.byType(AnimatedMessageItem)),
              findsNothing,
              reason: '旧气泡不能在手势接管后补播入场动画');
          expect(scroll.position.pixels - pixels, closeTo(3, 0.5));
          expect(tester.getTopLeft(first).dy - top, closeTo(3, 0.5),
              reason: '第 $segment 次真实新增气泡不能把旧消息拉走');
          expect(identical(tester.element(first), originalElement), isTrue);
          expect(
              fixture.bubbles.map((m) => m.sourceMessageId).toSet(), {sourceId},
              reason: '所有气泡必须来自同一次回复，而不是多次发送');
          if (segment == 2) {
            expect(find.textContaining('第2段正文实时分成新的独立气泡'), findsOneWidget,
                reason: '手指没松开时，新分段已经上屏，不能冻结列表');
          }
        }
        // 先停住手再抬起，隔离后续的静止阅读断言与惯性。
        await tester.pump(const Duration(milliseconds: 200));
        await gesture.up();
        await _settle(tester);
        final stoppedTop = tester.getTopLeft(first).dy;
        fixture.add('松手后生成仍继续追加新的消息气泡。');
        await tester.runAsync(
            () => fixture.waitUntil(() => fixture.bubbles.length == 10));
        await _settle(tester);
        expect(viewport.isDetached, isTrue);
        expect(tester.getTopLeft(first).dy, closeTo(stoppedTop, 0.5));

        // 点击真实回底按钮；动画未完成时的新气泡也不能让后续触摸失效。
        final badge = find.byKey(const ValueKey('chat_jump_to_latest_badge'));
        await tester.tap(badge);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 32));
        expect(scroll.position.pixels - scroll.position.minScrollExtent,
            greaterThan(1));
        final interrupt = await tester.startGesture(tester.getCenter(list));
        final heldPixels = scroll.position.pixels;
        fixture.add('回底动画期间新增的分段也不能抢占手指。');
        await tester.runAsync(
            () => fixture.waitUntil(() => fixture.bubbles.length == 11));
        await _settle(tester);
        expect(scroll.position.pixels, closeTo(heldPixels, 0.5));
        await interrupt.moveBy(const Offset(0, 40));
        await tester.pump();
        await interrupt.up();
        await _settle(tester);
        expect(viewport.isDetached, isTrue);

        await tester.tap(badge);
        await _settle(tester);
        expect(scroll.position.pixels - scroll.position.minScrollExtent,
            lessThanOrEqualTo(0.5));
        for (var segment = 12; segment <= 15; segment++) {
          fixture.add('回底后第$segment段继续正常分成新气泡。');
          await tester.runAsync(
              () => fixture.waitUntil(() => fixture.bubbles.length == segment));
          await _settle(tester);
          expect(scroll.position.pixels - scroll.position.minScrollExtent,
              lessThanOrEqualTo(0.5));
          final latest =
              find.byKey(ValueKey('message_bubble_${fixture.bubbles.last.id}'));
          expect(latest, findsOneWidget);
          expect(tester.getBottomLeft(latest).dy,
              lessThanOrEqualTo(tester.getBottomLeft(list).dy));
        }
        expect(fixture.deltaCount, 15);
        await tester.runAsync(fixture.finish);
        await _settle(tester);
        expect(fixture.bubbles.length, 15, reason: '真实 finalize 不得重复或吞掉分段');
        expect(fixture.timeline.value.any((m) => m.displayText == '生成中...'),
            isFalse);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
    }
    testWidgets('真实分段 $width px：新增 12 个气泡时惯性轨迹与无新增基线一致', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 640);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      Future<List<double>> sample({required bool growing}) async {
        final fixture = (await tester.runAsync(SegmentedChatFixture.create))!;
        final viewport = ChatViewportController();
        await tester.pumpWidget(_host(fixture, viewport));
        await _settle(tester);
        await tester.runAsync(fixture.start);
        try {
          viewport.onUserSend();
          fixture.add(List.generate(5, (i) => '初始第$i段正文已经完成。').join());
          await tester.runAsync(
              () => fixture.waitUntil(() => fixture.bubbles.length == 5));
          await _settle(tester);
          final list = find.byType(CustomScrollView);
          final scroll = tester.widget<CustomScrollView>(list).controller!;
          final anchor = find
              .byKey(ValueKey('message_bubble_${fixture.bubbles.first.id}'));
          await tester.fling(list, const Offset(0, 100), 500);
          await tester.pump();
          expect(scroll.position.activity, isA<BallisticScrollActivity>());
          final initial = tester.getTopLeft(anchor).dy;
          final offsets = <double>[];
          for (var i = 0; i < 12; i++) {
            if (growing) {
              fixture.add('惯性期间第$i段新增正文继续显示。');
              await tester.runAsync(() =>
                  fixture.waitUntil(() => fixture.bubbles.length == 6 + i));
            }
            await tester.pump(const Duration(milliseconds: 16));
            expect(viewport.isDetached, isTrue);
            expect(scroll.position.activity, isA<BallisticScrollActivity>());
            offsets.add(tester.getTopLeft(anchor).dy - initial);
          }
          expect(offsets.last, greaterThan(30), reason: '必须真的产生惯性位移');
          return offsets;
        } finally {
          await tester.runAsync(fixture.finish);
          await tester.pumpWidget(const SizedBox());
          await tester.runAsync(fixture.dispose);
          viewport.dispose();
        }
      }

      final baseline = await sample(growing: false);
      final growing = await sample(growing: true);
      for (var i = 0; i < baseline.length; i++) {
        expect(growing[i], closeTo(baseline[i], 0.5), reason: '第$i帧只允许惯性位移');
      }
    });
  }
}
