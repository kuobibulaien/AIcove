import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/moe_toast.dart';

void main() {
  testWidgets('old dismissible toast completion preserves newer notification',
      (tester) async {
    final save = Completer<void>();
    late BuildContext host;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) {
      host = context;
      return const Scaffold();
    })));
    MoeToast.showDismissible(host, 'Old notice',
        noticeKey: 'audit', onDismissForever: () => save.future);
    await tester.pumpAndSettle();
    await tester.tap(find.text('不再提醒'));
    await tester.pump();
    MoeToast.show(host, 'New notice', duration: const Duration(seconds: 10));
    await tester.pumpAndSettle();
    expect(find.text('New notice'), findsOneWidget);
    save.complete();
    await tester.pumpAndSettle();
    final newerNoticeRemains = find.text('New notice').evaluate().isNotEmpty;
    await tester.pump(const Duration(seconds: 11));
    expect(tester.takeException(), isNull);
    expect(newerNoticeRemains, isTrue,
        reason:
            'completion belongs to the old notification, not the current one');
  });
}
