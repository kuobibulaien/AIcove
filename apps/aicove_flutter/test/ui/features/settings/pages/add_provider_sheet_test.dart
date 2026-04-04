import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/ui/features/settings/pages/add_provider_sheet.dart';

void main() {
  test('聊天 API 格式只保留 OpenAI、Claude、Gemini', () {
    expect(
      ApiFormat.chatFormats.map((format) => format.value).toList(),
      <String>['openai', 'claude', 'gemini'],
    );
  });

  testWidgets('OpenAI 导入时基础 URL 不以 /v1 结尾会显示推荐提示', (tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: AddProviderSheet(),
          ),
        ),
      ),
    );

    expect(find.textContaining('OpenAI 格式推荐'), findsNothing);

    final textFields = find.byType(TextField);
    expect(textFields, findsNWidgets(4));

    await tester.enterText(textFields.at(2), 'https://api.example.com');
    await tester.pump();

    expect(find.textContaining('OpenAI 格式推荐'), findsOneWidget);

    await tester.enterText(textFields.at(2), 'https://api.example.com/v1');
    await tester.pump();

    expect(find.textContaining('OpenAI 格式推荐'), findsNothing);
  });
}
