import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/ui/features/chat/widgets/regenerate_guidance_dialog.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';

void main() {
  Future<List<String?>> pumpHost(WidgetTester tester, double width) async {
    await tester.binding.setSurfaceSize(Size(width, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final results = <String?>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(extensions: [MoeColors.light()]),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async =>
                results.add(await showRegenerateGuidanceDialog(context)),
            child: const Text('open'),
          ),
        ),
      ),
    );
    return results;
  }

  for (final width in [360.0, 1000.0]) {
    testWidgets('不填意见直接重新生成返回空字符串 width=$width', (tester) async {
      final results = await pumpHost(tester, width);
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('重新生成'), findsNWidgets(2));
      await tester.tap(find.widgetWithText(TextButton, '重新生成'));
      await tester.pumpAndSettle();
      expect(results, ['']);
      expect(tester.takeException(), isNull);
    });

    testWidgets('填写意见后返回去除首尾空白的文本 width=$width', (tester) async {
      final results = await pumpHost(tester, width);
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '  更简短一些 ');
      await tester.tap(find.widgetWithText(TextButton, '重新生成'));
      await tester.pumpAndSettle();
      expect(results, ['更简短一些']);
    });

    testWidgets('取消返回 null width=$width', (tester) async {
      final results = await pumpHost(tester, width);
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await tester.pumpAndSettle();
      expect(results, [null]);
    });
  }
}
