import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/ui/shared/widgets/buttons/moe_primary_button.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/meotalk_dialog.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/moe_global_ui_scale.dart';

void main() {
  testWidgets('界面缩放小于 1 时底部弹窗仍完整停在键盘上方', (tester) async {
    const screen = Size(390, 844);
    const keyboard = 300.0;
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = screen;
    tester.view.viewInsets = const FakeViewPadding(bottom: keyboard);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            MoeGlobalUiScale(scale: 0.85, child: child!),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showMeoTalkDialog(
                  context: context,
                  title: '进入隐私空间',
                  content: const TextField(),
                ),
                child: const Text('打开弹窗'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开弹窗'));
    await tester.pumpAndSettle();

    final keyboardTop = screen.height - keyboard;
    final buttonBottom = tester.getRect(find.byType(MoePrimaryButton)).bottom;
    expect(buttonBottom, lessThan(keyboardTop));
  });
}
