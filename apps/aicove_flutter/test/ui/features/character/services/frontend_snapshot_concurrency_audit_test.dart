import 'dart:io';

import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/ui/features/character/services/contact_edit_snapshot_store.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  const channel = MethodChannel('plugins.flutter.io/path_provider');

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('contact_edit_snapshot_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getApplicationDocumentsDirectory') {
        return tempDir.path;
      }
      return null;
    });
    await ContactEditSnapshotStore.instance.clearMemory();
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await ContactEditSnapshotStore.instance.clearMemory();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  Conversation buildConversation({
    required DateTime updatedAt,
    String description = '旧简介',
  }) {
    return Conversation(
      id: 'conv_1',
      title: 'Test',
      displayName: '测试角色',
      characterImage: 'assets/characters/images/nahida.jpg',
      description: description,
      personaPrompt: '温柔，聪明，善于倾听。',
      enabledPlugins: const ['imageGeneration'],
      createdAt: DateTime(2026, 4, 23, 10, 0),
      updatedAt: updatedAt,
    );
  }

  test('overlapping snapshot writes complete without temporary file collisions',
      () async {
    final conversation = buildConversation(updatedAt: DateTime(2026, 9, 6));
    final store = ContactEditSnapshotStore.instance;
    await store.writeFromConversation(conversation);
    final failures = <Object>[];
    await Future.wait(List.generate(8, (_) async {
      try {
        await store.writeFromConversation(conversation);
      } catch (error) {
        failures.add(error);
      }
    }));
    await store.clearMemory();
    final restored = await store.readFreshForConversation(conversation);
    expect(failures, isEmpty,
        reason:
            'simultaneous requests must not collide on one shared .tmp path');
    expect(restored?.displayName, conversation.displayName);
  });
}
