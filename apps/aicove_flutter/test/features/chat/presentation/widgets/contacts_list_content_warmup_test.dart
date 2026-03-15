import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/features/chat/presentation/widgets/contacts_list_content.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('联系人点击预热会延后到下一帧之后再执行', (tester) async {
    late BuildContext context;
    var called = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (ctx) {
            context = ctx;
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    scheduleConversationTapWarmup(
      context,
      () => called = true,
      delay: const Duration(milliseconds: 80),
    );

    expect(called, isFalse);

    await tester.pump();
    expect(called, isFalse);

    await tester.pump(const Duration(milliseconds: 79));
    expect(called, isFalse);

    await tester.pump(const Duration(milliseconds: 1));
    expect(called, isTrue);
  });

  testWidgets('联系人点击预热被取消后不再执行', (tester) async {
    late BuildContext context;
    var called = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (ctx) {
            context = ctx;
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    final cancel = scheduleConversationTapWarmup(
      context,
      () => called = true,
      delay: const Duration(milliseconds: 80),
    );

    cancel();

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));

    expect(called, isFalse);
  });
}
