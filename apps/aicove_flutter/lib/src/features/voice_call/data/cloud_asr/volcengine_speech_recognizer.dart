import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../domain/speech_recognizer_port.dart';
import 'websocket_speech_recognizer.dart';

/// 火山引擎豆包流式语音识别（双向流式优化版 `bigmodel_async`）。
///
/// 二进制帧：4 字节头（版本／头长、消息类型／标志、序列化／压缩、保留）＋ 4 字节大端长度 ＋ gzip 负载。
/// 开 `show_utterances` 后服务端按静音（`end_window_size`）判停，判停的分句带 `definite: true`。
class VolcengineSpeechRecognizer extends WebSocketSpeechRecognizer {
  VolcengineSpeechRecognizer({
    required this.apiKey,
    required this.resourceId,
    required this.endpoint,
    this.appId,
    this.endOfTurnSilenceMs = 500,
    super.connect,
  });

  /// 新版控制台的 API Key；旧版控制台填了 [appId] 时这里是 Access Token。
  final String apiKey;
  final String? appId;

  /// 即模型名，如 `volc.seedasr.sauc.duration`。
  final String resourceId;
  final Uri endpoint;
  final int endOfTurnSilenceMs;

  /// 已经报过定稿的分句（按开始时间），全量返回时不重复报。
  final _reported = <int>{};

  @override
  String get vendor => '火山引擎';

  @override
  Future<(Uri, Map<String, String>)> connection() async {
    final connectId = randomUuid();
    final legacy = appId?.trim().isNotEmpty ?? false;
    return (
      endpoint,
      {
        if (legacy) ...{
          'X-Api-App-Key': appId!.trim(),
          'X-Api-Access-Key': apiKey,
        } else
          'X-Api-Key': apiKey,
        'X-Api-Resource-Id': resourceId,
        'X-Api-Request-Id': connectId,
        'X-Api-Connect-Id': connectId,
      },
    );
  }

  @override
  void onOpen(WebSocket socket) {
    final payload = utf8.encode(
      jsonEncode({
        'user': {'uid': 'aicove'},
        'audio': {
          'format': 'pcm',
          'codec': 'raw',
          'rate': speechRecognizerSampleRate,
          'bits': 16,
          'channel': 1,
        },
        'request': {
          'model_name': 'bigmodel',
          'enable_itn': true,
          'enable_punc': true,
          'show_utterances': true,
          // 只返回新变化的分句，长通话不重复下发整段历史。
          'result_type': 'single',
          'end_window_size': endOfTurnSilenceMs,
        },
      }),
    );
    socket.add(
      volcengineFrame(type: 0x1, serialization: 0x1, payload: payload),
    );
    // 协议没有单独的就绪事件，发完请求即可送音频；鉴权失败会在握手或首帧报错。
    markReady();
  }

  @override
  void onMessage(Object data) {
    if (data is! List<int>) return;
    final frame = parseVolcengineFrame(Uint8List.fromList(data));
    if (frame.errorCode != null) {
      fail(
        '${frame.errorCode}: ${utf8.decode(frame.payload, allowMalformed: true)}',
      );
      return;
    }
    if (frame.type != 0x9) return;
    if (frame.payload.isNotEmpty) {
      final json = jsonDecode(utf8.decode(frame.payload));
      final result = json is Map ? json['result'] : null;
      final utterances = result is Map ? result['utterances'] : null;
      if (utterances is List) {
        for (final item in utterances.whereType<Map>()) {
          final text = item['text']?.toString() ?? '';
          final start = (item['start_time'] as num?)?.toInt() ?? -1;
          if (item['definite'] == true) {
            if (_reported.add(start)) finalText(text);
          } else if (!_reported.contains(start)) {
            partial(text);
          }
        }
      }
    }
    if (frame.isLast) markFinished();
  }

  @override
  void sendAudio(WebSocket socket, Uint8List pcm16) =>
      socket.add(volcengineFrame(type: 0x2, payload: pcm16));

  @override
  void sendFinish(WebSocket socket) =>
      socket.add(volcengineFrame(type: 0x2, flags: 0x2, payload: Uint8List(0)));
}

/// 组一帧客户端消息：负载一律 gzip。
Uint8List volcengineFrame({
  required int type,
  int flags = 0x0,
  int serialization = 0x0,
  required List<int> payload,
}) {
  final body = gzip.encode(payload);
  final out = BytesBuilder(copy: false)
    ..add([0x11, (type << 4) | flags, (serialization << 4) | 0x1, 0x00])
    ..add((ByteData(4)..setUint32(0, body.length)).buffer.asUint8List())
    ..add(body);
  return out.toBytes();
}

class VolcengineFrame {
  const VolcengineFrame({
    required this.type,
    required this.flags,
    required this.payload,
    this.errorCode,
  });

  final int type;
  final int flags;
  final Uint8List payload;
  final int? errorCode;

  /// 最后一包的结果（标志位第二位）。
  bool get isLast => flags & 0x2 != 0;
}

VolcengineFrame parseVolcengineFrame(Uint8List bytes) {
  final view = ByteData.sublistView(bytes);
  final headerSize = (bytes[0] & 0x0f) * 4;
  final type = bytes[1] >> 4;
  final flags = bytes[1] & 0x0f;
  final gzipped = bytes[2] & 0x0f == 0x1;
  var offset = headerSize;
  int? errorCode;
  if (type == 0xf) {
    errorCode = view.getUint32(offset);
    offset += 4;
  } else if (flags & 0x1 != 0) {
    offset += 4; // sequence
  }
  final size = view.getUint32(offset);
  offset += 4;
  var payload = Uint8List.sublistView(bytes, offset, offset + size);
  if (gzipped && payload.isNotEmpty) {
    payload = Uint8List.fromList(gzip.decode(payload));
  }
  return VolcengineFrame(
    type: type,
    flags: flags,
    payload: payload,
    errorCode: errorCode,
  );
}
