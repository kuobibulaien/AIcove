import 'package:aicove_flutter/src/features/chat/conversation_providers.dart';
import 'package:aicove_flutter/src/features/agent_context/providers/preset_recipe_provider.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/ui/features/character/pages/contact_edit_page.dart';
import 'package:aicove_flutter/src/ui/features/character/services/contact_edit_snapshot_store.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/moe_app_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _Roles extends ConversationsNotifier {
  _Roles(this.initial);
  final Conversation initial;
  @override
  Future<List<Conversation>> build() async => [initial];
  @override
  Future<void> updateOne(String id, Conversation Function(Conversation) fn,
      {bool persist = true}) async {
    state = AsyncData([
      for (final role in state.requireValue)
        if (role.id == id) fn(role) else role
    ]);
  }
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
    expect(find.text('已开启插件'), findsOneWidget);
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
    expect(find.text('已开启插件'), findsOneWidget);

    await tester.ensureVisible(find.text('角色卡信息'));
    await tester.tap(find.text('角色卡信息'));
    await tester.pumpAndSettle();
    expect(find.text('温柔，聪明，善于倾听。'), findsOneWidget);
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
      find.text('跟随默认 · 空预设'),
      500,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('跟随默认 · 空预设'));
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
}

Finder _headerNameField() => find.descendant(
  of: find.byType(MoeAppBar),
  matching: find.byType(TextField),
);
