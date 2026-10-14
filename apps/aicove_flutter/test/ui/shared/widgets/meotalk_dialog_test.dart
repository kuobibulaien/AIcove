import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/ui/shared/widgets/buttons/moe_primary_button.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/buttons/moe_secondary_button.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/meotalk_dialog.dart';

void main() {
  testWidgets('MeoTalkDialog 底部按钮具备按钮语义与键盘焦点触发', (tester) async {
    final semantics = tester.ensureSemantics();
    var confirmed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MeoTalkDialog(
            title: '确认操作',
            content: const Text('是否继续？'),
            onConfirm: () => confirmed = true,
          ),
        ),
      ),
    );
    expect(
      tester.getSemantics(find.byType(MoeSecondaryButton)).flagsCollection.isButton,
      isTrue,
    );
    expect(
      tester.getSemantics(find.byType(MoePrimaryButton)).flagsCollection.isButton,
      isTrue,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(confirmed, isTrue);
    semantics.dispose();
  });

  testWidgets('MeoTalkDialog 会根据键盘 inset 上移', (tester) async {
    await tester.pumpWidget(
      const MediaQuery(
        data: MediaQueryData(
          size: Size(390, 844),
          viewInsets: EdgeInsets.only(bottom: 240),
        ),
        child: MaterialApp(
          home: _DialogLauncher(),
        ),
      ),
    );

    await tester.tap(find.text('打开弹窗'));
    await tester.pumpAndSettle();

    expect(find.byType(MeoTalkDialog), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);

    final padding = tester.widget<AnimatedPadding>(
      find.descendant(
        of: find.byType(MeoTalkDialog),
        matching: find.byType(AnimatedPadding),
      ),
    );
    expect(padding.padding, const EdgeInsets.only(bottom: 240));

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
  });
}

class _DialogLauncher extends StatelessWidget {
  const _DialogLauncher();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: TextButton(
          onPressed: () {
            showMeoTalkDialog(
              context: context,
              title: '添加自定义模型',
              content: const TextField(),
            );
          },
          child: const Text('打开弹窗'),
        ),
      ),
    );
  }
}
