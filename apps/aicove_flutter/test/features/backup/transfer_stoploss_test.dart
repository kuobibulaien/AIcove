import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:aicove_flutter/src/core/database/database.dart' hide SyncScope;
import 'package:aicove_flutter/src/core/database/repositories/repositories.dart';
import 'package:aicove_flutter/src/core/database/converters/database_converters.dart';
import 'package:aicove_flutter/src/core/models/message_block.dart' as domain;
import 'package:aicove_flutter/src/features/chat/services/chat_frontend_message_projection_service.dart';
import 'package:aicove_flutter/src/features/backup/data/conversation_importer.dart';
import 'package:aicove_flutter/src/features/backup/data/conversation_exporter.dart';
import 'package:aicove_flutter/src/features/backup/models/export_format.dart';

const supported = [
  SyncScope.characterCards,
  SyncScope.characterSettings,
  SyncScope.chatHistory
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late AppDatabase db;
  late ConversationImporter importer;
  late ConversationExporter exporter;
  late int counter;
  Future<Directory> directory(String name) =>
      Directory(p.join(root.path, name)).create(recursive: true);
  Future<void> seed() async {
    await db.into(db.conversations).insert(ConversationsCompanion.insert(
        id: 'a',
        title: 'A',
        displayName: 'A',
        personaPrompt: const Value('private persona'),
        isMuted: const Value(true),
        createdAt: 1,
        updatedAt: 1));
    await db.into(db.messages).insert(MessagesCompanion.insert(
        id: 'local',
        conversationId: 'a',
        role: 'user',
        content: 'local chat',
        createdAt: 2));
  }

  Map<String, Object> msg(String id,
          {Object created = 3, List<Object> blocks = const []}) =>
      {
        'id': id,
        'conversation_id': 'a',
        'created_at': created,
        'content': 'imported',
        'blocks': blocks,
      };
  Future<File> bundle(
      {List<dynamic>? messages,
      List<String> scopes = supported,
      Map<String, Object>? card,
      List<Map<String, Object>>? cards,
      Map<String, Object?> manifestOverrides = const {},
      bool withMessages = true,
      List<ArchiveFile> files = const []}) async {
    final actualMessages = messages ?? [msg('imported')];
    final actualCards = cards ??
        [
          card ??
              {
                'id': 'a',
                'display_name': 'A',
                'persona_prompt': 'private persona',
                'is_muted': true
              }
        ];
    final archive = Archive();
    void add(String name, Object data) {
      final bytes = utf8.encode(jsonEncode(data));
      archive.addFile(ArchiveFile(name, bytes.length, bytes));
    }

    add('manifest.json', {
      ...ExportManifest(
              formatVersion: 1,
              appVersion: 'test',
              exportTime: DateTime(2026),
              includedScopes: scopes,
              conversationCount: actualCards.length,
              messageCount: actualMessages.length,
              fileCount: files.length)
          .toJson(),
      ...manifestOverrides,
    });
    add('conversations.json', {'conversations': actualCards});
    if (withMessages) add('messages.json', {'messages': actualMessages});
    for (final file in files) {
      archive.addFile(file);
    }
    final file = File(p.join(root.path, 'bundle_${counter++}.aicove'));
    await file.writeAsBytes(ZipEncoder().encode(archive)!);
    return file;
  }

  Future<ImportResult> restore(File file,
          {List<String> scopes = supported,
          ImportConflictResolution? resolution,
          void Function(ImportProgress)? progress}) =>
      importer.import(
          file: file,
          selectedScopes: scopes,
          selectedConversationIds: ['a'],
          conflictResolutions: {if (resolution != null) 'a': resolution},
          onProgress: progress);
  Future<List<File>> importedFiles() async {
    final dir = Directory(p.join(root.path, 'docs', 'imported_files'));
    if (!await dir.exists()) return [];
    return dir
        .list(recursive: true)
        .where((e) => e is File)
        .cast<File>()
        .toList();
  }

  domain.MessageBlock nativeAttachment(String kind, String path) =>
      kind == 'file'
          ? domain.FileBlock(
              id: 'attachment',
              messageId: 'local',
              fileName: '资料 空格.txt',
              fileSize: 3,
              mimeType: 'text/plain',
              filePath: path)
          : domain.EmojiBlock(
              id: 'attachment',
              messageId: 'local',
              emojiId: 'sticker-a',
              path: path,
              matchedTag: '开心',
              originalText: '表情原文');

  Future<void> putAttachment(String kind, String path,
      {bool cached = false}) async {
    final data = nativeAttachment(kind, path).toJson();
    if (cached) {
      await db.update(db.messages).write(MessagesCompanion(
              rawPayload: Value(jsonEncode({
            'version': 1,
            'providerConfig': {'apiKey': 'private-do-not-export'},
            'projectedMessages': [
              {
                'id': 'view',
                'role': 'user',
                'content': 'local chat',
                'createdAt': 2,
                'blocks': [data]
              }
            ],
          }))));
    } else {
      await db.into(db.messageBlocks).insert(MessageBlocksCompanion.insert(
          id: 'attachment',
          messageId: 'local',
          type: kind,
          data: jsonEncode(data),
          createdAt: 2));
    }
  }

  Future<List<domain.MessageBlock>> readableBlocks(String messageId) async {
    final rows = await MessageBlockRepository(db).getByMessage(messageId);
    final blocks = rows.map(MessageBlockConverter.fromDb).toList();
    expect(blocks.every((b) => b != null), isTrue,
        reason:
            'successful import must produce blocks the chat reader understands');
    return blocks.cast<domain.MessageBlock>();
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('aicove-stoploss-');
    counter = 0;
    db = AppDatabase.forTesting(NativeDatabase.memory());
    importer = ConversationImporter(
        convRepo: ConversationRepository(db),
        msgRepo: MessageRepository(db),
        blockRepo: MessageBlockRepository(db),
        temporaryDirectoryResolver: () => directory('temp'),
        documentsDirectoryResolver: () => directory('docs'));
    exporter = ConversationExporter(
        convRepo: ConversationRepository(db),
        msgRepo: MessageRepository(db),
        blockRepo: MessageBlockRepository(db),
        temporaryDirectoryResolver: () => directory('temp'),
        documentsDirectoryResolver: () => directory('docs'),
        outputDirectoryResolver: () => directory('output'),
        appVersionResolver: () async => 'test');
  });
  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });

  for (final scope in supported) {
    test('scope $scope filters exported fields, messages and attachments',
        () async {
      await seed();
      final avatar = File(p.join(root.path, 'avatar.png'));
      await avatar.writeAsBytes([1, 2, 3]);
      await db
          .update(db.conversations)
          .write(ConversationsCompanion(avatarUrl: Value(avatar.path)));
      final result = await exporter.exportConversations(
          conversationIds: ['a'], options: ExportOptions(scopes: [scope]));
      final archive =
          ZipDecoder().decodeBytes(await File(result.filePath).readAsBytes());
      dynamic entry(String name) =>
          jsonDecode(utf8.decode(archive.findFile(name)!.content as List<int>));
      final card =
          (entry('conversations.json')['conversations'] as List).single as Map;
      expect(card.containsKey('persona_prompt'),
          scope == SyncScope.characterCards);
      expect(
          card.containsKey('is_muted'), scope == SyncScope.characterSettings);
      expect((entry('messages.json')['messages'] as List).length,
          scope == SyncScope.chatHistory ? 1 : 0);
      expect(archive.files.where((f) => f.name.startsWith('files/')).length,
          scope == SyncScope.characterCards ? 1 : 0);
    });
    test('scope $scope filters legacy package contents on import', () async {
      await restore(await bundle(), scopes: [scope]);
      final card = (await ConversationRepository(db).getById('a'))!;
      expect(card.personaPrompt,
          scope == SyncScope.characterCards ? 'private persona' : '');
      expect(card.isMuted, scope == SyncScope.characterSettings);
      expect((await db.select(db.messages).get()).length,
          scope == SyncScope.chatHistory ? 1 : 0);
    });
  }
  test('unsupported memory export and import fail explicitly without writes',
      () async {
    await seed();
    await expectLater(
        exporter.exportConversations(
            conversationIds: ['a'],
            options: const ExportOptions(
                scopes: [SyncScope.characterCards, SyncScope.memory])),
        throwsFormatException);
    await expectLater(
        restore(await bundle(scopes: [SyncScope.memory]),
            scopes: [SyncScope.memory]),
        throwsFormatException);
    expect(
        (await MessageRepository(db).getById('local'))!.content, 'local chat');
    expect(await importedFiles(), isEmpty);
  });
  test('manifest excludes history even if legacy package contains messages',
      () async {
    await restore(await bundle(scopes: [SyncScope.characterCards]));
    expect(await db.select(db.messages).get(), isEmpty);
  });
  test('card-only replace cannot delete existing messages or settings',
      () async {
    await seed();
    await restore(await bundle(),
        scopes: [SyncScope.characterCards],
        resolution: ImportConflictResolution.replace);
    expect(
        (await MessageRepository(db).getById('local'))!.content, 'local chat');
    expect((await ConversationRepository(db).getById('a'))!.isMuted, isTrue);
  });
  for (final resolution in [null, ImportConflictResolution.replace]) {
    test('database rollback removes staged files resolution=$resolution',
        () async {
      if (resolution != null) await seed();
      final file = await bundle(messages: [
        msg('first', blocks: [
          {
            'id': 'attachment',
            'type': 'file',
            'data': {
              'filePath': 'files/note.txt',
              'fileName': 'note.txt',
              'fileSize': 3,
              'mimeType': 'text/plain'
            }
          }
        ]),
        msg('bad', created: 'invalid')
      ], files: [
        ArchiveFile('files/note.txt', 3, [1, 2, 3])
      ]);
      await expectLater(
          restore(file, resolution: resolution), throwsA(anything));
      expect(await MessageRepository(db).getById('first'), isNull);
      expect(await importedFiles(), isEmpty);
      if (resolution != null) {
        expect((await MessageRepository(db).getById('local'))!.content,
            'local chat');
      } else {
        expect(await db.select(db.conversations).get(), isEmpty);
      }
    });
  }
  test('attachment copy error rolls back earlier files and rows', () async {
    final file = await bundle(messages: [
      msg('first', blocks: [
        {
          'id': 'ok',
          'type': 'file',
          'data': {
            'filePath': 'files/ok.txt',
            'fileName': 'ok.txt',
            'fileSize': 1,
            'mimeType': 'text/plain'
          }
        }
      ]),
      msg('second', blocks: [
        {
          'id': 'missing',
          'type': 'image',
          'data': {'url': 'files/missing.png'}
        }
      ])
    ], files: [
      ArchiveFile('files/ok.txt', 1, [1])
    ]);
    await expectLater(restore(file), throwsA(anything));
    expect(await db.select(db.conversations).get(), isEmpty);
    expect(await importedFiles(), isEmpty);
  });
  for (final entry in [
    '../escape',
    '..\\escape',
    '/absolute',
    'C:\\outside',
    'files/../../escape'
  ]) {
    test('reject unsafe ZIP entry $entry before any extraction', () async {
      final file = await bundle(files: [
        ArchiveFile(entry, 1, [1])
      ]);
      await expectLater(importer.preview(file), throwsA(anything));
      expect(await (await directory('temp')).list().toList(), isEmpty);
      expect(await db.select(db.conversations).get(), isEmpty);
    });
  }
  test('reject ZIP symlink and duplicate normalized paths', () async {
    final link = ArchiveFile('files/link', 4, utf8.encode('../x'))
      ..isSymbolicLink = true
      ..mode = 0xA1FF
      ..nameOfLinkedFile = '../x';
    await expectLater(
        importer.preview(await bundle(files: [link])), throwsA(anything));
    await expectLater(
        importer.preview(await bundle(files: [
          ArchiveFile('files/a', 1, [1]),
          ArchiveFile('files/A', 1, [2])
        ])),
        throwsA(anything));
  });
  for (final key in ['avatar_file', 'chat_background_image_file']) {
    test('reject external local $key reference', () async {
      final secret = File(p.join(root.path, 'private.txt'));
      await secret.writeAsString('private');
      await expectLater(
          restore(await bundle(card: {'id': 'a', key: secret.path})),
          throwsA(anything));
      expect(await importedFiles(), isEmpty);
      expect(await db.select(db.conversations).get(), isEmpty);
      expect(await secret.readAsString(), 'private');
    });
  }
  test('reject external message media local path', () async {
    final secret = File(p.join(root.path, 'private.txt'));
    await secret.writeAsString('private');
    await expectLater(
        restore(await bundle(messages: [
          msg('m', blocks: [
            {
              'id': 'x',
              'type': 'file',
              'data': {'filePath': secret.path}
            }
          ])
        ])),
        throwsA(anything));
    expect(await db.select(db.messages).get(), isEmpty);
  });
  test('duplicate input message and block IDs roll back', () async {
    await expectLater(
        restore(await bundle(messages: [msg('same'), msg('same')])),
        throwsA(anything));
    await expectLater(
        restore(await bundle(messages: [
          msg('m', blocks: [
            {'id': 'same', 'type': 'text'},
            {'id': 'same', 'type': 'text'}
          ])
        ])),
        throwsA(anything));
    expect(await db.select(db.conversations).get(), isEmpty);
  });
  test('export callback exceptions do not invalidate the backup', () async {
    await seed();
    final result = await exporter.exportConversations(
        conversationIds: ['a'],
        onProgress: (_) => throw StateError('disposed'));
    expect((await importer.preview(File(result.filePath))).conversations.length,
        1);
  });
  test('import callback exceptions do not interrupt data commit', () async {
    final result = await restore(await bundle(),
        progress: (_) => throw StateError('disposed'));
    expect(result.messagesImported, 1);
    expect(
        (await MessageRepository(db).getById('imported'))!.content, 'imported');
  });
  test('concurrent exports keep both valid independent files', () async {
    await seed();
    final results = await Future.wait(List.generate(
        2, (_) => exporter.exportConversations(conversationIds: ['a'])));
    expect(results.map((r) => r.filePath).toSet().length, 2);
    for (final result in results) {
      expect(
          (await importer.preview(File(result.filePath))).totalMessageCount, 1);
    }
    expect((await (await directory('output')).list().toList()).length, 2);
  });
  for (final kind in ['file', 'emoji']) {
    for (final cached in [false, true]) {
      test('P01 $kind cached=$cached retains bytes, metadata and ownership',
          () async {
        await seed();
        final media = File(p.join(root.path, 'original.bin'));
        await media.writeAsBytes([1, 2, 3]);
        await putAttachment(kind, media.path, cached: cached);
        final source = (await MessageRepository(db).getById('local'))!;
        final before = const ChatFrontendMessageProjectionService()
            .projectMessage(MessageConverter.fromDb(source,
                blocks: await readableBlocks('local')));
        expect(
            before.expand((m) => m.blocks ?? <domain.MessageBlock>[]).where(
                (b) => kind == 'file'
                    ? b is domain.FileBlock
                    : b is domain.EmojiBlock),
            hasLength(1));
        final exported =
            await exporter.exportConversations(conversationIds: ['a']);
        final result = await restore(File(exported.filePath),
            resolution: ImportConflictResolution.createNew);
        final row = (await MessageRepository(db)
                .getAllByConversationOrderedStable(
                    result.conversationIds.single))
            .single;
        expect(
            [row.content, row.role, row.createdAt], ['local chat', 'user', 2]);
        final restored = (await readableBlocks(row.id))
            .where((b) =>
                kind == 'file' ? b is domain.FileBlock : b is domain.EmojiBlock)
            .single;
        final path = kind == 'file'
            ? (restored as domain.FileBlock).filePath
            : (restored as domain.EmojiBlock).path;
        expect(path, startsWith(p.join(root.path, 'docs', 'imported_files')));
        expect(await File(path).readAsBytes(), [1, 2, 3]);
        expect(restored.messageId, row.id);
        if (restored is domain.FileBlock) {
          expect([restored.fileName, restored.fileSize, restored.mimeType],
              ['资料 空格.txt', 3, 'text/plain']);
        } else if (restored is domain.EmojiBlock) {
          expect([restored.emojiId, restored.matchedTag, restored.originalText],
              ['sticker-a', '开心', '表情原文']);
        }
        final archive = ZipDecoder()
            .decodeBytes(await File(exported.filePath).readAsBytes());
        expect(archive.files.where((f) => f.name.startsWith('files/')),
            hasLength(1));
        final text = utf8
            .decode(archive.findFile('messages.json')!.content as List<int>);
        expect(text, isNot(contains(media.path)));
        expect(text, isNot(contains('private-do-not-export')));
        expect((await MessageRepository(db).getById('local'))!.rawPayload,
            source.rawPayload);
      });
    }
    test('P02 cached $kind hides stale missing native attachment', () async {
      await seed();
      await putAttachment(kind, p.join(root.path, 'stale-missing.bin'));
      final media = File(p.join(root.path, 'new.bin'));
      await media.writeAsBytes([1, 2, 3]);
      await putAttachment(kind, media.path, cached: true);
      final exported =
          await exporter.exportConversations(conversationIds: ['a']);
      final result = await restore(File(exported.filePath),
          resolution: ImportConflictResolution.createNew);
      final row = (await MessageRepository(db)
              .getAllByConversationOrderedStable(result.conversationIds.single))
          .single;
      expect(
          (await readableBlocks(row.id)).where((b) =>
              kind == 'file' ? b is domain.FileBlock : b is domain.EmojiBlock),
          hasLength(1));
    });
    test('P03 malformed $kind rolls back existing history and copied files',
        () async {
      await seed();
      final data = nativeAttachment(kind, 'files/attachment.bin').toJson();
      data.remove(kind == 'file' ? 'fileName' : 'emojiId');
      final file = await bundle(messages: [
        msg('imported', blocks: [
          {'id': 'new-block', 'type': kind, 'data': data}
        ])
      ], files: [
        ArchiveFile('files/attachment.bin', 3, [1, 2, 3])
      ]);
      await expectLater(
          restore(file, resolution: ImportConflictResolution.replace),
          throwsA(isA<ImportException>()));
      expect((await MessageRepository(db).getById('local'))!.content,
          'local chat');
      expect(await importedFiles(), isEmpty);
    });
    test('P04 missing selected native $kind must fail export', () async {
      await seed();
      await putAttachment(kind, p.join(root.path, 'missing.bin'));
      await expectLater(exporter.exportConversations(conversationIds: ['a']),
          throwsFormatException);
    });
  }
  for (final cached in [false, true]) {
    test('P05 excluded emoji cached=$cached stays excluded', () async {
      await seed();
      await putAttachment('emoji', p.join(root.path, 'missing.png'),
          cached: cached);
      final exported = await exporter.exportConversations(
          conversationIds: ['a'],
          options:
              const ExportOptions(includeImages: false, includeAudio: false));
      final archive =
          ZipDecoder().decodeBytes(await File(exported.filePath).readAsBytes());
      final json = jsonDecode(
          utf8.decode(archive.findFile('messages.json')!.content as List<int>));
      expect(
          (json['messages'][0]['blocks'] as List)
              .where((b) => b['type'] == 'emoji'),
          isEmpty);
      expect(archive.files.where((f) => f.name.startsWith('files/')), isEmpty);
    });
    test('P06 ordinary file cached=$cached survives images/audio off',
        () async {
      await seed();
      final media = File(p.join(root.path, 'file.txt'));
      await media.writeAsBytes([1, 2, 3]);
      await putAttachment('file', media.path, cached: cached);
      final exported = await exporter.exportConversations(
          conversationIds: ['a'],
          options:
              const ExportOptions(includeImages: false, includeAudio: false));
      final result = await restore(File(exported.filePath),
          resolution: ImportConflictResolution.createNew);
      final row = (await MessageRepository(db)
              .getAllByConversationOrderedStable(result.conversationIds.single))
          .single;
      final file =
          (await readableBlocks(row.id)).whereType<domain.FileBlock>().single;
      expect(await File(file.filePath).readAsBytes(), [1, 2, 3]);
    });
  }
  for (final kind in ['file', 'emoji']) {
    test('P08 cached $kind metadata overrides the same native file reference',
        () async {
      await seed();
      final media = File(p.join(root.path, 'same.bin'));
      await media.writeAsBytes([1, 2, 3]);
      await putAttachment(kind, media.path);
      final data = nativeAttachment(kind, media.path).toJson();
      data[kind == 'file' ? 'fileName' : 'originalText'] = '更新后的内容';
      await db.update(db.messages).write(MessagesCompanion(
              rawPayload: Value(jsonEncode({
            'version': 1,
            'projectedMessages': [
              {
                'id': 'view',
                'role': 'user',
                'content': 'local chat',
                'createdAt': 2,
                'blocks': [data]
              }
            ],
          }))));
      final exported =
          await exporter.exportConversations(conversationIds: ['a']);
      final result = await restore(File(exported.filePath),
          resolution: ImportConflictResolution.createNew);
      final row = (await MessageRepository(db)
              .getAllByConversationOrderedStable(result.conversationIds.single))
          .single;
      final block = (await readableBlocks(row.id))
          .where((b) =>
              kind == 'file' ? b is domain.FileBlock : b is domain.EmojiBlock)
          .single;
      expect(
          kind == 'file'
              ? (block as domain.FileBlock).fileName
              : (block as domain.EmojiBlock).originalText,
          '更新后的内容');
    });
    test('P09 cached text does not resurrect a hidden native $kind', () async {
      await seed();
      final media = File(p.join(root.path, 'hidden.bin'));
      await media.writeAsBytes([1, 2, 3]);
      await putAttachment(kind, media.path);
      await db.update(db.messages).write(MessagesCompanion(
              rawPayload: Value(jsonEncode({
            'version': 1,
            'projectedMessages': [
              {
                'id': 'view',
                'role': 'user',
                'content': 'local chat',
                'createdAt': 2,
                'blocks': []
              }
            ],
          }))));
      final exported =
          await exporter.exportConversations(conversationIds: ['a']);
      final archive =
          ZipDecoder().decodeBytes(await File(exported.filePath).readAsBytes());
      expect(archive.files.where((f) => f.name.startsWith('files/')), isEmpty);
      final result = await restore(File(exported.filePath),
          resolution: ImportConflictResolution.createNew);
      final row = (await MessageRepository(db)
              .getAllByConversationOrderedStable(result.conversationIds.single))
          .single;
      expect(
          (await readableBlocks(row.id)).where((b) =>
              kind == 'file' ? b is domain.FileBlock : b is domain.EmojiBlock),
          isEmpty);
    });
  }
  test('P07 negative file size must be rejected', () async {
    final data = nativeAttachment('file', 'files/f.bin').toJson()
      ..['fileSize'] = -1;
    await expectLater(
        restore(await bundle(messages: [
          msg('imported', blocks: [
            {'id': 'file', 'type': 'file', 'data': data}
          ])
        ], files: [
          ArchiveFile('files/f.bin', 3, [1, 2, 3])
        ])),
        throwsA(isA<ImportException>()));
    expect(await db.select(db.conversations).get(), isEmpty);
  });
  for (final preview in [false, true]) {
    test('R01 orphan message is rejected preview=$preview', () async {
      final file = await bundle(messages: [
        {...msg('orphan'), 'conversation_id': 'missing-owner'}
      ]);
      await expectLater(preview ? importer.preview(file) : restore(file),
          throwsA(isA<ImportException>()));
      expect(await db.select(db.conversations).get(), isEmpty);
    });
    for (final field in ['message_count', 'conversation_count']) {
      test('R02 inconsistent $field is rejected preview=$preview', () async {
        final file = await bundle(manifestOverrides: {field: 2});
        await expectLater(preview ? importer.preview(file) : restore(file),
            throwsA(isA<ImportException>()));
        expect(await db.select(db.conversations).get(), isEmpty);
      });
    }
    test('R06 missing declared history file is rejected preview=$preview',
        () async {
      final file = await bundle(withMessages: false);
      await expectLater(preview ? importer.preview(file) : restore(file),
          throwsA(isA<ImportException>()));
      expect(await db.select(db.conversations).get(), isEmpty);
    });
  }
  test('R03 preview rejects duplicate conversation IDs', () async {
    final file = await bundle(cards: [
      {'id': 'a'},
      {'id': 'a'}
    ]);
    await expectLater(importer.preview(file), throwsA(isA<ImportException>()));
  });
  test('R04 valid partial selection ignores unselected damaged block content',
      () async {
    final file = await bundle(cards: [
      {'id': 'a'},
      {'id': 'b'}
    ], messages: [
      msg('a-msg'),
      {
        ...msg('b-msg', blocks: [
          {'id': 'bad-code', 'type': 'code', 'data': {}}
        ]),
        'conversation_id': 'b'
      }
    ]);
    expect((await importer.preview(file)).totalMessageCount, 2);
    final result = await restore(file);
    expect(result.messagesImported, 1);
    expect((await db.select(db.messages).get()).single.id, 'a-msg');
    expect(await ConversationRepository(db).getById('b'), isNull);
  });
  test('R05 card-only legacy package does not inspect surplus chat data',
      () async {
    final file = await bundle(scopes: [
      SyncScope.characterCards
    ], messages: [
      {'conversation_id': 'orphan', 'blocks': 'damaged'}
    ], manifestOverrides: {
      'message_count': 999
    });
    expect((await importer.preview(file)).totalMessageCount, 0);
    await restore(file, scopes: [SyncScope.characterCards]);
    expect(await db.select(db.messages).get(), isEmpty);
  });
  for (final type in ['tool', 'code', 'error']) {
    test('R07 malformed $type is rejected and replacement rolled back',
        () async {
      await seed();
      final file = await bundle(messages: [
        msg('new-msg', blocks: [
          {'id': 'b', 'type': type, 'data': {}}
        ])
      ]);
      await expectLater(
          restore(file, resolution: ImportConflictResolution.replace),
          throwsA(isA<ImportException>()));
      expect((await MessageRepository(db).getById('local'))!.content,
          'local chat');
      expect(await MessageRepository(db).getById('new-msg'), isNull);
    });
    test('R07 valid $type stays readable without executing it', () async {
      final domain.MessageBlock block = switch (type) {
        'tool' => domain.ToolBlock(
            id: 'b',
            messageId: 'imported',
            toolName: 'lookup',
            arguments: {'query': 'test'},
            result: {'ok': true}),
        'code' => domain.CodeBlock(
            id: 'b',
            messageId: 'imported',
            content: 'print(1)',
            language: 'dart'),
        _ => domain.ErrorBlock(
            id: 'b', messageId: 'imported', message: 'stored error'),
      };
      await restore(await bundle(messages: [
        msg('imported', blocks: [
          {'id': 'b', 'type': type, 'data': block.toJson()}
        ])
      ]));
      expect((await readableBlocks('imported')).single.runtimeType,
          block.runtimeType);
      expect((await MessageRepository(db).getById('imported'))!.content,
          'imported');
    });
  }
  for (final type in ['translation', 'citation', 'video', 'future.block']) {
    test('R08 unsupported $type must not silently become placeholder',
        () async {
      final file = await bundle(messages: [
        msg('imported', blocks: [
          {
            'id': 'unsupported',
            'type': type,
            'data': {'content': 'unreadable content'}
          }
        ])
      ]);
      await expectLater(restore(file), throwsA(isA<ImportException>()));
      expect(await db.select(db.messages).get(), isEmpty);
    });
  }
  test('R09 explicit native placeholder remains compatible', () async {
    final data =
        domain.PlaceholderBlock(id: 'p', messageId: 'imported').toJson();
    await restore(await bundle(messages: [
      {
        ...msg('imported', blocks: [
          {'id': 'p', 'type': 'unknown', 'data': data}
        ]),
        'content': ''
      }
    ]));
    expect((await readableBlocks('imported')).single,
        isA<domain.PlaceholderBlock>());
  });
  test('R10 legacy unknown counts use actual records', () async {
    final file = await bundle(
        manifestOverrides: {'message_count': null, 'conversation_count': null});
    expect((await importer.preview(file)).totalMessageCount, 1);
    expect((await restore(file)).messagesImported, 1);
  });
  for (final preview in [false, true]) {
    test(
        'R12 ill-formed Unicode role IDs cannot collapse in SQLite preview=$preview',
        () async {
      final file = await bundle(cards: [
        {'id': 'bad-a', 'display_name': 'A'},
        {'id': 'bad-b', 'display_name': 'B'}
      ], messages: [
        {...msg('first'), 'conversation_id': 'bad-a'},
        {...msg('second'), 'conversation_id': 'bad-b'}
      ]);
      final archive = ZipDecoder().decodeBytes(await file.readAsBytes());
      final patched = Archive();
      for (final item in archive) {
        var bytes = item.content as List<int>;
        if (item.name.endsWith('.json')) {
          final text = utf8
              .decode(bytes)
              .replaceAll('"bad-a"', r'"\ud800"')
              .replaceAll('"bad-b"', r'"\ud801"');
          bytes = utf8.encode(text);
        }
        patched.addFile(ArchiveFile(item.name, bytes.length, bytes));
      }
      await file.writeAsBytes(ZipEncoder().encode(patched)!);
      Object? failure;
      try {
        if (preview) {
          await importer.preview(file);
        } else {
          await importer.import(
              file: file,
              selectedScopes: supported,
              selectedConversationIds: [
                String.fromCharCode(0xd800),
                String.fromCharCode(0xd801)
              ]);
        }
      } catch (e) {
        failure = e;
      }
      expect({
        'roles': (await db.select(db.conversations).get()).length,
        'messages': (await db.select(db.messages).get()).length
      }, {
        'roles': 0,
        'messages': 0
      },
          reason:
              'distinct invalid JSON IDs must not normalize to the same stored role');
      expect(failure, isA<ImportException>());
    });
  }
  test('R14 ill-formed Unicode block ID is rejected before persistence',
      () async {
    final file = await bundle(messages: [
      msg('imported', blocks: [
        {
          'id': 'bad-block',
          'type': 'code',
          'data': {'content': 'text', 'language': 'plain'}
        }
      ])
    ]);
    final archive = ZipDecoder().decodeBytes(await file.readAsBytes());
    final patched = Archive();
    for (final item in archive) {
      var bytes = item.content as List<int>;
      if (item.name == 'messages.json') {
        bytes = utf8
            .encode(utf8.decode(bytes).replaceAll('"bad-block"', r'"\ud800"'));
      }
      patched.addFile(ArchiveFile(item.name, bytes.length, bytes));
    }
    await file.writeAsBytes(ZipEncoder().encode(patched)!);
    await expectLater(restore(file), throwsA(isA<ImportException>()));
    expect(await db.select(db.conversations).get(), isEmpty);
  });
  test(
      'R15 empty optional source IDs must not collapse distinct messages during merge',
      () async {
    await seed();
    final file = await bundle(messages: [
      {...msg('first'), 'source_message_id': ''},
      {...msg('second'), 'source_message_id': ''},
    ]);
    expect(
        (await restore(file, resolution: ImportConflictResolution.merge))
            .messagesImported,
        2);
    expect((await MessageRepository(db).getById('second'))!.sourceMessageId,
        'second');
    final again =
        await restore(file, resolution: ImportConflictResolution.merge);
    expect([again.messagesImported, again.skipped], [0, 2]);
  });
  for (final field in ['source_message_id', 'source_block_id']) {
    test('R16 malformed Unicode $field is rejected', () async {
      final block = <String, Object>{
        'id': 'b',
        'type': 'mainText',
        'data': {'content': 'text'}
      };
      final message = msg('imported', blocks: [block]);
      if (field == 'source_message_id') {
        message[field] = 'bad-source';
      } else {
        block[field] = 'bad-source';
      }
      final file = await bundle(messages: [message]);
      final archive = ZipDecoder().decodeBytes(await file.readAsBytes());
      final patched = Archive();
      for (final item in archive) {
        var bytes = item.content as List<int>;
        if (item.name == 'messages.json') {
          bytes = utf8.encode(
              utf8.decode(bytes).replaceAll('"bad-source"', r'"\ud800"'));
        }
        patched.addFile(ArchiveFile(item.name, bytes.length, bytes));
      }
      await file.writeAsBytes(ZipEncoder().encode(patched)!);
      await expectLater(restore(file), throwsA(isA<ImportException>()));
      expect(await db.select(db.conversations).get(), isEmpty);
    });
  }
  test('R13 valid Unicode role IDs remain compatible', () async {
    const owner = '角色𝄞';
    final file = await bundle(cards: [
      {'id': owner}
    ], messages: [
      {...msg('unicode-msg'), 'conversation_id': owner}
    ]);
    expect((await importer.preview(file)).conversations.single.id, owner);
    await importer.import(
        file: file,
        selectedScopes: supported,
        selectedConversationIds: [owner]);
    expect((await MessageRepository(db).getById('unicode-msg'))!.conversationId,
        owner);
  });
  for (final preview in [false, true]) {
    for (final time in <Object>[
      8640000000000001,
      -8640000000000001,
      'yesterday',
      1.5
    ]) {
      test('S01 invalid message timestamp $time rejected preview=$preview',
          () async {
        await seed();
        final file = await bundle(messages: [msg('bad-time', created: time)]);
        await expectLater(
            preview
                ? importer.preview(file)
                : restore(file, resolution: ImportConflictResolution.replace),
            throwsA(isA<ImportException>()));
        expect((await MessageRepository(db).getById('local'))!.content,
            'local chat');
        expect(await MessageRepository(db).getById('bad-time'), isNull);
      });
    }
    for (final field in ['created_at', 'updated_at']) {
      test('S02 invalid character timestamp $field rejected preview=$preview',
          () async {
        final file = await bundle(card: {'id': 'a', field: 8640000000000001});
        await expectLater(preview ? importer.preview(file) : restore(file),
            throwsA(isA<ImportException>()));
        expect(await db.select(db.conversations).get(), isEmpty);
      });
    }
  }
  test(
      'S03 same millisecond export and new-copy restore preserve raw insertion order',
      () async {
    await seed();
    for (final id in ['z-last-lexically', 'a-first-lexically']) {
      await db.into(db.messages).insert(MessagesCompanion.insert(
          id: id,
          conversationId: 'a',
          role: 'assistant',
          content: id,
          createdAt: 2));
    }
    final exported = await exporter.exportConversations(conversationIds: ['a']);
    final result = await restore(File(exported.filePath),
        resolution: ImportConflictResolution.createNew);
    final messages = await MessageRepository(db)
        .getAllByConversationOrderedStable(result.conversationIds.single);
    expect(messages.map((m) => m.content),
        ['local chat', 'z-last-lexically', 'a-first-lexically']);
    expect(messages.map((m) => m.createdAt), [2, 2, 2]);
  });
  test(
      'S04 negative and zero epoch milliseconds remain valid and chronological',
      () async {
    final file = await bundle(
        messages: [msg('zero', created: 0), msg('negative', created: -1)]);
    expect(
        (await importer.preview(file))
            .conversations
            .single
            .lastMessageTime!
            .millisecondsSinceEpoch,
        0);
    await restore(file);
    final messages =
        await MessageRepository(db).getAllByConversationOrderedStable('a');
    expect(messages.map((m) => m.id), ['negative', 'zero']);
    expect(messages.map((m) => m.createdAt), [-1, 0]);
  });
  for (final time in [-8640000000000000, 8640000000000000]) {
    test('S05 exact DateTime boundary $time stays readable', () async {
      final file = await bundle(messages: [msg('boundary', created: time)]);
      expect(
          (await importer.preview(file))
              .conversations
              .single
              .lastMessageTime!
              .millisecondsSinceEpoch,
          time);
      await restore(file);
      final saved = (await MessageRepository(db).getById('boundary'))!;
      expect(
          DateTime.fromMillisecondsSinceEpoch(saved.createdAt)
              .millisecondsSinceEpoch,
          time);
    });
  }
  test('S06 legacy absent timestamp retains fallback compatibility', () async {
    final message = msg('legacy')..remove('created_at');
    final file = await bundle(messages: [message]);
    expect((await importer.preview(file)).conversations.single.lastMessageTime,
        isNull);
    final before = DateTime.now().millisecondsSinceEpoch;
    await restore(file);
    expect((await MessageRepository(db).getById('legacy'))!.createdAt,
        inInclusiveRange(before, DateTime.now().millisecondsSinceEpoch));
  });
  test('V01 merge recognizes native row through imported provenance', () async {
    await seed();
    final file = await bundle(messages: [
      {
        ...msg('copied-id', created: 2),
        'source_message_id': 'local',
        'content': 'local chat'
      }
    ]);
    final result =
        await restore(file, resolution: ImportConflictResolution.merge);
    expect([result.messagesImported, result.skipped], [0, 1]);
    expect((await db.select(db.messages).get()).length, 1);
  });
  test(
      'V02 same-time merge cannot silently append an older missing message after its successor',
      () async {
    await seed();
    final file = await bundle(messages: [
      msg('missing-predecessor', created: 2),
      {...msg('local', created: 2), 'content': 'local chat'}
    ]);
    await expectLater(restore(file, resolution: ImportConflictResolution.merge),
        throwsA(isA<ImportException>()));
    expect((await db.select(db.messages).get()).single.id, 'local');
  });
  test('V03 same-time merge can append a later message and repeat safely',
      () async {
    await seed();
    final file = await bundle(messages: [
      {...msg('local', created: 2), 'content': 'local chat'},
      msg('later', created: 2)
    ]);
    expect(
        (await restore(file, resolution: ImportConflictResolution.merge))
            .messagesImported,
        1);
    expect(
        (await restore(file, resolution: ImportConflictResolution.merge))
            .messagesImported,
        0);
    expect(
        (await MessageRepository(db).getAllByConversationOrderedStable('a'))
            .map((m) => m.id),
        ['local', 'later']);
  });
  test('V04 merge cannot report success into an invisible recycled character',
      () async {
    await seed();
    await ConversationRepository(db).softDelete('a', 1, 9999999999999);
    await expectLater(
        restore(await bundle(), resolution: ImportConflictResolution.merge),
        throwsA(isA<ImportException>()));
    expect(await MessageRepository(db).getById('imported'), isNull);
    expect((await ConversationRepository(db).getById('a'))!.deletedAt, 1);
  });
  test('V05 recycled character can still import as a visible copy', () async {
    await seed();
    await ConversationRepository(db).softDelete('a', 1, 9999999999999);
    final result = await restore(await bundle(),
        resolution: ImportConflictResolution.createNew);
    expect(
        (await ConversationRepository(db)
                .getById(result.conversationIds.single))!
            .deletedAt,
        isNull);
    expect(
        (await MessageRepository(db).getById('local'))!.content, 'local chat');
  });
  test('V06 same-time reverse overlap cannot silently keep contradictory order',
      () async {
    await seed();
    await db.into(db.messages).insert(MessagesCompanion.insert(
        id: 'later',
        conversationId: 'a',
        role: 'user',
        content: 'later',
        createdAt: 2));
    final file = await bundle(
        messages: [msg('later', created: 2), msg('local', created: 2)]);
    await expectLater(restore(file, resolution: ImportConflictResolution.merge),
        throwsA(isA<ImportException>()));
  });
  test('V07 older distinct timestamp can merge before local history', () async {
    await seed();
    final result = await restore(
        await bundle(
            messages: [msg('older', created: 1), msg('local', created: 2)]),
        resolution: ImportConflictResolution.merge);
    expect(result.messagesImported, 1);
    expect(
        (await MessageRepository(db).getAllByConversationOrderedStable('a'))
            .map((m) => m.id),
        ['older', 'local']);
  });
  test(
      'V08 selected basic card fields merge without changing plugin or settings fields',
      () async {
    await seed();
    await db.update(db.conversations).write(const ConversationsCompanion(
          voiceFile: Value('local-voice-preset'),
          recipeId: Value('local-recipe'),
          addressUser: Value('local-address'),
        ));
    await restore(
        await bundle(card: {
          'id': 'a',
          'display_name': 'New name',
          'persona_prompt': 'New persona',
          'self_address': 'Me'
        }),
        scopes: [SyncScope.characterCards],
        resolution: ImportConflictResolution.merge);
    final card = (await ConversationRepository(db).getById('a'))!;
    expect([card.displayName, card.personaPrompt, card.selfAddress],
        ['New name', 'New persona', 'Me']);
    expect([card.voiceFile, card.recipeId, card.addressUser],
        ['local-voice-preset', 'local-recipe', 'local-address']);
    expect(card.isMuted, isTrue);
    expect(
        (await MessageRepository(db).getById('local'))!.content, 'local chat');
  });
  test('V09 history-only merge leaves local basic card unchanged', () async {
    await seed();
    await restore(
        await bundle(card: {
          'id': 'a',
          'display_name': 'Other',
          'persona_prompt': 'Other'
        }),
        scopes: [SyncScope.chatHistory],
        resolution: ImportConflictResolution.merge);
    final card = (await ConversationRepository(db).getById('a'))!;
    expect([card.displayName, card.personaPrompt], ['A', 'private persona']);
  });
  test('V10 failed chat import rolls back basic card merge too', () async {
    await seed();
    await expectLater(
        restore(
            await bundle(card: {
              'id': 'a',
              'persona_prompt': 'changed'
            }, messages: [
              msg('bad', blocks: [
                {'id': 'b', 'type': 'code', 'data': {}}
              ])
            ]),
            resolution: ImportConflictResolution.merge),
        throwsA(isA<ImportException>()));
    expect((await ConversationRepository(db).getById('a'))!.personaPrompt,
        'private persona');
    expect(await MessageRepository(db).getById('bad'), isNull);
  });
  test('V11 card-only import does not rebuild local chat summary', () async {
    await seed();
    await ConversationRepository(db)
        .updateSummary('a', 'existing display summary', 10);
    await restore(await bundle(),
        scopes: [SyncScope.characterCards],
        resolution: ImportConflictResolution.merge);
    final card = (await ConversationRepository(db).getById('a'))!;
    expect([card.lastMessage, card.lastMessageTime],
        ['existing display summary', 10]);
  });
  test('V12 restored same-time messages paginate without loss or repetition',
      () async {
    final file = await bundle(
        messages: List.generate(7, (i) => msg('m-$i', created: 2)));
    await restore(file);
    final repo = MessageRepository(db);
    final all = await repo.getAllByConversationOrderedStable('a');
    expect(all.map((m) => m.id), List.generate(7, (i) => 'm-$i'));
    final seen = <String>[];
    Message? cursor;
    while (true) {
      final page = await repo.getByConversationStable('a',
          limit: 2, beforeTime: cursor?.createdAt, beforeId: cursor?.id);
      if (page.isEmpty) break;
      seen.addAll(page.map((m) => m.id));
      cursor = page.last;
      expect(seen.length, lessThanOrEqualTo(7));
    }
    expect(seen, List.generate(7, (i) => 'm-${6 - i}'));
  });
  test('R11 invalid format version is not marked compatible', () async {
    final file = await bundle(manifestOverrides: {'format_version': 0});
    expect((await importer.preview(file)).isCompatible, isFalse);
    await expectLater(restore(file), throwsA(isA<ImportException>()));
  });
  test('createNew with path-like ids cannot write outside job directory',
      () async {
    await seed();
    final result = await restore(
        await bundle(messages: [
          msg('../m', blocks: [
            {
              'id': '../../unsafe',
              'type': 'file',
              'data': {
                'filePath': 'files/note.txt',
                'fileName': 'note.txt',
                'fileSize': 1,
                'mimeType': 'text/plain'
              }
            }
          ])
        ], files: [
          ArchiveFile('files/note.txt', 1, [1])
        ]),
        resolution: ImportConflictResolution.createNew);
    expect(result.messagesImported, 1);
    expect((await importedFiles()).single.path,
        contains('/imported_files/import_'));
  });
}
