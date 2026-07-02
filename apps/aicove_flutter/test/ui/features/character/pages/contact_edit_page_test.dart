import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/ui/features/character/pages/contact_edit_page.dart';
import 'package:aicove_flutter/src/ui/features/character/services/contact_edit_snapshot_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

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

  testWidgets('角色编辑页在轻壳阶段也会立刻显示静态模糊背景', (tester) async {
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
    expect(
      find.byKey(const ValueKey('asset:assets/characters/images/nahida_blur.jpg')),
      findsOneWidget,
    );
    expect(find.text('角色描述'), findsNothing);

    await tester.pump(const Duration(milliseconds: 450));
    await tester.pump();

    expect(find.text('正在准备编辑界面'), findsNothing);
    expect(find.text('角色描述'), findsOneWidget);
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
    expect(find.text('角色描述'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('asset:assets/characters/images/nahida_blur.jpg')),
      findsOneWidget,
    );
  });
}
