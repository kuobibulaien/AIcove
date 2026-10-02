import 'dart:convert';

import 'package:dio/dio.dart';

import '../../../core/storage/device_credential_storage.dart';

import '../../sync/data/api_client.dart';
import '../../sync/models/user_model.dart';
import '../domain/account_port.dart';

class DeviceAccountStorage implements AccountStoragePort {
  const DeviceAccountStorage();
  static const _key = 'aicove.cloud.account_connection.v1';
  static const _storage = DeviceCredentialStorage();

  @override
  Future<String?> read() => _storage.read(key: _key);
  @override
  Future<void> write(String value) => _storage.write(key: _key, value: value);
}

class CloudAccountApi implements AccountRemotePort {
  const CloudAccountApi();

  @override
  Future<AuthResponse> login(
    String server,
    String username,
    String password,
  ) async {
    final api = ApiClient(baseUrl: server, useSecureTokenStore: false);
    try {
      return AuthResponse.fromJson(
        await api.login(username: username, password: password),
      );
    } on DioException catch (error) {
      throw _failure(error);
    } catch (_) {
      throw const AccountFailure('服务器返回的账号信息无效');
    } finally {
      api.close();
    }
  }

  @override
  Future<UserModel> currentUser(String server, String token) async {
    final api = ApiClient(baseUrl: server, useSecureTokenStore: false);
    try {
      await api.saveToken(token);
      return UserModel.fromJson(await api.getCurrentUser());
    } on DioException catch (error) {
      if (error.response?.statusCode == 401 ||
          error.response?.statusCode == 403) {
        throw const ExpiredAccountSession();
      }
      throw _failure(error);
    } catch (_) {
      throw const AccountFailure('服务器返回的账号信息无效');
    } finally {
      api.close();
    }
  }

  @override
  Future<AuthResponse?> renew(String server, String token) async {
    final api = ApiClient(baseUrl: server, useSecureTokenStore: false);
    try {
      await api.saveToken(token);
      return AuthResponse.fromJson(await api.refreshToken());
    } on DioException catch (error) {
      final status = error.response?.statusCode;
      if (status == 401 || status == 403) throw const ExpiredAccountSession();
      if (status == 404 || status == 405) return null;
      throw _failure(error);
    } catch (_) {
      throw const AccountFailure('服务器返回的账号信息无效');
    } finally {
      api.close();
    }
  }

  AccountFailure _failure(DioException error) =>
      AccountFailure(switch (error.response?.statusCode) {
        401 => '用户名或密码不正确',
        403 => '账号已停用，请联系服务器管理员',
        429 => '登录尝试过于频繁，请稍后重试',
        404 => '服务器地址不正确，未找到账号服务',
        _ => '无法连接账号服务，请检查网络和服务器地址',
      });
}

class ExpiredAccountSession implements Exception {
  const ExpiredAccountSession();
}

class AccountRepository implements AccountPort {
  AccountRepository(this._storage, this._remote);
  final AccountStoragePort _storage;
  final AccountRemotePort _remote;
  AccountConnection? _connection;
  bool _loaded = false;

  @override
  AccountConnection? get connection => _connection;

  @override
  Future<void> load() async {
    try {
      final saved = await _storage.read();
      _connection = saved == null
          ? null
          : AccountConnection.fromJson(
              jsonDecode(saved) as Map<String, dynamic>,
            );
      _loaded = true;
    } catch (_) {
      throw const AccountFailure('无法读取本机账号资料，请稍后重试');
    }
  }

  @override
  Future<void> login(String server, String username, String password) async {
    if (!_loaded) {
      throw const AccountFailure('本机账号资料尚未读取完成');
    }
    final address = normalizeCloudServer(server);
    final name = username.trim();
    if (name.isEmpty || password.isEmpty) {
      throw const AccountFailure('请填写用户名和密码');
    }
    final result = await _remote.login(address, name, password);
    if (result.accessToken.isEmpty || result.user.id <= 0) {
      throw const AccountFailure('服务器返回的账号信息无效');
    }
    final owner = _connection;
    if (owner != null && !owner.owns(address, result.user)) {
      // Until local datasets can be switched atomically, fail closed instead
      // of silently assigning existing chats to another authenticated user.
      throw AccountFailure('这台设备的数据已绑定 ${owner.user.username}，请使用该账号登录');
    }
    await _save(
      AccountConnection(
        server: address,
        user: result.user,
        token: result.accessToken,
      ),
    );
  }

  @override
  Future<void> refresh() async {
    final current = _connection;
    if (current == null || !current.hasSession) return;
    try {
      final user = await _remote.currentUser(current.server, current.token!);
      if (!current.owns(current.server, user)) {
        throw const ExpiredAccountSession();
      }
      // Sliding renewal: every successful check extends the session, so only
      // a device left unused past the server token lifetime must log in again.
      final renewed = await _remote.renew(current.server, current.token!);
      if (renewed != null &&
          (renewed.accessToken.isEmpty ||
              !current.owns(current.server, renewed.user))) {
        throw const ExpiredAccountSession();
      }
      await _save(
        AccountConnection(
          server: current.server,
          user: renewed?.user ?? user,
          token: renewed?.accessToken ?? current.token,
        ),
      );
    } on ExpiredAccountSession {
      await logout();
      throw const AccountFailure('登录已失效，请重新输入密码；本地数据已保留');
    }
  }

  @override
  Future<void> logout() async {
    final current = _connection;
    if (current == null) return;
    await _save(AccountConnection(server: current.server, user: current.user));
  }

  Future<void> _save(AccountConnection next) async {
    try {
      await _storage.write(jsonEncode(next.toJson()));
    } catch (_) {
      throw const AccountFailure('账号资料保存失败，请稍后重试');
    }
    _connection = next;
  }
}
