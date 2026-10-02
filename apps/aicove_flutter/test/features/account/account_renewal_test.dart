import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/features/account/domain/account_port.dart';
import 'package:aicove_flutter/src/features/account/providers/account_provider.dart';
import 'package:aicove_flutter/src/features/sync/models/user_model.dart';

class CountingAccount implements AccountPort {
  final user = UserModel(id: 12, username: 'fixture', uniqueId: 'uid-12');
  late AccountConnection? _connection = AccountConnection(
    server: 'https://example.test',
    user: user,
    token: 'token-0',
  );
  int refreshes = 0;
  Object? refreshError;

  @override
  AccountConnection? get connection => _connection;
  @override
  Future<void> load() async {}
  @override
  Future<void> login(String server, String username, String password) async {}
  @override
  Future<void> logout() async {
    _connection = AccountConnection(server: _connection!.server, user: user);
  }

  @override
  Future<void> refresh() async {
    refreshes++;
    final error = refreshError;
    if (error is AccountFailure) {
      await logout();
      throw error;
    }
    if (error != null) throw error;
    _connection = AccountConnection(
      server: _connection!.server,
      user: user,
      token: 'token-$refreshes',
    );
  }
}

void main() {
  testWidgets('running app renews the session periodically', (tester) async {
    final account = CountingAccount();
    final controller = AccountController(account);
    await tester.pump();
    expect(account.refreshes, 1);
    expect(controller.state.connection!.token, 'token-1');

    await tester.pump(AccountController.renewInterval);
    expect(account.refreshes, 2);
    expect(controller.state.connection!.token, 'token-2');
    expect(controller.state.busy, false);

    account.refreshError = StateError('offline');
    await tester.pump(AccountController.renewInterval);
    expect(controller.state.connection!.token, 'token-2');
    expect(controller.state.error, isNull);

    account.refreshError = const AccountFailure('登录已失效');
    await tester.pump(AccountController.renewInterval);
    expect(controller.state.connection!.hasSession, false);
    expect(controller.state.error, '登录已失效');

    final count = account.refreshes;
    await tester.pump(AccountController.renewInterval);
    expect(account.refreshes, count);
    controller.dispose();
  });
}
