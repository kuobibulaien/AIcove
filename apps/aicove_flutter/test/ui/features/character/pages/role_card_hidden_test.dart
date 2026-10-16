import 'package:aicove_flutter/src/features/chat/conversation_providers.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/ui/features/character/pages/role_card_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _Roles extends ConversationsNotifier {
  @override
  Future<List<Conversation>> build() async => [
    for (final (id, hidden) in [
      ('local-role', false),
      ('hidden-role', true),
      // A hidden materialized preset must not reappear from the preset list.
      ('preset_nahida', true),
    ])
      Conversation(
        id: id,
        title: id,
        displayName: id,
        isHidden: hidden,
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      ),
  ];
}

void main() {
  testWidgets('role directory leaves out privacy space roles', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [conversationsProvider.overrideWith(_Roles.new)],
        child: const MaterialApp(home: Scaffold(body: RoleCardContent())),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('role-directory-local-role')), findsOne);
    expect(
      find.byKey(const ValueKey('role-directory-hidden-role')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('role-directory-preset_nahida')),
      findsNothing,
    );
  });
}
