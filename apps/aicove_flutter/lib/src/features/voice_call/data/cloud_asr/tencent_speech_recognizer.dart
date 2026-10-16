import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'websocket_speech_recognizer.dart';

/// 腾讯云实时语音识别（WebSocket，`asr/v2/<appid>`）。
///
/// 鉴权在地址里：除 signature 外的参数按字典序拼成「主机/路径?参数」，
/// 用 SecretKey 做 HMAC-SHA1 再 base64，作为 signature 附在地址上。
/// 结果按 `slice_type` 区分：0 开始、1 未定稿、2 定稿；`final: 1` 表示整段结束。
class TencentSpeechRecognizer extends WebSocketSpeechRecognizer {
  TencentSpeechRecognizer({
    required this.appId,
    required this.secretId,
    required this.secretKey,
    required this.engineModelType,
    required this.endpoint,
    this.endOfTurnSilenceMs = 500,
    DateTime Function()? now,
    super.connect,
    super.keepAliveInterval,
  }) : _now = now ?? DateTime.now;

  final String appId;
  final String secretId;
  final String secretKey;

  /// 即模型名，如 `16k_zh`。
  final String engineModelType;
  final Uri endpoint;
  final int endOfTurnSilenceMs;
  final DateTime Function() _now;

  /// 支持自定义断句静音的引擎（其余引擎传了会报参数错误）。
  static const _vadSilenceEngines = {
    '8k_zh',
    '8k_zh_finance',
    '16k_zh',
    '16k_zh_en',
    '8k_zh_large',
    '16k_en',
    '16k_en_large',
  };

  @override
  String get vendor => '腾讯云';

  @override
  Future<(Uri, Map<String, String>)> connection() async =>
      (signedUri(), const <String, String>{});

  /// 签好名的连接地址。
  Uri signedUri() {
    final timestamp = _now().millisecondsSinceEpoch ~/ 1000;
    final params = <String, String>{
      'secretid': secretId,
      'timestamp': '$timestamp',
      'expired': '${timestamp + 24 * 3600}',
      'nonce': '${Random.secure().nextInt(1 << 31)}',
      'engine_model_type': engineModelType,
      'voice_id': randomUuid(),
      'voice_format': '1',
      'needvad': '1',
      if (_vadSilenceEngines.contains(engineModelType))
        // 取值 500～2000 ms。
        'vad_silence_time': '${endOfTurnSilenceMs.clamp(500, 2000)}',
    };
    final keys = params.keys.toList()..sort();
    final query = keys.map((k) => '$k=${params[k]}').join('&');
    final path = '${_basePath()}/$appId';
    // 签名原文是「主机/路径?参数」；非默认端口时主机带端口。
    final authority = endpoint.authority;
    final raw = '$authority$path?$query';
    final signature = base64Encode(
      Hmac(sha1, utf8.encode(secretKey)).convert(utf8.encode(raw)).bytes,
    );
    return Uri.parse(
      '${endpoint.scheme}://$authority$path?$query'
      '&signature=${Uri.encodeComponent(signature)}',
    );
  }

  String _basePath() {
    final path = endpoint.path;
    return path.endsWith('/') ? path.substring(0, path.length - 1) : path;
  }

  @override
  void onOpen(WebSocket socket) {}

  @override
  void onMessage(Object data) {
    if (data is! String) return;
    final message = jsonDecode(data);
    if (message is! Map) return;
    final code = message['code'];
    if (code != 0) {
      fail('$code: ${message['message']}');
      return;
    }
    // 握手成功先回一条不带结果的消息。
    markReady();
    final result = message['result'];
    if (result is Map) {
      final text = result['voice_text_str']?.toString() ?? '';
      switch (result['slice_type']) {
        case 0:
          speechStarted();
        case 1:
          partial(text);
        case 2:
          finalText(text);
      }
    }
    if (message['final'] == 1) markFinished();
  }

  @override
  void sendAudio(WebSocket socket, Uint8List pcm16) => socket.add(pcm16);

  @override
  void sendFinish(WebSocket socket) => socket.add(jsonEncode({'type': 'end'}));
}
