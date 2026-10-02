import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/features/account/domain/account_port.dart';
import 'package:aicove_flutter/src/features/sync/data/cloud_api.dart';
import 'package:aicove_flutter/src/features/sync/models/user_model.dart';

void main() {
  test('sync transport switches to a renewed token in place', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final seen = <String?>[];
    server.listen((request) async {
      seen.add(request.headers.value('authorization'));
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'ok': true}));
      await request.response.close();
    });
    final api = CloudApi(
      AccountConnection(
        server: 'http://127.0.0.1:${server.port}',
        user: UserModel(id: 12, username: 'fixture', uniqueId: 'uid-12'),
        token: 'old-token',
      ),
    );
    addTearDown(api.close);
    await api.get('status');
    api.updateToken('new-token');
    await api.get('status');
    expect(seen, ['Bearer old-token', 'Bearer new-token']);
  });
}
