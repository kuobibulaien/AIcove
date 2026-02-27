import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../../core/app_logger.dart';

/// 阿里云 Qwen-TTS Realtime WebSocket 服务
///
/// 用于声音复刻模型（qwen3-tts-vc-realtime）的语音合成
/// 这些模型只支持 WebSocket 接口，不支持 HTTP REST API
///
/// WebSocket 端点: wss://dashscope.aliyuncs.com/api-ws/v1/realtime
///
/// 交互流程:
/// 1. 建立 WebSocket 连接（带 Authorization 头）
/// 2. 收到 session.created 事件
/// 3. 发送 session.update 配置音色等参数
/// 4. 收到 session.updated 确认
/// 5. 发送 input_text_buffer.append 添加文本
/// 6. 发送 session.finish 结束输入
/// 7. 接收 response.audio.delta 音频数据（Base64）
/// 8. 收到 session.finished 表示完成
class AliyunQwenTtsWebSocket {
  final String apiKey;
  final String model;

  /// WebSocket 端点
  static const String _wsEndpoint =
      'wss://dashscope.aliyuncs.com/api-ws/v1/realtime';

  AliyunQwenTtsWebSocket({
    required this.apiKey,
    required this.model,
  });

  /// 合成语音（一次性返回完整音频）
  ///
  /// [text] 要合成的文本
  /// [voiceId] 音色 ID（声音复刻创建的音色）
  /// [responseFormat] 音频格式: pcm（realtime 模型只支持 pcm）
  /// [sampleRate] 采样率: 8000, 16000, 24000, 48000
  Future<Uint8List> synthesize({
    required String text,
    required String voiceId,
    String responseFormat = 'pcm', // realtime 模型只支持 pcm
    int sampleRate = 24000,
    String languageType = 'Chinese',
  }) async {
    AppLogger.info('TTS-WS', '开始 WebSocket 语音合成', metadata: {
      'model': model,
      'voiceId': voiceId,
      'textLength': text.length,
      'responseFormat': responseFormat,
      'sampleRate': sampleRate,
    });

    final completer = Completer<Uint8List>();
    final audioChunks = <Uint8List>[];
    WebSocket? socket;

    try {
      // 构建 WebSocket URL（model 必须作为查询参数）
      final wsUri = Uri.parse('$_wsEndpoint?model=$model');

      AppLogger.info('TTS-WS', '连接 WebSocket', metadata: {
        'url': wsUri.toString(),
        'model': model,
      });

      // 使用 dart:io WebSocket 支持自定义头
      socket = await WebSocket.connect(
        wsUri.toString(),
        headers: {
          'Authorization': 'Bearer $apiKey',
        },
      );

      AppLogger.info('TTS-WS', 'WebSocket 连接成功');

      // 监听消息
      socket.listen(
        (dynamic message) {
          try {
            final data = jsonDecode(message as String) as Map<String, dynamic>;
            final type = data['type'] as String?;

            switch (type) {
              case 'session.created':
                // 会话创建成功，发送配置
                final sessionId = (data['session'] as Map?)?['id'] as String?;
                AppLogger.info('TTS-WS', '会话已创建', metadata: {
                  'sessionId': sessionId,
                });
                _sendSessionUpdate(
                  socket!,
                  voiceId: voiceId,
                  responseFormat: responseFormat,
                  sampleRate: sampleRate,
                  languageType: languageType,
                );
                break;

              case 'session.updated':
                // 配置更新成功，发送文本
                AppLogger.info('TTS-WS', '会话配置已更新');
                _sendText(socket!, text);
                // 发送结束信号
                _sendFinish(socket);
                break;

              case 'response.audio.delta':
                // 收到音频数据
                final delta = data['delta'] as String?;
                if (delta != null && delta.isNotEmpty) {
                  final audioBytes = base64Decode(delta);
                  audioChunks.add(Uint8List.fromList(audioBytes));
                }
                break;

              case 'response.done':
                // 响应完成
                AppLogger.info('TTS-WS', '响应完成', metadata: {
                  'responseId': (data['response'] as Map?)?['id'],
                  'usage': (data['response'] as Map?)?['usage'],
                });
                break;

              case 'session.finished':
                // 会话结束，合并音频数据
                AppLogger.info('TTS-WS', '会话结束，合并音频数据', metadata: {
                  'chunksCount': audioChunks.length,
                });
                _completeWithAudio(completer, audioChunks);
                break;

              case 'error':
                // 错误
                final error = data['error'] as Map<String, dynamic>?;
                final code = error?['code'] as String? ?? 'unknown';
                final errMsg = error?['message'] as String? ?? '未知错误';
                AppLogger.error('TTS-WS', 'WebSocket 错误', metadata: {
                  'code': code,
                  'message': errMsg,
                });
                if (!completer.isCompleted) {
                  completer.completeError(
                    AliyunTtsWebSocketException('$code: $errMsg'),
                  );
                }
                break;
            }
          } catch (e, st) {
            AppLogger.error('TTS-WS', '处理消息异常', metadata: {
              'error': e.toString(),
            });
            if (!completer.isCompleted) {
              completer.completeError(e, st);
            }
          }
        },
        onError: (Object error, StackTrace stackTrace) {
          AppLogger.error('TTS-WS', 'WebSocket 连接错误', metadata: {
            'error': error.toString(),
          });
          if (!completer.isCompleted) {
            completer.completeError(
              AliyunTtsWebSocketException('WebSocket 连接错误: $error'),
              stackTrace,
            );
          }
        },
        onDone: () {
          AppLogger.info('TTS-WS', 'WebSocket 连接关闭');
          if (!completer.isCompleted) {
            if (audioChunks.isNotEmpty) {
              _completeWithAudio(completer, audioChunks);
            } else {
              completer.completeError(
                AliyunTtsWebSocketException('WebSocket 连接意外关闭，未收到音频数据'),
              );
            }
          }
        },
      );

      // 设置超时
      return await completer.future.timeout(
        const Duration(seconds: 60),
        onTimeout: () {
          throw AliyunTtsWebSocketException('WebSocket 语音合成超时');
        },
      );
    } catch (e) {
      AppLogger.error('TTS-WS', 'WebSocket 语音合成失败', metadata: {
        'error': e.toString(),
      });
      rethrow;
    } finally {
      await socket?.close();
    }
  }

  /// 合并音频数据并完成
  void _completeWithAudio(
    Completer<Uint8List> completer,
    List<Uint8List> audioChunks,
  ) {
    if (completer.isCompleted) return;

    final totalLength =
        audioChunks.fold<int>(0, (sum, chunk) => sum + chunk.length);
    final result = Uint8List(totalLength);
    var offset = 0;
    for (final chunk in audioChunks) {
      result.setRange(offset, offset + chunk.length, chunk);
      offset += chunk.length;
    }
    completer.complete(result);
  }

  /// 发送会话配置
  void _sendSessionUpdate(
    WebSocket socket, {
    required String voiceId,
    required String responseFormat,
    required int sampleRate,
    required String languageType,
  }) {
    final event = {
      'type': 'session.update',
      'event_id': _generateEventId(),
      'session': {
        'mode': 'server_commit',
        'voice': voiceId,
        'language_type': languageType,
        'response_format': responseFormat,
        'sample_rate': sampleRate,
      },
    };

    AppLogger.debug('TTS-WS', '发送 session.update', metadata: {
      'voiceId': voiceId,
    });
    socket.add(jsonEncode(event));
  }

  /// 发送文本
  void _sendText(WebSocket socket, String text) {
    final event = {
      'type': 'input_text_buffer.append',
      'event_id': _generateEventId(),
      'text': text,
    };

    AppLogger.debug('TTS-WS', '发送文本', metadata: {
      'textLength': text.length,
    });
    socket.add(jsonEncode(event));
  }

  /// 发送结束信号
  void _sendFinish(WebSocket socket) {
    final event = {
      'type': 'session.finish',
      'event_id': _generateEventId(),
    };

    AppLogger.debug('TTS-WS', '发送 session.finish');
    socket.add(jsonEncode(event));
  }

  /// 生成事件 ID
  String _generateEventId() {
    return 'event_${DateTime.now().millisecondsSinceEpoch}';
  }

  /// 判断模型是否需要使用 WebSocket
  static bool requiresWebSocket(String modelId) {
    final lower = modelId.toLowerCase();
    // qwen3-tts-vc-realtime 和 qwen3-tts-vd-realtime 系列需要 WebSocket
    return lower.contains('realtime') &&
        (lower.contains('vc') || lower.contains('vd'));
  }
}

/// 阿里云 TTS WebSocket 异常
class AliyunTtsWebSocketException implements Exception {
  final String message;

  AliyunTtsWebSocketException(this.message);

  @override
  String toString() => 'AliyunTtsWebSocketException: $message';
}
