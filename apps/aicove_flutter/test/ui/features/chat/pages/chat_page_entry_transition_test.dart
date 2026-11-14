import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/features/chat/application/chat_page_conversation_actions.dart';
import 'package:aicove_flutter/src/features/chat/conversation_providers.dart';
import 'package:aicove_flutter/src/core/utils/image_preheat_queue.dart';
import 'package:aicove_flutter/src/ui/features/chat/pages/chat_page.dart';
import 'package:aicove_flutter/src/ui/theme/skin_provider.dart';
import 'package:aicove_flutter/src/ui/theme/skins/moetalk_skin.dart';
import '../../../../../tool/chat_segmented_fixture.dart';

class _EntryActions extends ChatPageConversationActions {
  _EntryActions(super.ref, this.onClear);
  final void Function() onClear;
  @override
  Future<void> clearUnread(String conversationId) async => onClear();
}

class _EntryImages extends ImagePreheatQueue {
  _EntryImages(this.onWarm);
  final void Function() onWarm;
  @override
  void enqueueAllFromContext(
    BuildContext context,
    Iterable<ImageProvider> providers, {
    ImagePreheatPriority priority = ImagePreheatPriority.normal,
    Size? size,
  }) =>
      onWarm();
}

class _SlowRoute extends CupertinoPageRoute<void> {
  _SlowRoute({required super.builder});
  @override
  Duration get transitionDuration => const Duration(seconds: 2);
}

void main() {
  for (final slow in [false, true]) {
    for (final earlyPop in [false, true]) {
      testWidgets('进场完成才维护、提前返回取消：slow=$slow earlyPop=$earlyPop',
          (tester) async {
        final fixture = (await tester
            .runAsync(() => SegmentedChatFixture.create(historyCount: 0)))!;
        final navigator = GlobalKey<NavigatorState>();
        final phases = <AnimationStatus>[];
        final imagePhases = <AnimationStatus>[];
        final conversation = fixture.conversation
            .copyWith(avatarUrl: 'assets/characters/images/nahida.jpg');
        late CupertinoPageRoute<void> route;
        await tester.pumpWidget(UncontrolledProviderScope(
          container: fixture.container,
          child: ProviderScope(
              overrides: [
                imagePreheatQueueProvider.overrideWith((ref) => _EntryImages(
                    () => imagePhases.add(route.animation!.status))),
                chatPageConversationActionsProvider.overrideWith((ref) =>
                    _EntryActions(
                        ref, () => phases.add(route.animation!.status))),
              ],
              child: SkinScope(
                  skin: const MoeTalkSkin(),
                  child: MaterialApp(
                    navigatorKey: navigator,
                    home: const Scaffold(body: Text('联系人')),
                  ))),
        ));
        Widget page(BuildContext _) => ChatPage(
              conversationId: conversation.id,
              initialConversation: conversation,
            );
        route = slow
            ? _SlowRoute(builder: page)
            : CupertinoPageRoute(builder: page);
        unawaited(navigator.currentState!.push(route));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 180));
        final during = List.of(phases);
        final imagesDuring = List.of(imagePhases);
        expect(route.animation!.status, AnimationStatus.forward);
        if (earlyPop) {
          navigator.currentState!.pop();
          await tester.pump();
        }
        await tester.pump(route.transitionDuration);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));
        final after = List.of(phases);
        await tester.pumpWidget(const SizedBox.shrink());
        // 页面在假时钟里排下的数据库工作要靠 pump 推进；只在 runAsync 里
        // 关闭会让 database.close 永远等不到它们完成。
        var disposed = false;
        final cleanup = fixture.dispose().then((_) => disposed = true);
        for (var attempt = 0; attempt < 100 && !disposed; attempt++) {
          await tester.pump(const Duration(milliseconds: 16));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 5)),
          );
        }
        expect(disposed, isTrue);
        await cleanup;
        expect(during, isEmpty, reason: '160ms清未读会与尚未完成的左移动画争抢');
        expect(after, earlyPop ? isEmpty : [AnimationStatus.completed]);
        expect(imagesDuring, isEmpty);
        expect(imagePhases, earlyPop ? isEmpty : [AnimationStatus.completed]);
      });
    }
  }

  for (final covered in [false, true]) {
    testWidgets('页面开着时新到的未读随即清掉，被盖住时等返回再清：covered=$covered',
        (tester) async {
      final fixture = (await tester
          .runAsync(() => SegmentedChatFixture.create(historyCount: 0)))!;
      final navigator = GlobalKey<NavigatorState>();
      var clears = 0;
      await tester.pumpWidget(UncontrolledProviderScope(
        container: fixture.container,
        child: ProviderScope(
            overrides: [
              imagePreheatQueueProvider
                  .overrideWith((ref) => _EntryImages(() {})),
              chatPageConversationActionsProvider
                  .overrideWith((ref) => _EntryActions(ref, () => clears++)),
            ],
            child: SkinScope(
                skin: const MoeTalkSkin(),
                child: MaterialApp(
                  navigatorKey: navigator,
                  home: ChatPage(
                    conversationId: fixture.conversation.id,
                    initialConversation: fixture.conversation,
                  ),
                ))),
      ));
      await tester.pump(const Duration(milliseconds: 200));
      final afterEntry = clears;
      if (covered) {
        unawaited(navigator.currentState!.push(MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('设置')))));
        await tester.pumpAndSettle();
      }
      await fixture.container.read(conversationsProvider.notifier).updateOne(
            fixture.conversation.id,
            (c) => c.copyWith(unreadCount: 1),
            persist: false,
          );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      final afterArrival = clears;
      if (covered) {
        navigator.currentState!.pop();
        await tester.pumpAndSettle();
        await tester.pump(const Duration(milliseconds: 200));
      }
      final afterReturn = clears;
      await tester.pumpWidget(const SizedBox.shrink());
      var disposed = false;
      final cleanup = fixture.dispose().then((_) => disposed = true);
      for (var attempt = 0; attempt < 100 && !disposed; attempt++) {
        await tester.pump(const Duration(milliseconds: 16));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
      }
      await cleanup;
      expect(afterArrival - afterEntry, covered ? 0 : 1);
      expect(afterReturn - afterEntry, 1);
    });
  }
}
