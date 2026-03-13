import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:aicove_flutter/src/core/database/database.dart';
import 'package:aicove_flutter/src/core/database/repositories/repositories.dart';
import 'package:aicove_flutter/src/features/backup/data/conversation_exporter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late ConversationRepository convRepo;
  late MessageRepository msgRepo;
  late MessageBlockRepository blockRepo;
  late Directory tempRoot;
  late Directory outputDir;
  late ConversationExporter exporter;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    convRepo = ConversationRepository(db);
    msgRepo = MessageRepository(db);
    blockRepo = MessageBlockRepository(db);

    tempRoot =
        await Directory.systemTemp.createTemp('conversation_exporter_test_');
    outputDir = Directory(p.join(tempRoot.path, 'out'));
    await outputDir.create(recursive: true);

    exporter = ConversationExporter(
      convRepo: convRepo,
      msgRepo: msgRepo,
      blockRepo: blockRepo,
      temporaryDirectoryResolver: () async => tempRoot,
      documentsDirectoryResolver: () async => outputDir,
      externalStorageDirectoryResolver: () async => outputDir,
      outputDirectoryResolver: () async => outputDir,
      appVersionResolver: () async => '1.0.0-test',
    );
  });

  tearDown(() async {
    await db.close();
    if (await tempRoot.exists()) {
      await tempRoot.delete(recursive: true);
    }
  });

  test('空 block data 不应导致导出失败', () async {
    const convId = 'conv_empty_block_data';
    const msgId = 'msg_empty_block_data';
    const blockId = 'blk_empty_block_data';
    final now = DateTime.now().millisecondsSinceEpoch;

    await convRepo.upsert(ConversationsCompanion.insert(
      id: convId,
      title: '角色',
      displayName: '角/色:*?<>|',
      personaPrompt: const Value('test'),
      createdAt: now,
      updatedAt: now,
    ));

    await msgRepo.insert(MessagesCompanion.insert(
      id: msgId,
      conversationId: convId,
      role: 'assistant',
      content: 'hello',
      createdAt: now,
    ));

    await blockRepo.insert(MessageBlocksCompanion.insert(
      id: blockId,
      messageId: msgId,
      type: 'image',
      data: '',
      createdAt: now,
    ));

    final result = await exporter.exportConversations(
      conversationIds: const [convId],
    );

    expect(await File(result.filePath).exists(), isTrue);
    expect(result.fileName.contains('/'), isFalse);
    expect(result.fileName.contains(':'), isFalse);
    expect(result.fileName.contains('*'), isFalse);

    final archive =
        ZipDecoder().decodeBytes(await File(result.filePath).readAsBytes());
    final messagesEntry =
        archive.files.firstWhere((f) => f.name == 'messages.json');
    final messagesJson =
        jsonDecode(utf8.decode(messagesEntry.content as List<int>))
            as Map<String, dynamic>;

    final messages = messagesJson['messages'] as List<dynamic>;
    expect(messages.length, 1);

    final blocks =
        (messages.first as Map<String, dynamic>)['blocks'] as List<dynamic>;
    final data =
        (blocks.first as Map<String, dynamic>)['data'] as Map<String, dynamic>;
    expect(data, isEmpty);
  });

  test('导出应包含会话全部消息，不应被50条限制截断', () async {
    const convId = 'conv_all_messages';
    final now = DateTime.now().millisecondsSinceEpoch;

    await convRepo.upsert(ConversationsCompanion.insert(
      id: convId,
      title: '全部消息',
      displayName: '全部消息',
      personaPrompt: const Value('test'),
      createdAt: now,
      updatedAt: now,
    ));

    for (var i = 0; i < 80; i++) {
      await msgRepo.insert(MessagesCompanion.insert(
        id: 'msg_all_$i',
        conversationId: convId,
        role: i.isEven ? 'user' : 'assistant',
        content: 'message_$i',
        createdAt: now + i,
      ));
    }

    final result = await exporter.exportConversations(
      conversationIds: const [convId],
    );

    final archive =
        ZipDecoder().decodeBytes(await File(result.filePath).readAsBytes());
    final messagesEntry =
        archive.files.firstWhere((f) => f.name == 'messages.json');
    final messagesJson =
        jsonDecode(utf8.decode(messagesEntry.content as List<int>))
            as Map<String, dynamic>;
    final messages = messagesJson['messages'] as List<dynamic>;

    expect(messages.length, 80);
  });

  test('导出应保留来源 id 供后续 merge 去重', () async {
    const convId = 'conv_source_ids';
    const msgId = 'msg_local_1';
    const blockId = 'blk_local_1';
    final now = DateTime.now().millisecondsSinceEpoch;

    await convRepo.upsert(ConversationsCompanion.insert(
      id: convId,
      title: '来源会话',
      displayName: '来源会话',
      personaPrompt: const Value('test'),
      createdAt: now,
      updatedAt: now,
    ));

    await msgRepo.insert(MessagesCompanion.insert(
      id: msgId,
      conversationId: convId,
      role: 'assistant',
      content: 'hello',
      createdAt: now,
      sourceMessageId: const Value('msg_source_1'),
    ));

    await blockRepo.insert(MessageBlocksCompanion.insert(
      id: blockId,
      messageId: msgId,
      type: 'mainText',
      data: jsonEncode(<String, dynamic>{
        'type': 'text',
        'messageId': msgId,
        'content': 'hello',
      }),
      createdAt: now,
      sourceBlockId: const Value('blk_source_1'),
    ));

    final result = await exporter.exportConversations(
      conversationIds: const <String>[convId],
    );

    final archive =
        ZipDecoder().decodeBytes(await File(result.filePath).readAsBytes());
    final messagesEntry =
        archive.files.firstWhere((f) => f.name == 'messages.json');
    final messagesJson =
        jsonDecode(utf8.decode(messagesEntry.content as List<int>))
            as Map<String, dynamic>;
    final messages = messagesJson['messages'] as List<dynamic>;

    expect(messages, hasLength(1));
    final message = messages.single as Map<String, dynamic>;
    expect(message['source_message_id'], 'msg_source_1');

    final blocks = message['blocks'] as List<dynamic>;
    expect(blocks, hasLength(1));
    expect(
      (blocks.single as Map<String, dynamic>)['source_block_id'],
      'blk_source_1',
    );
  });
}
