import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:aicove_flutter/src/features/agent_context/domain/tavern_compatibility_port.dart';
import 'package:aicove_flutter/src/features/agent_context/providers/preset_recipe_provider.dart';
import 'package:aicove_flutter/src/ui/features/character/widgets/character_plugins_section.dart';
import 'package:aicove_flutter/src/ui/features/settings/pages/chat_plugin_settings_page.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/index.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('已开启插件各占一个容器，按序展开绑定行', (tester) async {
    await tester.pumpWidget(const _TestApp());
    await tester.pumpAndSettle();

    // 主动关怀全局未开启，不算已开启：六个插件容器 + 全部插件容器
    final labels = ['音色', '生图', '记忆', '酒馆', '表情包', '时间感知'];
    for (final label in labels) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    expect(find.text('主动关怀'), findsNothing);
    expect(find.byType(MoeSettingsGroup), findsNWidgets(labels.length + 1));
    final ys = [
      for (final label in labels) tester.getTopLeft(find.text(label)).dy,
    ];
    expect(ys, [...ys]..sort());

    expect(find.text('音色配置包'), findsOneWidget);
    expect(find.text('跟随默认音色配置包'), findsOneWidget);
    expect(find.text('绘图配置包'), findsOneWidget);
    expect(find.text('角色记忆文档'), findsOneWidget);
    expect(find.text('跟随默认酒馆预设'), findsOneWidget);
    expect(find.byIcon(Icons.record_voice_over_outlined), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('关闭后容器消失，在全部插件里重新开启后恢复', (tester) async {
    await tester.pumpWidget(const _TestApp());
    await tester.pumpAndSettle();

    final host = tester.state<_TestAppState>(find.byType(_TestApp));

    await tester.tap(find.text('音色'));
    await tester.pumpAndSettle();
    expect(host.selectedPluginIds.contains('tts'), isFalse);
    expect(find.text('音色'), findsNothing);
    expect(find.text('音色配置包'), findsNothing);

    await tester.tap(find.text('全部插件'));
    await tester.pumpAndSettle();
    final ttsRow = find.byKey(const ValueKey('all-plugins-tts'));
    await tester.ensureVisible(ttsRow);
    await tester.tap(ttsRow);
    await tester.pumpAndSettle();

    expect(host.selectedPluginIds.contains('tts'), isTrue);
    expect(find.text('音色配置包'), findsOneWidget);
    // 全部插件列表与已开启容器里各有一处
    expect(find.text('音色'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('酒馆行点击打开预设选择弹窗', (tester) async {
    await tester.pumpWidget(const _TestApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('酒馆'));
    await tester.pumpAndSettle();

    expect(find.text('选择酒馆预设'), findsOneWidget);
    expect(find.text('跟随默认酒馆预设'), findsWidgets);
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
