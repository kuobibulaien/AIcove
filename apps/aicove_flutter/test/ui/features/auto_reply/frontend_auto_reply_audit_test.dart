import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/auto_reply_trigger.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/auto_reply_trigger_controller.dart';
import 'package:aicove_flutter/src/ui/features/auto_reply/pages/auto_reply_trigger_list_page.dart';

class AuditTriggerController extends AutoReplyTriggerController {
  @override
  Future<List<AutoReplyTrigger>> build() async => List.generate(
      100,
      (i) => AutoReplyTrigger(
            id: 'audit-$i',
            title: 'Reminder $i',
            type: AutoReplyTriggerType.delay,
            status: AutoReplyTriggerStatus.pending,
            createdAt: DateTime(2026, 9, 6),
            nextFireAt: DateTime(2026, 9, 7).add(Duration(minutes: i)),
            allowNight: false,
            requireExact: false,
            delayMinutes: 30,
            manual: true,
            conversationId: 'synthetic',
          ));
}

void main() {
  for (final width in [320.0, 1000.0]) {
    for (final scale in [1.0, 1.2, 1.8, 2.0]) {
      testWidgets('trigger list width=$width scale=$scale', (tester) async {
        await tester.binding.setSurfaceSize(Size(width, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(ProviderScope(
          overrides: [
            autoReplyTriggersProvider.overrideWith(AuditTriggerController.new)
          ],
          child: MaterialApp(
            builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(scale)),
                child: child!),
            home: const AutoReplyTriggerListPage(),
          ),
        ));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.scrollUntilVisible(find.text('Reminder 99'), 500,
            maxScrolls: 100);
        expect(find.text('Reminder 99').hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
