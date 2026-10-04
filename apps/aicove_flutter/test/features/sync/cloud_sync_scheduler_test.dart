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

  var clock = DateTime(2026, 10, 4, 9);
  CloudSyncScheduler make(Future<bool> Function() run) =>
      scheduler = CloudSyncScheduler(local, run, now: () => clock);

  test(
    'first launch runs one round, then waits for the daily interval',
    () async {
      var calls = 0;
      make(() async {
        calls++;
        return true;
      }).start();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(calls, 1);
      clock = clock.add(const Duration(hours: 7, minutes: 59));
      await scheduler!.synchronizeIfDue();
      expect(calls, 1);
      clock = clock.add(const Duration(minutes: 1));
      await scheduler!.synchronizeIfDue();
      expect(calls, 2);
    },
  );

  test('a failed round retries after an hour, not on every resume', () async {
    var calls = 0;
    make(() async {
      calls++;
      return false;
    });
    await scheduler!.synchronizeIfDue();
    clock = clock.add(const Duration(minutes: 59));
    await scheduler!.synchronizeIfDue();
    expect(calls, 1);
    clock = clock.add(const Duration(minutes: 1));
    await scheduler!.synchronizeIfDue();
    expect(calls, 2);
  });

  test('local edits never wake the network; manual sync always runs', () async {
    var calls = 0;
    make(() async {
      calls++;
      return true;
    });
    await scheduler!.synchronize();
    await message('local');
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await scheduler!.synchronizeIfDue();
    expect(calls, 1);
    await scheduler!.synchronize();
    expect(calls, 2);
  });

  test('concurrent requests join one round and disposal stops it', () async {
    final release = Completer<void>();
    var active = 0, calls = 0;
    make(() async {
      expect(++active, 1);
      calls++;
      await release.future;
      active--;
      return true;
    });
    final first = scheduler!.synchronize();
    final second = scheduler!.synchronize();
    release.complete();
    await Future.wait([first, second]);
    expect(calls, 1);
    scheduler!.close();
    await scheduler!.synchronize();
    expect(calls, 1);
  });
}
