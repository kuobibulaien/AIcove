import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/features/chat/presentation/widgets/message_action_sheet.dart';

void main() {
  for (final width in [320.0, 360.0, 1000.0]) {
    for (final scale in [1.2, 1.8]) {
      testWidgets('full AI message menu width=$width scale=$scale',
          (tester) async {
        await tester.binding.setSurfaceSize(Size(width, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final targetKey = GlobalKey();
        MessageAction? selected;
        await tester.pumpWidget(MaterialApp(
          builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: child!),
          home: Scaffold(
              body: Center(
                  child: Builder(
                      builder: (context) => TextButton(
                            key: targetKey,
                            onPressed: () => showMessageActionMenu(
                              context,
                              targetBox: targetKey.currentContext!
                                  .findRenderObject()! as RenderBox,
                              isUserMessage: false,
                              messageText: 'synthetic',
                              showEnhanceRegenerate: true,
                              showTranscribe: true,
                              onAction: (action) => selected = action,
                            ),
                            child: const Text('open'),
                          )))),
        ));
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('引用'));
        await tester.pumpAndSettle();
        expect(selected, MessageAction.quote);
      });
    }
  }
}
