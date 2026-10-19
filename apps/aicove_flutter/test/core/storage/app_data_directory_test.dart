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
    AppDataMigration.debugUsesSupportDirectory = false;
    addTearDown(() => AppDataMigration.debugUsesSupportDirectory = null);
    expect(AppDataMigration.usesSupportDirectory, isFalse);
  });
}
