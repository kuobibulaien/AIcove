import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/ui/features/character/pages/contact_edit_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Conversation buildConversation() {
    final now = DateTime(2026, 3, 20);
    return Conversation(
      id: 'conv_1',
      title: 'Test',
      displayName: '测试角色',
      createdAt: now,
      updatedAt: now,
    );
  }

  testWidgets('角色编辑页在转场期先显示轻壳，再挂载完整编辑内容', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: ContactEditPage(
            conversation: buildConversation(),
            editMode: EditMode.editConversation,
          ),
        ),
      ),
    );

    expect(find.text('正在准备编辑界面'), findsOneWidget);
    expect(find.text('角色描述'), findsNothing);

    await tester.pump(const Duration(milliseconds: 450));
    await tester.pump();

    expect(find.text('正在准备编辑界面'), findsNothing);
    expect(find.text('角色描述'), findsOneWidget);
  });
}
