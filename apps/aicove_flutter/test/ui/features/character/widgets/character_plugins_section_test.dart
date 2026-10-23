import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:aicove_flutter/src/features/agent_context/domain/tavern_compatibility_port.dart';
import 'package:aicove_flutter/src/features/agent_context/providers/preset_recipe_provider.dart';
import 'package:aicove_flutter/src/features/stickers/sticker_library.dart';
import 'package:aicove_flutter/src/features/stickers/sticker_library_provider.dart';
import 'package:aicove_flutter/src/features/stickers/sticker_pack_grants.dart';
import 'package:aicove_flutter/src/features/workspace/domain/workspace_grants.dart';
import 'package:aicove_flutter/src/features/workspace/domain/workspace_models.dart';
import 'package:aicove_flutter/src/features/workspace/workspace_providers.dart';
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

    // 只有已开启插件列表一个容器，「管理插件」是它的末行
    expect(find.byType(MoeSettingsGroup), findsOneWidget);
    expect(find.text('已开启插件'), findsNothing);
    expect(
      find.descendant(
        of: find.byType(MoeSettingsGroup),
        matching: find.byKey(const ValueKey('manage-plugins')),
      ),
      findsOneWidget,
    );
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
    // 插件行都带分割线，每行等高
    final heights = {for (final row in rows) tester.getSize(row).height};
    expect(heights, hasLength(1));
    // 管理弹窗未打开，上方列表不出现开关
    expect(find.byType(Switch), findsNothing);

    // 跟随默认写「默认」，不再标渠道状态；只有联网搜索标「未配置」。
    expect(find.text('默认'), findsNWidgets(3), reason: '音色、生图、酒馆');
    expect(find.text('未配置'), findsOneWidget, reason: '联网搜索');
    expect(find.text('角色记忆文档'), findsNothing);
    expect(find.textContaining('跟随默认'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('音色、生图跟随默认只写「默认」，联网搜索没服务标「未配置」', (tester) async {
    await tester.pumpWidget(const _TestApp());
    await tester.pumpAndSettle();
    String trailingOf(String id) => tester
        .widgetList<Text>(
          find.descendant(
            of: find.byKey(ValueKey('enabled-plugin-$id')),
            matching: find.byType(Text),
          ),
        )
        .map((t) => t.data)
        .join('|');
    // 测试环境没有生图、语音、搜索渠道。
    expect(trailingOf('image'), '生图|默认');
    expect(trailingOf('tts'), '音色|默认');
    expect(trailingOf('web_search'), contains('未配置'));
    expect(trailingOf('time_awareness'), '时间感知|');
    expect(trailingOf('memory'), '记忆|');
    // 有设置页的插件都带箭头，可直接跳转。
    for (final id in [
      'sticker',
      'trigger',
      'time_awareness',
      'web_search',
      'workspaces',
    ]) {
      expect(
        find.descendant(
          of: find.byKey(ValueKey('enabled-plugin-$id')),
          matching: find.byIcon(Icons.chevron_right),
        ),
        findsOneWidget,
        reason: id,
      );
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('工作空间一行常驻，点开逐个授权；内置空间常开', (tester) async {
    WorkspaceInfo space(String id, String name) => WorkspaceInfo(
      id: id,
      name: name,
      description: '',
      createdAt: DateTime(2026, 10, 21),
    );
    await tester.pumpWidget(
      _TestApp(
        initialPluginIds: const {},
        workspaces: [space(defaultWorkspaceId, 'AIcove'), space('b', '画册')],
        builtInWorkspaceIds: const {defaultWorkspaceId},
      ),
    );
    await tester.pumpAndSettle();

    final builtIn = WorkspaceGrants.pluginIdOf(defaultWorkspaceId);
    final other = WorkspaceGrants.pluginIdOf('b');
    final row = find.byKey(const ValueKey('enabled-plugin-workspaces'));
    expect(row, findsOneWidget);
    expect(find.textContaining('空间 ·'), findsNothing);
    expect(
      find.descendant(of: row, matching: find.text('AIcove')),
      findsOneWidget,
    );

    // 管理插件里不再列空间。
    await tester.ensureVisible(find.text('管理插件'));
    await tester.tap(find.text('管理插件'));
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('all-plugins-$other')), findsNothing);
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(row);
    await tester.tap(row);
    await tester.pumpAndSettle();
    final host = tester.state<_TestAppState>(find.byType(_TestApp));
    await tester.tap(find.byKey(ValueKey('all-plugins-$builtIn')));
    await tester.pumpAndSettle();
    expect(host.selectedPluginIds, isEmpty, reason: '内置空间不能关');
    await tester.tap(find.byKey(ValueKey('all-plugins-$other')));
    await tester.pumpAndSettle();
    expect(host.selectedPluginIds, {other});
    expect(
      find.descendant(of: row, matching: find.text('AIcove、画册')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('表情包一行点开选这个角色能用的套组，不再直接跳表情库', (tester) async {
    const packs = [
      StickerPack(id: 'a', name: '猫猫', stickers: []),
      StickerPack(id: 'b', name: '狗狗', stickers: []),
      StickerPack(id: 'c', name: '旧图', stickers: [], enabled: false),
    ];
    await tester.pumpWidget(
      const _TestApp(initialPluginIds: {'sticker'}, stickerPacks: packs),
    );
    await tester.pumpAndSettle();
    final host = tester.state<_TestAppState>(find.byType(_TestApp));
    final row = find.byKey(const ValueKey('enabled-plugin-sticker'));
    expect(find.descendant(of: row, matching: find.text('全部套组')),
        findsOneWidget);

    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(find.text('表情包套组'), findsOneWidget);
    expect(find.text('旧图（已停用）'), findsOneWidget);
    expect(find.text('管理表情包'), findsOneWidget);

    // 全部模式下关掉一个，等于显式选其余的
    await tester.tap(
      find.byKey(ValueKey('all-plugins-${StickerPackGrants.pluginIdOf('b')}')),
    );
    await tester.pumpAndSettle();
    expect(host.selectedPluginIds, {
      'sticker',
      StickerPackGrants.pluginIdOf('a'),
      StickerPackGrants.pluginIdOf('c'),
    });
    await tester.tap(
      find.byKey(ValueKey('all-plugins-${StickerPackGrants.pluginIdOf('c')}')),
    );
    await tester.pumpAndSettle();
    // 最后一个不能关
    await tester.tap(
      find.byKey(ValueKey('all-plugins-${StickerPackGrants.pluginIdOf('a')}')),
    );
    await tester.pumpAndSettle();
    expect(host.selectedPluginIds, {
      'sticker',
      StickerPackGrants.pluginIdOf('a'),
    });
    await tester.pump(const Duration(seconds: 3));

    // 打开「全部套组」清掉所有套组授权
    await tester.tap(find.byKey(const ValueKey('all-plugins-sticker-all')));
    await tester.pumpAndSettle();
    expect(host.selectedPluginIds, {'sticker'});
    await tester.tap(find.byKey(const ValueKey('all-plugins-sticker-all')));
    await tester.pumpAndSettle();
    expect(StickerPackGrants.of(host.selectedPluginIds), {'a', 'b', 'c'});
    await tester.tap(
      find.byKey(ValueKey('all-plugins-${StickerPackGrants.pluginIdOf('a')}')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    expect(find.descendant(of: row, matching: find.text('狗狗、旧图')),
        findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('默认只有酒馆，在管理插件弹窗里逐项开启后加入、关闭后移除', (tester) async {
    await tester.pumpWidget(const _TestApp(initialPluginIds: {}));
    await tester.pumpAndSettle();

    final host = tester.state<_TestAppState>(find.byType(_TestApp));
    expect(find.byKey(const ValueKey('enabled-plugin-tavern')), findsOneWidget);
    expect(find.byKey(const ValueKey('enabled-plugin-tts')), findsNothing);

    await tester.ensureVisible(find.text('管理插件'));
    await tester.tap(find.text('管理插件'));
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
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('enabled-plugin-tts')),
        matching: find.text('默认'),
      ),
      findsOneWidget,
    );

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
  final List<WorkspaceInfo> workspaces;
  final Set<String> builtInWorkspaceIds;
  final List<StickerPack> stickerPacks;

  const _TestApp({
    this.initialPluginIds,
    this.workspaces = const [],
    this.builtInWorkspaceIds = const {},
    this.stickerPacks = const [],
  });

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
        workspacesProvider.overrideWith((ref) async => widget.workspaces),
        stickerLibraryProvider.overrideWith(
          () => _FakeStickerLibrary(widget.stickerPacks),
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
              builtInWorkspaceIds: widget.builtInWorkspaceIds,
            ),
          ),
        ),
      ),
    );
  }
}

class _FakeStickerLibrary extends StickerLibraryNotifier {
  _FakeStickerLibrary(this.packs);
  final List<StickerPack> packs;

  @override
  Future<List<StickerPack>> build() async => packs;
}
