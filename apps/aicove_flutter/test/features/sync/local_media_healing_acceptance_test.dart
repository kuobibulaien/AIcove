import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:aicove_flutter/src/core/database/database.dart'
    show AppDatabase;
import 'package:aicove_flutter/src/core/media/media_store.dart';
import 'package:aicove_flutter/src/core/models/message_block.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart' as domain;
import 'package:aicove_flutter/src/features/chat/services/chat_frontend_message_projection_service.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_message_projection_codec.dart';
import 'package:aicove_flutter/src/features/sync/data/cloud_local_store.dart';
import 'package:aicove_flutter/src/features/sync/data/lan_media.dart';

import 'lan_repository_test.dart' show LanMemoryPreferences;

/// Explicit opt-in only: first point this at a SQLite backup, then (after that
/// passes and a fresh backup exists) the authorized local database.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final path = Platform.environment['AICOVE_MEDIA_HEAL_DB'];
  final indexRoot = Platform.environment['AICOVE_MEDIA_HEAL_INDEX_ROOT'];
  test(
    'authorized local fixture repairs 31 references, 55 media blocks and 159 queue tombstones',
    () async {
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
      final db = AppDatabase.forTesting(NativeDatabase(File(path!)));
      final scratch = await Directory.systemTemp.createTemp(
        'media-heal-acceptance-',
      );
      final store = CloudLocalStore(
        db,
        LanMemoryPreferences(),
        scratch,
        scratch,
      );
      final media = MediaStore(Directory(indexRoot!), 'acceptance');
      // Freeze acceptance identities to the audit backup: a live client may
      // already have normalized some rows through the receive path.
      final baseline = sqlite.sqlite3.open(
        Platform.environment['AICOVE_MEDIA_HEAL_BASELINE_DB'] ?? path,
        mode: sqlite.OpenMode.readOnly,
      );
      addTearDown(() async {
        baseline.dispose();
        await media.close();
        await db.close();
        await scratch.delete(recursive: true);
      });
      final queue = baseline.select(
        "SELECT media_id FROM lan_media_queue WHERE json_extract(asset_json,'\$.unavailable')=1",
      );
      final dead = queue.map((r) => r['media_id'] as String).toSet();
      expect(dead, hasLength(159));
      final aligned = <String, Set<String>>{};
      final supplemented = <String, int>{};
      final oldIds = <String, Set<String>>{};
      final originals = <String, String>{};
      final blocks = <String, List<MessageBlock>>{};
      for (final row in await store.rows(
        'SELECT * FROM message_blocks WHERE deleted_at IS NULL',
      )) {
        (blocks[row['message_id'] as String] ??= []).add(
          MessageBlock.fromJson(
            Map<String, dynamic>.from(jsonDecode(row['data'] as String) as Map),
          ),
        );
      }
      for (final row in baseline.select(
        'SELECT * FROM messages WHERE deleted_at IS NULL AND replaced_by IS NULL AND raw_payload IS NOT NULL',
      )) {
        final raw = row['raw_payload'] as String;
        final payload = Map<String, dynamic>.from(jsonDecode(raw) as Map);
        final snapshots = ChatMessageProjectionCodec.projectedMessages(payload);
        final used = <String>{};
        for (final message in snapshots) {
          for (final block in message.blocks ?? const <MessageBlock>[]) {
            final source = block is ImageBlock
                ? block.localPath ?? block.url
                : block is AudioBlock
                ? block.url
                : null;
            if (source != null &&
                source.startsWith('aicove-media://') &&
                dead.contains(Uri.parse(source).host))
              used.add(Uri.parse(source).host);
          }
        }
        if (used.isEmpty) continue;
        final id = row['id'] as String;
        originals[id] =
            (await store.rows('SELECT content FROM messages WHERE id=?', [
                  id,
                ])).single['content']
                as String;
        if ((blocks[id] ?? []).isNotEmpty) {
          aligned[id] = used;
        } else {
          final messages = snapshots
              .where(
                (m) => (m.blocks ?? []).any(
                  (b) => b is ImageBlock || b is AudioBlock,
                ),
              )
              .toList();
          supplemented[id] = messages
              .expand((m) => m.blocks ?? <MessageBlock>[])
              .where((b) => b is ImageBlock || b is AudioBlock)
              .length;
          oldIds[id] = messages.map((m) => m.id).toSet();
        }
      }
      expect(aligned, hasLength(31));
      expect(supplemented, hasLength(17));
      expect(supplemented.values.fold<int>(0, (a, b) => a + b), 55);
      final changed = await store.normalizeLegacyMessageMedia();
      if (Platform.environment['AICOVE_MEDIA_HEAL_BASELINE_DB'] == null) {
        expect(changed, greaterThanOrEqualTo(48));
      }
      var validAligned = 0;
      var validSupplements = 0;
      const projection = ChatFrontendMessageProjectionService();
      Future<bool> exists(MessageBlock block) async {
        final String? source = block is ImageBlock
            ? block.localPath ?? block.url
            : block is AudioBlock
            ? block.url
            : null;
        if (source == null) return false;
        if (source.startsWith('aicove-media://')) {
          final record = await media.load(Uri.parse(source).host);
          final original = record?.originalPath;
          if (original == null || !await File(original).exists()) return false;
          return (await media.original(
            Uri.parse(source).host,
            allowDownload: false,
          )).exists();
        }
        final path = source.replaceFirst(RegExp(r'^file://'), '');
        if (!await File(path).exists()) return false;
        final managed = RegExp(
          r'/cloud_media/assets/([0-9a-f]{64})/',
        ).firstMatch(path);
        if (managed != null)
          return (await media.original(
            managed[1]!,
            allowDownload: false,
          )).exists();
        return true;
      }

      for (final id in {...aligned.keys, ...supplemented.keys}) {
        final row = (await store.rows('SELECT * FROM messages WHERE id=?', [
          id,
        ])).single;
        expect(row['content'], originals[id]);
        final payload = Map<String, dynamic>.from(
          jsonDecode(row['raw_payload'] as String) as Map,
        );
        final projected = projection.projectMessage(
          domain.Message(
            id: id,
            role: row['role'] as String,
            content: row['content'] as String,
            createdAt: DateTime.fromMillisecondsSinceEpoch(
              row['created_at'] as int,
            ),
            blocks: blocks[id],
            rawPayload: payload,
          ),
        );
        final mediaBlocks = projected
            .expand((m) => m.blocks ?? <MessageBlock>[])
            .where((b) => b is ImageBlock || b is AudioBlock)
            .toList();
        if (aligned.containsKey(id)) {
          for (final old in aligned[id]!) {
            expect(row['raw_payload'], isNot(contains(old)));
          }
          if (await Future.wait(
            mediaBlocks.map(exists),
          ).then((values) => values.any((v) => v)))
            validAligned++;
        } else {
          expect(
            ChatMessageProjectionCodec.supplementInsertOps(payload),
            hasLength(supplemented[id]!),
          );
          expect(mediaBlocks, hasLength(supplemented[id]!));
          expect(
            projected.map((m) => m.id).toSet().containsAll(oldIds[id]!),
            isTrue,
          );
          validSupplements += (await Future.wait(
            mediaBlocks.map(exists),
          )).where((v) => v).length;
        }
      }
      expect(validAligned, 27);
      expect(validSupplements, 12);
      final lan = LanMedia(
        store,
        media,
        (_, _) async => throw StateError('acceptance must not use network'),
      );
      await lan.reconcileQueue(ids: dead);
      expect(
        await store.rows(
          "SELECT media_id FROM lan_media_queue WHERE json_extract(asset_json,'\$.unavailable')=1",
        ),
        isEmpty,
      );
      expect(await store.normalizeLegacyMessageMedia(), 0);
      expect(await lan.reconcileQueue(ids: dead), 0);
      // Counts are intentionally content-free, suitable for the verification log.
      // ignore: avoid_print
      print(
        'MEDIA_HEAL_ACCEPTANCE changed=$changed aligned=31 validAligned=$validAligned messages=17 media=55 validSupplements=$validSupplements cleared=159 counts=${await lan.counts()}',
      );
    },
    skip: path == null || indexRoot == null,
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
