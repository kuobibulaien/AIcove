import '../../sync/models/user_model.dart';

const defaultCloudServer = 'https://cpa.aicove.online/aicove';

class AccountFailure implements Exception {
  const AccountFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Ownership of this installation's existing local dataset survives logout.
class AccountConnection {
  const AccountConnection({
    required this.server,
    required this.user,
    this.token,
  });
  final String server;
  final UserModel user;
  final String? token;

  bool get hasSession => token != null && token!.isNotEmpty;

  bool owns(String address, UserModel candidate) =>
      server == address &&
      user.id == candidate.id &&
      user.uniqueId == candidate.uniqueId;

  Map<String, dynamic> toJson() => {
    'version': 1,
    'server': server,
    'user': user.toJson(),
    'token': token,
  };

  factory AccountConnection.fromJson(Map<String, dynamic> json) {
    if (json['version'] != 1) {
      throw const AccountFailure('账号资料版本不受支持，请更新应用');
    }
    return AccountConnection(
      server: normalizeCloudServer(json['server'] as String),
      user: UserModel.fromJson(Map<String, dynamic>.from(json['user'] as Map)),
      token: json['token'] as String?,
    );
  }
}

String normalizeCloudServer(String value) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null ||
      !uri.hasAuthority ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      (uri.scheme != 'https' &&
          !(uri.scheme == 'http' &&
              const ['localhost', '127.0.0.1', '::1'].contains(uri.host)))) {
    throw const AccountFailure('请输入有效的 HTTPS 服务器地址');
  }
  return uri.toString().replaceFirst(RegExp(r'/+$'), '');
}

abstract interface class AccountStoragePort {
  Future<String?> read();
  Future<void> write(String value);
}

abstract interface class AccountRemotePort {
  Future<AuthResponse> login(String server, String username, String password);
  Future<UserModel> currentUser(String server, String token);

  /// Exchanges a still-valid token for a fresh one. Returns null when the
  /// server predates token renewal, so the current token stays in use.
  Future<AuthResponse?> renew(String server, String token);
}

abstract interface class AccountPort {
  AccountConnection? get connection;
  Future<void> load();
  Future<void> login(String server, String username, String password);
  Future<void> refresh();
  Future<void> logout();
}
