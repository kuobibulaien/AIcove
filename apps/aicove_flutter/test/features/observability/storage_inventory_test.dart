import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/features/observability/storage_inventory.dart';
import 'package:aicove_flutter/src/features/observability/diagnostic_access_service.dart';

void main() {
  test(
    'counts actual sizes without exposing filenames, bodies or linked data',
    () async {
      final root = await Directory.systemTemp.createTemp('storage_inventory');
      addTearDown(() => root.delete(recursive: true));
      final data = await Directory(
        '${root.path}/data/app_flutter/logs/trace/payload',
      ).create(recursive: true);
      await File(
        '${data.path}/private-person.json',
      ).writeAsString('SECRET_BODY');
      await File(
        '${root.path}/data/app_flutter/aicove.db',
      ).writeAsBytes(List.filled(100, 0));
      await File('${root.path}/outside').writeAsBytes(List.filled(1000, 0));
      await Link('${data.path}/outside-link').create('${root.path}/outside');
      final result = await createStorageInventory('${root.path}/data');
      expect(result['totalBytes'], 111);
      expect(result['fileCount'], 2);
      final text = jsonEncode(result);
      expect(text, isNot(contains('SECRET_BODY')));
      expect(text, isNot(contains('private-person')));
      expect(text, isNot(contains(root.path)));
      expect((result['coverage'] as Map)['linksSkipped'], 1);
      expect((result['coverage'] as Map)['truncated'], false);
      expect((result['largestFiles'] as List).first['kind'], 'aicove.db');
      final limited = await createStorageInventory(
        '${root.path}/data',
        maxEntries: 1,
      );
      expect((limited['coverage'] as Map)['truncated'], true);
      final missing = await createStorageInventory('${root.path}/missing');
      expect((missing['coverage'] as Map)['errors'], 1);
    },
  );

  test(
    'storage endpoint requires authentication and rejects caller paths',
    () async {
      var scans = 0;
      final service = DiagnosticAccessService(
        port: 0,
        tokenLoader: () async => 'test-token',
        storageBuilder: () async {
          scans++;
          return Uint8List.fromList(utf8.encode('{"totalBytes":111}'));
        },
      );
      final client = HttpClient()..findProxy = (_) => 'DIRECT';
      addTearDown(() async {
        client.close(force: true);
        await service.stop();
      });
      await service.start();
      Future<HttpClientResponse> request(
        String path, {
        bool auth = true,
      }) async {
        final req = await client.getUrl(
          Uri.parse('http://127.0.0.1:${service.session.value!.port}$path'),
        );
        if (auth) req.headers.set('Authorization', 'Bearer test-token');
        return req.close();
      }

      for (final item in [
        ('/v1/storage', false, 401),
        ('/v1/storage?path=/etc', true, 404),
      ]) {
        final response = await request(item.$1, auth: item.$2);
        expect(response.statusCode, item.$3);
        await response.drain<void>();
      }
      expect(scans, 0);
      final response = await request('/v1/storage');
      expect(response.statusCode, 200);
      expect(
        jsonDecode(await utf8.decoder.bind(response).join())['totalBytes'],
        111,
      );
      expect(scans, 1);
    },
  );
}
