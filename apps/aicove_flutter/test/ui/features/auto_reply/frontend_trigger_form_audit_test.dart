import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/features/chat/conversation_providers.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/features/auto_reply/presentation/widgets/auto_reply_trigger_form.dart';

class AuditTriggerContacts extends ConversationsNotifier {
  @override
  Future<List<Conversation>> build() async => List.generate(
      100,
      (i) => Conversation(
          id: 'audit-$i',
          title: 'Audit $i',
          displayName: 'Synthetic contact $i',
          createdAt: DateTime(2026, 9, 6),
          updatedAt: DateTime(2026, 9, 6)));
}

void main() {
  for (final size in [const Size(320, 568), const Size(1000, 768)]) {
    for (final scale in [1.2, 1.8]) {
      testWidgets('trigger form size=$size scale=$scale', (tester) async {
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(ProviderScope(
            overrides: [
              conversationsProvider.overrideWith(AuditTriggerContacts.new)
            ],
            child: MaterialApp(
                builder: (context, child) => MediaQuery(
                    data: MediaQuery.of(context)
                        .copyWith(textScaler: TextScaler.linear(scale)),
                    child: child!),
                home: Scaffold(
                    body: Consumer(
                        builder: (context, ref, _) => TextButton(
                            onPressed: () =>
                                showCreateAutoReplyTriggerSheet(context, ref),
                            child: const Text('open')))))));
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(find.text('创建触发器'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text('创建触发器').hitTestable(), findsOneWidget);
      });
    }
  }
}
