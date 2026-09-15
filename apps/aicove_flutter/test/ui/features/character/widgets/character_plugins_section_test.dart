import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:aicove_flutter/src/features/agent_context/domain/tavern_compatibility_port.dart';
import 'package:aicove_flutter/src/features/agent_context/providers/preset_recipe_provider.dart';
import 'package:aicove_flutter/src/ui/features/character/widgets/character_plugins_section.dart';
import 'package:aicove_flutter/src/ui/features/settings/pages/chat_plugin_settings_page.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('七项插件按序渲染，允许后展开绑定行', (tester) async {
    await tester.pumpWidget(const _TestApp());
    await tester.pumpAndSettle();

    for (final label in ['音色', '生图', '记忆', '酒馆', '表情包', '主动关怀', '时间感知']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }

    // 默认全部允许：音色行下展开绑定预设
    expect(find.text('音色配置包'), findsOneWidget);
    expect(find.text('跟随默认音色配置包'), findsOneWidget);
    // 生图/记忆同样展开绑定行
    expect(find.text('绘图配置包'), findsOneWidget);
    expect(find.text('角色记忆文档'), findsOneWidget);
    // 酒馆行直接显示绑定预设
    expect(find.text('跟随插件默认预设'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('关闭插件开关后收起绑定行并回调', (tester) async {
    await tester.pumpWidget(const _TestApp());
    await tester.pumpAndSettle();

    final host = tester.state<_TestAppState>(find.byType(_TestApp));

    // 关闭音色开关：行仍在，绑定行消失
    await tester.tap(find.text('音色'));
    await tester.pumpAndSettle();

    expect(host.selectedPluginIds.contains('tts'), isFalse);
    expect(find.text('音色配置包'), findsNothing);

    // 重新打开：绑定行恢复
    await tester.tap(find.text('音色'));
    await tester.pumpAndSettle();
    expect(host.selectedPluginIds.contains('tts'), isTrue);
    expect(find.text('音色配置包'), findsOneWidget);
  });

  testWidgets('酒馆行点击打开预设选择弹窗', (tester) async {
    await tester.pumpWidget(const _TestApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('酒馆'));
    await tester.pumpAndSettle();

    expect(find.text('选择酒馆预设'), findsOneWidget);
    expect(find.text('跟随插件默认预设'), findsWidgets);
    await tester.tap(find.text('通用剧情 v2'));
    await tester.pumpAndSettle();

    final host = tester.state<_TestAppState>(find.byType(_TestApp));
    expect(host.recipeId, 'recipe_story');
    expect(find.text('通用剧情 v2'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

class _TestApp extends StatefulWidget {
  const _TestApp();

  @override
  State<_TestApp> createState() => _TestAppState();
}

class _TestAppState extends State<_TestApp> {
  late Set<String> selectedPluginIds = {
    for (final item in conversationScopedChatPluginItems) item.id,
  };
  String? recipeId;

  @override
  Widget build(BuildContext context) {
    return ProviderScope(
      overrides: [
        presetRecipeListProvider.overrideWith(
          (ref) async => const [
            PresetRecipeSummary(
              id: 'recipe_story',
              name: '通用剧情 v2',
              description: '4 个启用节点 · 顺序组 1',
            ),
          ],
        ),
        tavernPluginSettingsProvider.overrideWith(
          (ref) async => const TavernPluginSettings(enabled: true),
        ),
      ],
      child: MaterialApp(
        theme: ThemeData(extensions: [MoeColors.light()]),
        home: Scaffold(
          body: SingleChildScrollView(
            child: CharacterPluginsSection(
              selectedPluginIds: selectedPluginIds,
              boundVoiceId: null,
              voicePresets: const [],
              drawingPersonaPrompt: '',
              selectedRecipeId: recipeId,
              memoryDocAvailable: true,
              onOpenMemoryDoc: () {},
              onPluginIdsChanged: (ids) =>
                  setState(() => selectedPluginIds = ids),
              onVoiceChanged: (_) {},
              onDrawingPresetChanged: (_) {},
              onRecipeChanged: (id) => setState(() => recipeId = id),
            ),
          ),
        ),
      ),
    );
  }
}
