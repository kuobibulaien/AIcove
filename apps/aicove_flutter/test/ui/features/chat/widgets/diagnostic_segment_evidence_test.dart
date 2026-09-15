import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:aicove_flutter/src/core/app_logger.dart';
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final original = PathProviderPlatform.instance;
  late Directory folder;
  setUpAll(() {
    folder = Directory.systemTemp.createTempSync('diagnostic_segments_');
    PathProviderPlatform.instance = _Paths(folder.path);
  });
  tearDownAll(() async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    PathProviderPlatform.instance = original;
    folder.deleteSync(recursive: true);
  });
  for (final width in [360.0, 1000.0]) {
    testWidgets('$width：真实分段、用户拖动的动画裁决可从日志还原', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 640);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final fixture =
          (await tester.runAsync(() => SegmentedChatFixture.create()))!;
      final viewport = ChatViewportController();
      var disposed = false;
      addTearDown(() async {
        if (!disposed) {
          await fixture.dispose();
          viewport.dispose();
        }
      });
      await tester.pumpWidget(UncontrolledProviderScope(
          container: fixture.container,
          child: SkinScope(
              skin: const MoeTalkSkin(),
              child: MaterialApp(
                  home: Scaffold(
                      body: ValueListenableBuilder<List<Message>>(
                          valueListenable: fixture.timeline,
                          builder: (_, messages, __) => ChatMessageList(
                              conversationId: fixture.conversation.id,
                              messages: messages,
                              displayName: '离线日志验收',
                              viewportController: viewport,
                              hasMoreMessages: false)))))));
      for (var i = 0; i < 24; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      await tester.runAsync(fixture.start);
      viewport.onUserSend();
      fixture.add('第一段文字形成真实独立气泡。');
      await tester
          .runAsync(() => fixture.waitUntil(() => fixture.bubbles.length == 1));
      for (var i = 0; i < 24; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      final id = fixture.bubbles.first.id;
      final gesture = await tester
          .startGesture(tester.getCenter(find.byType(CustomScrollView)));
      await gesture.moveBy(const Offset(0, 40));
      await tester.pump();
      fixture.add('第二段到达时旧气泡的动画裁决必须有依据。');
      await tester
          .runAsync(() => fixture.waitUntil(() => fixture.bubbles.length == 2));
      await tester.pump();
      final animated = find
          .ancestor(
              of: find.byKey(ValueKey('message_bubble_$id')),
              matching: find.byType(AnimatedMessageItem))
          .evaluate()
          .isNotEmpty;
      await tester.pump(); // 诊断微任务不在 build 内同步通知 UI。
      final decisions = AppLogger.entries.value
          .where((e) =>
              e.metadata?['event'] == 'animationDecision' &&
              e.metadata?['messageId'] == id)
          .toList();
      expect(decisions, isNotEmpty);
      final latest = decisions.last.metadata!;
      expect(latest['state']['animate'], animated);
      expect(latest['state']['previouslyBuilt'], true);
      expect(latest['state']['userOwnsViewport'], true);
      expect(latest['pageInstanceId'], isNotNull);
      expect(latest['operationId'], latest['pageInstanceId']);
      expect(latest['state']['viewportClock'], true);
      expect(latest['parentOperationId'], isNotNull);
      expect(latest['traceId'], isNotNull);
      expect(
          AppLogger.entries.value.any((e) =>
              e.metadata?['event'] == 'projectionApplied' &&
              e.metadata?['state']?['afterCount'] == 2),
          true);
      await gesture.up();
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(fixture.dispose);
      viewport.dispose();
      disposed = true;
      expect(tester.takeException(), isNull);
    });
  }
}
