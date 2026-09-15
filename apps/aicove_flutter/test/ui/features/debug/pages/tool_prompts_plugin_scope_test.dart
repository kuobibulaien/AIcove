import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:aicove_flutter/src/features/plugins/plugin_manager.dart';
import 'package:aicove_flutter/src/features/plugins/plugin_providers.dart';
import 'package:aicove_flutter/src/ui/features/debug/pages/tool_prompts_page.dart';

void main() {
  testWidgets('immediate back persists the final prompt before leaving',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(ProviderScope(
      overrides: [pluginManagerProvider.overrideWithValue(PluginManager())],
      child: MaterialApp(
          home: Builder(
              builder: (context) => Scaffold(
                      body: TextButton(
                    child: const Text('open'),
                    onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                            builder: (_) => const ToolPromptsPage())),
                  )))),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('语音合成 (TTS)'));
    await tester.pumpAndSettle();
    final container =
        ProviderScope.containerOf(tester.element(find.byType(ToolPromptsPage)));
    await tester.enterText(find.byType(TextField).first, 'last prompt edit');
    Navigator.of(tester.element(find.byType(ToolPromptsPage))).maybePop();
    await tester.pumpAndSettle();
    expect(container.read(ttsPluginConfigProvider).systemPromptTemplate,
        'last prompt edit');
    expect(find.text('open'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final width in [360.0, 1000.0]) {
    testWidgets('empty plugin preview at width $width has no injected lead-in',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(ProviderScope(
        overrides: [pluginManagerProvider.overrideWithValue(PluginManager())],
        child: const MaterialApp(home: ToolPromptsPage()),
      ));
      await tester.pumpAndSettle();
      expect(find.textContaining('以下是当前会话启用的特殊标签说明'), findsNothing);
      expect(find.text('当前没有启用的标签说明注入'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
