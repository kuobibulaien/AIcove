// Audit assertions describe the intended safe behavior. Known defects stay red
// until repaired; all databases/files are synthetic and isolated per test.
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:aicove_flutter/src/core/database/database.dart' hide SyncScope;
import 'package:aicove_flutter/src/core/database/repositories/repositories.dart';
import 'package:aicove_flutter/src/features/backup/data/conversation_exporter.dart';
import 'package:aicove_flutter/src/features/backup/data/conversation_importer.dart';
import 'package:aicove_flutter/src/features/backup/models/export_format.dart';
import 'package:aicove_flutter/src/features/memory/data/markdown_contact_memory_store.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_message_projection_codec.dart';
import 'package:aicove_flutter/src/features/memory/domain/contact_memory_port.dart';

const scopes = [
  SyncScope.characterCards,
  SyncScope.characterSettings,
  SyncScope.chatHistory,
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // Two independent in-memory connections intentionally model two devices.
  final previousWarning = driftRuntimeOptions.dontWarnAboutMultipleDatabases;
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);
  tearDownAll(() =>
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = previousWarning);
  late Directory root;
  late AppDatabase source;
  late AppDatabase target;
  late ConversationExporter exporter;
  late ConversationImporter importer;

  Future<void> conversation(AppDatabase db, String id, {String name = '角色'}) =>
      db
          .into(db.conversations)
          .insert(ConversationsCompanion.insert(
            id: id,
            title: name,
            displayName: name,
            createdAt: 1000,
            updatedAt: 1000,
            personaPrompt: const Value('人物设定'),
          ))
          .then((_) {});
  Future<void> message(AppDatabase db, String id,
          {String owner = 'a', String? raw, String content = '秘密聊天'}) =>
      db
          .into(db.messages)
          .insert(MessagesCompanion.insert(
              id: id,
              conversationId: owner,
              role: 'assistant',
              content: content,
              createdAt: 2000,
              rawPayload: Value(raw)))
          .then((_) {});
  Future<File> export(
          {List<String> selected = scopes,
          bool images = true,
          bool audio = true}) async =>
      File((await exporter.exportConversations(
              conversationIds: ['a'],
              options: ExportOptions(
                  scopes: selected,
                  includeImages: images,
                  includeAudio: audio)))
          .filePath);
  Future<ImportResult> restore(File file,
          {List<String> selected = scopes,
          Map<String, ImportConflictResolution> conflicts = const {}}) =>
      importer.import(
          file: file,
          selectedScopes: selected,
          selectedConversationIds: ['a'],
          conflictResolutions: conflicts);
  Future<Map<String, dynamic>> entry(File file, String name) async {
    final archive = ZipDecoder().decodeBytes(await file.readAsBytes());
    return jsonDecode(utf8.decode(archive.findFile(name)!.content as List<int>))
        as Map<String, dynamic>;
  }

  Future<File> rewrite(File file, String name, Object value) async {
    final archive = ZipDecoder().decodeBytes(await file.readAsBytes());
    final out = Archive();
    for (final item in archive) {
      if (item.name != name) out.addFile(item);
    }
    final bytes = utf8.encode(jsonEncode(value));
    out.addFile(ArchiveFile(name, bytes.length, bytes));
    final changed = File(p.join(root.path, 'edited.aicove'));
    await changed.writeAsBytes(ZipEncoder().encode(out)!);
    return changed;
  }

  Future<void> block(String id, String type, Map<String, dynamic> data) async {
    await source.into(source.messageBlocks).insert(
        MessageBlocksCompanion.insert(
            id: id,
            messageId: 'm',
            type: type,
            data: jsonEncode(data),
            createdAt: 2000));
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('aicove-transfer-audit-');
    source = AppDatabase.forTesting(NativeDatabase.memory());
    target = AppDatabase.forTesting(NativeDatabase.memory());
    Future<Directory> dir(String name) =>
        Directory(p.join(root.path, name)).create(recursive: true);
    exporter = ConversationExporter(
        convRepo: ConversationRepository(source),
        msgRepo: MessageRepository(source),
        blockRepo: MessageBlockRepository(source),
        temporaryDirectoryResolver: () => dir('export-temp'),
        documentsDirectoryResolver: () => dir('source-docs'),
        outputDirectoryResolver: () => dir('output'),
        appVersionResolver: () async => 'audit');
    importer = ConversationImporter(
        convRepo: ConversationRepository(target),
        msgRepo: MessageRepository(target),
        blockRepo: MessageBlockRepository(target),
        temporaryDirectoryResolver: () => dir('import-temp'),
        documentsDirectoryResolver: () => dir('target-docs'));
    await conversation(source, 'a');
    await message(source, 'm');
  });
  tearDown(() async {
    await source.close();
    await target.close();
    await root.delete(recursive: true);
  });

  test('T01 card-only export must not include private chat', () async {
    final file = await export(selected: [SyncScope.characterCards]);
    expect((await entry(file, 'messages.json'))['messages'], isEmpty);
  });
  test('T02 card-only import must not write chat', () async {
    await restore(await export(), selected: [SyncScope.characterCards]);
    expect(await target.select(target.messages).get(), isEmpty);
  });
  test('T03 no selected scopes must not write any data', () async {
    try {
      await restore(await export(), selected: []);
    } catch (_) {}
    expect(await target.select(target.conversations).get(), isEmpty);
  });
  for (final field in [
    'session_provider',
    'enabled_plugins',
    'recipe_id',
    'thinking_levels',
    'chat_background_blur_sigma',
    'context_start_message_id'
  ]) {
    test('T04 round trip preserves $field', () async {
      final values = <String, Object>{
        'session_provider': 'provider/model',
        'enabled_plugins': '["memory"]',
        'recipe_id': 'recipe-a',
        'thinking_levels': '{"provider/model":"high"}',
        'chat_background_blur_sigma': 12.0,
        'context_start_message_id': 'm'
      };
      await source.customStatement(
          'UPDATE conversations SET $field = ? WHERE id = ?',
          [values[field], 'a']);
      await restore(await export());
      final result = await target.customSelect(
          'SELECT $field FROM conversations WHERE id = ?',
          variables: [Variable.withString('a')]).getSingle();
      expect(result.data[field], values[field]);
    });
  }
  test('T05 asset avatar and remote poster survive round trip', () async {
    await source.update(source.conversations).write(
        const ConversationsCompanion(
            avatarUrl: Value('assets/characters/Arona.webp'),
            characterImage: Value('https://example.invalid/poster.png')));
    await restore(await export());
    final restored = await ConversationRepository(target).getById('a');
    expect([restored!.avatarUrl, restored.characterImage],
        ['assets/characters/Arona.webp', 'https://example.invalid/poster.png']);
  });
  test('T06 raw payload survives round trip', () async {
    const payload = '{"reasoningContent":"thinking","custom":"raw-evidence"}';
    await source
        .update(source.messages)
        .write(const MessagesCompanion(rawPayload: Value(payload)));
    await restore(await export());
    expect((await MessageRepository(target).getById('m'))!.rawPayload, payload);
  });
  test('T07 legacy memories survive memory-inclusive round trip', () async {
    await source.into(source.memories).insert(MemoriesCompanion.insert(
        id: 'memory-a',
        content: '喜欢安静',
        conversationId: const Value('a'),
        createdAt: 1000,
        updatedAt: 1000));
    await restore(await export(selected: [...scopes, SyncScope.memory]));
    expect((await target.select(target.memories).get()).map((m) => m.content),
        ['喜欢安静']);
  });
  test('T08 Markdown core and archived events survive round trip', () async {
    final store = MarkdownContactMemoryStore(() async =>
        Directory(p.join(root.path, 'source-support', 'contact_memories')));
    await store.save(ContactMemoryNotebook(
        ownerId: 'a',
        enabled: true,
        core: '喜欢安静',
        events: [
          ContactMemoryEvent(
              id: 'event-a',
              title: '散步',
              body: '一起散步',
              occurredAt: DateTime(2026, 9, 1))
        ]));
    // Unsupported memory remains a red completeness test; stop-loss must reject it.
    await restore(await export(selected: [...scopes, SyncScope.memory]));
    final restored = await MarkdownContactMemoryStore(() async =>
            Directory(p.join(root.path, 'target-support', 'contact_memories')))
        .load('a');
    expect([
      restored.core,
      restored.enabled,
      restored.events.map((e) => e.body).toList()
    ], [
      '喜欢安静',
      true,
      ['一起散步']
    ]);
  });
  test('T09 merge applies explicitly selected character settings', () async {
    await conversation(target, 'a', name: 'old');
    await source
        .update(source.conversations)
        .write(const ConversationsCompanion(isMuted: Value(true)));
    await restore(await export(),
        selected: [SyncScope.characterSettings],
        conflicts: {'a': ImportConflictResolution.merge});
    expect(
        (await ConversationRepository(target).getById('a'))!.isMuted, isTrue);
  });
  test('T10 replace failure leaves original chat intact', () async {
    await conversation(target, 'a');
    await message(target, 'original', content: 'must survive');
    final file = await rewrite(await export(), 'messages.json', {
      'version': 1,
      'messages': [
        {'id': 'bad', 'conversation_id': 'a', 'created_at': 'not-an-integer'}
      ]
    });
    await expectLater(
        restore(file, conflicts: {'a': ImportConflictResolution.replace}),
        throwsA(anything));
    expect((await MessageRepository(target).getById('original'))?.content,
        'must survive');
  });
  test('T11 malformed second message rolls back first and conversation',
      () async {
    final file = await rewrite(await export(), 'messages.json', {
      'version': 1,
      'messages': [
        {'id': 'first', 'conversation_id': 'a', 'content': 'partial'},
        {'id': 'bad', 'conversation_id': 'a', 'created_at': 'not-an-integer'}
      ]
    });
    await expectLater(restore(file), throwsA(anything));
    expect(await target.select(target.messages).get(), isEmpty);
    expect(await target.select(target.conversations).get(), isEmpty);
  });
  test('T12 colliding global message id must not steal another character chat',
      () async {
    await conversation(target, 'b');
    await message(target, 'm', owner: 'b', content: 'B private');
    try {
      await restore(await export());
    } catch (_) {}
    final original = await MessageRepository(target).getById('m');
    expect(original!.conversationId, 'b');
    expect(original.content, 'B private');
  });
  test('T13 same-day exports must not overwrite previous backup', () async {
    final first = await export();
    final bytes = await first.readAsBytes();
    await source
        .update(source.messages)
        .write(const MessagesCompanion(content: Value('changed')));
    final second = await export();
    expect(await first.readAsBytes(), bytes,
        reason: 'a later export must preserve the old backup bytes');
    expect(second.path, isNot(first.path));
  });
  test('T14 preview must not write outside extraction directory', () async {
    final sentinel = File(p.join(root.path, 'import-temp', 'sentinel.txt'));
    await sentinel.parent.create(recursive: true);
    await sentinel.writeAsString('unchanged');
    final archive =
        ZipDecoder().decodeBytes(await (await export()).readAsBytes());
    final bytes = utf8.encode('overwritten');
    archive.addFile(ArchiveFile('../sentinel.txt', bytes.length, bytes));
    final malicious = File(p.join(root.path, 'synthetic-traversal.aicove'));
    await malicious.writeAsBytes(ZipEncoder().encode(archive)!);
    try {
      await importer.preview(malicious);
    } catch (_) {}
    expect(await sentinel.readAsString(), 'unchanged');
  });
  test('T15 missing declared attachment must not silently succeed', () async {
    final file = await rewrite(await export(), 'messages.json', {
      'version': 1,
      'messages': [
        {
          'id': 'm',
          'conversation_id': 'a',
          'blocks': [
            {
              'id': 'image',
              'type': 'image',
              'data': {'localPath': 'files/missing.png'}
            }
          ]
        }
      ]
    });
    await expectLater(restore(file), throwsA(anything));
  });
  test('T16 includeVideo must copy local video and thumbnail', () async {
    final video = File(p.join(root.path, 'clip.mp4'));
    final thumb = File(p.join(root.path, 'thumb.jpg'));
    await video.writeAsBytes([1, 2, 3]);
    await thumb.writeAsBytes([4, 5, 6]);
    await block(
        'video', 'video', {'url': video.path, 'thumbnailPath': thumb.path});
    final archive =
        ZipDecoder().decodeBytes(await (await export()).readAsBytes());
    expect(archive.files.where((f) => f.name.startsWith('files/')).length, 2);
  });
  test('T17 included local image and audio physically restore', () async {
    final image = File(p.join(root.path, 'image.png'));
    final audio = File(p.join(root.path, 'audio.mp3'));
    await image.writeAsBytes([1, 2, 3]);
    await audio.writeAsBytes([4, 5, 6]);
    await block('image', 'image', {'localPath': image.path});
    await block('audio', 'audio', {'url': audio.path});
    await restore(await export());
    final blocks = await target.select(target.messageBlocks).get();
    for (final b in blocks) {
      final data = jsonDecode(b.data) as Map<String, dynamic>;
      final restored = File((data['localPath'] ?? data['url']) as String);
      expect(restored.path, startsWith(p.join(root.path, 'target-docs')));
      expect(await restored.readAsBytes(),
          b.type == 'image' ? [1, 2, 3] : [4, 5, 6]);
    }
  });
  test('T18 same timestamp chat order survives round trip', () async {
    await message(source, 'z');
    await message(source, 'b');
    await restore(await export());
    expect(
        (await MessageRepository(target).getAllByConversationOrderedStable('a'))
            .map((m) => m.id),
        ['m', 'z', 'b']);
  });
  test('T19 repeated merge is idempotent', () async {
    final file = await export();
    await restore(file);
    final result =
        await restore(file, conflicts: {'a': ImportConflictResolution.merge});
    expect(result.messagesImported, 0);
    expect(result.skipped, 1);
    expect((await target.select(target.messages).get()).length, 1);
  });
  test('T20 createNew maps message block and linked message ids', () async {
    await conversation(target, 'a');
    await block('linked', 'tool', {
      'id': 'linked',
      'messageId': 'm',
      'type': 'tool',
      'status': 'success',
      'toolName': 'audit_tool',
    });
    final result = await restore(await export(),
        conflicts: {'a': ImportConflictResolution.createNew});
    final newId = result.conversationIds.single;
    expect(newId, isNot('a'));
    final msg = (await MessageRepository(target)
            .getAllByConversationOrderedStable(newId))
        .single;
    final b = (await target.select(target.messageBlocks).get()).single;
    expect(msg.id, isNot('m'));
    expect(b.id, isNot('linked'));
    expect(jsonDecode(b.data)['messageId'], msg.id);
  });
  test('T22 topic handoff summary survives round trip', () async {
    await source.customStatement('''INSERT INTO topic_handoffs
      (id, owner_id, boundary_id, summary, source_ids, source_digest, created_at, memory_state)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)''',
        ['handoff', 'a', 'm', '承接摘要', '["m"]', 'digest', 2000, 'none']);
    await restore(await export());
    final rows =
        await target.customSelect('SELECT summary FROM topic_handoffs').get();
    expect(rows.map((r) => r.read<String>('summary')), ['承接摘要']);
  });
  test('T23 basic card and legacy settings round trip', () async {
    await source.update(source.conversations).write(
        const ConversationsCompanion(
            selfAddress: Value('我'),
            addressUser: Value('你'),
            isPinned: Value(true),
            isFavorite: Value(true),
            isMuted: Value(true),
            notificationSound: Value(false),
            chatBackgroundMaskOpacity: Value(0.3)));
    await restore(await export());
    final c = (await ConversationRepository(target).getById('a'))!;
    expect([
      c.displayName,
      c.personaPrompt,
      c.selfAddress,
      c.addressUser,
      c.isPinned,
      c.isFavorite,
      c.isMuted,
      c.notificationSound,
      c.chatBackgroundMaskOpacity
    ], [
      '角色',
      '人物设定',
      '我',
      '你',
      true,
      true,
      true,
      false,
      0.3
    ]);
  });
  test('T24 unknown ids must not produce a successful empty export', () async {
    await expectLater(
        exporter.exportConversations(conversationIds: ['missing']),
        throwsA(anything));
  });
  test('T25 reference path must not read outside archive', () async {
    // The only out-of-archive file is a synthetic sentinel under this test root.
    final secret = File(p.join(root.path, 'import-temp', 'private.txt'));
    await secret.parent.create(recursive: true);
    await secret.writeAsString('synthetic-private');
    // A legitimate file ensures the archive contains a files/ directory.
    final dummy = File(p.join(root.path, 'dummy.txt'));
    await dummy.writeAsString('legitimate');
    await block('dummy', 'file', {'filePath': dummy.path});
    final file = await rewrite(await export(), 'conversations.json', {
      'version': 1,
      'conversations': [
        {'id': 'a', 'chat_background_image_file': 'files/../../private.txt'}
      ]
    });
    try {
      await restore(file);
    } catch (_) {}
    final copies = await Directory(p.join(root.path, 'target-docs'))
        .list(recursive: true)
        .where((e) => e is File)
        .toList();
    final contents =
        await Future.wait(copies.cast<File>().map((f) => f.readAsString()));
    expect(contents, isNot(contains('synthetic-private')),
        reason: 'metadata cannot import files outside extraction root');
  });
  test('T26 card-only export must not include unselected private settings',
      () async {
    await source
        .update(source.conversations)
        .write(const ConversationsCompanion(isMuted: Value(true)));
    final data = await entry(await export(selected: [SyncScope.characterCards]),
        'conversations.json');
    expect((data['conversations'] as List).single.containsKey('is_muted'),
        isFalse);
  });
  test('T27 merge applies selected persona changes', () async {
    await conversation(target, 'a');
    await source
        .update(source.conversations)
        .write(const ConversationsCompanion(personaPrompt: Value('新设定')));
    await restore(await export(),
        selected: [SyncScope.characterCards],
        conflicts: {'a': ImportConflictResolution.merge});
    expect((await ConversationRepository(target).getById('a'))!.personaPrompt,
        '新设定');
  });
  test('T28 block id collision must not steal another character attachment',
      () async {
    await conversation(target, 'b');
    await message(target, 'other', owner: 'b');
    await target.into(target.messageBlocks).insert(
        MessageBlocksCompanion.insert(
            id: 'shared',
            messageId: 'other',
            type: 'text',
            data: '{"content":"B"}',
            createdAt: 1000));
    await block('shared', 'text', {'content': 'A'});
    try {
      await restore(await export());
    } catch (_) {}
    final original = await (target.select(target.messageBlocks)
          ..where((b) => b.id.equals('shared')))
        .getSingle();
    expect(original.messageId, 'other');
  });
  test('T29 excluded image and audio bytes do not enter archive', () async {
    final image = File(p.join(root.path, 'private.png'));
    final audio = File(p.join(root.path, 'private.mp3'));
    await image.writeAsBytes([1, 2, 3]);
    await audio.writeAsBytes([4, 5, 6]);
    await block('image', 'image', {'localPath': image.path});
    await block('audio', 'audio', {'url': audio.path});
    final archive = ZipDecoder().decodeBytes(
        await (await export(images: false, audio: false)).readAsBytes());
    expect(archive.files.where((f) => f.name.startsWith('files/')), isEmpty);
  });
  test('T30 selected conversation isolation and conflict skip', () async {
    await conversation(source, 'b');
    await message(source, 'b-msg', owner: 'b');
    final file = await export();
    expect(
        ((await entry(file, 'conversations.json'))['conversations'] as List)
            .length,
        1);
    await conversation(target, 'a', name: 'unchanged');
    final result =
        await restore(file, conflicts: {'a': ImportConflictResolution.skip});
    expect(result.conversationIds, isEmpty);
    expect(await target.select(target.messages).get(), isEmpty);
    expect((await ConversationRepository(target).getById('a'))!.displayName,
        'unchanged');
  });
  test('T31 corrupt ZIP must not change database', () async {
    final file = File(p.join(root.path, 'invalid.aicove'));
    await file.writeAsBytes([1, 2, 3]);
    await expectLater(restore(file), throwsA(anything));
    expect(await target.select(target.conversations).get(), isEmpty);
  });
  test('T32 supplement image stored in raw payload enters backup', () async {
    final image = File(p.join(root.path, 'supplement.png'));
    await image.writeAsBytes([7, 8, 9]);
    final payload =
        ChatMessageProjectionCodec.copyWithSupplementInsertOps(null, [
      StoredSupplementInsertOp(
          kind: 'image',
          textCharsBefore: 1,
          forceAppendToTail: true,
          localPath: image.path),
    ]);
    await source
        .update(source.messages)
        .write(MessagesCompanion(rawPayload: Value(jsonEncode(payload))));
    final archive =
        ZipDecoder().decodeBytes(await (await export()).readAsBytes());
    expect(archive.files.where((f) => f.name.startsWith('files/')).length, 1);
  });
  test('T21 future version is rejected without database changes', () async {
    final file = await export();
    final manifest = await entry(file, 'manifest.json');
    manifest['format_version'] = 999;
    final changed = await rewrite(file, 'manifest.json', manifest);
    expect((await importer.preview(changed)).isCompatible, isFalse);
    await expectLater(restore(changed), throwsA(isA<ImportException>()));
    expect(await target.select(target.conversations).get(), isEmpty);
  });
}
