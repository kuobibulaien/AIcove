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

  testWidgets('已开启插件合并为统一行高的列表，不带开关', (tester) async {
    await tester.pumpWidget(const _TestApp());
    await tester.pumpAndSettle();

    // 已开启插件列表 + 管理开启的插件容器
    expect(find.byType(MoeSettingsGroup), findsNWidgets(2));
    final labels = ['音色', '生图', '记忆', '酒馆', '表情包', '主动关怀', '时间感知'];
    final rows = [
      for (final id in [
        'tts',
        'image',
        'memory',
        'tavern',
        'sticker',
        'trigger',
        'time_awareness',
      ])
        find.byKey(ValueKey('enabled-plugin-$id')),
    ];
    for (var i = 0; i < rows.length; i++) {
      expect(rows[i], findsOneWidget, reason: labels[i]);
    }
    final ys = [for (final row in rows) tester.getTopLeft(row).dy];
    expect(ys, [...ys]..sort());
    // 末行无分割线，除此之外每行等高
    final heights = {
      for (final row in rows.take(rows.length - 1)) tester.getSize(row).height,
    };
    expect(heights, hasLength(1));
    expect(tester.getSize(rows.last).height, closeTo(heights.single, 0.5));
    // 管理开启的插件未展开，上方列表不出现开关
    expect(find.byType(Switch), findsNothing);

    expect(find.text('跟随默认音色配置包'), findsOneWidget);
    expect(find.text('角色记忆文档'), findsOneWidget);
    expect(find.text('跟随默认 · 空预设'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('默认只有酒馆，在管理开启的插件里逐项开启后加入、关闭后移除', (tester) async {
    await tester.pumpWidget(const _TestApp(initialPluginIds: {}));
    await tester.pumpAndSettle();

    final host = tester.state<_TestAppState>(find.byType(_TestApp));
    expect(find.byKey(const ValueKey('enabled-plugin-tavern')), findsOneWidget);
    expect(find.byKey(const ValueKey('enabled-plugin-tts')), findsNothing);

    await tester.ensureVisible(find.text('管理开启的插件'));
    await tester.tap(find.text('管理开启的插件'));
    await tester.pumpAndSettle();
    // 酒馆没有按角色开关，不进入管理列表
    expect(find.byKey(const ValueKey('all-plugins-tavern')), findsNothing);
    final ttsRow = find.byKey(const ValueKey('all-plugins-tts'));
    await tester.ensureVisible(ttsRow);
    await tester.tap(ttsRow);
    await tester.pumpAndSettle();

    expect(host.selectedPluginIds, {'tts'});
    // 管理列表行与已开启列表行等高（音色排在酒馆前，两者都带分割线）
    expect(
      tester.getSize(find.byKey(const ValueKey('all-plugins-image'))).height,
      tester.getSize(find.byKey(const ValueKey('enabled-plugin-tts'))).height,
    );
    expect(find.byKey(const ValueKey('enabled-plugin-tts')), findsOneWidget);
    expect(find.text('跟随默认音色配置包'), findsOneWidget);

    await tester.tap(ttsRow);
    await tester.pumpAndSettle();
    expect(host.selectedPluginIds, isEmpty);
    expect(find.byKey(const ValueKey('enabled-plugin-tts')), findsNothing);
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
  final Set<String>? initialPluginIds;

  const _TestApp({this.initialPluginIds});

  @override
  State<_TestApp> createState() => _TestAppState();
}

class _TestAppState extends State<_TestApp> {
  late Set<String> selectedPluginIds =
      widget.initialPluginIds ??
      {for (final item in conversationScopedChatPluginItems) item.id};
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
