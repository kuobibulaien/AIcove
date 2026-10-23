import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aicove_flutter/src/core/database/database.dart';
import 'package:aicove_flutter/src/core/media/media_store.dart';
import 'package:aicove_flutter/src/core/sync/cloud_local_write.dart';
import 'package:aicove_flutter/src/core/sync/cloud_setting_policy.dart';
import 'package:aicove_flutter/src/features/agent_plugins/file_change_journal.dart';
import 'package:aicove_flutter/src/features/assistant/application/assistant_provider_tools.dart';
import 'package:aicove_flutter/src/features/assistant/application/assistant_settings_tools.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/features/settings/data/local/ui_models_store_local_data_source.dart';
import 'package:aicove_flutter/src/features/sync/data/cloud_document.dart';
import 'package:aicove_flutter/src/features/sync/data/cloud_local_store.dart';
import 'package:aicove_flutter/src/features/sync/data/cloud_media_codec.dart';
import 'package:aicove_flutter/src/features/sync/data/lan_repository.dart';
import 'package:aicove_flutter/src/features/sync/domain/lan_contract.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _HeldSettings extends AppSettingsNotifier {
  Completer<void>? entered;
  Completer<void>? resume;

  @override
  Future<T> transaction<T>(Future<T> Function() body) {
    final signal = entered;
    final gate = resume;
    if (signal == null) return super.transaction(body);
    entered = null;
    return super.transaction(() async {
      signal.complete();
      await gate!.future;
      return body();
    });
  }
}

class _PausedPreferences implements SharedPreferences {
  _PausedPreferences(this.delegate);
  final SharedPreferences delegate;
  final entered = Completer<void>();
  final resume = Completer<void>();

  @override
  Object? get(String key) => delegate.get(key);

  @override
  String? getString(String key) => delegate.getString(key);

  @override
  Set<String> getKeys() => delegate.getKeys();

  @override
  Future<void> reload() => delegate.reload();

  @override
  Future<bool> setString(String key, String value) async {
    if (key == cloudUiModelsKey && !entered.isCompleted) {
      entered.complete();
      await resume.future;
    }
    return delegate.setString(key, value);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final providerUndo in [false, true]) {
    test('${providerUndo ? 'provider' : 'setting'} undo checks persistence '
        'instead of a stale provider value', () async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container.read(appSettingsProvider.future);
      final notifier = container.read(appSettingsProvider.notifier);
      await notifier.setUserName('after');
      await notifier.editProvider(providerId: 'deepseek', displayName: 'after');
      const source = UiModelsStoreLocalDataSource();
      if (providerUndo) {
        await source.updateProvider(
          providerId: 'deepseek',
          displayName: 'manual',
        );
      } else {
        await source.updatePartial({'user_name': 'manual'});
      }
      final CheckedChangeApplier applier = providerUndo
          ? AssistantProviderApplier(notifier: () => notifier)
          : AssistantSettingApplier(notifier: () => notifier);
      expect(
        await applier.applyIfCurrent(
          {
            if (providerUndo)
              'provider_id': 'deepseek'
            else
              'key': 'profile.user_name',
            if (providerUndo) 'display_name': 'after' else 'value': 'after',
          },
          {
            if (providerUndo)
              'provider_id': 'deepseek'
            else
              'key': 'profile.user_name',
            if (providerUndo) 'display_name': 'before' else 'value': 'before',
          },
        ),
        isFalse,
      );
      final saved = mapUiModelsToAppSettings(await source.fetchAll());
      expect(
        providerUndo
            ? saved.getProvider('deepseek')!.displayName
            : saved.userName,
        'manual',
      );
    });

    test('${providerUndo ? 'provider' : 'setting'} undo survives invalidation '
        'while holding the write lock', () async {
      SharedPreferences.setMockInitialValues({});
      final notifier = _HeldSettings();
      final container = ProviderContainer(
        overrides: [appSettingsProvider.overrideWith(() => notifier)],
      );
      addTearDown(container.dispose);
      await container.read(appSettingsProvider.future);
      await notifier.setUserName('after');
      await notifier.editProvider(providerId: 'deepseek', displayName: 'after');
      final CheckedChangeApplier applier = providerUndo
          ? AssistantProviderApplier(notifier: () => notifier)
          : AssistantSettingApplier(notifier: () => notifier);
      final expected = <String, Object?>{
        if (providerUndo)
          'provider_id': 'deepseek'
        else
          'key': 'profile.user_name',
        if (providerUndo) 'display_name': 'after' else 'value': 'after',
      };
      final restored = {
        ...expected,
        if (providerUndo) 'display_name': 'before' else 'value': 'before',
      };
      final entered = Completer<void>();
      final resume = Completer<void>();
      notifier.entered = entered;
      notifier.resume = resume;
      final undo = applier.applyIfCurrent(expected, restored);
      await entered.future;
      // This rebuild starts outside the undo's reentrant Zone.
      container.invalidate(appSettingsProvider);
      final rebuilt = container.read(appSettingsProvider.future);
      resume.complete();
      expect(await undo.timeout(const Duration(seconds: 2)), isTrue);
      await rebuilt.timeout(const Duration(seconds: 2));
      await notifier
          .setHideUserAvatar(true)
          .timeout(const Duration(seconds: 2));
      final fresh = ProviderContainer();
      addTearDown(fresh.dispose);
      final saved = await fresh.read(appSettingsProvider.future);
      expect(
        providerUndo
            ? saved.getProvider('deepseek')!.displayName
            : saved.userName,
        'before',
      );
      expect(saved.hideUserAvatar, isTrue);
    });
  }

  for (final path in ['cloud', 'lan', 'normalization']) {
    test(
      '$path sync apply and a local read-merge-write retain both edits',
      () async {
        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();
        const source = UiModelsStoreLocalDataSource();
        final initial = await source.fetchAll();
        final db = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(db.close);
        final root = await Directory.systemTemp.createTemp('settings-storage-');
        addTearDown(() => root.delete(recursive: true));
        final paused = _PausedPreferences(prefs);
        addTearDown(() {
          if (!paused.resume.isCompleted) paused.resume.complete();
        });
        final local = CloudLocalStore(db, paused, root, root);
        final id = cloudObjectId('preference:$cloudUiModelsKey');
        final payload = <String, dynamic>{
          'storage': 'preference',
          'key': cloudUiModelsKey,
          'json_value': jsonEncode({
            ...initial,
            'compaction_model': 'remote:model',
          }),
        };
        final Future<void> sync;
        if (path == 'lan') {
          final media = MediaStore(Directory('${root.path}/media'), 'local');
          addTearDown(media.close);
          final repo = LanRepository(local, CloudMediaCodec(media), 'local');
          await repo.capture();
          final manifest = await repo.manifest();
          final head =
              (manifest['items'] as List).singleWhere(
                    (item) =>
                        item['kind'] == 'settings' && item['entity_id'] == id,
                  )
                  as Map;
          final revision = await repo.revision(
            (head['hashes'] as List).single as String,
          );
          sync = repo.receive(
            LanRevision(
              kind: 'settings',
              id: id,
              vector: {...revision.vector, 'remote': 1},
              payload: payload,
            ),
          );
        } else if (path == 'normalization') {
          // Force load's migration/normalization write-back on the old snapshot.
          final legacy = {...initial, 'user_name': 'local'}
            ..remove('applied_migrations');
          await prefs.setString(cloudUiModelsKey, jsonEncode(legacy));
          sync = cloudLocalWrite(
            () => local.apply('settings', id, payload, false),
          );
        } else {
          // Direct apply must take the lock too, independently of either engine.
          sync = local.apply('settings', id, payload, false);
        }
        await paused.entered.future.timeout(const Duration(seconds: 2));
        final edit = path == 'normalization'
            ? source.fetchAll()
            : source.updatePartial({
                'user_name': 'local',
                'memory_model': 'local:model',
              });
        // Flush pending microtasks through an event turn, without a timing race.
        await Future<void>(() {});
        paused.resume.complete();
        await Future.wait([sync, edit]).timeout(const Duration(seconds: 2));
        final saved = jsonDecode(prefs.getString(cloudUiModelsKey)!) as Map;
        expect(saved['compaction_model'], 'remote:model');
        expect(saved['user_name'], 'local');
        if (path != 'normalization') {
          expect(saved['memory_model'], 'local:model');
        }
      },
    );
  }

  test(
    'different Zones serialize and a failed write releases the queue',
    () async {
      final entered = Completer<void>();
      final resume = Completer<void>();
      addTearDown(() {
        if (!resume.isCompleted) resume.complete();
      });
      final order = <int>[];
      final first = runZoned(
        () => cloudLocalWrite(() async {
          entered.complete();
          await resume.future;
          await cloudLocalWrite(() async => order.add(1));
          throw StateError('expected');
        }),
      );
      final failure = expectLater(first, throwsStateError);
      await entered.future;
      final second = runZoned(() => cloudLocalWrite(() async => order.add(2)));
      await Future<void>(() {});
      expect(order, isEmpty);
      resume.complete();
      await Future.wait([failure, second]).timeout(const Duration(seconds: 2));
      expect(order, [1, 2]);
    },
  );

  test('a detached continuation cannot reuse an expired write lease', () async {
    late Zone expired;
    await cloudLocalWrite(() async => expired = Zone.current);
    final entered = Completer<void>();
    final resume = Completer<void>();
    addTearDown(() {
      if (!resume.isCompleted) resume.complete();
    });
    final held = cloudLocalWrite(() async {
      entered.complete();
      await resume.future;
    });
    await entered.future;
    var ran = false;
    final detached = expired.run(() => cloudLocalWrite(() async => ran = true));
    await Future<void>(() {});
    expect(ran, isFalse);
    resume.complete();
    await Future.wait([held, detached]).timeout(const Duration(seconds: 2));
    expect(ran, isTrue);
  });
}
