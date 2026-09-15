import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/account_repository.dart';
import '../domain/account_port.dart';

class AccountState {
  const AccountState({this.connection, this.busy = false, this.error});
  final AccountConnection? connection;
  final bool busy;
  final String? error;
}

final accountRepositoryProvider = Provider<AccountPort>(
  (ref) =>
      AccountRepository(const DeviceAccountStorage(), const CloudAccountApi()),
);

final accountProvider = StateNotifierProvider<AccountController, AccountState>(
  (ref) => AccountController(ref.watch(accountRepositoryProvider)),
);

class AccountController extends StateNotifier<AccountState> {
  AccountController(this._account) : super(const AccountState(busy: true)) {
    unawaited(_initialize());
  }
  final AccountPort _account;

  Future<void> _initialize() async {
    await _run(() async {
      await _account.load();
      await _account.refresh();
    }, initializing: true);
  }

  Future<bool> login(String server, String username, String password) =>
      _run(() => _account.login(server, username, password));
  Future<bool> logout() => _run(_account.logout);
  Future<bool> refresh() => _run(() async {
    await _account.load();
    await _account.refresh();
  });

  Future<bool> _run(
    Future<void> Function() action, {
    bool initializing = false,
  }) async {
    if (state.busy && !initializing) return false;
    state = AccountState(connection: _account.connection, busy: true);
    try {
      await action();
      if (mounted) state = AccountState(connection: _account.connection);
      return true;
    } catch (error) {
      if (mounted) {
        state = AccountState(
          connection: _account.connection,
          error: error is AccountFailure ? error.message : '账号操作失败，请稍后重试',
        );
      }
      return false;
    }
  }
}
