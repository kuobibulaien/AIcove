import 'package:aicove_flutter/src/features/backup/backup_providers.dart';
import 'package:aicove_flutter/src/features/backup/data/conversation_exporter.dart';
import 'package:aicove_flutter/src/features/backup/models/export_format.dart';
import 'package:aicove_flutter/src/features/chat/conversation_providers.dart';
import 'package:aicove_flutter/src/features/agent_context/providers/preset_recipe_provider.dart';
import 'package:aicove_flutter/src/features/chat/domain/chat_display_policy.dart';
import 'package:aicove_flutter/src/features/assistant/domain/assistant_onboarding.dart'
    show kAicoveAssistantId;
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/features/chat/domain/persona_prompt_codec.dart';
import 'package:aicove_flutter/src/features/chat/domain/role_agent_mode.dart';
import 'package:aicove_flutter/src/ui/features/character/pages/contact_edit_page.dart';
import 'package:aicove_flutter/src/ui/features/character/pages/role_extra_prompt_page.dart';
import 'package:aicove_flutter/src/ui/features/character/services/contact_edit_snapshot_store.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/moe_app_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

class _Roles extends ConversationsNotifier {
  _Roles(this.initial);
  final Conversation initial;
  @override
  Future<List<Conversation>> build() async => [initial];
  @override
  Future<String> createNew({ChatDisplayStyle? chatDisplayStyle}) async {
    final created = initial.copyWith(
      id: 'created',
      chatDisplayStyle: chatDisplayStyle,
    );
    state = AsyncData([created, ...await future]);
    return created.id;
  }

  @override
  Future<void> updateOne(String id, Conversation Function(Conversation) fn,
      {bool persist = true}) async {
    state = AsyncData([
      for (final role in state.requireValue)
        if (role.id == id) fn(role) else role
    ]);
  }
}

class _FakeExporter implements ConversationExporter {
  List<String>? ids;
  ExportOptions? options;

  @override
  Future<ExportResult> exportConversations({
    required List<String> conversationIds,
    ExportOptions options = const ExportOptions(),
    void Function(ExportProgress)? onProgress,
  }) async {
    ids = conversationIds;
    this.options = options;
    return const ExportResult(
      filePath: '/tmp/role.zip',
      fileName: 'role.zip',
      conversationCount: 1,
      messageCount: 0,
      fileCount: 0,
      sizeBytes: 2048,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  Conversation buildConversation({String? characterImage}) {
    final now = DateTime(2026, 3, 20);
    return Conversation(
      id: 'conv_1',
      title: 'Test',
      displayName: '测试角色',
      characterImage: characterImage,
      createdAt: now,
      updatedAt: now,
    );
  }

  testWidgets('角色编辑页轻壳显示标题栏且无需保存入口', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: ContactEditPage(
            conversation: buildConversation(
              characterImage: 'assets/characters/images/nahida.jpg',
            ),
            editMode: EditMode.editConversation,
          ),
        ),
      ),
    );

    expect(find.text('正在准备编辑界面'), findsOneWidget);
    expect(_headerNameField(), findsOneWidget);
    expect(find.byTooltip('保存'), findsNothing);
    expect(find.text('角色描述'), findsNothing);

    await tester.pump(const Duration(milliseconds: 450));
    await tester.pump();

    expect(find.text('正在准备编辑界面'), findsNothing);
    expect(find.text('角色描述'), findsNothing);
    expect(find.text('壁纸'), findsNothing);
    expect(find.text('管理插件'), findsOneWidget);
  });

  testWidgets('角色编辑页命中持久快照后首帧直接显示完整表单', (tester) async {
    final conversation = buildConversation(
      characterImage: 'assets/characters/images/nahida.jpg',
    ).copyWith(
      description: '来自快照的简介',
      selfAddress: '纳西妲',
      addressUser: '旅行者',
      personaPrompt: '温柔，聪明，善于倾听。',
      enabledPlugins: const ['imageGeneration'],
    );

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: ContactEditPage(
            conversation: conversation,
            initialSnapshot: ContactEditSnapshot.fromConversation(conversation),
            editMode: EditMode.editConversation,
          ),
        ),
      ),
    );

    expect(find.text('正在准备编辑界面'), findsNothing);
    expect(find.text('角色描述'), findsNothing);
    expect(_headerNameField(), findsOneWidget);
    expect(find.text('壁纸'), findsNothing);
    expect(find.text('管理插件'), findsOneWidget);

    // 提示词卡片只有「角色提示词」「附加提示词」两行，生图偏好并入附加提示词页。
    await tester.ensureVisible(find.text('角色提示词'));
    expect(find.text('角色卡信息'), findsNothing);
    expect(find.text('附加提示词'), findsOneWidget);
    expect(find.text('生图偏好'), findsNothing);
    expect(find.text('温柔，聪明，善于倾听。'), findsNothing);
  });

  testWidgets('更多菜单可直接导出当前角色卡，也可进入导入', (tester) async {
    final conversation = buildConversation();
    final exporter = _FakeExporter();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          conversationsProvider.overrideWith(() => _Roles(conversation)),
          conversationExporterProvider.overrideWithValue(exporter),
        ],
        child: MaterialApp(
          home: ContactEditPage(
            conversation: conversation,
            initialSnapshot: ContactEditSnapshot.fromConversation(conversation),
            editMode: EditMode.editConversation,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    expect(find.text('导入角色卡'), findsOneWidget);
    await tester.tap(find.text('导出角色卡'));
    await tester.pumpAndSettle();

    expect(exporter.ids, ['conv_1']);
    expect(exporter.options?.scopes, [SyncScope.characterCards]);
    expect(find.text('导出成功'), findsOneWidget);
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('导入角色卡'));
    await tester.pumpAndSettle();
    expect(find.text('点击选择文件'), findsOneWidget);

    // 导入合并到当前角色后返回：编辑页应换成新数据，而不是留着旧表单。
    final container =
        ProviderScope.containerOf(tester.element(find.text('点击选择文件')));
    await container
        .read(conversationsProvider.notifier)
        .updateOne('conv_1', (c) => c.copyWith(displayName: '导入后的角色'));
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pumpAndSettle();

    final name = tester.widget<TextField>(_headerNameField());
    expect(name.controller?.text, '导入后的角色');
  });

  testWidgets('切换酒馆预设后无需确认即可自动保存', (tester) async {
    final conversation = buildConversation();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          conversationsProvider.overrideWith(() => _Roles(conversation)),
          presetRecipeListProvider.overrideWith(
            (ref) async => const <PresetRecipeSummary>[
              PresetRecipeSummary(
                id: 'st_preset_aaaaaaaaaaaaaaaaaaaaaaaa',
                name: '酒馆测试预设',
                description: '4 个启用节点 · 顺序组 1',
              ),
            ],
          ),
        ],
        child: MaterialApp(
          home: ContactEditPage(
            conversation: conversation,
            initialSnapshot: ContactEditSnapshot.fromConversation(conversation),
            editMode: EditMode.editConversation,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('enabled-plugin-tavern')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await Scrollable.ensureVisible(
      tester.element(find.byKey(const ValueKey('enabled-plugin-tavern'))),
      alignment: 0.5,
    );
    await tester.pumpAndSettle();
    // 跟随默认时行尾不写字，点整行打开选择。
    await tester.tap(find.byKey(const ValueKey('enabled-plugin-tavern')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('酒馆测试预设'));
    await tester.pumpAndSettle();

    expect(find.text('酒馆测试预设'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    final container =
        ProviderScope.containerOf(tester.element(find.byType(ContactEditPage)));
    expect(container.read(conversationsProvider).requireValue.single.recipeId,
        'st_preset_aaaaaaaaaaaaaaaaaaaaaaaa');
    expect(find.text('退出编辑'), findsNothing);
  });

  testWidgets('保存角色时保留本机没有的工作区授权', (tester) async {
    final conversation = buildConversation().copyWith(
      enabledPlugins: const ['imageGeneration', 'workspace:not-on-this-device'],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          conversationsProvider.overrideWith(() => _Roles(conversation)),
          presetRecipeListProvider.overrideWith(
            (ref) async => const <PresetRecipeSummary>[
              PresetRecipeSummary(
                id: 'st_preset_aaaaaaaaaaaaaaaaaaaaaaaa',
                name: '酒馆测试预设',
                description: '',
              ),
            ],
          ),
        ],
        child: MaterialApp(
          home: ContactEditPage(
            conversation: conversation,
            initialSnapshot: ContactEditSnapshot.fromConversation(conversation),
            editMode: EditMode.editConversation,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('enabled-plugin-tavern')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await Scrollable.ensureVisible(
      tester.element(find.byKey(const ValueKey('enabled-plugin-tavern'))),
      alignment: 0.5,
    );
    await tester.pumpAndSettle();
    // 跟随默认时行尾不写字，点整行打开选择。
    await tester.tap(find.byKey(const ValueKey('enabled-plugin-tavern')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('酒馆测试预设'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    final container =
        ProviderScope.containerOf(tester.element(find.byType(ContactEditPage)));
    final saved = container.read(conversationsProvider).requireValue.single;
    expect(saved.recipeId, 'st_preset_aaaaaaaaaaaaaaaaaaaaaaaa');
    expect(saved.enabledPlugins, contains('workspace:not-on-this-device'));
  });
  testWidgets('AIcove酱 系统提示词只读，附加提示词可编辑并单独保存', (tester) async {
    final conversation = buildConversation().copyWith(
      id: kAicoveAssistantId,
      personaPrompt: PersonaPromptCodec.compose(
        userPrompt: '内置系统提示词',
        extraPrompt: '旧附加',
      ),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          conversationsProvider.overrideWith(() => _Roles(conversation)),
          presetRecipeListProvider.overrideWith(
            (ref) async => const <PresetRecipeSummary>[],
          ),
        ],
        child: MaterialApp(
          home: ContactEditPage(
            conversation: conversation,
            initialSnapshot: ContactEditSnapshot.fromConversation(conversation),
            editMode: EditMode.editConversation,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('角色提示词'), findsNothing);
    await tester.ensureVisible(find.text('系统提示词'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('系统提示词'));
    await tester.pumpAndSettle();
    final systemField = tester.widget<TextField>(
      find.widgetWithText(TextField, '内置系统提示词'),
    );
    expect(systemField.readOnly, isTrue);
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('附加提示词'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, '旧附加'),
      '新附加',
    );
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();

    final container =
        ProviderScope.containerOf(tester.element(find.byType(ContactEditPage)));
    final saved = PersonaPromptCodec.parse(
      container.read(conversationsProvider).requireValue.single.personaPrompt,
    );
    expect(saved.userPrompt, '内置系统提示词');
    expect(saved.extraPrompt, '新附加');
  });

  testWidgets('普通角色可独立编辑附加提示词与生图偏好', (tester) async {
    final conversation = buildConversation().copyWith(
      personaPrompt: PersonaPromptCodec.compose(
        userPrompt: '基础角色设定',
        customDrawingPrompt: '白发绿瞳',
      ),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          conversationsProvider.overrideWith(() => _Roles(conversation)),
          presetRecipeListProvider.overrideWith(
            (ref) async => const <PresetRecipeSummary>[],
          ),
        ],
        child: MaterialApp(
          home: ContactEditPage(
            conversation: conversation,
            initialSnapshot: ContactEditSnapshot.fromConversation(conversation),
            editMode: EditMode.editConversation,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('附加提示词'));
    await tester.tap(find.text('附加提示词'));
    await tester.pumpAndSettle();
    final pageFields = find.descendant(
      of: find.byType(RoleExtraPromptPage),
      matching: find.byType(TextField),
    );
    await tester.enterText(pageFields.first, '今天心情很好');
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, '白发绿瞳'), findsOneWidget);

    await tester.ensureVisible(find.text('NovelAI 分镜漫画'));
    await tester.tap(find.text('NovelAI 分镜漫画'));
    await tester.pumpAndSettle();
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();

    final container =
        ProviderScope.containerOf(tester.element(find.byType(ContactEditPage)));
    final saved = PersonaPromptCodec.parse(
      container.read(conversationsProvider).requireValue.single.personaPrompt,
    );
    expect(saved.userPrompt, '基础角色设定');
    expect(saved.extraPrompt, '今天心情很好');
    expect(saved.customDrawingPrompt, '白发绿瞳');
    expect(saved.drawingPromptPackId, 'builtin.image.novelai_manga');
  });

  for (final (mode, label, style) in [
    (RoleAgentMode.chat, '纯聊天', ChatDisplayStyle.bubble),
    (RoleAgentMode.tool, '工具', ChatDisplayStyle.document),
    (RoleAgentMode.agent, '智能体', ChatDisplayStyle.bubble),
  ]) {
    testWidgets('以$label模式创建角色默认用${style.name}样式', (tester) async {
      final draft = buildConversation().copyWith(id: 'new_conv');
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) =>
                ContactEditPage(conversation: draft, editMode: EditMode.create),
          ),
          GoRoute(path: '/chat/:id', builder: (_, _) => const Text('chat')),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            conversationsProvider.overrideWith(() => _Roles(draft)),
            presetRecipeListProvider.overrideWith(
              (ref) async => const <PresetRecipeSummary>[],
            ),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();

      if (mode != RoleAgentMode.chat) {
        await tester.ensureVisible(find.text(label));
        await tester.tap(find.text(label));
        await tester.pumpAndSettle();
      }
      final container = ProviderScope.containerOf(
        tester.element(find.byType(ContactEditPage)),
      );
      await tester.tap(find.byTooltip('创建角色'));
      await tester.pumpAndSettle();
      final created = container
          .read(conversationsProvider)
          .requireValue
          .firstWhere((c) => c.id == 'created');
      expect(created.effectiveAgentMode, mode);
      expect(created.chatDisplayStyle, style);
    });
  }
}

Finder _headerNameField() => find.descendant(
  of: find.byType(MoeAppBar),
  matching: find.byType(TextField),
);
