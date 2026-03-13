import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:aicove_flutter/src/ui/features/plugins/pages/draw_image_tool_description_page.dart';

void main() {
  testWidgets('create drawing prompt preset should not throw framework assertion',
      (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});

    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: DrawImageToolDescriptionPage(),
        ),
      ),
    );

    await tester.pumpAndSettle();

    await tester.tap(find.text('添加预设'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).last, '测试预设A');
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();

    expect(find.text('测试预设A'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
