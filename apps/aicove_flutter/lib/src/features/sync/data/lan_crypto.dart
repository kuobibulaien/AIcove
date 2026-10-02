import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import '../domain/lan_contract.dart';
import 'cloud_document.dart';

class LanCrypto {
  static final cipher = AesGcm.with256bits();
  static Future<String> randomKey() async =>
      base64Url.encode(await (await cipher.newSecretKey()).extractBytes());
  static SecretKey key(String encoded) {
    final bytes = base64Url.decode(encoded);
    if (bytes.length != 32) throw const LanSyncFailure('配对密钥无效');
    return SecretKey(bytes);
  }

  static Future<String> pairKey(String inviteKey, String a, String b) async {
    final devices = [a, b]..sort();
    final derived = await Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
      secretKey: key(inviteKey),
      nonce: utf8.encode('aicove-lan-pair-v1'),
      info: utf8.encode(canonicalJson(devices)),
    );
    return base64Url.encode(await derived.extractBytes());
  }

  static Future<Map<String, dynamic>> seal(
    String secret,
    Map<String, dynamic> value, {
    required String from,
    required String to,
    required String requestId,
    bool response = false,
  }) async {
    final header = {
      'protocol': lanProtocolVersion,
      'from': from,
      'to': to,
      'request_id': requestId,
      'response': response,
    };
    final box = await cipher.encrypt(
      utf8.encode(canonicalJson(value)),
      secretKey: key(secret),
      aad: utf8.encode(canonicalJson(header)),
    );
    return {
      ...header,
      'nonce': base64Url.encode(box.nonce),
      'ciphertext': base64Url.encode(box.cipherText),
      'mac': base64Url.encode(box.mac.bytes),
    };
  }

  static Future<Map<String, dynamic>> open(
    String secret,
    Map<String, dynamic> envelope, {
    required String from,
    required String to,
    required String requestId,
    bool response = false,
  }) async {
    final header = {
      'protocol': lanProtocolVersion,
      'from': from,
      'to': to,
      'request_id': requestId,
      'response': response,
    };
    if (header.entries.any((e) => envelope[e.key] != e.value)) {
      throw const LanSyncFailure('设备身份或同步请求不匹配');
    }
    try {
      final box = SecretBox(
        base64Url.decode(envelope['ciphertext'] as String),
        nonce: base64Url.decode(envelope['nonce'] as String),
        mac: Mac(base64Url.decode(envelope['mac'] as String)),
      );
      final bytes = await cipher.decrypt(
        box,
        secretKey: key(secret),
        aad: utf8.encode(canonicalJson(header)),
      );
      return Map<String, dynamic>.from(jsonDecode(utf8.decode(bytes)) as Map);
    } catch (_) {
      throw const LanSyncFailure('局域网连接认证失败，数据未被接收');
    }
  }
}
