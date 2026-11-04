import 'dart:convert';
import 'dart:isolate';
import '../../observability/frame_jank_recorder.dart';
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

  /// Six-digit codes are short, so the code only authenticates an X25519
  /// exchange: a passive observer who later guesses it still lacks the pair key.
  static Future<String> pinKey(String pin, String hostId) async {
    final derived =
        await Pbkdf2(
          macAlgorithm: Hmac.sha256(),
          iterations: 60000,
          bits: 256,
        ).deriveKey(
          secretKey: SecretKey(utf8.encode(pin)),
          nonce: utf8.encode('aicove-lan-pin-v1/$hostId'),
        );
    return base64Url.encode(await derived.extractBytes());
  }

  static Future<SimpleKeyPair> exchangeKeyPair() => X25519().newKeyPair();

  static Future<String> publicKey(SimpleKeyPair pair) async =>
      base64Url.encode((await pair.extractPublicKey()).bytes);

  static Future<String> pinPairKey(
    String pinKey,
    SimpleKeyPair own,
    String remotePublicKey,
    String a,
    String b,
  ) async {
    final remote = base64Url.decode(remotePublicKey);
    if (remote.length != 32) throw const LanSyncFailure('配对密钥无效');
    final shared = await X25519().sharedSecretKey(
      keyPair: own,
      remotePublicKey: SimplePublicKey(remote, type: KeyPairType.x25519),
    );
    final devices = [a, b]..sort();
    final derived = await Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
      secretKey: SecretKey([
        ...await shared.extractBytes(),
        ...base64Url.decode(pinKey),
      ]),
      nonce: utf8.encode('aicove-lan-pin-pair-v1'),
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
    if (_largeValue(value)) {
      return Isolate.run(() => _seal(secret, value, header, trace: false));
    }
    return _seal(secret, value, header, trace: true);
  }

  static Future<Map<String, dynamic>> _seal(
    String secret,
    Map<String, dynamic> value,
    Map<String, Object> header, {
    required bool trace,
  }) async {
    List<int> encode() => utf8.encode(canonicalJson(value));
    final bytes = trace
        ? FrameJankRecorder.instance.traceSync('lan.crypto.seal', encode)
        : encode();
    final box = await cipher.encrypt(
      bytes,
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
      if ((envelope['ciphertext'] as String).length >= 16384) {
        return await Isolate.run(
          () => _open(secret, envelope, header, trace: false),
        );
      }
      return await _open(secret, envelope, header, trace: true);
    } catch (_) {
      throw const LanSyncFailure('局域网连接认证失败，数据未被接收');
    }
  }

  static Future<Map<String, dynamic>> _open(
    String secret,
    Map<String, dynamic> envelope,
    Map<String, Object> header, {
    required bool trace,
  }) async {
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
    Map<String, dynamic> decode() =>
        Map<String, dynamic>.from(jsonDecode(utf8.decode(bytes)) as Map);
    return trace
        ? FrameJankRecorder.instance.traceSync('lan.crypto.open', decode)
        : decode();
  }

  // Count the JSON UTF-8 size without building a large serialized string on
  // the UI isolate. Stop as soon as the worker threshold is reached.
  static bool _largeValue(Object? value) {
    const limit = 16384;
    var size = 0;
    void string(String text) {
      size += 2;
      for (var i = 0; i < text.length && size < limit; i++) {
        final unit = text.codeUnitAt(i);
        if (unit == 0x22 ||
            unit == 0x5c ||
            unit == 8 ||
            unit == 9 ||
            unit == 10 ||
            unit == 12 ||
            unit == 13) {
          size += 2;
        } else if (unit < 0x20) {
          size += 6;
        } else if (unit < 0x80) {
          size++;
        } else if (unit < 0x800) {
          size += 2;
        } else if (unit >= 0xd800 &&
            unit <= 0xdbff &&
            i + 1 < text.length &&
            text.codeUnitAt(i + 1) >= 0xdc00 &&
            text.codeUnitAt(i + 1) <= 0xdfff) {
          size += 4;
          i++;
        } else {
          size += 3;
        }
      }
    }

    void visit(Object? item) {
      if (size >= limit) return;
      if (item is String) {
        string(item);
      } else if (item is Map) {
        size += 2;
        var first = true;
        for (final entry in item.entries) {
          if (!first) size++;
          first = false;
          string(entry.key.toString());
          size++;
          visit(entry.value);
          if (size >= limit) break;
        }
      } else if (item is List) {
        size += 2;
        var first = true;
        for (final child in item) {
          if (!first) size++;
          first = false;
          visit(child);
          if (size >= limit) break;
        }
      } else {
        size += jsonEncode(item).length;
      }
    }

    visit(value);
    return size >= limit;
  }
}
