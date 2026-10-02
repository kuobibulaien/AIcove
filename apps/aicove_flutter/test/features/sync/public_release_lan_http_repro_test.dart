import 'dart:io';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/features/sync/data/lan_service.dart';
import 'package:aicove_flutter/src/features/sync/data/lan_transport.dart';
import 'lan_repository_test.dart' show lanTestDevice, seedLan;
import 'lan_service_test.dart' show LanTestDiscovery;
import 'lan_transport_test.dart' show LanMemoryCredentials;

void main() {
  test(
    'real paired HTTP first synchronization must preserve uncaptured local message',
    () async {
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
      final root = await Directory.systemTemp.createTemp('release-lan-http-');
      final a = await lanTestDevice(root, 'a');
      final b = await lanTestDevice(root, 'b');
      final sa = LanService(
        a.repo,
        LanPeerStore(LanMemoryCredentials(), loopback: true),
        discovery: LanTestDiscovery(),
        loopback: true,
        automatic: false,
      );
      final sb = LanService(
        b.repo,
        LanPeerStore(LanMemoryCredentials(), loopback: true),
        discovery: LanTestDiscovery(),
        loopback: true,
        automatic: false,
      );
      addTearDown(() async {
        await sa.close();
        await sb.close();
        for (final device in [a, b]) {
          await device.media.close();
          await device.local.db.close();
        }
        await root.delete(recursive: true);
      });
      await seedLan(a);
      await seedLan(b);
      await b.local.db.transaction(() async {
        for (var i = 0; i < 1600; i++) {
          await b.local.execute(
            'INSERT INTO messages(id,conversation_id,role,content,created_at) VALUES(?,?,?,?,?)',
            [
              'a${i.toString().padLeft(5, '0')}',
              'role',
              'user',
              'local history',
              1,
            ],
          );
        }
        await b.local.execute('UPDATE messages SET content=? WHERE id=?', [
          'local edit must survive',
          'message',
        ]);
      });
      await sa.initialize();
      await sb.initialize();
      await sa.setEnabled(true);
      await sb.setEnabled(true);
      await sa.invite();
      await sb.pair(sa.state.invitation!);
      await sa.approve('b');
      await sb.synchronize();
      expect(sb.peers.peers['a']!.error, isNull);
      final content = (await b.local.read(
        'messages',
        'message',
      ))!.payload['row']['content'];
      print(
        'AUDIT HTTP sync finished: content=$content; conflicts=${(await b.repo.conflicts()).length}; peer_error=${sb.peers.peers['a']!.error}',
      );
      expect(content, 'local edit must survive');
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
