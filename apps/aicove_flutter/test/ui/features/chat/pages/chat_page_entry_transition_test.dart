import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/features/chat/application/chat_page_conversation_actions.dart';
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
        await tester.pump();
        await tester.runAsync(fixture.dispose);
        expect(during, isEmpty, reason: '160ms清未读会与尚未完成的左移动画争抢');
        expect(after, earlyPop ? isEmpty : [AnimationStatus.completed]);
        expect(imagesDuring, isEmpty);
        expect(imagePhases, earlyPop ? isEmpty : [AnimationStatus.completed]);
      });
    }
  }
}
