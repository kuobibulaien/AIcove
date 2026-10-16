import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'websocket_speech_recognizer.dart';

/// 讯飞实时语音转写（标准版，`rtasr.xfyun.cn/v1/ws`）。
///
/// 鉴权：`signa = base64(HmacSHA1(MD5(appid + ts), apiKey))`，与 appid、ts 一起放在地址里。
/// 结果在 `data` 字段里（JSON 字符串），`cn.st.type` 为 "0" 是定稿、"1" 是中间结果。
class XfyunSpeechRecognizer extends WebSocketSpeechRecognizer {
  XfyunSpeechRecognizer({
    required this.appId,
    required this.apiKey,
    required this.endpoint,
    DateTime Function()? now,
    super.connect,
  }) : _now = now ?? DateTime.now;

  final String appId;
  final String apiKey;
  final Uri endpoint;
  final DateTime Function() _now;

  @override
  String get vendor => '讯飞';

  @override
  Future<(Uri, Map<String, String>)> connection() async {
    final ts = '${_now().millisecondsSinceEpoch ~/ 1000}';
    final base = md5.convert(utf8.encode('$appId$ts')).toString();
    final signa = base64Encode(
      Hmac(sha1, utf8.encode(apiKey)).convert(utf8.encode(base)).bytes,
    );
    return (
      endpoint.replace(
        queryParameters: {
          ...endpoint.queryParameters,
          'appid': appId,
          'ts': ts,
          'signa': signa,
        },
      ),
      const <String, String>{},
    );
  }

  @override
  void onOpen(WebSocket socket) {}

  @override
  void onMessage(Object data) {
    if (data is! String) return;
    final message = jsonDecode(data);
    if (message is! Map) return;
    switch (message['action']) {
      case 'started':
        markReady();
      case 'error':
        fail('${message['code']}: ${message['desc']}');
      case 'result':
        final raw = message['data'];
        final result = raw is String && raw.isNotEmpty ? jsonDecode(raw) : raw;
        _onResult(result);
    }
  }

  void _onResult(Object? result) {
    final cn = result is Map ? result['cn'] : null;
    final st = cn is Map ? cn['st'] : null;
    if (st is! Map) return;
    final text = StringBuffer();
    for (final rt in (st['rt'] as List? ?? const []).whereType<Map>()) {
      for (final ws in (rt['ws'] as List? ?? const []).whereType<Map>()) {
        final cw = (ws['cw'] as List? ?? const []).whereType<Map>();
        if (cw.isNotEmpty) text.write(cw.first['w'] ?? '');
      }
    }
    if ('${st['type']}' == '0') {
      finalText(text.toString());
    } else {
      partial(text.toString());
    }
  }

  @override
  void sendAudio(WebSocket socket, Uint8List pcm16) => socket.add(pcm16);

  /// 讯飞收到结束标记后发完结果就关连接，由连接关闭收尾。
  @override
  void sendFinish(WebSocket socket) =>
      socket.add(utf8.encode(jsonEncode({'end': true})));
}
