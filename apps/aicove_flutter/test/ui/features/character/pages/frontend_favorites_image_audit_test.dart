import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/features/chat/conversation_providers.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/ui/features/character/pages/favorites_page.dart';
import 'package:aicove_flutter/src/ui/shared/effects/frosted_glass_card.dart';

class AuditFavorites extends ConversationsNotifier {
  @override
  Future<List<Conversation>> build() async => [
        Conversation(
          id: 'synthetic',
          title: 'Synthetic',
          displayName: 'Synthetic',
          isFavorite: true,
          characterImage: 'https://example.invalid/portrait.png',
          createdAt: DateTime(2026, 9, 6),
          updatedAt: DateTime(2026, 9, 6),
        )
      ];
}

void main() {
  testWidgets('favorite remote portrait is not treated as a bundled asset',
      (tester) async {
    await tester.pumpWidget(ProviderScope(overrides: [
      conversationsProvider.overrideWith(AuditFavorites.new),
    ], child: const MaterialApp(home: FavoritesPage())));
    await tester.pumpAndSettle();
    final card = tester.widget<FrostedGlassCard>(find.byType(FrostedGlassCard));
    expect(card.imageProvider, isNotNull);
    expect(card.imageProvider, isNot(isA<AssetImage>()));
    expect(tester.takeException(), isNull);
  });
}
