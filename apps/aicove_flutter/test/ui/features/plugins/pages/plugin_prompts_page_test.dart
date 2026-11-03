import 'dart:io';
import 'dart:ui' as ui;

import 'package:aicove_flutter/src/features/plugins/prompts/plugin_prompts.dart';
import 'package:aicove_flutter/src/features/plugins/prompts/prompt_pack_store.dart';
import 'package:aicove_flutter/src/ui/features/character/pages/role_extra_prompt_page.dart';
import 'package:aicove_flutter/src/ui/features/plugins/pages/plugin_prompts_page.dart';
import 'package:aicove_flutter/src/ui/features/plugins/pages/prompt_pack_pages.dart';
import 'package:aicove_flutter/src/ui/theme/skin_provider.dart';
import 'package:aicove_flutter/src/ui/theme/skins/moetalk_skin.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MemoryStore implements PluginPromptStore {
  _MemoryStore(this.saved);
  PluginPrompts saved;

  @override
  Future<PluginPrompts> load() async => saved;

  @override
  Future<void> save(PluginPrompts prompts) async => saved = prompts;
}

void main() {
  const capture = bool.fromEnvironment('WRITE_PLUGIN_PROMPTS_PREVIEW');

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<_MemoryStore> mount(
    WidgetTester tester, {
    double width = 400,
    double height = 1000,
    GlobalKey? boundary,
  }) async {
    tester.view.physicalSize = Size(width, height);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = _MemoryStore(
      const PluginPrompts().withText(PluginPromptSlot.sticker, '少发表情包，{tags}'),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [pluginPromptStoreProvider.overrideWithValue(store)],
        child: RepaintBoundary(
          key: boundary,
          child: SkinScope(
            skin: const MoeTalkSkin(),
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: ThemeData(
                fontFamily: capture ? 'Preview' : null,
                extensions: [MoeColors.light()],
              ),
              home: const PluginPromptsPage(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return store;
  }

  testWidgets('聚合中心展示语音与绘图提示词包及各插件提示词，点击进入编辑并自动保存与恢复默认', (tester) async {
    final store = await mount(tester, height: 1800);

    // 验证语音与绘图提示词包分组展示在聚合中心
    expect(find.text('语音提示词包'), findsOneWidget);
    expect(find.text('绘图提示词包'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('hub-import-pack-tts'), skipOffstage: false),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('hub-import-pack-image'), skipOffstage: false),
      findsOneWidget,
    );

    // 滚动到全局插件提示词分组
    final stickerRow = find.byKey(const ValueKey('prompt-slot-sticker'));
    await tester.scrollUntilVisible(stickerRow, 200);
    await tester.pumpAndSettle();
    expect(find.text('表情包说明'), findsOneWidget);
    expect(find.text('已修改'), findsWidgets);

    // 点击『当前时间提醒』进入编辑页并修改
    final timeRow = find.byKey(const ValueKey('prompt-slot-currentTime'));
    await tester.scrollUntilVisible(timeRow, 200);
    await tester.pumpAndSettle();
    await tester.tap(timeRow);
    await tester.pumpAndSettle();

    expect(find.byType(PluginPromptSlotEditorPage), findsOneWidget);
    await tester.enterText(find.byType(TextField), '此刻 {datetime}');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(store.saved.of(PluginPromptSlot.currentTime), '此刻 {datetime}');

    // 返回总控台，再进『表情包说明』点恢复默认
    await tester.pageBack();
    await tester.pumpAndSettle();

    await tester.tap(stickerRow);
    await tester.pumpAndSettle();
    expect(find.text('恢复默认'), findsOneWidget);
    await tester.tap(find.text('恢复默认'));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(store.saved.isDefault(PluginPromptSlot.sticker), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('生图方案详情页展示后处理方式，另存为自建包后可切换后处理方式', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        child: SkinScope(
          skin: const MoeTalkSkin(),
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData(extensions: [MoeColors.light()]),
            home: const PromptPackDetailPage(
              packId: 'builtin.image.novelai_manga',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('后处理：NovelAI 分镜解析'), findsOneWidget);
    expect(find.text('拆格定位与台词嵌字，并自动过滤单图冲突词'), findsOneWidget);

    final forkBtn = find.text('另存为新包');
    await tester.scrollUntilVisible(forkBtn, 200);
    await tester.pumpAndSettle();
    await tester.tap(forkBtn);
    await tester.pumpAndSettle();

    expect(find.text('后处理方式'), findsOneWidget);
    expect(find.text('NovelAI 分镜解析'), findsOneWidget);

    await tester.tap(find.text('NovelAI 分镜解析'));
    await tester.pumpAndSettle();
    expect(find.text('MOSS 多格排版'), findsOneWidget);
    expect(find.text('直接发送'), findsOneWidget);

    await tester.tap(find.text('MOSS 多格排版'));
    await tester.pumpAndSettle();
    expect(find.text('MOSS 多格排版'), findsOneWidget);
    expect(find.text('将版式暗号编译为多格坐标后发给工作流'), findsOneWidget);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(PromptPackDetailPage)),
    );
    final customPack = (await container.read(promptPackProvider.future))
        .library
        .custom
        .single;
    expect(customPack.postProcessor, 'moss_manga');
    expect(tester.takeException(), isNull);
  });

  testWidgets('post processor and role extra prompt preview capture', (
    tester,
  ) async {
    if (!capture) return;
    final flutterRoot =
        Platform.environment['FLUTTER_ROOT'] ??
        '${Platform.environment['HOME']}/dev-sdks/flutter-3.44.6';
    await tester.runAsync(() async {
      final loader = FontLoader('Preview')
        ..addFont(
          File(
            '/System/Library/Fonts/STHeiti Medium.ttc',
          ).readAsBytes().then(ByteData.sublistView),
        );
      await loader.load();
      final icons = FontLoader('MaterialIcons')
        ..addFont(
          File(
            '$flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
          ).readAsBytes().then(ByteData.sublistView),
        );
      await icons.load();
    });

    Future<void> savePng(GlobalKey key, String path) async {
      await tester.runAsync(() async {
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File(path);
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }

    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final key1 = GlobalKey();
    await tester.pumpWidget(
      ProviderScope(
        child: RepaintBoundary(
          key: key1,
          child: SkinScope(
            skin: const MoeTalkSkin(),
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: ThemeData(
                fontFamily: 'Preview',
                extensions: [MoeColors.light()],
              ),
              home: const PromptPackDetailPage(
                packId: 'builtin.image.novelai_manga',
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final forkBtn = find.text('另存为新包');
    await tester.scrollUntilVisible(forkBtn, 200);
    await tester.pumpAndSettle();
    await tester.tap(forkBtn);
    await tester.pumpAndSettle();
    await savePng(
      key1,
      '/home/kuobibulaien/.gemini/antigravity/brain/4609f3ae-3e50-42ea-a697-6271cadcc6da/prompt_pack_post_processor_preview.png',
    );

    final extraCtrl = TextEditingController(text: '日常保持温柔耐心的语气。');
    final drawCtrl = TextEditingController(
      text: '1girl, silver hair, green eyes',
    );
    addTearDown(extraCtrl.dispose);
    addTearDown(drawCtrl.dispose);

    final key2 = GlobalKey();
    await tester.pumpWidget(
      ProviderScope(
        key: UniqueKey(),
        child: RepaintBoundary(
          key: key2,
          child: SkinScope(
            skin: const MoeTalkSkin(),
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: ThemeData(
                fontFamily: 'Preview',
                extensions: [MoeColors.light()],
              ),
              home: RoleExtraPromptPage(
                extraPromptController: extraCtrl,
                extraPromptHint: '补充角色设定',
                drawingPromptController: drawCtrl,
                initialPackId: 'builtin.image.novelai_manga',
                drawingPersonaPrompt: '',
                onPackChanged: (_) {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('当前方案需配合 NovelAI 渠道的画风预设使用，请在角色编辑页切换画风预设。'),
      150,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await savePng(
      key2,
      '/home/kuobibulaien/.gemini/antigravity/brain/4609f3ae-3e50-42ea-a697-6271cadcc6da/role_extra_prompt_channel_hint_preview.png',
    );
  });

  testWidgets('plugin prompts source rendered preview', (tester) async {
    if (!capture) return;
    await tester.runAsync(() async {
      final loader = FontLoader('Preview')
        ..addFont(
          File(
            '/System/Library/Fonts/STHeiti Medium.ttc',
          ).readAsBytes().then(ByteData.sublistView),
        );
      await loader.load();
      final icons = FontLoader('MaterialIcons')
        ..addFont(
          File(
            '${Platform.environment['HOME']}/dev-sdks/flutter-3.44.6/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
          ).readAsBytes().then(ByteData.sublistView),
        );
      await icons.load();
    });

    Future<void> saveScreenshot(GlobalKey key, String filename) async {
      await tester.runAsync(() async {
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final dir = Directory(
          '/home/kuobibulaien/.gemini/antigravity/brain/8425a5fb-c5e7-4125-ad06-4957309e606c',
        )..createSync(recursive: true);
        await File(
          '${dir.path}/$filename',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }

    final key = GlobalKey();
    await mount(tester, width: 400, height: 920, boundary: key);
    await saveScreenshot(key, 'preview_plugin_prompts_hub_packs.png');

    // Scroll down to show global plugin prompts groups
    final lastRow = find.byKey(
      const ValueKey('prompt-slot-proactiveReachOutReminder'),
    );
    await tester.scrollUntilVisible(lastRow, 200);
    await tester.pumpAndSettle();
    await saveScreenshot(key, 'preview_plugin_prompts_hub_global.png');

    // Tap into a slot editor page
    final webSearchRow = find.byKey(
      const ValueKey('prompt-slot-webSearchTool'),
    );
    await tester.tap(webSearchRow);
    await tester.pumpAndSettle();
    await saveScreenshot(key, 'preview_plugin_prompts_slot_editor.png');
  });
}
