import 'dart:convert';
import 'package:aicove_flutter/src/ui/shared/animations/moe_menu_transition.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/meotalk_dialog.dart';
import 'package:aicove_flutter/src/features/chat/conversation_providers.dart';
import '../../../features/plugins/image/drawing_preset_delete_test.dart'
    show DrawingTestRoles, roleWithDrawing;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:aicove_flutter/src/features/plugins/image/drawing_preset.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/features/agent_context/providers/preset_recipe_provider.dart';
import 'package:aicove_flutter/src/features/chat/domain/persona_prompt_codec.dart';
import 'package:aicove_flutter/src/ui/features/character/pages/contact_edit_page.dart';
import 'package:aicove_flutter/src/features/plugins/image/drawing_preset_provider.dart';
import 'package:aicove_flutter/src/features/plugins/image/image_config.dart';
import 'package:aicove_flutter/src/ui/features/plugins/pages/drawing_preset_editor_page.dart';
import 'package:aicove_flutter/src/ui/features/plugins/pages/image_plugin_detail_page.dart';
import 'package:aicove_flutter/src/ui/features/plugins/pages/image_generation_test_page.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/form/moe_text_field.dart';
import '../../../features/plugins/image/drawing_preset_test.dart'
    show MemoryDrawingStore;

class _EditableRoles extends DrawingTestRoles {
  _EditableRoles(super.roles);
  @override
  Future<void> updateOne(
    String id,
    Conversation Function(Conversation) fn, {
    bool persist = true,
  }) async {
    state = AsyncData([
      for (final role in state.requireValue)
        if (role.id == id) fn(role) else role,
    ]);
  }
}

const _preset = DrawingPreset(
  id: 'stable-id',
  name: '角色A绘图',
  config: ImageConfig(
    selectedProviderId: 'nai',
    selectedModelId: 'nai:nai-diffusion-5-full',
  ),
);

void _seed() {
  SharedPreferences.setMockInitialValues({
    'aicove.ui_models.v1': jsonEncode({
      'providers': [
        {
          'id': 'nai',
          'displayName': '绘图渠道',
          'apiKeys': ['test-key'],
          'apiBaseUrl': 'https://invalid.example',
          'enabled': true,
          'models': ['nai-diffusion-5-full'],
          'visible_models': ['nai-diffusion-5-full'],
          'capabilities': ['image'],
          'custom_config': {'requestFormat': 'novelai'},
        },
      ],
      'model_types': {'nai:nai-diffusion-5-full': 'image'},
      'image_generation_enabled': true,
    }),
  });
}

MemoryDrawingStore _store() => MemoryDrawingStore(
  DrawingPresetCatalog(
    presets: [_preset],
    defaultPresetId: _preset.id,
    legacyConfig: const ImageConfig(),
  ),
);

Future<void> _mount(
  WidgetTester tester,
  MemoryDrawingStore store, {
  Size size = const Size(360, 800),
  double scale = 1.2,
  Widget? home,
  List<Conversation>? roles,
}) async {
  _seed();
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        drawingPresetStoreProvider.overrideWithValue(store),
        if (roles != null)
          conversationsProvider.overrideWith(() => _EditableRoles(roles)),
        presetRecipeListProvider.overrideWith((ref) async => const []),
      ],
      child: MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: home ?? const ImagePluginDetailPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _scrollTo(WidgetTester tester, Finder target) async {
  await tester.scrollUntilVisible(
    target,
    300,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'preset overflow uses shared menu and opens editor after closing',
    (tester) async {
      await _mount(tester, _store());
      await tester.tap(find.byKey(const ValueKey('preset-menu-stable-id')));
      await tester.pumpAndSettle();
      expect(find.byType(MoeMenuTransition), findsOneWidget);
      expect(
        find.byKey(const ValueKey('delete-drawing-stable-id')),
        findsOneWidget,
      );
      expect(find.text('设为默认'), findsNothing);
      await tester.tap(find.text('编辑'));
      await tester.pump();
      expect(find.byType(DrawingPresetEditorPage), findsNothing);
      await tester.pumpAndSettle();
      expect(find.byType(MoeMenuTransition), findsNothing);
      expect(find.byType(DrawingPresetEditorPage), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final width in [360.0, 1000.0]) {
    testWidgets('delete confirmation cancels then persists at width $width', (
      tester,
    ) async {
      final store = _store();
      store.catalog = store.catalog.upsert(
        const DrawingPreset(id: 'extra', name: '待清理绘图', config: ImageConfig()),
      );
      await _mount(
        tester,
        store,
        size: Size(width, 900),
        scale: 1.8,
        roles: [],
      );
      await tester.tap(find.text('待清理绘图'));
      await tester.pumpAndSettle();
      final delete = find.byKey(const ValueKey('delete-drawing-extra'));
      await _scrollTo(tester, delete);
      await tester.tap(delete);
      await tester.pumpAndSettle();
      expect(find.text('删除绘图预设？'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(store.catalog.presets.length, 2);
      await tester.tap(delete);
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(MeoTalkDialog),
          matching: find.text('删除'),
        ),
      );
      await tester.pumpAndSettle();
      expect(store.catalog.presets.length, 1);
      expect(find.text('待清理绘图'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(seconds: 4));
    });
  }

  for (final bound in [false, true]) {
    testWidgets('delete failure keeps card (bound=$bound)', (tester) async {
      final store = _store()..fail = !bound;
      store.catalog = store.catalog.upsert(
        const DrawingPreset(id: 'extra', name: '待清理绘图', config: ImageConfig()),
      );
      await _mount(
        tester,
        store,
        roles: [
          if (bound)
            roleWithDrawing(
              PersonaPromptCodec.compose(
                userPrompt: '',
                drawingPresetId: 'extra',
              ),
            ),
        ],
      );
      await tester.tap(find.text('待清理绘图'));
      await tester.pumpAndSettle();
      final delete = find.byKey(const ValueKey('delete-drawing-extra'));
      await _scrollTo(tester, delete);
      await tester.tap(delete);
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(MeoTalkDialog),
          matching: find.text('删除'),
        ),
      );
      await tester.pumpAndSettle();
      expect(store.catalog.presets.length, 2);
      expect(find.textContaining(bound ? '仍在使用' : 'disk full'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('待清理绘图'), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('default delete explains how to choose a replacement', (
    tester,
  ) async {
    final store = _store();
    await _mount(tester, store);
    await tester.tap(find.text('角色A绘图'));
    await tester.pumpAndSettle();
    await _scrollTo(tester, find.text('删除预设'));
    await tester.tap(find.text('删除预设'));
    await tester.pumpAndSettle();
    expect(find.textContaining('请先将其他预设设为默认'), findsOneWidget);
    expect(store.catalog.presets.length, 1);
    expect(find.text('删除绘图预设？'), findsNothing);
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('every drawing preset exposes a delete action', (tester) async {
    await _mount(tester, _store());
    await tester.tap(find.text('角色A绘图'));
    await tester.pumpAndSettle();
    await _scrollTo(tester, find.text('删除预设'));
    expect(find.text('删除预设'), findsOneWidget);
  });

  testWidgets(
    'role editor saves a single stable preset ID and preserves personal drawing requirements',
    (tester) async {
      final store = _store();
      store.catalog = store.catalog.upsert(
        const DrawingPreset(id: 'role-b', name: '另一套绘图', config: ImageConfig()),
      );
      final now = DateTime(2026, 9, 6);
      final conversation = Conversation(
        id: 'role',
        title: '角色',
        displayName: '角色',
        createdAt: now,
        updatedAt: now,
        personaPrompt: PersonaPromptCodec.compose(
          userPrompt: '温柔',
          customDrawingPrompt: '绿色眼睛',
        ),
      );
      await _mount(
        tester,
        store,
        roles: [conversation],
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              child: const Text('打开角色'),
              onPressed: () async {
                await Navigator.push<void>(
                  context,
                  MaterialPageRoute(
                    builder: (_) => ContactEditPage(conversation: conversation),
                  ),
                );
              },
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开角色'));
      await tester.pumpAndSettle();
      await _scrollTo(tester, find.text('绘图配置包'));
      await tester.tap(find.text('绘图配置包'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('另一套绘图'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(ContactEditPage)),
      );
      final saved = container.read(conversationsProvider).requireValue.single;
      final parts = PersonaPromptCodec.parse(saved.personaPrompt);
      expect(parts.drawingPresetId, 'role-b');
      expect(parts.userPrompt, '温柔');
      expect(parts.customDrawingPrompt, '绿色眼睛');
      expect(parts.drawingArtistPresetName, isNull);
      expect(parts.drawingToolPresetName, isNull);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'test page displays selected preset rather than legacy global settings',
    (tester) async {
      await _mount(
        tester,
        _store(),
        home: const ImageGenerationTestPage(
          drawingConfig: ImageConfig(
            selectedProviderId: 'nai',
            selectedModelId: 'nai:nai-diffusion-5-full',
            defaultWidth: 1024,
            defaultHeight: 768,
            defaultSteps: 35,
            defaultCount: 2,
          ),
        ),
      );
      expect(find.text('尺寸：1024 x 768  ·  步数：35  ·  张数：2'), findsOneWidget);
      expect(find.text('渠道：绘图渠道'), findsOneWidget);
    },
  );
  for (final size in [const Size(360, 800), const Size(1000, 900)]) {
    for (final scale in [1.2, 1.8]) {
      testWidgets('list/editor/advanced layout ${size.width} scale=$scale', (
        tester,
      ) async {
        await _mount(tester, _store(), size: size, scale: scale);
        expect(find.text('绘图预设'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('角色A绘图'));
        await tester.pumpAndSettle();
        expect(find.text('工具说明'), findsNothing);
        await _scrollTo(tester, find.text('高级'));
        await tester.tap(find.text('高级'));
        await tester.pumpAndSettle();
        await _scrollTo(tester, find.text('请求超时（5–600 秒）'));
        // 标签说明全局一份，预设不再携带提示词字段。
        expect(find.text('快速模式辅助提示词'), findsNothing);
        expect(find.text('正面提示词规范'), findsNothing);
        expect(tester.takeException(), isNull);
        expect(find.text('保存预设'), findsNothing);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('save preserves ID and reopening sees edits', (tester) async {
    final store = _store();
    await _mount(tester, store);
    await tester.tap(find.text('角色A绘图'));
    await tester.pumpAndSettle();
    final name = find.byWidgetPredicate(
      (w) => w is MoeTextField && w.label == '预设名称',
    );
    await tester.enterText(
      find.descendant(of: name, matching: find.byType(TextField)),
      '新的名字',
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(store.catalog.require('stable-id').name, '新的名字');
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('绘图预设'), findsOneWidget);
    await tester.tap(find.text('新的名字'));
    await tester.pumpAndSettle();
    expect(find.text('新的名字'), findsWidgets);
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'failed autosave retains edits and back never discards or confirms',
    (tester) async {
      final store = _store()..fail = true;
      await _mount(tester, store);
      await tester.tap(find.text('角色A绘图'));
      await tester.pumpAndSettle();
      final name = find.byWidgetPredicate(
        (w) => w is MoeTextField && w.label == '预设名称',
      );
      await tester.enterText(
        find.descendant(of: name, matching: find.byType(TextField)),
        '未保存',
      );
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      expect(store.catalog.require('stable-id').name, '角色A绘图');
      expect(find.textContaining('自动保存失败'), findsOneWidget);
      final context = tester.element(find.byType(DrawingPresetEditorPage));
      Navigator.of(context).maybePop();
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('未保存'), findsOneWidget);
      store.fail = false;
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(store.catalog.require('stable-id').name, '未保存');
      expect(find.byType(DrawingPresetEditorPage), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
