import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:aicove_flutter/src/core/database/database.dart' hide SyncScope;
import 'package:aicove_flutter/src/core/database/converters/database_converters.dart';
import 'package:aicove_flutter/src/core/database/repositories/repositories.dart';
import 'package:aicove_flutter/src/core/models/message_block.dart' as domain;
import 'package:aicove_flutter/src/features/backup/data/conversation_importer.dart';
import 'package:aicove_flutter/src/features/backup/models/export_format.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  late Directory root;
  late ConversationImporter importer;
  Future<Directory> dir(String name) =>
      Directory(p.join(root.path, name)).create(recursive: true);
  Future<File> package(String type, Map<String, dynamic>? data,
      {bool attachment = false}) async {
    final archive = Archive();
    void add(String name, Object value) {
      final bytes = utf8.encode(jsonEncode(value));
      archive.addFile(ArchiveFile(name, bytes.length, bytes));
    }

    add(
        'manifest.json',
        ExportManifest(
                formatVersion: 1,
                appVersion: 'test',
                exportTime: DateTime(2026),
                includedScopes: [SyncScope.chatHistory],
                conversationCount: 1,
                messageCount: 1,
                fileCount: attachment ? 1 : 0)
            .toJson());
    add('conversations.json', {
      'conversations': [
        {'id': 'a', 'display_name': 'A'}
      ]
    });
    add('messages.json', {
      'messages': [
        {
          'id': 'm',
          'conversation_id': 'a',
          'role': 'assistant',
          'content': '原正文',
          'created_at': 2,
          'blocks': [
            {'id': 'block', 'type': type, 'status': 'success', 'data': data},
          ]
        }
      ]
    });
    if (attachment) {
      archive.addFile(ArchiveFile('files/media.bin', 3, [1, 2, 3]));
    }
    final file = File(p.join(root.path, 'test.aicove'));
    await file.writeAsBytes(ZipEncoder().encode(archive)!);
    return file;
  }

  Future<ImportResult> restore(File file,
          {ImportConflictResolution? resolution}) =>
      importer.import(
          file: file,
          selectedScopes: [SyncScope.chatHistory],
          selectedConversationIds: ['a'],
          conflictResolutions: {if (resolution != null) 'a': resolution});
  Future<void> seed() async {
    await db.into(db.conversations).insert(ConversationsCompanion.insert(
        id: 'a', title: 'A', displayName: 'A', createdAt: 1, updatedAt: 1));
    await db.into(db.messages).insert(MessagesCompanion.insert(
        id: 'original',
        conversationId: 'a',
        role: 'user',
        content: 'must survive',
        createdAt: 1));
  }

  Future<domain.MessageBlock> restoredBlock() async {
    final row = (await MessageBlockRepository(db).getByMessage('m')).single;
    final block = MessageBlockConverter.fromDb(row);
    expect(block, isNotNull,
        reason:
            'successful import must be readable by the actual chat converter');
    return block!;
  }

  Map<String, dynamic> core(String type) =>
      {'id': 'block', 'messageId': 'm', 'type': type, 'status': 'success'};

  setUp(() async {
    root = await Directory.systemTemp.createTemp('aicove-import-block-');
    db = AppDatabase.forTesting(NativeDatabase.memory());
    importer = ConversationImporter(
        convRepo: ConversationRepository(db),
        msgRepo: MessageRepository(db),
        blockRepo: MessageBlockRepository(db),
        temporaryDirectoryResolver: () => dir('temp'),
        documentsDirectoryResolver: () => dir('docs'));
  });
  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });

  for (final type in ['image', 'audio', 'mainText', 'thinking']) {
    test('B01 missing required $type content must reject without rows',
        () async {
      await expectLater(restore(await package(type, core(type))),
          throwsA(isA<ImportException>()));
      expect(await db.select(db.conversations).get(), isEmpty);
      expect(await db.select(db.messages).get(), isEmpty);
    });
  }
  test(
      'B02 invalid image field after file copy rolls back replacement and files',
      () async {
    await seed();
    final file = await package('image',
        {...core('image'), 'localPath': 'files/media.bin', 'width': 'bad'},
        attachment: true);
    await expectLater(
        restore(file, resolution: ImportConflictResolution.replace),
        throwsA(isA<ImportException>()));
    expect((await MessageRepository(db).getById('original'))!.content,
        'must survive');
    expect(await MessageRepository(db).getById('m'), isNull);
    final files = await (await dir('docs'))
        .list(recursive: true)
        .where((f) => f is File)
        .toList();
    expect(files, isEmpty);
  });
  test('B03 envelope and inner type disagreement is rejected', () async {
    await expectLater(
        restore(await package(
            'image', {...core('mainText'), 'content': 'not an image'})),
        throwsA(isA<ImportException>()));
    expect(await db.select(db.messages).get(), isEmpty);
  });
  test('B04 legacy envelope-only identity becomes a real image block',
      () async {
    await restore(await package('image', {'localPath': 'files/media.bin'},
        attachment: true));
    final block = await restoredBlock() as domain.ImageBlock;
    expect([block.id, block.messageId], ['block', 'm']);
    expect(await File(block.localPath!).readAsBytes(), [1, 2, 3]);
  });
  test('B05 foreign inner message owner cannot survive import', () async {
    await restore(await package('mainText', {
      'id': 'foreign-id',
      'messageId': 'other-character-message',
      'type': 'mainText',
      'content': 'text'
    }));
    final block = await restoredBlock();
    expect([block.id, block.messageId], ['block', 'm']);
  });
  test('B06 valid integer audio duration is normalized for the actual decoder',
      () async {
    await restore(await package(
        'audio',
        {
          ...core('audio'),
          'url': 'files/media.bin',
          'durationSeconds': 2,
          'text': 'spoken text'
        },
        attachment: true));
    final block = await restoredBlock() as domain.AudioBlock;
    expect(block.durationSeconds, 2.0);
    expect(block.text, 'spoken text');
    expect(await File(block.url).readAsBytes(), [1, 2, 3]);
  });
  test('B07 valid native typed text remains unchanged', () async {
    await restore(
        await package('mainText', {...core('mainText'), 'content': 'text'}));
    expect((await restoredBlock() as domain.TextBlock).content, 'text');
    expect((await MessageRepository(db).getById('m'))!.content, '原正文');
  });
  test('B08 null image data cannot silently become an unreadable row',
      () async {
    await expectLater(
        restore(await package('image', null)), throwsA(isA<ImportException>()));
    expect(await db.select(db.messages).get(), isEmpty);
  });
  test('B09 text alias in legacy v1 becomes readable mainText', () async {
    await restore(await package('text', {'content': 'legacy text'}));
    expect((await restoredBlock() as domain.TextBlock).content, 'legacy text');
    expect((await MessageBlockRepository(db).getByMessage('m')).single.type,
        'mainText');
  });
  test('B10 createNew binds inner block identity to its own new message',
      () async {
    await seed();
    final result = await restore(
        await package('mainText', {
          'id': 'wrong',
          'messageId': 'foreign',
          'type': 'mainText',
          'content': 'text'
        }),
        resolution: ImportConflictResolution.createNew);
    final messages = await MessageRepository(db)
        .getAllByConversationOrderedStable(result.conversationIds.single);
    final row =
        (await MessageBlockRepository(db).getByMessage(messages.single.id))
            .single;
    final block = MessageBlockConverter.fromDb(row)!;
    expect([block.id, block.messageId], [row.id, messages.single.id]);
    expect((await MessageRepository(db).getById('original'))!.content,
        'must survive');
  });
}
