import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:aicove_flutter/src/core/database/database.dart';
import 'package:aicove_flutter/src/core/database/repositories/repositories.dart';
import 'package:aicove_flutter/src/features/backup/data/conversation_importer.dart';
import 'package:aicove_flutter/src/features/backup/models/export_format.dart'
    as backup;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late ConversationRepository convRepo;
  late MessageRepository msgRepo;
  late MessageBlockRepository blockRepo;
  late Directory tempRoot;
  late Directory appDocsDir;
  late ConversationImporter importer;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    convRepo = ConversationRepository(db);
    msgRepo = MessageRepository(db);
    blockRepo = MessageBlockRepository(db);

    tempRoot =
        await Directory.systemTemp.createTemp('conversation_importer_test_');
    appDocsDir = Directory(p.join(tempRoot.path, 'docs'));
    await appDocsDir.create(recursive: true);

    importer = ConversationImporter(
      convRepo: convRepo,
      msgRepo: msgRepo,
      blockRepo: blockRepo,
      temporaryDirectoryResolver: () async => tempRoot,
      documentsDirectoryResolver: () async => appDocsDir,
    );
  });

  tearDown(() async {
    await db.close();
    if (await tempRoot.exists()) {
      await tempRoot.delete(recursive: true);
    }
  });

  test('createNew 导入必须重写消息和 block 主键，并保留来源 id', () async {
    const convId = 'conv_existing';
    const now = 1710000000000;
    await convRepo.upsert(ConversationsCompanion.insert(
      id: convId,
      title: '旧会话',
      displayName: '旧会话',
      personaPrompt: const Value('persona'),
      createdAt: now,
      updatedAt: now,
    ));

    final archiveFile = await _buildImportArchive(
      tempRoot,
      conversations: <Map<String, dynamic>>[
        {
          'id': convId,
          'title': '导入会话',
          'display_name': '导入会话',
          'persona_prompt': 'persona',
          'created_at': now,
          'updated_at': now,
        },
      ],
      messages: <Map<String, dynamic>>[
        {
          'id': 'msg_src_1',
          'conversation_id': convId,
          'role': 'assistant',
          'content': 'hello',
          'status': 'sent',
          'created_at': now + 1,
          'blocks': <Map<String, dynamic>>[
            {
              'id': 'blk_src_1',
              'type': 'mainText',
              'status': 'success',
              'sort_order': 0,
              'data': <String, dynamic>{
                'type': 'text',
                'messageId': 'msg_src_1',
                'content': 'hello',
              },
            },
          ],
        },
      ],
    );

    final result = await importer.import(
      file: archiveFile,
      selectedScopes: const <String>[backup.SyncScope.chatHistory],
      selectedConversationIds: const <String>[convId],
      conflictResolutions: const <String, backup.ImportConflictResolution>{
        convId: backup.ImportConflictResolution.createNew,
      },
    );

    expect(result.conflicts, isEmpty);
    expect(result.conversationIds, hasLength(1));
    expect(result.conversationIds.single, isNot(convId));

    final importedMessages =
        await msgRepo.getAllByConversationOrderedStable(result.conversationIds.single);
    expect(importedMessages, hasLength(1));
    expect(importedMessages.single.id, isNot('msg_src_1'));
    expect(importedMessages.single.sourceMessageId, 'msg_src_1');

    final importedBlocks = await blockRepo.getByMessage(importedMessages.single.id);
    expect(importedBlocks, hasLength(1));
    expect(importedBlocks.single.id, isNot('blk_src_1'));
    expect(importedBlocks.single.sourceBlockId, 'blk_src_1');
    expect(importedBlocks.single.messageId, importedMessages.single.id);
  });

  test('merge 导入必须扫描完整历史，并按 sourceMessageId 去重', () async {
    const convId = 'conv_merge';
    const now = 1710000100000;
    await convRepo.upsert(ConversationsCompanion.insert(
      id: convId,
      title: '会话',
      displayName: '会话',
      personaPrompt: const Value('persona'),
      createdAt: now,
      updatedAt: now,
    ));

    for (var i = 0; i < 60; i++) {
      await msgRepo.insert(MessagesCompanion.insert(
        id: 'local_$i',
        conversationId: convId,
        role: i.isEven ? 'user' : 'assistant',
        content: 'local_$i',
        createdAt: now + i,
        sourceMessageId: Value('src_$i'),
      ));
    }

    final archiveFile = await _buildImportArchive(
      tempRoot,
      conversations: <Map<String, dynamic>>[
        {
          'id': convId,
          'title': '会话',
          'display_name': '会话',
          'persona_prompt': 'persona',
          'created_at': now,
          'updated_at': now,
        },
      ],
      messages: <Map<String, dynamic>>[
        {
          'id': 'src_0',
          'conversation_id': convId,
          'role': 'assistant',
          'content': 'duplicate',
          'status': 'sent',
          'created_at': now - 100,
          'blocks': const <Map<String, dynamic>>[],
        },
      ],
    );

    final result = await importer.import(
      file: archiveFile,
      selectedScopes: const <String>[backup.SyncScope.chatHistory],
      selectedConversationIds: const <String>[convId],
      conflictResolutions: const <String, backup.ImportConflictResolution>{
        convId: backup.ImportConflictResolution.merge,
      },
    );

    expect(result.conflicts, isEmpty);
    expect(result.skipped, 1);

    final importedMessages = await msgRepo.getAllByConversationOrderedStable(convId);
    expect(importedMessages, hasLength(60));
    expect(importedMessages.where((m) => m.content == 'duplicate'), isEmpty);
  });
}

Future<File> _buildImportArchive(
  Directory tempRoot, {
  required List<Map<String, dynamic>> conversations,
  required List<Map<String, dynamic>> messages,
}) async {
  final exportDir = Directory(
    p.join(tempRoot.path, 'archive_${DateTime.now().microsecondsSinceEpoch}'),
  );
  await exportDir.create(recursive: true);

  final manifest = backup.ExportManifest(
    formatVersion: backup.kExportFormatVersion,
    appVersion: '1.0.0-test',
    exportTime: DateTime.fromMillisecondsSinceEpoch(1710000000000),
    exportDevice: 'test',
    includedScopes: const <String>[backup.SyncScope.chatHistory],
    conversationCount: conversations.length,
    messageCount: messages.length,
    fileCount: 0,
  );
  await File(p.join(exportDir.path, 'manifest.json'))
      .writeAsString(jsonEncode(manifest.toJson()));
  await File(p.join(exportDir.path, 'conversations.json')).writeAsString(
    jsonEncode(<String, dynamic>{
      'version': 1,
      'conversations': conversations,
    }),
  );
  await File(p.join(exportDir.path, 'messages.json')).writeAsString(
    jsonEncode(<String, dynamic>{
      'version': 1,
      'messages': messages,
    }),
  );

  final archive = Archive();
  await for (final entity in exportDir.list(recursive: true)) {
    if (entity is! File) continue;
    final relativePath = p.relative(entity.path, from: exportDir.path);
    final bytes = await entity.readAsBytes();
    archive.addFile(
      ArchiveFile(relativePath.replaceAll('\\', '/'), bytes.length, bytes),
    );
  }

  final zipBytes = ZipEncoder().encode(archive)!;
  final zipFile = File(p.join(tempRoot.path, 'import_test.aicove'));
  await zipFile.writeAsBytes(zipBytes);
  return zipFile;
}
