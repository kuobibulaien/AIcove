import 'dart:io';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_logger.dart';

/// Root directory for the app's own data (database, logs, wallpapers, ...).
///
/// Mobile apps keep using their sandboxed documents directory. On Windows,
/// Linux and the unsandboxed macOS app (ADR0106) that directory is the user's
/// visible "Documents" folder (often synced by OneDrive or iCloud), so the app
/// keeps its data in the per-user application support directory instead.
/// Files the user exports on purpose still go to Documents; they are not
/// resolved through here.
Future<Directory> appDataDirectory() async {
  final legacy = AppDataMigration._legacyDirectory;
  if (legacy != null) return legacy;
  if (!AppDataMigration.usesSupportDirectory) {
    return getApplicationDocumentsDirectory();
  }
  return getApplicationSupportDirectory();
}

/// Moves data that older builds wrote elsewhere to [appDataDirectory], and
/// rewrites stored absolute paths that point at it:
/// - Windows/Linux builds wrote into Documents;
/// - sandboxed macOS builds wrote into their container, both its Documents
///   and its application support directory (preferences are copied natively
///   in `MainFlutterWindow.swift` before Flutter starts).
///
/// Runs once per launch before anything touches app data. Moving is skipped
/// when nothing is left in the old place; path rewriting runs until it
/// succeeded once (marker in preferences and in the database).
class AppDataMigration {
  AppDataMigration._();

  /// Entries older builds created directly under Documents.
  static const databaseFiles = [
    'aicove.db',
    'aicove.db-wal',
    'aicove.db-shm',
    'aicove.db-journal',
  ];
  static const directories = [
    'aicove',
    'blurred_backgrounds',
    'chat_message_list_cache',
    'contact_edit_snapshots',
    'generated_images',
    'imported_files',
    'log_history',
    'logs',
    'voice_presets',
    'voices',
    'wallpapers',
  ];

  static const preferencesMarker = 'aicove.storage.data_dir_paths_v1';
  static const databaseMarker = 'data_dir_paths_v1';

  @visibleForTesting
  static bool? debugUsesSupportDirectory;

  /// A sandboxed process always has this variable; the unsandboxed one never.
  static bool get _unsandboxedMac =>
      Platform.isMacOS &&
      !Platform.environment.containsKey('APP_SANDBOX_CONTAINER_ID');

  static bool get usesSupportDirectory =>
      debugUsesSupportDirectory ??
      (Platform.isWindows || Platform.isLinux || _unsandboxedMac);

  static Directory? _legacyDirectory;
  static PathRewrites? _rewrites;

  static Future<void> run() async {
    if (!usesSupportDirectory) return;
    Directory? from;
    try {
      final to = await getApplicationSupportDirectory();
      var extra = const <(String, String)>[];
      if (_unsandboxedMac) {
        final home = Platform.environment['HOME'];
        if (home == null) return;
        final old = MacContainer(home, p.basename(to.path));
        from = old.documents;
        extra = [(old.support.path, to.path)];
        await moveSupport(old.support, to);
      } else {
        from = await getApplicationDocumentsDirectory();
      }
      if (p.equals(from.path, to.path)) return;
      if (!await moveEntries(from, to)) {
        _legacyDirectory = from;
        return;
      }
      final rewrites = PathRewrites(from.path, to.path, extra: extra);
      _rewrites = rewrites;
      await rewritePreferences(await SharedPreferences.getInstance(), rewrites);
    } catch (error) {
      // Keep using the old location while the old database is still there.
      if (from != null &&
          await File(p.join(from.path, databaseFiles.first)).exists()) {
        _legacyDirectory = from;
        _rewrites = null;
      }
      AppLogger.error('AppDataMigration', '数据目录迁移失败：$error');
    }
  }

  @visibleForTesting
  static void debugReset() {
    _legacyDirectory = null;
    _rewrites = null;
  }

  /// Moves every entry of the sandboxed app's support directory; it holds
  /// nothing but this app's data. Best-effort per entry, like [moveEntries].
  static Future<void> moveSupport(Directory from, Directory to) async {
    if (!await from.exists()) return;
    await to.create(recursive: true);
    await for (final entry in from.list(followLinks: false)) {
      final name = p.basename(entry.path);
      try {
        if (entry is Directory) {
          await _moveDirectory(entry, Directory(p.join(to.path, name)));
        } else if (entry is File &&
            !await File(p.join(to.path, name)).exists()) {
          await entry.rename(p.join(to.path, name));
        }
      } catch (error) {
        AppLogger.warning('AppDataMigration', '迁移 $name 未完成，下次启动重试：$error');
      }
    }
    if (await from.list().isEmpty) await from.delete();
  }

  /// Moves the database first, as one unit. Returns false when the database
  /// could not be moved; the caller then keeps using [from] for this launch
  /// and nothing else has been touched. Other entries are moved best-effort.
  static Future<bool> moveEntries(Directory from, Directory to) async {
    await to.create(recursive: true);
    if (!await _moveDatabase(from, to)) return false;
    for (final name in directories) {
      final source = Directory(p.join(from.path, name));
      if (!await source.exists()) continue;
      try {
        await _moveDirectory(source, Directory(p.join(to.path, name)));
      } catch (error) {
        AppLogger.warning('AppDataMigration', '迁移 $name 未完成，下次启动重试：$error');
      }
    }
    return true;
  }

  static Future<bool> _moveDatabase(Directory from, Directory to) async {
    final sources = [
      for (final name in databaseFiles)
        if (await File(p.join(from.path, name)).exists())
          File(p.join(from.path, name)),
    ];
    if (sources.isEmpty) return true;
    if (await File(p.join(to.path, databaseFiles.first)).exists()) {
      // Both exist: the new location is the live one; keep the old copy as is.
      AppLogger.warning('AppDataMigration', '新旧位置都有数据库，沿用新位置，旧文件保留不动');
      return true;
    }
    final parts = <File>[];
    try {
      // Copy everything first so a failure leaves the old database complete.
      for (final source in sources) {
        parts.add(await source.copy(p.join(to.path, '${p.basename(source.path)}.moving')));
      }
      for (final part in parts) {
        await part.rename(part.path.substring(0, part.path.length - '.moving'.length));
      }
    } catch (error) {
      for (final part in parts) {
        if (await part.exists()) await part.delete();
      }
      for (final name in databaseFiles) {
        final copied = File(p.join(to.path, name));
        if (await copied.exists() && sources.any((s) => p.basename(s.path) == name)) {
          await copied.delete();
        }
      }
      AppLogger.error('AppDataMigration', '数据库迁移失败，本次继续使用旧位置：$error');
      return false;
    }
    // The main file goes first: if it is still locked (an old copy of the app
    // is running and may keep writing), undo the copy so the next launch does
    // not prefer a stale snapshot.
    try {
      for (final source in sources) {
        await source.delete();
      }
    } on FileSystemException catch (error) {
      if (await sources.first.exists()) {
        for (final source in sources) {
          final copied = File(p.join(to.path, p.basename(source.path)));
          if (await copied.exists()) await copied.delete();
        }
        AppLogger.error('AppDataMigration', '旧数据库仍被占用，本次继续使用旧位置：$error');
        return false;
      }
    }
    AppLogger.info('AppDataMigration', '数据库已迁到 ${to.path}');
    return true;
  }

  /// Moves [source] into [target]. Existing files in [target] win; the old
  /// copy of such a file stays where it was.
  static Future<void> _moveDirectory(Directory source, Directory target) async {
    if (!await target.exists()) {
      try {
        await source.rename(target.path);
        return;
      } on FileSystemException {
        // Different volume: fall through to copying entry by entry.
      }
    }
    await target.create(recursive: true);
    await for (final entity in source.list(followLinks: false)) {
      final destination = p.join(target.path, p.basename(entity.path));
      if (entity is Directory) {
        await _moveDirectory(entity, Directory(destination));
      } else if (entity is File) {
        if (await File(destination).exists()) continue;
        try {
          await entity.rename(destination);
        } on FileSystemException {
          await entity.copy('$destination.moving');
          await File('$destination.moving').rename(destination);
          await entity.delete();
        }
      }
    }
    if (await source.list().isEmpty) await source.delete();
  }

  @visibleForTesting
  static Future<void> rewritePreferences(
    SharedPreferences preferences,
    PathRewrites rewrites,
  ) async {
    if (preferences.getBool(preferencesMarker) == true) return;
    for (final key in preferences.getKeys()) {
      final value = preferences.get(key);
      if (value is String) {
        final next = rewrites.apply(value);
        if (next != value) await preferences.setString(key, next);
      } else if (value is List) {
        final list = value.cast<String>();
        final next = [for (final item in list) rewrites.apply(item)];
        if (!listEquals(next, list)) await preferences.setStringList(key, next);
      }
    }
    await preferences.setBool(preferencesMarker, true);
  }

  /// Rewrites stored paths in every text column of the app's own tables.
  /// Sync bookkeeping tables are skipped and change tracking is suspended, so
  /// this local relocation is not uploaded as user edits.
  static Future<void> rewriteDatabase(
    GeneratedDatabase db, [
    PathRewrites? rewrites,
  ]) async {
    final pairs = rewrites ?? _rewrites;
    if (pairs == null) return;
    await db.customStatement(
      'CREATE TABLE IF NOT EXISTS local_storage_migrations (name TEXT PRIMARY KEY)',
    );
    final done = await db.customSelect(
      'SELECT 1 FROM local_storage_migrations WHERE name = ?',
      variables: [Variable.withString(databaseMarker)],
    ).get();
    if (done.isNotEmpty) return;
    await db.transaction(() async {
      final suspended = <String, Object?>{};
      for (final table in const ['cloud_client_state', 'lan_state']) {
        if (!await _hasTable(db, table)) continue;
        final rows = await db.customSelect('SELECT suspended FROM $table WHERE id=1').get();
        if (rows.isEmpty) continue;
        suspended[table] = rows.single.data['suspended'];
        await db.customStatement('UPDATE $table SET suspended=1 WHERE id=1');
      }
      final tables = await db.customSelect(
        "SELECT name, sql FROM sqlite_master WHERE type='table' "
        "AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'cloud_%' "
        "AND name NOT LIKE 'lan_%' AND name <> 'local_storage_migrations'",
      ).get();
      for (final table in tables) {
        final name = table.data['name'] as String;
        if ((table.data['sql'] as String? ?? '').toUpperCase().contains('WITHOUT ROWID')) continue;
        final columns = await db.customSelect('PRAGMA table_info("$name")').get();
        for (final column in columns) {
          final type = (column.data['type'] as String? ?? '').toUpperCase();
          if (type.isNotEmpty && !type.contains('TEXT') && !type.contains('CHAR')) continue;
          final field = column.data['name'] as String;
          final rows = await db.customSelect(
            'SELECT rowid AS rid, "$field" AS value FROM "$name" '
            'WHERE ${[for (final _ in pairs.probes) 'instr("$field", ?) > 0'].join(' OR ')}',
            variables: [for (final probe in pairs.probes) Variable.withString(probe)],
          ).get();
          for (final row in rows) {
            final value = row.data['value'];
            if (value is! String) continue;
            final next = pairs.apply(value);
            if (next == value) continue;
            await db.customUpdate(
              'UPDATE "$name" SET "$field" = ? WHERE rowid = ?',
              variables: [Variable.withString(next), Variable.withInt(row.data['rid'] as int)],
            );
          }
        }
      }
      for (final entry in suspended.entries) {
        await db.customUpdate(
          'UPDATE ${entry.key} SET suspended=? WHERE id=1',
          variables: [Variable(entry.value)],
        );
      }
      await db.customStatement(
        'INSERT OR IGNORE INTO local_storage_migrations(name) VALUES(?)',
        [databaseMarker],
      );
    });
  }

  static Future<bool> _hasTable(GeneratedDatabase db, String table) async {
    final rows = await db.customSelect(
      "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?",
      variables: [Variable.withString(table)],
    ).get();
    return rows.isNotEmpty;
  }
}

/// Where the sandboxed macOS app kept its data (ADR0106).
class MacContainer {
  MacContainer(String home, this.bundleId)
    : data = Directory(p.join(home, 'Library', 'Containers', bundleId, 'Data'));

  final String bundleId;
  final Directory data;

  Directory get documents => Directory(p.join(data.path, 'Documents'));
  Directory get support => Directory(
    p.join(data.path, 'Library', 'Application Support', bundleId),
  );
}

/// Old→new prefixes of moved entries, in every spelling a stored path may
/// use: native, JSON escaped and forward slashes. Directory prefixes end with
/// a separator so unrelated names sharing a prefix are left alone. [extra]
/// directories moved as a whole are rewritten below any name.
class PathRewrites {
  PathRewrites(String from, String to, {List<(String, String)> extra = const []})
      : probes = [
          for (final old in [from, for (final (dir, _) in extra) dir])
            old.split(RegExp(r'[\\/]')).lastWhere((part) => part.isNotEmpty),
        ] {
    Set<(String, String)> spellingsOf(String from, String to) => {
      (from, to),
      (from.replaceAll(r'\', r'\\'), to.replaceAll(r'\', r'\\')),
      (from.replaceAll(r'\', '/'), to.replaceAll(r'\', '/')),
    };
    final rewrites = <(String, String)>{};
    for (final (oldBase, newBase) in spellingsOf(from, to)) {
      for (final separator in const [r'\', r'\\', '/']) {
        for (final name in AppDataMigration.databaseFiles) {
          rewrites.add(('$oldBase$separator$name', '$newBase$separator$name'));
        }
        for (final name in AppDataMigration.directories) {
          rewrites.add((
            '$oldBase$separator$name$separator',
            '$newBase$separator$name$separator',
          ));
        }
      }
    }
    for (final (oldDir, newDir) in extra) {
      for (final (oldBase, newBase) in spellingsOf(oldDir, newDir)) {
        for (final separator in const [r'\', r'\\', '/']) {
          rewrites.add(('$oldBase$separator', '$newBase$separator'));
        }
      }
    }
    // Longest first, so an escaped spelling is not half-rewritten by a
    // shorter one.
    pairs = rewrites.toList()
      ..sort((a, b) => b.$1.length.compareTo(a.$1.length));
  }

  /// Every stored old path contains one of these; a cheap filter before
  /// [apply].
  final List<String> probes;
  late final List<(String, String)> pairs;

  String apply(String value) {
    if (!probes.any(value.contains)) return value;
    var result = value;
    for (final (oldPrefix, newPrefix) in pairs) {
      if (result.contains(oldPrefix)) {
        result = result.replaceAll(oldPrefix, newPrefix);
      }
    }
    return result;
  }
}
