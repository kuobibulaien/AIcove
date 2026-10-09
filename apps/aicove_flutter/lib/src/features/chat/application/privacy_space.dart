/// 隐私空间密码：把联系人移入隐私空间（会话 `isHidden`）后，凭密码进入查看。
///
/// 只存 PBKDF2 哈希，放在随设置同步的偏好里，多设备共用一个密码（ADR0070）。
/// 值是单个字符串而不是 JSON 对象：同步按 JSON 字段合并，盐和哈希若分属
/// 两台设备的修改会被拼成一个永远验证不过的组合。
library;

import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/sync/cloud_setting_policy.dart';

const privacySpaceMinPasswordLength = 4;

/// 持久化端口，测试可替换为内存实现。
class PrivacySpaceStore {
  const PrivacySpaceStore({required this.read, required this.write});

  factory PrivacySpaceStore.preferences() => PrivacySpaceStore(
    read: () async {
      final preferences = await SharedPreferences.getInstance();
      // 同步可能在别的 isolate 写入，读前刷新。
      await preferences.reload();
      return preferences.getString(privacySpacePasswordKey);
    },
    write: (value) async {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(privacySpacePasswordKey, value);
    },
  );

  final Future<String?> Function() read;
  final Future<void> Function(String value) write;
}

final privacySpaceStoreProvider = Provider<PrivacySpaceStore>(
  (ref) => PrivacySpaceStore.preferences(),
);

final privacySpacePasswordProvider = Provider<PrivacySpacePassword>(
  (ref) => PrivacySpacePassword(ref.watch(privacySpaceStoreProvider)),
);

/// 每次都读存储，不缓存：另一台设备改的密码同步过来后立即生效。
class PrivacySpacePassword {
  const PrivacySpacePassword(this._store);

  static const _version = 'v1';
  static const _iterations = 60000;

  final PrivacySpaceStore _store;

  Future<({String salt, String hash})?> _load() async {
    final parts = (await _store.read())?.split(r'$');
    if (parts == null || parts.length != 3 || parts[0] != _version) {
      return null;
    }
    return (salt: parts[1], hash: parts[2]);
  }

  static Future<String> _derive(String password, String salt) async {
    final key =
        await Pbkdf2(
          macAlgorithm: Hmac.sha256(),
          iterations: _iterations,
          bits: 256,
        ).deriveKey(
          secretKey: SecretKey(utf8.encode(password)),
          nonce: base64Url.decode(salt),
        );
    return base64Url.encode(await key.extractBytes());
  }

  Future<bool> isSet() async => await _load() != null;

  Future<void> set(String password) async {
    if (password.length < privacySpaceMinPasswordLength) {
      throw ArgumentError.value(password, 'password', 'too short');
    }
    final random = Random.secure();
    final salt = base64Url.encode(
      List<int>.generate(16, (_) => random.nextInt(256)),
    );
    await _store.write('$_version\$$salt\$${await _derive(password, salt)}');
  }

  Future<bool> verify(String password) async {
    final stored = await _load();
    if (stored == null) return false;
    return await _derive(password, stored.salt) == stored.hash;
  }
}
