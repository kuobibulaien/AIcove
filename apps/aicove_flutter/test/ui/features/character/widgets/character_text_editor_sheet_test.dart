import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/ui/features/character/widgets/character_text_editor_sheet.dart';

void main() {
  testWidgets('showCharacterTextEditorSheet returns latest draft on close',
      (tester) async {
    String? sheetResult;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            return Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () async {
                    sheetResult = await showCharacterTextEditorSheet(
                      context: context,
                      title: '编辑简介',
                      initialValue: '旧文本',
                      hint: '请输入',
                    );
                  },
                  child: const Text('打开弹窗'),
                ),
              ),
            );
          },
        ),
      ),
    );

    await tester.tap(find.text('打开弹窗'));
    await tester.pumpAndSettle();

    expect(find.byType(TextField), findsOneWidget);

    await tester.enterText(find.byType(TextField), '新文本');
    expect(find.text('完成'), findsNothing);
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();

    expect(sheetResult, '新文本');
  });
}
