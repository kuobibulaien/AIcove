import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:aicove_flutter/src/ui/features/plugins/pages/drawing_prompt_page.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('新建系统提示词预设会进入独立编辑页面并可返回', (tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: DrawingPromptPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('添加系统提示词预设'));
    await tester.pumpAndSettle();

    expect(find.text('添加系统提示词预设'), findsOneWidget);
    expect(find.byType(TextField), findsNWidgets(2));

    await tester.pageBack();
    await tester.pumpAndSettle();

    expect(find.text('绘图提示词'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('新建系统提示词预设保存后会回到列表并显示新条目', (tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: DrawingPromptPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('添加系统提示词预设'));
    await tester.pumpAndSettle();

    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), '测试预设');
    await tester.enterText(fields.at(1), '测试内容');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(find.text('测试预设'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
  });
}
