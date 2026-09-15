import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
// SQLite is already provided by Drift; this temporary probe uses read-only SQL.
// ignore: depend_on_referenced_packages
import 'package:sqlite3/sqlite3.dart';

/// Returns aggregate numbers only, never database values or media contents.
Future<Map<String, Object?>> storageProbeDetails(String root) async {
  final result = <String, Object?>{};
  final documents = Directory(p.join(root, 'app_flutter'));
  final folders = <String, List<int>>{};
  final imageSizes = <int, List<File>>{};
  final imageMonths = <String, List<int>>{};
  var errors = 0;
  await for (final entity in documents.list(
    recursive: true,
    followLinks: false,
  )) {
    if (entity is! File) continue;
    try {
      final stat = await entity.stat();
      final relative = p.relative(entity.path, from: documents.path);
      final parts = p.split(relative);
      final folder = parts.length == 1 ? '(root)' : parts.first;
      final safeFolder = RegExp(r'^[a-z_]{1,48}$').hasMatch(folder)
          ? folder
          : '(other)';
      final group = folders.putIfAbsent(safeFolder, () => [0, 0]);
      group[0]++;
      group[1] += stat.size;
      if (const {
        '.png',
        '.jpg',
        '.jpeg',
        '.webp',
      }.contains(p.extension(entity.path).toLowerCase())) {
        imageSizes.putIfAbsent(stat.size, () => []).add(entity);
        final month = stat.modified.toUtc().toIso8601String().substring(0, 7);
        final group = imageMonths.putIfAbsent(month, () => [0, 0]);
        group[0]++;
        group[1] += stat.size;
      }
    } on FileSystemException {
      errors++;
    }
  }
  result['documentDirectories'] = [
    for (final e in folders.entries)
      {'directory': e.key, 'files': e.value[0], 'bytes': e.value[1]},
  ]..sort((a, b) => (b['bytes'] as int).compareTo(a['bytes'] as int));
  result['imageMonthsByModificationTime'] = [
    for (final e in imageMonths.entries)
      {'month': e.key, 'files': e.value[0], 'bytes': e.value[1]},
  ];
  final watch = Stopwatch()..start();
  var hashedBytes = 0;
  var extraCopies = 0;
  var duplicateBytes = 0;
  var duplicateGroups = 0;
  var truncated = false;
  for (final entry in imageSizes.entries.where((e) => e.value.length > 1)) {
    final hashes = <String, int>{};
    for (final file in entry.value) {
      if (watch.elapsed > const Duration(seconds: 40)) {
        truncated = true;
        break;
      }
      try {
        final digest = (await sha256.bind(file.openRead()).first).toString();
        hashes[digest] = (hashes[digest] ?? 0) + 1;
        hashedBytes += entry.key;
      } on FileSystemException {
        errors++;
      }
    }
    for (final count in hashes.values.where((n) => n > 1)) {
      duplicateGroups++;
      extraCopies += count - 1;
      duplicateBytes += (count - 1) * entry.key;
    }
    if (truncated) break;
  }
  result['identicalImages'] = {
    'groups': duplicateGroups,
    'extraCopies': extraCopies,
    'extraBytes': duplicateBytes,
    'hashedBytes': hashedBytes,
    'truncated': truncated,
    'errors': errors,
    'meaning': 'byte_identical_only_not_proof_of_safe_deletion',
  };

  final db = sqlite3.open(
    p.join(documents.path, 'aicove.db'),
    mode: OpenMode.readOnly,
  );
  try {
    db.execute('PRAGMA query_only = ON');
    result['databasePragmas'] = {
      for (final name in [
        'user_version',
        'page_size',
        'page_count',
        'freelist_count',
      ])
        name: db.select('PRAGMA $name').first.values.first,
    };
    try {
      result['databasePages'] = db
          .select(
            'SELECT name, SUM(pgsize) AS bytes, SUM(payload) AS payloadBytes, SUM(unused) AS unusedBytes FROM dbstat GROUP BY name ORDER BY bytes DESC',
          )
          .map((r) => Map<String, Object?>.from(r))
          .toList();
    } on SqliteException {
      result['databasePagesAvailable'] = false;
    }
    final tables = <Map<String, Object?>>[];
    for (final row in db.select(
      "SELECT name FROM sqlite_master WHERE type='table'",
    )) {
      final table = row['name'] as String;
      if (!RegExp(r'^[a-z_][a-z_0-9]*$').hasMatch(table)) continue;
      final info = db.select('PRAGMA table_info("$table")');
      final columns = [
        for (final c in info)
          if (['TEXT', 'BLOB'].contains(c['type'].toString().toUpperCase()) &&
              RegExp(r'^[a-z_][a-z_0-9]*$').hasMatch(c['name'] as String))
            c['name'] as String,
      ];
      final sql = [
        'COUNT(*) AS rows',
        for (final c in columns)
          'COALESCE(SUM(length(CAST("$c" AS BLOB))),0) AS "$c"',
      ].join(',');
      final totals = Map<String, Object?>.from(
        db.select('SELECT $sql FROM "$table"').first,
      );
      tables.add({'table': table, ...totals});
    }
    result['databaseColumnBytes'] = tables;
    result['messageStates'] = db
        .select(
          'SELECT (deleted_at IS NOT NULL) AS deleted, (source_message_id IS NOT NULL) AS projected, COUNT(*) AS rows, SUM(length(CAST(content AS BLOB))) AS contentBytes, SUM(length(CAST(raw_payload AS BLOB))) AS rawPayloadBytes FROM messages GROUP BY deleted, projected',
        )
        .map((r) => Map<String, Object?>.from(r))
        .toList();
    try {
      const keys = [
        'rawReplyText',
        'processedText',
        'hiddenThoughtParts',
        'pluginEvents',
        'pluginContents',
        'toolAudioResults',
        'toolCalls',
        'rawToolResults',
        'projectedMessages',
        'supplementInsertOps',
      ];
      result['messagePayloadFields'] = db
          .select(
            "SELECT j.key AS field, COUNT(*) AS rows, SUM(length(CAST(j.value AS BLOB))) AS bytes FROM messages, json_each(CASE WHEN json_valid(raw_payload) THEN raw_payload ELSE '{}' END) AS j GROUP BY j.key",
          )
          .where((r) => keys.contains(r['field']))
          .map((r) => Map<String, Object?>.from(r))
          .toList();
    } on SqliteException {
      result['messagePayloadFieldsAvailable'] = false;
    }
  } finally {
    db.dispose();
  }
  return result;
}
