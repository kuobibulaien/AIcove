import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
// ignore: depend_on_referenced_packages
import 'package:sqlite3/sqlite3.dart';

const cacheTargets = [
  'app_flutter/conversation_short_windows',
  'cache/aicove_audio_cache',
  'app_flutter/chat_message_list_cache',
  'app_flutter/blurred_backgrounds',
];

Future<Map<String, dynamic>> planCacheCleanup(String root) async {
  final references = {for (final target in cacheTargets) target: 0};
  var scanErrors = 0;
  final db = sqlite3.open(
    p.join(root, 'app_flutter/aicove.db'),
    mode: OpenMode.readOnly,
  );
  try {
    db.execute('PRAGMA query_only = ON');
    for (final tableRow in db.select(
      "SELECT name FROM sqlite_master WHERE type='table'",
    )) {
      final table = tableRow['name'] as String;
      if (!RegExp(r'^[a-z_][a-z_0-9]*$').hasMatch(table)) {
        scanErrors++;
        continue;
      }
      final columns = [
        for (final c in db.select('PRAGMA table_info("$table")'))
          if (['TEXT', 'BLOB'].contains(c['type'].toString().toUpperCase()) &&
              RegExp(r'^[a-z_][a-z_0-9]*$').hasMatch(c['name'] as String))
            c['name'] as String,
      ];
      if (columns.isEmpty) continue;
      final sums = [
        for (var i = 0; i < cacheTargets.length; i++)
          'COALESCE(SUM(CASE WHEN ${columns.map((c) => 'instr(CAST("$c" AS TEXT), \'${p.basename(cacheTargets[i])}\')>0').join(' OR ')} THEN 1 ELSE 0 END),0) AS n$i',
      ];
      final row = db.select('SELECT ${sums.join(',')} FROM "$table"').first;
      for (var i = 0; i < cacheTargets.length; i++) {
        references[cacheTargets[i]] =
            references[cacheTargets[i]]! + (row['n$i'] as int);
      }
    }
  } finally {
    db.dispose();
  }

  // Inspect persisted text settings/snapshots in-process, returning counts only.
  // Diagnostic logs do not own media; skip them. Unknown/unreadable input blocks cleanup.
  await for (final entity in Directory(
    root,
  ).list(recursive: true, followLinks: false)) {
    if (entity is Link) {
      scanErrors++;
      continue;
    }
    if (entity is! File) continue;
    final relative = p.relative(entity.path, from: root);
    if (relative.startsWith('app_flutter/logs/') ||
        relative.startsWith('app_flutter/log_history/')) {
      continue;
    }
    if (!const {
      '.json',
      '.xml',
      '.txt',
      '.md',
    }.contains(p.extension(entity.path).toLowerCase())) {
      continue;
    }
    try {
      if (await entity.length() > 64 * 1024 * 1024) {
        scanErrors++;
        continue;
      }
      final text = await entity.readAsString();
      for (final target in cacheTargets) {
        if (!p.isWithin(target, relative) &&
            text.contains(p.basename(target))) {
          references[target] = references[target]! + 1;
        }
      }
    } catch (_) {
      scanErrors++;
    }
  }
  final targets = <Map<String, dynamic>>[];
  for (final target in cacheTargets) {
    final files = <Map<String, dynamic>>[];
    var errors = 0;
    final directory = Directory(p.join(root, target));
    if (await FileSystemEntity.type(directory.path, followLinks: false) ==
        FileSystemEntityType.link) {
      errors++;
    } else if (await directory.exists()) {
      await for (final entity in directory.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is Link) {
          errors++;
          continue;
        }
        if (entity is! File) continue;
        final stat = await entity.stat();
        files.add({
          'path': p.relative(entity.path, from: root),
          'bytes': stat.size,
          'modifiedUs': stat.modified.microsecondsSinceEpoch,
        });
      }
    }
    files.sort((a, b) => (a['path'] as String).compareTo(b['path'] as String));
    targets.add({
      'directory': target,
      'files': files,
      'bytes': files.fold<int>(0, (n, f) => n + (f['bytes'] as int)),
      'references': references[target],
      'errors': errors,
      'eligible': scanErrors == 0 && errors == 0 && references[target] == 0,
    });
  }
  final imageDirectories = <String, List<int>>{};
  final imageRoot = Directory(p.join(root, 'app_flutter/generated_images'));
  if (await imageRoot.exists()) {
    await for (final entity in imageRoot.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File) continue;
      final directory = p.dirname(p.relative(entity.path, from: root));
      final totals = imageDirectories.putIfAbsent(directory, () => [0, 0]);
      totals[0]++;
      totals[1] += await entity.length();
    }
  }
  return {
    'planId': sha256.convert(utf8.encode(jsonEncode(targets))).toString(),
    'scanErrors': scanErrors,
    'targets': targets,
    'imageDirectories': [
      for (final e in imageDirectories.entries)
        {'directory': e.key, 'files': e.value[0], 'bytes': e.value[1]},
    ],
  };
}

Map<String, dynamic> publicCleanupPlan(Map<String, dynamic> plan) => {
  'planId': plan['planId'],
  'scanErrors': plan['scanErrors'],
  'imageDirectories': plan['imageDirectories'],
  'targets': [
    for (final t in plan['targets'] as List)
      {
        ...Map<String, dynamic>.from(t)..remove('files'),
        'fileCount': (t['files'] as List).length,
      },
  ],
};

Future<Map<String, dynamic>> executeCacheCleanup(
  String root,
  String expectedPlanId,
) async {
  final plan = await planCacheCleanup(root);
  if (plan['planId'] != expectedPlanId) {
    throw StateError('Cache state changed; request a fresh plan');
  }
  final deleted = <Map<String, dynamic>>[];
  for (final t in plan['targets'] as List) {
    if (t['eligible'] != true) continue;
    var bytes = 0;
    var count = 0;
    var skipped = 0;
    for (final f in t['files'] as List) {
      final relative = f['path'] as String;
      if (!p.isWithin(t['directory'] as String, relative)) {
        throw StateError('Out-of-scope path');
      }
      final file = File(p.join(root, relative));
      // Resolve every ancestor before deletion; do not traverse replacement links.
      if (await file.resolveSymbolicLinks() !=
          p.normalize(file.absolute.path)) {
        skipped++;
        continue;
      }
      if (await FileSystemEntity.type(file.path, followLinks: false) !=
          FileSystemEntityType.file) {
        skipped++;
        continue;
      }
      final stat = await file.stat();
      if (stat.size != f['bytes'] ||
          stat.modified.microsecondsSinceEpoch != f['modifiedUs']) {
        skipped++;
        continue;
      }
      await file.delete();
      count++;
      bytes += stat.size;
    }
    deleted.add({
      'directory': t['directory'],
      'files': count,
      'bytes': bytes,
      'skipped': skipped,
    });
  }
  return {
    'deleted': deleted,
    'deletedBytes': deleted.fold<int>(0, (n, t) => n + (t['bytes'] as int)),
    'planId': expectedPlanId,
  };
}
