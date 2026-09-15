import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:sqlite3/sqlite3.dart';
import '../../../tool/storage_probe_details.dart';

void main() {
  test(
    'reports byte-identical images and SQL aggregates without modifying data',
    () async {
      final root = await Directory.systemTemp.createTemp('storage_details');
      addTearDown(() => root.delete(recursive: true));
      final documents = await Directory('${root.path}/app_flutter').create();
      final images = await Directory(
        '${documents.path}/generated_images',
      ).create();
      await File('${images.path}/private-name.png').writeAsString('abc');
      await File('${images.path}/second.png').writeAsString('abc');
      await File('${images.path}/different.png').writeAsString('def');
      final file = File('${documents.path}/aicove.db');
      final db = sqlite3.open(file.path);
      db.execute(
        'CREATE TABLE messages(content TEXT, raw_payload TEXT, deleted_at INTEGER, source_message_id TEXT)',
      );
      db.execute('INSERT INTO messages VALUES (?, ?, NULL, NULL)', [
        'PRIVATE_CHAT',
        '{"rawReplyText":"SECRET"}',
      ]);
      db.dispose();
      final before = await file.readAsBytes();
      final result = await storageProbeDetails(root.path);
      expect((result['identicalImages'] as Map)['extraCopies'], 1);
      expect((result['identicalImages'] as Map)['extraBytes'], 3);
      final columns = (result['databaseColumnBytes'] as List).first;
      expect(columns['rows'], 1);
      expect(columns['content'], 12);
      final encoded = jsonEncode(result);
      expect(encoded, isNot(contains('PRIVATE_CHAT')));
      expect(encoded, isNot(contains('SECRET')));
      expect(encoded, isNot(contains('private-name')));
      expect(await file.readAsBytes(), before);
    },
  );
}
