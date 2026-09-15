import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:aicove_flutter/src/core/database/database.dart'
    hide SyncScope, MessageBlock;
import 'package:aicove_flutter/src/core/database/repositories/repositories.dart';
import 'package:aicove_flutter/src/core/database/converters/database_converters.dart';
import 'package:aicove_flutter/src/core/models/message_block.dart';
import 'package:aicove_flutter/src/features/backup/data/conversation_exporter.dart';
import 'package:aicove_flutter/src/features/backup/data/conversation_importer.dart';
import 'package:aicove_flutter/src/features/backup/models/export_format.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_frontend_message_projection_service.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_message_projection_codec.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final previous = driftRuntimeOptions.dontWarnAboutMultipleDatabases;
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);
  tearDownAll(
      () => driftRuntimeOptions.dontWarnAboutMultipleDatabases = previous);
  late AppDatabase source;
  late AppDatabase target;
  late Directory root;
  late ConversationExporter exporter;
  late ConversationImporter importer;
  const scopes = [SyncScope.characterCards, SyncScope.chatHistory];
  Future<Directory> dir(String name) =>
      Directory(p.join(root.path, name)).create(recursive: true);
  Future<File> export(
          {bool images = true,
          bool audio = true,
          List<String> selected = scopes}) async =>
      File((await exporter.exportConversations(
              conversationIds: ['a'],
              options: ExportOptions(
                  scopes: selected,
                  includeImages: images,
                  includeAudio: audio)))
          .filePath);
  Future<void> restore(File file) async {
    await importer.import(
        file: file, selectedScopes: scopes, selectedConversationIds: ['a']);
  }

  Future<void> block(String type, String data) async {
    await source.into(source.messageBlocks).insert(
        MessageBlocksCompanion.insert(
            id: 'block', messageId: 'm', type: type, data: data, createdAt: 2));
  }

  Future<List<MessageBlock>> loadBlocks(AppDatabase db, String id) async {
    final rows = await MessageBlockRepository(db).getByMessage(id);
    final blocks = rows.map(MessageBlockConverter.fromDb).toList();
    expect(blocks.every((b) => b != null), isTrue,
        reason: 'restored blocks must be understood by the real DB converter');
    return blocks.cast<MessageBlock>();
  }

  const imageSnapshot = ImageGenerationSnapshot(providerId: 'original-provider',
    modelId:'original-model', requestProvider:'openai',prompt:'cat',negativePrompt:'old',
    width:1024,height:768,steps:31,guidanceScale:6.5,
    basePrompt: 'cat', baseNegativePrompt: 'base negative');
  Map<String, dynamic> payloadFor(String kind, String path, String shape) {
    final base = <String, dynamic>{
      'version': 1,
      'rawReplyText': '正文',
      'processedText': '正文',
      'providerConfig': {'apiKey': 'never-export-me'}
    };
    if (shape == 'supplement') {
      return ChatMessageProjectionCodec.copyWithSupplementInsertOps(base, [
        StoredSupplementInsertOp(
            kind: kind,
            textCharsBefore: 0,
            forceAppendToTail: false,
            localPath: kind == 'image' ? path : null,
            generationSnapshot: kind == 'image' ? imageSnapshot : null,
            audioUrl: kind == 'audio' ? path : null,
            text: '语音正文'),
      ]);
    }
    if (shape == 'plugin') {
      return {
        ...base,
        'pluginContents': [
          {
            'type': kind,
            'localPath': path,
            if (kind == 'image') 'generationSnapshot': imageSnapshot.toJson(),
            if (kind == 'audio') 'durationMs': 1250
          },
        ]
      };
    }
    if (shape == 'tool') {
      return {
        ...base,
        'toolAudioResults': [
          {'audioUrl': path, 'text': '语音正文'}
        ]
      };
    }
    final data = kind == 'image'
        ? ImageBlock(id: 'cached', messageId: 'cached-message', localPath: path, generationSnapshot:imageSnapshot)
            .toJson()
        : AudioBlock(
                id: 'cached',
                messageId: 'cached-message',
                url: path,
                text: '语音正文',
                durationSeconds: 1.25)
            .toJson();
    return {
      ...base,
      'projectedMessages': [
        {
          'id': 'cached-message',
          'role': 'assistant',
          'content': '正文',
          'createdAt': 2,
          'status': 'sent',
          'blocks': [data],
        }
      ]
    };
  }

  Future<void> storePayload(Map<String, dynamic> payload) => source
      .update(source.messages)
      .write(MessagesCompanion(rawPayload: Value(jsonEncode(payload))))
      .then((_) {});

  Future<List<File>> backups() async => (await dir('output'))
      .list()
      .where((f) => f is File)
      .cast<File>()
      .toList();
  setUp(() async {
    root = await Directory.systemTemp.createTemp('aicove-history-integrity-');
    source = AppDatabase.forTesting(NativeDatabase.memory());
    target = AppDatabase.forTesting(NativeDatabase.memory());
    exporter = ConversationExporter(
        convRepo: ConversationRepository(source),
        msgRepo: MessageRepository(source),
        blockRepo: MessageBlockRepository(source),
        temporaryDirectoryResolver: () => dir('temp'),
        documentsDirectoryResolver: () => dir('source-docs'),
        outputDirectoryResolver: () => dir('output'),
        appVersionResolver: () async => 'test');
    importer = ConversationImporter(
        convRepo: ConversationRepository(target),
        msgRepo: MessageRepository(target),
        blockRepo: MessageBlockRepository(target),
        temporaryDirectoryResolver: () => dir('temp'),
        documentsDirectoryResolver: () => dir('target-docs'));
    await source.into(source.conversations).insert(
        ConversationsCompanion.insert(
            id: 'a',
            title: '角色',
            displayName: '角色',
            personaPrompt: const Value('基本人设'),
            createdAt: 1,
            updatedAt: 1));
    await source.into(source.messages).insert(MessagesCompanion.insert(
        id: 'm',
        conversationId: 'a',
        role: 'assistant',
        content: '正文',
        createdAt: 2));
  });
  tearDown(() async {
    await source.close();
    await target.close();
    await root.delete(recursive: true);
  });

  for (final type in ['image', 'audio', 'file']) {
    test(
        'H01 selected $type missing locally must fail without damaging old backup',
        () async {
      final old = await export();
      final bytes = await old.readAsBytes();
      final key = type == 'image'
          ? 'localPath'
          : type == 'audio'
              ? 'url'
              : 'filePath';
      await block(type, jsonEncode({key: p.join(root.path, 'missing.bin')}));
      await expectLater(export(), throwsFormatException);
      expect(await old.readAsBytes(), bytes);
      expect((await backups()).length, 1);
      expect(await (await dir('temp')).list().toList(), isEmpty);
    });
  }
  for (final type in ['image', 'audio']) {
    test('H02 explicitly excluded missing $type must not block text backup',
        () async {
      await block(
          type,
          jsonEncode({
            type == 'image' ? 'localPath' : 'url':
                p.join(root.path, 'missing.bin')
          }));
      await restore(await export(images: false, audio: false));
      expect((await MessageRepository(target).getById('m'))!.content, '正文');
    });
  }
  for (final raw in ['{broken', '[]', 'null']) {
    test('H03 malformed nonempty block $raw must not silently become empty',
        () async {
      await block('image', raw);
      await expectLater(export(), throwsFormatException);
      expect(await backups(), isEmpty);
      expect(
          (await MessageBlockRepository(source).getById('block'))!.data, raw);
    });
  }
  test('H04 card-only export ignores corrupt unselected chat', () async {
    await block('image', '{broken');
    await restore(await export(selected: [SyncScope.characterCards]));
    expect((await ConversationRepository(target).getById('a'))!.personaPrompt,
        '基本人设');
    expect(await target.select(target.messages).get(), isEmpty);
  });
  for (final field in ['avatar', 'poster']) {
    test('H05 missing selected $field must not silently disappear from backup',
        () async {
      final path = p.join(root.path, 'missing.png');
      await source.update(source.conversations).write(ConversationsCompanion(
          avatarUrl: field == 'avatar' ? Value(path) : const Value.absent(),
          characterImage:
              field == 'poster' ? Value(path) : const Value.absent()));
      await expectLater(export(), throwsFormatException);
      expect(await backups(), isEmpty);
    });
  }
  for (final reference in [
    'assets/characters/Arona.webp',
    'https://example.invalid/avatar.png'
  ]) {
    test('H06 basic card retains supported reference $reference', () async {
      await source.update(source.conversations).write(ConversationsCompanion(
          avatarUrl: Value(reference), characterImage: Value(reference)));
      await restore(await export());
      final card = (await ConversationRepository(target).getById('a'))!;
      expect([card.avatarUrl, card.characterImage, card.personaPrompt],
          [reference, reference, '基本人设']);
    });
  }
  for (final kind in ['image', 'audio']) {
    for (final shape in [
      'supplement',
      'plugin',
      'cached',
      if (kind == 'audio') 'tool'
    ]) {
      test('H07 actual chat rebuild retains $shape $kind and bytes', () async {
        final media = File(
            p.join(root.path, 'supplement.${kind == 'image' ? 'png' : 'mp3'}'));
        await media.writeAsBytes([1, 2, 3]);
        final payload = payloadFor(kind, media.path, shape);
        await storePayload(payload);
        const projector = ChatFrontendMessageProjectionService();
        final before = projector.projectMessage(MessageConverter.fromDb(
            (await MessageRepository(source).getById('m'))!,
            blocks: await loadBlocks(source, 'm')));
        expect(
            before.expand((m) => m.blocks ?? <MessageBlock>[]).where(
                (b) => kind == 'image' ? b is ImageBlock : b is AudioBlock),
            hasLength(1),
            reason: 'fixture must really render media before export');
        final file = await export();
        await restore(file);
        final row = (await MessageRepository(target).getById('m'))!;
        expect([row.content, row.conversationId, row.role, row.createdAt],
            ['正文', 'a', 'assistant', 2]);
        final after = projector.projectMessage(MessageConverter.fromDb(row,
            blocks: await loadBlocks(target, 'm')));
        final mediaBlocks = after
            .expand((m) => m.blocks ?? <MessageBlock>[])
            .where((b) => kind == 'image' ? b is ImageBlock : b is AudioBlock)
            .toList();
        expect(mediaBlocks, hasLength(1));
        if (kind == 'image') {
          expect((mediaBlocks.single as ImageBlock).generationSnapshot!.toJson(), imageSnapshot.toJson());
        }
        final restoredPath = kind == 'image'
            ? (mediaBlocks.single as ImageBlock).localPath!
            : (mediaBlocks.single as AudioBlock).url;
        expect(restoredPath, startsWith(p.join(root.path, 'target-docs')));
        expect(await File(restoredPath).readAsBytes(), [1, 2, 3]);
        expect(
            after.every((m) =>
                m.sourceMessageId == 'm' &&
                m.createdAt.millisecondsSinceEpoch == 2),
            isTrue);
        expect(
            after
                .expand((m) => m.blocks ?? <MessageBlock>[])
                .whereType<TextBlock>()
                .map((b) => b.content),
            contains('正文'));
        final archive = ZipDecoder().decodeBytes(await file.readAsBytes());
        final manifest = jsonDecode(utf8
            .decode(archive.findFile('manifest.json')!.content as List<int>));
        expect(manifest['format_version'], 1);
        final messageJson = utf8
            .decode(archive.findFile('messages.json')!.content as List<int>);
        expect(messageJson, isNot(contains('never-export-me')));
        expect(messageJson, isNot(contains('raw_payload')));
        expect(messageJson, isNot(contains(media.path)));
        expect((await MessageRepository(source).getById('m'))!.rawPayload,
            jsonEncode(payload));
        expect(await source.select(source.messageBlocks).get(), isEmpty);
      });
    }
    test('H08 excluded $kind remains excluded even inside payload', () async {
      await storePayload(
          payloadFor(kind, p.join(root.path, 'missing'), 'cached'));
      await restore(await export(images: false, audio: false));
      expect(
          (await loadBlocks(target, 'm'))
              .where((b) => b is ImageBlock || b is AudioBlock),
          isEmpty);
      expect((await MessageRepository(target).getById('m'))!.content, '正文');
    });
    test('H09 missing supplemental $kind fails without new backup', () async {
      await storePayload(
          payloadFor(kind, p.join(root.path, 'missing'), 'supplement'));
      await expectLater(export(), throwsFormatException);
      expect(await backups(), isEmpty);
    });
  }
  for (final kind in ['image', 'audio']) {
    test('H10 createNew $kind rewrites DB, block and displayed ownership',
        () async {
      final media = File(p.join(root.path, 'media.bin'));
      await media.writeAsBytes([1, 2, 3]);
      await storePayload(payloadFor(kind, media.path, 'cached'));
      final file = await export();
      await restore(file);
      final result = await importer.import(
          file: file,
          selectedScopes: scopes,
          selectedConversationIds: ['a'],
          conflictResolutions: {'a': ImportConflictResolution.createNew});
      final messages = await MessageRepository(target)
          .getAllByConversationOrderedStable(result.conversationIds.single);
      expect(messages, hasLength(1));
      expect(messages.single.id, isNot('m'));
      final rows =
          await MessageBlockRepository(target).getByMessage(messages.single.id);
      expect(rows.where((b) => b.type == kind), hasLength(1));
      for (final row in rows) {
        final decoded = MessageBlockConverter.fromDb(row)!;
        expect(decoded.id, row.id);
        expect(decoded.messageId, messages.single.id);
      }
      final display = const ChatFrontendMessageProjectionService()
          .projectMessage(MessageConverter.fromDb(messages.single,
              blocks: await loadBlocks(target, messages.single.id)));
      expect(
          display.every((m) => m.sourceMessageId == messages.single.id), isTrue,
          reason:
              'a displayed copy must target its own raw row, not the original character');
      expect(messages.single.sourceMessageId, 'm',
          reason: 'DB import provenance must stay available for merge');
      expect(
          (await loadBlocks(target, 'm')).where(
              (b) => kind == 'image' ? b is ImageBlock : b is AudioBlock),
          hasLength(1));
    });
  }
  test('H11 repeated merge and existing media do not duplicate attachments',
      () async {
    final media = File(p.join(root.path, 'image.png'));
    await media.writeAsBytes([1, 2, 3]);
    await block(
        'image',
        jsonEncode(
            ImageBlock(id: 'block', messageId: 'm', localPath: media.path)
                .toJson()));
    await storePayload(payloadFor('image', media.path, 'supplement'));
    final file = await export();
    await restore(file);
    final merged = await importer.import(
        file: file,
        selectedScopes: scopes,
        selectedConversationIds: ['a'],
        conflictResolutions: {'a': ImportConflictResolution.merge});
    expect(merged.messagesImported, 0);
    expect(
        (await loadBlocks(target, 'm')).whereType<ImageBlock>(), hasLength(1));
  });
  test(
      'H12 selected cached representation takes precedence over stale supplements',
      () async {
    final media = File(p.join(root.path, 'image.png'));
    await media.writeAsBytes([1, 2, 3]);
    final payload = payloadFor('image', media.path, 'cached');
    payload['supplementInsertOps'] = payloadFor(
        'image',
        p.join(root.path, 'stale-missing'),
        'supplement')['supplementInsertOps'];
    await storePayload(payload);
    await restore(await export());
    expect(
        (await loadBlocks(target, 'm')).whereType<ImageBlock>(), hasLength(1));
  });
  test('H14 repeated references preserve occurrences but copy bytes once',
      () async {
    final media = File(p.join(root.path, 'image.png'));
    await media.writeAsBytes([1, 2, 3]);
    final payload = payloadFor('image', media.path, 'supplement');
    final op = (payload['supplementInsertOps'] as List).single;
    payload['supplementInsertOps'] = [op, op];
    await storePayload(payload);
    final first = await export();
    final second = await export();
    List<dynamic> blockIds(File file) {
      final archive = ZipDecoder().decodeBytes(file.readAsBytesSync());
      final json = jsonDecode(
          utf8.decode(archive.findFile('messages.json')!.content as List<int>));
      return (json['messages'][0]['blocks'] as List)
          .map((b) => b['id'])
          .toList();
    }

    expect(blockIds(first), blockIds(second));
    await restore(first);
    expect(
        (await loadBlocks(target, 'm')).whereType<ImageBlock>(), hasLength(2));
    final archive = ZipDecoder().decodeBytes(await first.readAsBytes());
    expect(
        archive.files.where((f) => f.name.startsWith('files/')), hasLength(1));
  });
  test('H15 inline image survives and remains excluded after a round trip',
      () async {
    final data =
        ImageBlock(id: 'cached', messageId: 'cached-message', base64: 'AQID')
            .toJson();
    await storePayload({
      'version': 1,
      'projectedMessages': [
        {
          'id': 'cached-message',
          'role': 'assistant',
          'content': '正文',
          'createdAt': 2,
          'blocks': [data],
        }
      ]
    });
    await restore(await export());
    expect(
        (await loadBlocks(target, 'm')).whereType<ImageBlock>().single.base64,
        'AQID');
    // Simulate an imported native block being exported again with images disabled.
    final restored =
        (await loadBlocks(target, 'm')).whereType<ImageBlock>().single;
    await source
        .update(source.messages)
        .write(const MessagesCompanion(rawPayload: Value(null)));
    await block('image', jsonEncode(restored.toJson()));
    final excluded = ZipDecoder()
        .decodeBytes(await (await export(images: false)).readAsBytes());
    final text =
        utf8.decode(excluded.findFile('messages.json')!.content as List<int>);
    expect(text, isNot(contains('AQID')));
    expect(
        (jsonDecode(text)['messages'][0]['blocks'] as List)
            .where((b) => b['type'] == 'image'),
        isEmpty);
  });
  test('H16 card-only export does not inspect or leak payload media', () async {
    await storePayload(
        payloadFor('audio', p.join(root.path, 'missing.mp3'), 'supplement'));
    final archive = ZipDecoder().decodeBytes(
        await (await export(selected: [SyncScope.characterCards]))
            .readAsBytes());
    expect(archive.files.where((f) => f.name.startsWith('files/')), isEmpty);
    final json = jsonDecode(
        utf8.decode(archive.findFile('messages.json')!.content as List<int>));
    expect(json['messages'], isEmpty);
  });
  test('H18 cached text must not resurrect an old native image', () async {
    final old = File(p.join(root.path, 'old.png'));
    await old.writeAsBytes([9]);
    await block(
        'image',
        jsonEncode(ImageBlock(id: 'block', messageId: 'm', localPath: old.path)
            .toJson()));
    await storePayload({
      'version': 1,
      'projectedMessages': [
        {
          'id': 'view',
          'role': 'assistant',
          'content': '正文',
          'createdAt': 2,
          'blocks': [],
        }
      ]
    });
    final before = const ChatFrontendMessageProjectionService().projectMessage(
        MessageConverter.fromDb((await MessageRepository(source).getById('m'))!,
            blocks: await loadBlocks(source, 'm')));
    expect(
        before
            .expand((m) => m.blocks ?? <MessageBlock>[])
            .whereType<ImageBlock>(),
        isEmpty);
    await restore(await export());
    expect((await loadBlocks(target, 'm')).whereType<ImageBlock>(), isEmpty);
  });
  test('H19 cached media replaces stale native media without reading its file',
      () async {
    final media = File(p.join(root.path, 'new.png'));
    await media.writeAsBytes([1, 2, 3]);
    await block(
        'image',
        jsonEncode(ImageBlock(
                id: 'block',
                messageId: 'm',
                localPath: p.join(root.path, 'old-missing.png'))
            .toJson()));
    await storePayload(payloadFor('image', media.path, 'cached'));
    await restore(await export());
    final image =
        (await loadBlocks(target, 'm')).whereType<ImageBlock>().single;
    expect(await File(image.localPath!).readAsBytes(), [1, 2, 3]);
  });
  test('H20 user message ignores assistant-only supplemental payload',
      () async {
    await source
        .update(source.messages)
        .write(const MessagesCompanion(role: Value('user')));
    await storePayload(payloadFor(
        'image', p.join(root.path, 'unused-missing.png'), 'supplement'));
    await restore(await export());
    expect((await loadBlocks(target, 'm')).whereType<ImageBlock>(), isEmpty);
    expect((await MessageRepository(target).getById('m'))!.role, 'user');
  });
  test('H17 text-only export ignores unused corrupt media payload', () async {
    await source
        .update(source.messages)
        .write(const MessagesCompanion(rawPayload: Value('{broken')));
    await restore(await export(images: false, audio: false));
    expect((await MessageRepository(target).getById('m'))!.content, '正文');
  });
  test('H13 malformed known media fails instead of silently dropping it',
      () async {
    await storePayload({
      'version': 1,
      'supplementInsertOps': [
        {'kind': 'image', 'localPath': 42}
      ]
    });
    await expectLater(export(), throwsFormatException);
    expect(await backups(), isEmpty);
  });
}
