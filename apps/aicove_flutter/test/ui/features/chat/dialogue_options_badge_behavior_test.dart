import 'package:aicove_flutter/src/features/chat/chat_providers.dart';
import 'package:aicove_flutter/src/features/dialogue_options/application/dialogue_options_providers.dart';
import 'package:aicove_flutter/src/features/dialogue_options/domain/dialogue_options.dart';
import 'package:aicove_flutter/src/ui/features/chat/widgets/dialogue_options_badge.dart';
import 'package:aicove_flutter/src/ui/theme/skin_provider.dart';
import 'package:aicove_flutter/src/ui/theme/skins/moetalk_skin.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _id = 'conv';
final _badge = find.byKey(const ValueKey('dialogue_options_badge'));
final _firstOption = find.byKey(const ValueKey('dialogue_option_0'));

void main() {
  late ProviderContainer container;
  late ValueNotifier<DialogueOptions?> options;

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: SkinScope(
          skin: const MoeTalkSkin(),
          child: MaterialApp(
            theme: ThemeData(extensions: [MoeColors.light()]),
            home: Scaffold(
              body: Align(
                alignment: Alignment.bottomRight,
                child: ValueListenableBuilder<DialogueOptions?>(
                  valueListenable: options,
                  builder: (_, value, _) => DialogueOptionsBadge(
                    conversationId: _id,
                    options: value,
                    size: 44,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> finishReply(WidgetTester tester, DialogueOptions? next) async {
    container.read(conversationSendingProvider(_id).notifier).state = true;
    await tester.pump();
    options.value = next;
    container.read(conversationSendingProvider(_id).notifier).state = false;
    await tester.pumpAndSettle();
  }

  setUp(() {
    container = ProviderContainer();
    options = ValueNotifier(null);
  });
  tearDown(() {
    container.dispose();
    options.dispose();
  });

  testWidgets('existing options stay collapsed until tapped', (tester) async {
    options.value = const DialogueOptions(messageId: 'a1', items: ['好', '不']);
    await pump(tester);
    expect(_badge, findsOneWidget);
    expect(_firstOption, findsNothing);
    await tester.tap(_badge);
    await tester.pumpAndSettle();
    expect(_firstOption, findsOneWidget);
  });

  testWidgets('a finished reply expands once; dismissing keeps the badge', (
    tester,
  ) async {
    await pump(tester);
    expect(_badge, findsNothing);
    await finishReply(
      tester,
      const DialogueOptions(messageId: 'a1', items: ['靠近', '离开']),
    );
    expect(_firstOption, findsOneWidget);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(_firstOption, findsNothing);
    expect(_badge, findsOneWidget);
  });

  testWidgets('choosing an option delivers it and hides the badge', (
    tester,
  ) async {
    container.listen<DialogueOptionPick?>(dialogueOptionPickProvider(_id), (
      _,
      pick,
    ) {
      // Mirrors the composer accepting the pick.
      if (pick != null) {
        container.read(dialogueOptionsConsumedProvider(_id).notifier).state =
            pick.signature;
      }
    });
    await pump(tester);
    const next = DialogueOptions(messageId: 'a1', items: ['靠近', '离开']);
    await finishReply(tester, next);
    await tester.tap(find.byKey(const ValueKey('dialogue_option_1')));
    await tester.pumpAndSettle();
    expect(container.read(dialogueOptionsConsumedProvider(_id)), next.signature);
    expect(_badge, findsNothing);
  });

  testWidgets('a reply without new options does not reopen old ones', (
    tester,
  ) async {
    const old = DialogueOptions(messageId: 'a1', items: ['好', '不']);
    options.value = old;
    await pump(tester);
    await finishReply(tester, old);
    expect(_firstOption, findsNothing);
    expect(_badge, findsOneWidget);
  });
}
