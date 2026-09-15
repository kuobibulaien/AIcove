import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/features/account/data/account_repository.dart';
import 'package:aicove_flutter/src/features/account/domain/account_port.dart';
import 'package:aicove_flutter/src/features/sync/models/user_model.dart';

class MemoryStorage implements AccountStoragePort {
  String? value;
  bool failWrite = false;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String next) async {
    if (failWrite) throw StateError('storage unavailable');
    value = next;
  }
}

class RemoteAccount implements AccountRemotePort {
  UserModel user = UserModel(id: 12, username: 'fixture', uniqueId: 'uid-12');
  String? receivedPassword;
  Exception? refreshError;
  @override
  Future<AuthResponse> login(
    String server,
    String name,
    String password,
  ) async {
    receivedPassword = password;
    return AuthResponse(
      accessToken: 'fixture-token',
      tokenType: 'bearer',
      user: user,
    );
  }

  @override
  Future<UserModel> currentUser(String server, String token) async {
    if (refreshError != null) throw refreshError!;
    return user;
  }
}

void main() {
  test(
    'bind, restart, logout and relogin retain ownership without saving password',
    () async {
      final storage = MemoryStorage();
      final remote = RemoteAccount();
      var repo = AccountRepository(storage, remote);
      await repo.load();
      await repo.login(
        'https://example.test/cloud/',
        ' fixture ',
        ' private-pass ',
      );
      expect(remote.receivedPassword, ' private-pass ');
      expect(storage.value, isNot(contains('private-pass')));
      expect(repo.connection!.server, 'https://example.test/cloud');
      repo = AccountRepository(storage, remote);
      await repo.load();
      expect(repo.connection!.user.id, 12);
      await repo.logout();
      expect(repo.connection!.hasSession, false);
      expect(repo.connection!.user.id, 12);
      expect(storage.value, isNot(contains('fixture-token')));
      await repo.login('https://example.test/cloud', 'fixture', 'private-pass');
      expect(repo.connection!.hasSession, true);
    },
  );

  test(
    'another account or server cannot claim the existing local dataset',
    () async {
      final storage = MemoryStorage();
      final remote = RemoteAccount();
      final repo = AccountRepository(storage, remote);
      await repo.load();
      await repo.login('https://example.test', 'fixture', 'test-password');
      await repo.logout();
      final original = storage.value;
      remote.user = UserModel(id: 13, username: 'other', uniqueId: 'uid-13');
      await expectLater(
        repo.login('https://example.test', 'other', 'password'),
        throwsA(isA<AccountFailure>()),
      );
      remote.user = UserModel(id: 12, username: 'fixture', uniqueId: 'uid-12');
      await expectLater(
        repo.login('https://elsewhere.test', 'fixture', 'password'),
        throwsA(isA<AccountFailure>()),
      );
      remote.user = UserModel(
        id: 12,
        username: 'fixture',
        uniqueId: 'reused-id',
      );
      await expectLater(
        repo.login('https://example.test', 'fixture', 'password'),
        throwsA(isA<AccountFailure>()),
      );
      expect(storage.value, original);
    },
  );

  test(
    'offline validation preserves session; expired token preserves owner',
    () async {
      final storage = MemoryStorage();
      final remote = RemoteAccount();
      final repo = AccountRepository(storage, remote);
      await repo.load();
      await repo.login('https://example.test', 'fixture', 'test-password');
      remote.refreshError = const AccountFailure('offline');
      await expectLater(repo.refresh(), throwsA(isA<AccountFailure>()));
      expect(repo.connection!.hasSession, true);
      remote.refreshError = const ExpiredAccountSession();
      await expectLater(repo.refresh(), throwsA(isA<AccountFailure>()));
      expect(repo.connection!.hasSession, false);
      expect(repo.connection!.user.id, 12);
    },
  );

  test('secure storage failures cannot falsely complete a binding', () async {
    final storage = MemoryStorage()..failWrite = true;
    final repo = AccountRepository(storage, RemoteAccount());
    await repo.load();
    await expectLater(
      repo.login('https://example.test', 'fixture', 'password'),
      throwsA(isA<AccountFailure>()),
    );
    expect(repo.connection, isNull);
  });

  test('corrupt ownership is not silently replaced with a new login', () async {
    final storage = MemoryStorage()..value = 'corrupt';
    final repo = AccountRepository(storage, RemoteAccount());
    await expectLater(repo.load(), throwsA(isA<AccountFailure>()));
    await expectLater(
      repo.login('https://example.test', 'fixture', 'password'),
      throwsA(isA<AccountFailure>()),
    );
    expect(storage.value, 'corrupt');
  });

  test(
    'remote transport preserves URL prefix and never sends old universal token',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final requests = <String>[];
      server.listen((request) async {
        requests.add(request.uri.path);
        request.response.headers.contentType = ContentType.json;
        if (request.uri.path.endsWith('/login')) {
          expect(request.headers.value('authorization'), isNull);
          final body = jsonDecode(await utf8.decoder.bind(request).join());
          expect(body['password'], 'test-password');
          request.response.write(
            jsonEncode({
              'access_token': 'only-for-this-server',
              'token_type': 'bearer',
              'user': {'id': 12, 'username': 'fixture', 'unique_id': 'uid-12'},
            }),
          );
        } else {
          expect(
            request.headers.value('authorization'),
            'Bearer only-for-this-server',
          );
          request.response.write(
            jsonEncode({
              'id': 12,
              'username': 'fixture',
              'unique_id': 'uid-12',
            }),
          );
        }
        await request.response.close();
      });
      const api = CloudAccountApi();
      final base = 'http://127.0.0.1:${server.port}/cloud';
      final result = await api.login(base, 'fixture', 'test-password');
      expect((await api.currentUser(base, result.accessToken)).id, 12);
      expect(requests, ['/cloud/api/v1/auth/login', '/cloud/api/v1/auth/me']);
    },
  );

  test(
    'insecure public URLs and credential-bearing addresses are rejected',
    () {
      for (final value in [
        'http://example.test',
        'https://name:pass@example.test',
        'https://example.test?token=secret',
        'https://example.test#secret',
        '/relative',
      ]) {
        expect(
          () => normalizeCloudServer(value),
          throwsA(isA<AccountFailure>()),
        );
      }
    },
  );
}
