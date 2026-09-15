import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:aicove_flutter/src/core/database/database.dart';
import 'package:aicove_flutter/src/features/sync/data/cloud_local_store.dart';
import 'package:aicove_flutter/src/features/sync/data/cloud_sync_scheduler.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase database;
  late CloudLocalStore local;
  late Directory directory;
  CloudSyncScheduler? scheduler;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    database = AppDatabase.forTesting(NativeDatabase.memory());
    directory = await Directory.systemTemp.createTemp('sync-wakeup-');
    local = CloudLocalStore(
      database,
      await SharedPreferences.getInstance(),
      directory,
      directory,
    );
    await database
        .into(database.conversations)
        .insert(
          ConversationsCompanion.insert(
            id: 'room',
            title: 'fixture',
            displayName: 'fixture',
            createdAt: 1,
            updatedAt: 1,
          ),
        );
    await local.execute('DELETE FROM cloud_dirty');
  });

  tearDown(() async {
    scheduler?.close();
    await database.close();
    await directory.delete(recursive: true);
  });

  Future<void> message(String id) => database
      .into(database.messages)
      .insert(
        MessagesCompanion.insert(
          id: id,
          conversationId: 'room',
          role: 'user',
          content: 'fixture',
          createdAt: 2,
        ),
      )
      .then((_) {});

  test(
    'a committed message wakes upload without waiting for the periodic timer',
    () async {
      final uploaded = Completer<void>();
      scheduler = CloudSyncScheduler(local, ({bool pollOnly = false}) async {
        expect(pollOnly, isFalse);
        expect(
          (await local.rows("SELECT 1 FROM messages WHERE id='new'")).length,
          1,
        );
        uploaded.complete();
      })..start();
      final entered = Completer<void>();
      final release = Completer<void>();
      final transaction = database.transaction(() async {
        await message('new');
        entered.complete();
        await release.future;
      });
      await entered.future;
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(
        uploaded.isCompleted,
        isFalse,
        reason: 'Uncommitted content must stay local',
      );
      release.complete();
      await transaction;
      await uploaded.future.timeout(const Duration(seconds: 2));
    },
  );

  test(
    'edits during an active network request trigger a follow-up without overlap',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      final second = Completer<void>();
      var active = 0;
      var calls = 0;
      scheduler = CloudSyncScheduler(local, ({bool pollOnly = false}) async {
        expect(++active, 1);
        calls++;
        if (calls == 1) {
          entered.complete();
          await release.future;
        } else {
          expect(pollOnly, isFalse);
          second.complete();
        }
        active--;
      })..start();
      final running = scheduler!.synchronize(pollOnly: true);
      await entered.future;
      await message('while-running');
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(calls, 1);
      release.complete();
      await second.future.timeout(const Duration(seconds: 2));
      await running;
      expect(calls, 2);
    },
  );

  test(
    'remote applies do not cause an upload echo and disposal cancels wakeups',
    () async {
      var calls = 0;
      scheduler = CloudSyncScheduler(local, ({bool pollOnly = false}) async {
        calls++;
      })..start();
      await database.transaction(() async {
        await local.execute('UPDATE cloud_client_state SET suspended=1');
        await message('remote');
        await local.execute('UPDATE cloud_client_state SET suspended=0');
      });
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(calls, 0);
      await message('local');
      scheduler!.close();
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(calls, 0);
    },
  );
}
