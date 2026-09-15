import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// Read metadata only. Never open file contents or follow symbolic links.
Future<Map<String, Object?>> createStorageInventory(
  String rootPath, {
  int maxEntries = 200000,
  Duration timeout = const Duration(seconds: 45),
}) async {
  final watch = Stopwatch()..start();
  final groups = <String, List<int>>{};
  final largest = <Map<String, Object?>>[];
  var bytes = 0;
  var files = 0;
  var entries = 0;
  var errors = 0;
  var links = 0;
  var truncated = false;

  Future<void> scan(Directory directory, int depth) async {
    if (depth > 32) {
      truncated = true;
      return;
    }
    try {
      await for (final entry in directory.list(followLinks: false)) {
        if (++entries > maxEntries || watch.elapsed > timeout) {
          truncated = true;
          return;
        }
        if (entry is Link) {
          links++;
        } else if (entry is Directory) {
          await scan(entry, depth + 1);
          if (entries > maxEntries || watch.elapsed > timeout) return;
        } else if (entry is File) {
          try {
            // Recheck the type in case an entry changed during enumeration.
            if (await FileSystemEntity.type(entry.path, followLinks: false) !=
                FileSystemEntityType.file) {
              errors++;
              continue;
            }
            final stat = await entry.stat();
            final relative = p.relative(entry.path, from: rootPath);
            final bucket = _bucket(relative);
            final group = groups.putIfAbsent(bucket, () => [0, 0]);
            group[0]++;
            group[1] += stat.size;
            files++;
            bytes += stat.size;
            largest.add({
              'bucket': bucket,
              'fileId': sha256.convert(utf8.encode(relative)).toString(),
              'kind': _kind(relative),
              'bytes': stat.size,
              'modifiedAt': stat.modified.toUtc().toIso8601String(),
            });
            largest.sort(
              (a, b) => (b['bytes'] as int).compareTo(a['bytes'] as int),
            );
            if (largest.length > 40) largest.removeLast();
          } on FileSystemException {
            errors++;
          }
        }
      }
    } on FileSystemException {
      errors++;
    }
  }

  await scan(Directory(rootPath), 0);
  final buckets = [
    for (final group in groups.entries)
      {'bucket': group.key, 'files': group.value[0], 'bytes': group.value[1]},
  ]..sort((a, b) => (b['bytes'] as int).compareTo(a['bytes'] as int));
  return {
    'format': 'aicove-storage-inventory-v1',
    'collectedAt': DateTime.now().toUtc().toIso8601String(),
    'totalBytes': bytes,
    'fileCount': files,
    'buckets': buckets,
    'largestFiles': largest,
    'coverage': {
      'metadataOnly': true,
      'snapshotAtomic': false,
      'sizeMeaning': 'logical_file_bytes_not_allocated_blocks',
      'scope': 'internal_app_data_excludes_apk_and_external_storage',
      'entriesVisited': entries,
      'errors': errors,
      'linksSkipped': links,
      'truncated': truncated,
      'elapsedMs': watch.elapsedMilliseconds,
    },
  };
}

String _bucket(String relative) {
  final parts = p.split(relative);
  const allowed = {
    'app_flutter',
    'files',
    'cache',
    'code_cache',
    'databases',
    'shared_prefs',
    'no_backup',
    'app_webview',
    'logs',
    'log_history',
    'trace',
    'payload',
    'generated_images',
    'imported_files',
    'blurred_backgrounds',
    'voice_presets',
    'aicove_audio_cache',
    'file_picker',
    'image_picker',
    'lib',
  };
  final directories = parts.take(parts.length - 1).take(4);
  return [
    for (final part in directories)
      if (allowed.contains(part)) part else 'other',
    if (parts.length == 1) 'root',
  ].join('/');
}

String _kind(String relative) {
  final name = p.basename(relative);
  if (const {'aicove.db', 'aicove.db-wal', 'aicove.db-shm'}.contains(name)) {
    return name;
  }
  final extension = p.extension(name).toLowerCase();
  return const {
        '.db',
        '.sqlite',
        '.sqlite3',
        '.json',
        '.jsonl',
        '.xml',
        '.png',
        '.jpg',
        '.jpeg',
        '.webp',
        '.mp3',
        '.wav',
        '.ogg',
        '.m4a',
        '.zip',
        '.bin',
        '.partial',
      }.contains(extension)
      ? extension
      : 'other';
}
