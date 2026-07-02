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

  test('角色编辑页快照会持久化到本地并可在清空内存后恢复', () async {
    final conversation = buildConversation(updatedAt: DateTime(2026, 4, 23, 10));

    await ContactEditSnapshotStore.instance.writeFromConversation(conversation);
    await ContactEditSnapshotStore.instance.clearMemory();

    final restored =
        await ContactEditSnapshotStore.instance.readFreshForConversation(
      conversation,
    );

    expect(restored, isNotNull);
    expect(restored!.displayName, '测试角色');
    expect(restored.description, '旧简介');
    expect(restored.characterImage, 'assets/characters/images/nahida.jpg');
  });

  test('角色数据更新后会刷新本地快照并覆盖旧内容', () async {
    final oldConversation =
        buildConversation(updatedAt: DateTime(2026, 4, 23, 10));
    final newConversation = buildConversation(
      updatedAt: DateTime(2026, 4, 23, 11),
      description: '新简介',
    );

    await ContactEditSnapshotStore.instance.writeFromConversation(
      oldConversation,
    );
    final prepared = await ContactEditSnapshotStore.instance
        .prepareFreshSnapshot(newConversation);
    await ContactEditSnapshotStore.instance.clearMemory();

    final restored =
        await ContactEditSnapshotStore.instance.readFreshForConversation(
      newConversation,
    );

    expect(prepared.description, '新简介');
    expect(restored, isNotNull);
    expect(restored!.description, '新简介');
    expect(restored.sourceUpdatedAtMs,
        newConversation.updatedAt.millisecondsSinceEpoch);
  });
}
