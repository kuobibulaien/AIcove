import 'package:flutter/material.dart';
import 'package:aicove_flutter/src/features/agent_context/providers/preset_recipe_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/ui/features/character/pages/contact_edit_page.dart';
import 'package:aicove_flutter/src/ui/features/character/services/contact_edit_snapshot_store.dart';

void main() {
  for (final hasImage in [false, true]) {
    for (final size in [const Size(320, 568), const Size(1000, 768)]) {
      for (final scale in [1.2, 1.8]) {
        testWidgets('contact edit size=$size scale=$scale hasImage=$hasImage',
            (tester) async {
          SharedPreferences.setMockInitialValues({});
          await tester.binding.setSurfaceSize(size);
          addTearDown(() => tester.binding.setSurfaceSize(null));
          final conversation = Conversation(
              id: 'audit',
              characterImage: hasImage
                  ? 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO7Z0ioAAAAASUVORK5CYII='
                  : null,
              title: 'Synthetic',
              displayName: 'Synthetic',
              createdAt: DateTime(2026, 9, 6),
              updatedAt: DateTime(2026, 9, 6));
          await tester.pumpWidget(ProviderScope(
              overrides: [
                presetRecipeListProvider
                    .overrideWith((ref) async => const <PresetRecipeSummary>[])
              ],
              child: MaterialApp(
                builder: (context, child) => MediaQuery(
                    data: MediaQuery.of(context)
                        .copyWith(textScaler: TextScaler.linear(scale)),
                    child: child!),
                home: ContactEditPage(
                    conversation: conversation,
                    initialSnapshot:
                        ContactEditSnapshot.fromConversation(conversation)),
              )));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          final scroll = find.byType(Scrollable).first;
          await tester.drag(scroll, const Offset(0, -3000));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        });
      }
    }
  }
}
