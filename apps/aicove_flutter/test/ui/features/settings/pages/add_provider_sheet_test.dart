import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/ui/features/settings/pages/add_provider_sheet.dart';

void main() {
  Widget buildSheet() {
    return const ProviderScope(
      child: MaterialApp(home: Scaffold(body: AddProviderSheet())),
    );
  }

  void usePhoneSize(WidgetTester tester) {
    tester.view.physicalSize = const Size(390, 960);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  test('聊天 API 格式只保留 OpenAI、Claude、Gemini', () {
    expect(
      ApiFormat.chatFormats.map((format) => format.value).toList(),
      <String>['openai', 'claude', 'gemini'],
    );
  });

  test('ComfyUI 只属于绘图分类', () {
    expect(ApiFormat.forCategory(ProviderCategory.chat),
        isNot(contains(ApiFormat.comfyui)));
    expect(ApiFormat.forCategory(ProviderCategory.tts),
        isNot(contains(ApiFormat.comfyui)));
    expect(ApiFormat.forCategory(ProviderCategory.image),
        contains(ApiFormat.comfyui));
  });

  testWidgets('默认对话分类不显示 ComfyUI，切到绘图后才出现', (tester) async {
    usePhoneSize(tester);
    await tester.pumpWidget(buildSheet());

    expect(find.text('Claude'), findsOneWidget);
    expect(find.text('ComfyUI'), findsNothing);

    await tester.tap(find.text('绘图'));
    await tester.pumpAndSettle();

    expect(find.text('ComfyUI'), findsOneWidget);
    expect(find.text('NovelAI'), findsOneWidget);
    expect(find.text('Claude'), findsNothing);
    expect(find.text('API 路径'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('语音分类切换格式后填入对应默认地址且不显示 API 路径', (tester) async {
    usePhoneSize(tester);
    await tester.pumpWidget(buildSheet());

    await tester.tap(find.text('语音'));
    await tester.pumpAndSettle();
    expect(find.text('API 路径'), findsNothing);
    expect(find.text('https://api.openai.com/v1'), findsOneWidget);

    await tester.ensureVisible(find.text('Fish Audio'));
    await tester.tap(find.text('Fish Audio'));
    await tester.pumpAndSettle();
    expect(find.text('https://api.fish.audio/v1'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('输入框占满标题右侧空间', (tester) async {
    usePhoneSize(tester);
    await tester.pumpWidget(buildSheet());

    // 旧版固定 160～180 宽，现在随行宽伸展。
    final urlField = find.byType(TextField).at(2);
    expect(tester.getSize(urlField).width, greaterThan(180));
    final nameField = find.byType(TextField).at(0);
    expect(tester.getSize(nameField).width, greaterThan(180));
  });

  testWidgets('OpenAI 导入时基础 URL 不以 /v1 结尾会显示推荐提示', (tester) async {
    await tester.pumpWidget(buildSheet());

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
