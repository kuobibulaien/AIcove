import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:sqlite3/sqlite3.dart';
import '../../../tool/storage_cache_cleanup.dart';

void main() {
  Future<String> fixture() async {
    final temp = await Directory.systemTemp.createTemp('cache_cleanup');
    final root = await temp.resolveSymbolicLinks();
    addTearDown(() => temp.delete(recursive: true));
    await Directory('$root/app_flutter').create();
    final db = sqlite3.open('$root/app_flutter/aicove.db');
    db.execute('CREATE TABLE messages(content TEXT)');
    db.dispose();
    for (final target in cacheTargets) {
      await Directory('$root/$target').create(recursive: true);
      await File('$root/$target/test.bin').writeAsBytes([1, 2, 3]);
    }
    await Directory(
      '$root/app_flutter/generated_images/model',
    ).create(recursive: true);
    await File(
      '$root/app_flutter/generated_images/model/original.png',
    ).writeAsBytes([4, 5, 6]);
    return root;
  }

  test(
    'cleans only unreferenced allowlisted caches and preserves database and images',
    () async {
      final root = await fixture();
      final db = sqlite3.open('$root/app_flutter/aicove.db');
      db.execute('INSERT INTO messages VALUES (?)', [
        '/data/user/0/app/app_flutter/conversation_short_windows/media.png',
      ]);
      db.dispose();
      await File(
        '$root/app_flutter/settings.json',
      ).writeAsString('{"background":"blurred_backgrounds/saved.jpg"}');
      final before = await File('$root/app_flutter/aicove.db').readAsBytes();
      final plan = await planCacheCleanup(root);
      expect(plan['scanErrors'], 0);
      final result = await executeCacheCleanup(root, plan['planId'] as String);
      expect(result['deletedBytes'], 6);
      expect(
        await File(
          '$root/app_flutter/conversation_short_windows/test.bin',
        ).exists(),
        true,
      );
      expect(
        await File('$root/app_flutter/blurred_backgrounds/test.bin').exists(),
        true,
      );
      expect(
        await File(
          '$root/app_flutter/generated_images/model/original.png',
        ).readAsBytes(),
        [4, 5, 6],
      );
      expect(await File('$root/app_flutter/aicove.db').readAsBytes(), before);
    },
  );
  test('changed plans and links fail closed', () async {
    final root = await fixture();
    final plan = await planCacheCleanup(root);
    await File('$root/cache/aicove_audio_cache/test.bin').writeAsBytes([9]);
    await expectLater(
      executeCacheCleanup(root, plan['planId'] as String),
      throwsStateError,
    );
    await Link(
      '$root/cache/aicove_audio_cache/link',
    ).create('$root/app_flutter/generated_images');
    final linked = await planCacheCleanup(root);
    expect(linked['scanErrors'], greaterThan(0));
    expect(
      (linked['targets'] as List).every((t) => t['eligible'] == false),
      true,
    );
  });
}
