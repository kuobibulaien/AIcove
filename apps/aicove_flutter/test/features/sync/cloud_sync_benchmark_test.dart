import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:crypto/crypto.dart';
import 'package:aicove_flutter/src/features/sync/data/cloud_document.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/core/database/database.dart';
import 'package:aicove_flutter/src/core/media/media_store.dart';
import 'package:aicove_flutter/src/features/account/data/account_repository.dart';
import 'package:aicove_flutter/src/features/account/domain/account_port.dart';
import 'package:aicove_flutter/src/features/sync/data/cloud_api.dart';
import 'package:aicove_flutter/src/features/sync/data/cloud_local_store.dart';
import 'package:aicove_flutter/src/features/sync/data/cloud_sync_engine.dart';

import 'cloud_sync_contract_test.dart' show MemoryPreferences;

void main() {
  test(
    'measure recent readiness through real HTTP and on-disk Flutter database',
    () async {
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
      final backend = Platform.environment['AICOVE_SYNC_TEST_BACKEND']!;
      final python = Platform.environment['AICOVE_SYNC_TEST_PYTHON']!;
      final server = await Process.start(python, [
        '$backend/tests/serve_sync_benchmark.py',
      ], workingDirectory: backend);
      server.stderr.transform(utf8.decoder).listen(stderr.write);
      final ready = Completer<String>();
      server.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            if (line.startsWith('READY ') && !ready.isCompleted) {
              ready.complete(line.substring(6));
            }
          });
      addTearDown(() async {
        server.kill();
        await server.exitCode;
      });
      final address =
          'http://127.0.0.1:${await ready.future.timeout(const Duration(minutes: 3))}';
      final auth = await const CloudAccountApi().login(
        address,
        'benchmark',
        'local-benchmark-password',
      );
      final root = await Directory.systemTemp.createTemp('sync-bench-client-');
      final db = AppDatabase.forTesting(
        NativeDatabase(File('${root.path}/client.db')),
      );
      final prefs = MemoryPreferences();
      final local = CloudLocalStore(
        db,
        prefs,
        Directory('${root.path}/docs')..createSync(),
        Directory('${root.path}/support')..createSync(),
      );
      final media = MediaStore(
        Directory('${root.path}/media'),
        'benchmark-receiver',
      );
      final clock = Stopwatch();
      int? firstRecent, recentReady;
      final callbacks = <Future<void>>[];
      final sync = CloudSyncEngine(
        local,
        CloudApi(
          AccountConnection(
            server: address,
            user: auth.user,
            token: auth.accessToken,
          ),
        ),
        media,
        'fixture',
        clock: () => DateTime.utc(2026, 9, 13),
        onApplied: (kinds) {
          if (!kinds.contains('messages')) return;
          callbacks.add(() async {
            final rows =
                (await local.rows(
                      'SELECT COUNT(*) n FROM messages',
                    )).single['n']
                    as int;
            if (rows > 0 &&
                prefs.get('aicove.ui_models.v1') != null &&
                firstRecent == null) {
              firstRecent = clock.elapsedMilliseconds;
              // ignore: avoid_print
              print('FIRST_RECENT_MS=$firstRecent ROWS=$rows');
            }
            if (rows >= 250 && recentReady == null) {
              recentReady = clock.elapsedMilliseconds;
            }
          }());
        },
      );
      addTearDown(() async {
        sync.close();
        if (Platform.environment['AICOVE_BENCH_BASELINE'] != '1') {
          await (sync as dynamic).waitForMedia();
        }
        await media.close();
        await db.close();
        await root.delete(recursive: true);
      });
      clock.start();
      await sync.enable();
      final allText = clock.elapsedMilliseconds;
      await Future.wait(callbacks);
      if (Platform.environment['AICOVE_BENCH_BASELINE'] != '1') {
        await (sync as dynamic).waitForMedia();
      }
      final withMedia = clock.elapsedMilliseconds;
      final count = int.parse(
        Platform.environment['AICOVE_BENCH_MESSAGES'] ?? '10000',
      );
      expect(
        (await local.rows('SELECT COUNT(*) n FROM messages')).single['n'],
        count,
      );
      expect(
        (await local.rows('SELECT COUNT(*) n FROM message_blocks')).single['n'],
        count,
      );
      expect(
        (await local.rows(
          'SELECT COUNT(*) n FROM message_projection_mappings',
        )).single['n'],
        count * 2,
      );
      expect(firstRecent, isNotNull);
      final http = HttpClient();
      final response = await (await http.getUrl(
        Uri.parse('$address/fixture/metrics'),
      )).close();
      final metrics =
          jsonDecode(await response.transform(utf8.decoder).join())
              as Map<String, dynamic>;
      http.close();
      Stream<List<int>> contentBytes() async* {
        var after = '';
        while (true) {
          final rows = await local.rows(
            'SELECT id,content,raw_payload FROM messages WHERE id>? ORDER BY id LIMIT 100',
            [after],
          );
          if (rows.isEmpty) return;
          for (final row in rows) {
            yield utf8.encode(
              canonicalJson({
                'id': row['id'],
                'content': row['content'],
                'raw': jsonDecode(row['raw_payload'] as String),
              }),
            );
          }
          after = rows.last['id'] as String;
        }
      }

      expect(
        (await sha256.bind(contentBytes()).first).toString(),
        metrics['content_sha256'],
      );
      if (Platform.environment['AICOVE_BENCH_BASELINE'] != '1') {
        expect(
          (await local.rows(
            'SELECT count(*) n FROM cloud_media_queue',
          )).single['n'],
          0,
        );
      }
      var originals = 0;
      await for (final record in media.records()) {
        if (record.originalPath != null &&
            await File(record.originalPath!).exists()) {
          originals++;
        }
      }
      expect(originals, 10);
      Map<String, dynamic>? uploadReport;
      if (Platform.environment['AICOVE_BENCH_UPLOAD'] == '1') {
        // Clone only synthetic business records into a fresh source installation.
        // Seeding time is excluded; the timed section runs the ordinary upload path.
        final sourceRoot = Directory('${root.path}/source')..createSync();
        final sourceDb = AppDatabase.forTesting(
          NativeDatabase(File('${sourceRoot.path}/source.db')),
        );
        final sourcePrefs = MemoryPreferences()..values.addAll(prefs.values);
        final sourceLocal = CloudLocalStore(
          sourceDb,
          sourcePrefs,
          Directory('${sourceRoot.path}/docs')..createSync(),
          Directory('${sourceRoot.path}/support')..createSync(),
        );
        final sourceMedia = MediaStore(
          Directory('${sourceRoot.path}/media'),
          'upload-source',
        );
        await sourceLocal.state();
        for (final kind in ['conversations', 'messages']) {
          final ids = await local.rows('SELECT id FROM $kind ORDER BY id');
          for (var offset = 0; offset < ids.length; offset += 100) {
            await sourceDb.transaction(() async {
              for (final row in ids.skip(offset).take(100)) {
                final doc = (await local.read(kind, row['id'] as String))!;
                await sourceLocal.apply(kind, doc.id, doc.payload, false);
              }
            });
          }
        }
        await for (final record in media.records()) {
          final copied = await File(
            record.originalPath!,
          ).copy('${sourceRoot.path}/${record.asset.id}.png');
          final registered = await sourceMedia.register(
            copied.path,
            mimeType: 'image/png',
            createdAtMs: DateTime.utc(2026, 9, 13).millisecondsSinceEpoch,
          );
          expect(registered.asset.id, record.asset.id);
        }
        final login = await const CloudAccountApi().login(
          address,
          'uploader',
          'local-benchmark-password',
        );
        final uploadSync = CloudSyncEngine(
          sourceLocal,
          CloudApi(
            AccountConnection(
              server: address,
              user: login.user,
              token: login.accessToken,
            ),
          ),
          sourceMedia,
          'upload-fixture',
          clock: () => DateTime.utc(2026, 9, 13),
        );
        Future<Map<String, dynamic>> fixture(
          String path, {
          bool post = false,
        }) async {
          final client = HttpClient();
          try {
            final request = post
                ? await client.postUrl(Uri.parse('$address/fixture/$path'))
                : await client.getUrl(Uri.parse('$address/fixture/$path'));
            return jsonDecode(
                  await (await request.close()).transform(utf8.decoder).join(),
                )
                as Map<String, dynamic>;
          } finally {
            client.close();
          }
        }

        try {
          await fixture('reset-metrics', post: true);
          final uploadClock = Stopwatch()..start();
          await uploadSync.enable();
          final recordsUploaded = uploadClock.elapsedMilliseconds;
          if (Platform.environment['AICOVE_BENCH_BASELINE'] != '1') {
            await (uploadSync as dynamic).waitForMedia();
          }
          final uploadTotal = uploadClock.elapsedMilliseconds;
          final uploaded = await fixture('upload-state');
          expect(uploaded['messages'], count);
          expect(uploaded['content_sha256'], metrics['content_sha256']);
          uploadReport = {
            'records_uploaded_ms': recordsUploaded,
            'with_required_media_ms': uploadTotal,
            'content_sha256': uploaded['content_sha256'],
            'routes': (await fixture('metrics'))['routes'],
            'limits':
                'fresh source clone of the same synthetic messages; originals only, no prebuilt thumbnails; seeding excluded',
          };
        } finally {
          uploadSync.close();
          if (Platform.environment['AICOVE_BENCH_BASELINE'] != '1') {
            await (uploadSync as dynamic).waitForMedia();
          }
          await sourceMedia.close();
          await sourceDb.close();
        }
      }
      final report = {
        ...metrics,
        if (uploadReport != null) 'upload': uploadReport,
        'first_recent_and_settings_ms': firstRecent,
        'recent_250_ms': recentReady,
        'all_history_ms': allText,
        'with_required_media_ms': withMedia,
        'database_bytes': await File('${root.path}/client.db').length(),
        'database_kind': 'on-disk SQLite via real Flutter CloudSyncEngine',
        'limits':
            'synthetic dataset, injected per-request latency, loopback HTTP; excludes UI paint and real mobile/server network',
      };
      // ignore: avoid_print
      print('SYNC_BENCHMARK ${jsonEncode(report)}');
      final output = Platform.environment['AICOVE_BENCH_OUTPUT'];
      if (output != null) {
        await File(output).writeAsString(
          '${const JsonEncoder.withIndent('  ').convert(report)}\n',
        );
      }
    },
    timeout: const Timeout(Duration(minutes: 15)),
    skip: Platform.environment['AICOVE_SYNC_BENCHMARK'] != '1',
  );
}
