import 'dart:convert';
import 'dart:io';

import 'package:aicove_flutter/src/core/database/database.dart';
import 'package:aicove_flutter/src/core/storage/app_data_directory.dart';
import 'package:drift/drift.dart' hide isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

const oldDocs = r'C:\Users\amy\Documents';
const newDir = r'C:\Users\amy\AppData\Roaming\com.example\aicove_flutter';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PathRewrites', () {
    final rewrites = PathRewrites(oldDocs, newDir);

    test('rewrites native, JSON-escaped and forward-slash spellings', () {
      expect(
        rewrites.apply(r'C:\Users\amy\Documents\wallpapers\a.png'),
        r'C:\Users\amy\AppData\Roaming\com.example\aicove_flutter\wallpapers\a.png',
      );
      expect(
        rewrites.apply(r'C:\Users\amy\Documents/voices/v.wav'),
        r'C:\Users\amy\AppData\Roaming\com.example\aicove_flutter/voices/v.wav',
      );
      final stored = jsonEncode({
        'path': r'C:\Users\amy\Documents\generated_images\p\m\1.png',
      });
      expect(
        jsonDecode(rewrites.apply(stored))['path'],
        r'C:\Users\amy\AppData\Roaming\com.example\aicove_flutter\generated_images\p\m\1.png',
      );
      expect(
        rewrites.apply('file:///C:/path/to/home/Documents/imported_files/x.jpg'),
        'file:///C:/path/to/home/AppData/Roaming/com.example/aicove_flutter/imported_files/x.jpg',
      );
    });

    test('leaves the user\'s own Documents files alone', () {
      for (final value in [
        r'C:\Users\amy\Documents\notes.txt',
        r'C:\Users\amy\Documents\logsheet.xlsx',
        r'C:\Users\amy\Documents\AIcove-export.zip',
        'no path here',
      ]) {
        expect(rewrites.apply(value), value);
      }
    });
  });

  group('moveEntries', () {
    late Directory root, from, to;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('app_data_move');
      from = await Directory(p.join(root.path, 'Documents')).create();
      to = Directory(p.join(root.path, 'support'));
    });
    tearDown(() => root.delete(recursive: true));

    Future<void> write(Directory dir, String relative, String content) async {
      final file = File(p.join(dir.path, relative));
      await file.parent.create(recursive: true);
      await file.writeAsString(content);
    }

    test('moves database and known folders, leaves other files', () async {
      await write(from, 'aicove.db', 'db');
      await write(from, 'aicove.db-wal', 'wal');
      await write(from, 'wallpapers/w.png', 'w');
      await write(from, 'aicove/sillytavern_presets/a.json', 'a');
      await write(from, 'my_thesis.docx', 'mine');

      expect(await AppDataMigration.moveEntries(from, to), isTrue);

      expect(await File(p.join(to.path, 'aicove.db')).readAsString(), 'db');
      expect(await File(p.join(to.path, 'aicove.db-wal')).readAsString(), 'wal');
      expect(await File(p.join(to.path, 'wallpapers/w.png')).exists(), isTrue);
      expect(
        await File(p.join(to.path, 'aicove/sillytavern_presets/a.json')).exists(),
        isTrue,
      );
      expect(await File(p.join(from.path, 'aicove.db')).exists(), isFalse);
      expect(await Directory(p.join(from.path, 'wallpapers')).exists(), isFalse);
      expect(await File(p.join(from.path, 'my_thesis.docx')).exists(), isTrue);
    });

    test('merges into existing folders without overwriting', () async {
      await write(from, 'logs/old.log', 'old');
      await write(from, 'logs/same.log', 'from-documents');
      await write(to, 'logs/same.log', 'already-new');

      expect(await AppDataMigration.moveEntries(from, to), isTrue);

      expect(await File(p.join(to.path, 'logs/old.log')).readAsString(), 'old');
      expect(
        await File(p.join(to.path, 'logs/same.log')).readAsString(),
        'already-new',
      );
      expect(
        await File(p.join(from.path, 'logs/same.log')).readAsString(),
        'from-documents',
      );
    });

    test('keeps both databases when the new location already has one', () async {
      await write(from, 'aicove.db', 'old');
      await write(to, 'aicove.db', 'new');

      expect(await AppDataMigration.moveEntries(from, to), isTrue);

      expect(await File(p.join(to.path, 'aicove.db')).readAsString(), 'new');
      expect(await File(p.join(from.path, 'aicove.db')).readAsString(), 'old');
    });

    test('rolls back when the old database cannot be removed', () async {
      await write(from, 'aicove.db', 'db');
      await write(from, 'aicove.db-wal', 'wal');
      // Read-only folder: copying works, deleting fails (like a file another
      // running copy of the app still holds open on Windows).
      await Process.run('chmod', ['555', from.path]);
      addTearDown(() => Process.run('chmod', ['755', from.path]));

      expect(await AppDataMigration.moveEntries(from, to), isFalse);

      expect(await File(p.join(from.path, 'aicove.db')).readAsString(), 'db');
      expect(await File(p.join(to.path, 'aicove.db')).exists(), isFalse);
      expect(await File(p.join(to.path, 'aicove.db-wal')).exists(), isFalse);
    }, skip: Platform.isWindows);

    test('nothing to move is a success', () async {
      expect(await AppDataMigration.moveEntries(from, to), isTrue);
    });
  });

  test('rewritePreferences rewrites strings and lists once', () async {
    SharedPreferences.setMockInitialValues({
      'wallpaper': r'C:\Users\amy\Documents\wallpapers\w.png',
      'paths': [r'C:\Users\amy\Documents\voices\a.wav', 'other'],
      'count': 3,
    });
    final preferences = await SharedPreferences.getInstance();
    final rewrites = PathRewrites(oldDocs, newDir);

    await AppDataMigration.rewritePreferences(preferences, rewrites);

    expect(preferences.getString('wallpaper'), '$newDir\\wallpapers\\w.png');
    expect(preferences.getStringList('paths'), ['$newDir\\voices\\a.wav', 'other']);
    expect(preferences.getInt('count'), 3);
    expect(preferences.getBool(AppDataMigration.preferencesMarker), isTrue);

    await preferences.setString('wallpaper', r'C:\Users\amy\Documents\wallpapers\b.png');
    await AppDataMigration.rewritePreferences(preferences, rewrites);
    expect(
      preferences.getString('wallpaper'),
      r'C:\Users\amy\Documents\wallpapers\b.png',
      reason: 'runs only once',
    );
  });

  test('rewriteDatabase rewrites paths without marking rows for sync', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await db.customSelect('SELECT 1').get(); // open: installs sync tracking

    final columns = await db.customSelect('PRAGMA table_info(conversations)').get();
    final values = <String, Object>{};
    for (final column in columns) {
      final name = column.data['name'] as String;
      if (column.data['notnull'] == 1 && column.data['dflt_value'] == null) {
        final type = (column.data['type'] as String).toUpperCase();
        values[name] = type.contains('INT') ? 0 : 'x';
      }
    }
    values['id'] = 'c1';
    values['avatar_url'] = r'C:\Users\amy\Documents\voices\..\wallpapers\a.png';
    await db.customStatement(
      'INSERT INTO conversations(${values.keys.join(',')}) '
      'VALUES(${values.keys.map((_) => '?').join(',')})',
      values.values.toList(),
    );
    await db.customStatement('DELETE FROM cloud_dirty');
    await db.customStatement('DELETE FROM cloud_setting_times');

    await AppDataMigration.rewriteDatabase(db, PathRewrites(oldDocs, newDir));

    final row = await db
        .customSelect("SELECT avatar_url FROM conversations WHERE id='c1'")
        .getSingle();
    expect(row.data['avatar_url'], '$newDir\\voices\\..\\wallpapers\\a.png');
    expect(await db.customSelect('SELECT * FROM cloud_dirty').get(), isEmpty);
    expect(await db.customSelect('SELECT * FROM cloud_setting_times').get(), isEmpty);
    final state = await db
        .customSelect('SELECT suspended FROM cloud_client_state WHERE id=1')
        .getSingle();
    expect(state.data['suspended'], 0);

    // Marked done: a second pass leaves later values alone.
    await db.customUpdate(
      "UPDATE conversations SET avatar_url=? WHERE id='c1'",
      variables: [Variable.withString(r'C:\Users\amy\Documents\wallpapers\b.png')],
    );
    await AppDataMigration.rewriteDatabase(db, PathRewrites(oldDocs, newDir));
    final again = await db
        .customSelect("SELECT avatar_url FROM conversations WHERE id='c1'")
        .getSingle();
    expect(again.data['avatar_url'], r'C:\Users\amy\Documents\wallpapers\b.png');
  });

  test('appDataDirectory keeps Documents where it is sandboxed', () {
    final previous = AppDataMigration.debugUsesSupportDirectory;
    AppDataMigration.debugUsesSupportDirectory = false;
    addTearDown(() => AppDataMigration.debugUsesSupportDirectory = previous);
    expect(AppDataMigration.usesSupportDirectory, isFalse);
  });

  group('sandboxed macOS container (ADR0106)', () {
    const home = '/path/to/home';
    const bundle = 'com.example.aicoveFlutter';
    final container = MacContainer(home, bundle);
    const newSupport = '/path/to/home/Library/Application Support/$bundle';

    test('locates the old documents and support directories', () {
      expect(
        container.documents.path,
        '/path/to/home/Library/Containers/$bundle/Data/Documents',
      );
      expect(
        container.support.path,
        '/path/to/home/Library/Containers/$bundle/Data/Library/Application Support/$bundle',
      );
    });

    test('rewrites paths below both old directories, in the database too', () async {
      final rewrites = PathRewrites(
        container.documents.path,
        newSupport,
        extra: [(container.support.path, newSupport)],
      );
      expect(
        rewrites.apply('${container.documents.path}/wallpapers/w.png'),
        '$newSupport/wallpapers/w.png',
      );
      expect(
        rewrites.apply('${container.support.path}/cloud_media/m/1.jpg'),
        '$newSupport/cloud_media/m/1.jpg',
      );
      expect(
        jsonDecode(rewrites.apply(jsonEncode({
          'p': '${container.support.path}/voice_call/a.wav',
        })))['p'],
        '$newSupport/voice_call/a.wav',
      );
      for (final untouched in [
        '${container.documents.path}/notes.txt',
        '/path/to/home/Documents/wallpapers/w.png',
        container.support.path,
      ]) {
        expect(rewrites.apply(untouched), untouched);
      }

      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      await db.customSelect('SELECT 1').get();
      await db.customStatement('CREATE TABLE t (v TEXT)');
      await db.customStatement('INSERT INTO t VALUES (?)', [
        '${container.support.path}/cloud_media/x.png',
      ]);
      await AppDataMigration.rewriteDatabase(db, rewrites);
      final row = await db.customSelect('SELECT v FROM t').getSingle();
      expect(row.data['v'], '$newSupport/cloud_media/x.png');
    });

    test('moveSupport moves every entry and removes the emptied folder', () async {
      final root = await Directory.systemTemp.createTemp('mac_container');
      addTearDown(() => root.delete(recursive: true));
      final from = Directory(p.join(root.path, 'old'));
      final to = Directory(p.join(root.path, 'new'));
      for (final (path, content) in [
        ('local_credentials/key', 'k'),
        ('cloud_media/a/1.png', 'img'),
        ('top.json', '{}'),
      ]) {
        final file = File(p.join(from.path, path));
        await file.parent.create(recursive: true);
        await file.writeAsString(content);
      }
      await File(p.join(to.path, 'top.json')).create(recursive: true);

      await AppDataMigration.moveSupport(from, to);

      expect(await File(p.join(to.path, 'local_credentials/key')).readAsString(), 'k');
      expect(await File(p.join(to.path, 'cloud_media/a/1.png')).readAsString(), 'img');
      expect(await File(p.join(to.path, 'top.json')).readAsString(), '',
          reason: 'existing files in the new place win');
      expect(await File(p.join(from.path, 'top.json')).readAsString(), '{}');
      expect(await Directory(p.join(from.path, 'cloud_media')).exists(), isFalse);

      await AppDataMigration.moveSupport(Directory(p.join(root.path, 'none')), to);
    });
  });
}
