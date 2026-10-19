import 'package:aicove_flutter/src/core/database/database.dart';
import 'package:aicove_flutter/src/core/database/database_provider.dart';
import 'package:aicove_flutter/src/features/assistant/domain/assistant_onboarding.dart';
import 'package:aicove_flutter/src/features/chat/conversation_providers.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase database;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    database = AppDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() => database.close());

  ProviderContainer container() {
    final c = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(database)],
    );
    addTearDown(c.dispose);
    return c;
  }

  test(
    'a fresh install gets the pinned assistant next to the preset',
    () async {
      final list = await container().read(conversationsProvider.future);

      final assistant = list.firstWhere((c) => c.id == kAicoveAssistantId);
      expect(assistant.isPinned, isTrue);
      expect(assistant.displayName, 'AIcove 助手');
      expect(assistant.personaPrompt, contains('AIcove'));
      expect(list.map((c) => c.id), contains('preset_nahida'));
    },
  );

  test(
    'a deleted assistant stays deleted until restored from settings',
    () async {
      final first = container();
      await first.read(conversationsProvider.future);
      // Same trash write as deleting the contact in the app.
      await first
          .read(conversationRepositoryProvider)
          .softDelete(kAicoveAssistantId, 1, 2);

      final second = container();
      final relaunched = await second.read(conversationsProvider.future);
      expect(relaunched.map((c) => c.id), isNot(contains(kAicoveAssistantId)));

      final restored = await second
          .read(conversationsProvider.notifier)
          .restoreAssistant();
      expect(restored?.id, kAicoveAssistantId);
      final third = container();
      final afterRestore = await third.read(conversationsProvider.future);
      expect(afterRestore.map((c) => c.id), contains(kAicoveAssistantId));
    },
  );
}
