import 'dart:io';

import 'package:aicove_flutter/src/core/database/database.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _TemporaryPaths extends PathProviderPlatform {
  _TemporaryPaths(this.path);
  final String path;

  @override
  Future<String?> getApplicationDocumentsPath() async => path;

  @override
  Future<String?> getApplicationSupportPath() async => path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('生产连接在临时目录启用5000ms忙等待、外键与WAL', () async {
    final directory = await Directory.systemTemp.createTemp('db_connection_');
    final previous = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _TemporaryPaths(directory.path);
    final database = AppDatabase();
    addTearDown(() async {
      await database.close();
      PathProviderPlatform.instance = previous;
      await directory.delete(recursive: true);
    });

    expect(
      (await database.customSelect('PRAGMA busy_timeout').getSingle())
          .read<int>('timeout'),
      5000,
    );
    expect(
      (await database.customSelect('PRAGMA foreign_keys').getSingle())
          .read<int>('foreign_keys'),
      1,
    );
    expect(
      (await database.customSelect('PRAGMA journal_mode').getSingle())
          .read<String>('journal_mode'),
      'wal',
    );
    expect(File('${directory.path}/aicove.db').existsSync(), isTrue);
  });
}
