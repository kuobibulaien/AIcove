import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../../core/app_logger.dart';
import 'tts_config.dart';

/// TTS 服务：在客户端直接调用第三方 TTS 渠道商
class TtsService {
  final TtsConfig config;

  TtsService(this.config);

  /// 单次文本转换为语音
  ///
  /// - 使用异步任务接口创建 TTS 任务
  /// - 再轮询任务状态，直到拿到最终的音频地址
  Future<TtsConvertResult> convert(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      throw TtsException('TTS 文本不能为空');
    }

    final requestUrl = config.requestUrl.trim();
    if (requestUrl.isEmpty) {
      throw TtsException('TTS API URL 未配置');
    }

    final speechUri = _buildSpeechUri(requestUrl);
    final requestBody = _buildRequestBody(trimmed);
    final headers = _buildHeaders();

    AppLogger.info('TTS', '开始发起 TTS 请求', metadata: {
      'url': speechUri.toString(),
      'textLength': trimmed.length,
    });

    try {
      // 第一步：创建异步 TTS 任务
      final createResp = await http
          .post(
            speechUri,
            headers: headers,
            body: jsonEncode(requestBody),
          )
          .timeout(const Duration(seconds: 10));

      if (createResp.statusCode != 200) {
        AppLogger.error('TTS', '创建 TTS 任务失败', metadata: {
          'status': createResp.statusCode,
          'response': createResp.body,
        });
        throw TtsException(
          '创建 TTS 任务失败: ${createResp.statusCode} - ${createResp.body}',
        );
      }

      final createData = jsonDecode(createResp.body) as Map<String, dynamic>;
      final taskId = createData['task_id'] as String?;
      if (taskId == null || taskId.isEmpty) {
        AppLogger.error('TTS', 'TTS 任务创建成功但未返回 task_id', metadata: {
          'response': createResp.body,
        });
        throw TtsException('创建 TTS 任务失败：未返回 task_id');
      }

      AppLogger.info('TTS', 'TTS 任务创建成功，开始轮询结果', metadata: {
        'taskId': taskId,
      });

      // 第二步：轮询任务结果
      final result = await _waitForTaskResult(
        speechUri: speechUri,
        taskId: taskId,
        timeout: const Duration(seconds: 30),
        retryInterval: const Duration(seconds: 2),
      );

      AppLogger.info('TTS', 'TTS 任务完成，准备解析结果', metadata: {
        'taskId': taskId,
      });

      return _parseResponse(result);
    } on TtsException {
      rethrow;
    } on TimeoutException catch (e) {
      AppLogger.error('TTS', 'TTS 请求超时', metadata: {
        'error': e.toString(),
      });
      throw TtsException('TTS 请求超时，请稍后重试');
    } catch (e) {
      AppLogger.error('TTS', 'TTS 请求异常', metadata: {
        'error': e.toString(),
      });
      throw TtsException('TTS 请求异常: $e');
    }
  }

  /// 根据配置构造真正的异步语音接口地址
  ///
  /// 兼容两种写法：
  /// - 只填基础地址，如：https://ai.gitee.com/v1
  /// - 直接填完整地址，如：https://ai.gitee.com/v1/async/audio/speech
  Uri _buildSpeechUri(String rawUrl) {
    final uri = Uri.parse(rawUrl);
    final path = uri.path;

    const speechPath = '/async/audio/speech';
    if (path.contains(speechPath)) {
      // 已经是完整路径，直接使用
      return uri.replace(query: '');
    }

    String newPath;
    if (path.isEmpty || path == '/') {
      // 只有域名或域名后一个斜杠
      newPath = speechPath;
    } else if (path.endsWith('/')) {
      newPath = '$path${speechPath.substring(1)}';
    } else {
      newPath = '$path$speechPath';
    }

    return uri.replace(path: newPath, query: '');
  }

  /// 批量文本转换为语音
  Future<List<TtsConvertResult>> convertBatch(List<String> texts) async {
    final results = <TtsConvertResult>[];

    for (final text in texts) {
      try {
        final result = await convert(text);
        results.add(result);
      } catch (e) {
        // 单条失败不影响整体结果，记录日志并返回失败条目
        AppLogger.warning('TTS', '单条 TTS 转换失败', metadata: {
          'error': e.toString(),
        });
        results.add(
          TtsConvertResult(
            audioUrl: '',
            text: text,
            success: false,
            error: e.toString(),
          ),
        );
      }
    }

    return results;
  }

  /// 轮询异步任务状态，直到成功或超时
  Future<Map<String, dynamic>> _waitForTaskResult({
    required Uri speechUri,
    required String taskId,
    required Duration timeout,
    required Duration retryInterval,
  }) async {
    final taskUri = _buildTaskUri(speechUri, taskId);
    final deadline = DateTime.now().add(timeout);
    String? lastStatus;

    while (true) {
      if (DateTime.now().isAfter(deadline)) {
        throw TtsException('TTS 任务超时');
      }

      try {
        final resp = await http
            .get(
              taskUri,
              headers: _buildHeaders(),
            )
            .timeout(const Duration(seconds: 5));

        if (resp.statusCode != 200) {
          AppLogger.error('TTS', '查询 TTS 任务失败', metadata: {
            'status': resp.statusCode,
            'response': resp.body,
          });
          throw TtsException(
            '查询 TTS 任务失败: ${resp.statusCode} - ${resp.body}',
          );
        }

        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        final status = (data['status'] as String? ?? 'unknown').toLowerCase();

        if (status == 'success') {
          return data;
        }

        if (status == 'failed' || status == 'error') {
          final message = data['message'] as String? ?? '任务失败';
          throw TtsException('TTS 任务失败: $message');
        }

        if (status != lastStatus) {
          AppLogger.info('TTS', 'TTS 任务状态更新', metadata: {
            'taskId': taskId,
            'status': status,
          });
          lastStatus = status;
        }
      } on TimeoutException {
        AppLogger.warning('TTS', '查询 TTS 任务超时，准备重试', metadata: {
          'taskId': taskId,
        });
      } catch (e) {
        AppLogger.error('TTS', '查询 TTS 任务异常', metadata: {
          'taskId': taskId,
          'error': e.toString(),
        });
        throw TtsException('查询 TTS 任务异常: $e');
      }

      await Future.delayed(retryInterval);
    }
  }

  /// 构造任务查询接口的 URL
  ///
  /// - 如果路径包含 `/async/audio/speech`，则替换为 `/task/{taskId}`
  /// - 否则退化为在原路径后追加 `/task/{taskId}`
  Uri _buildTaskUri(Uri speechUri, String taskId) {
    final path = speechUri.path;
    const marker = '/async/audio/speech';

    String taskPath;
    final index = path.indexOf(marker);

    if (index != -1) {
      final basePath = path.substring(0, index);
      if (basePath.isEmpty) {
        taskPath = '/task/$taskId';
      } else if (basePath.endsWith('/')) {
        taskPath = '${basePath}task/$taskId';
      } else {
        taskPath = '$basePath/task/$taskId';
      }
    } else {
      if (path.endsWith('/')) {
        taskPath = '${path}task/$taskId';
      } else {
        taskPath = '$path/task/$taskId';
      }
    }

    return speechUri.replace(path: taskPath, query: '');
  }

  /// 构建请求体
  ///
  /// 映射到模力方舟的异步 TTS 接口：
  /// - inputs: 要合成的文本
  /// - model: 固定使用 IndexTTS-2
  /// - prompt_audio_url: 克隆音色样本直链（可选）
  /// - prompt_text: 与样本对应的文本（可选）
  /// - emo_text: 不使用，固定空串
  /// - use_emo_text: 固定 false
  Map<String, dynamic> _buildRequestBody(String text) {
    // 仅保留官方示例字段，避免多余参数触发后端类型校验 (KISS/YAGNI)
    final body = <String, dynamic>{
      'inputs': text,
      'model': 'IndexTTS-2',
    };

    final promptAudioUrl = config.promptAudioUrl?.trim();
    if (promptAudioUrl != null && promptAudioUrl.isNotEmpty) {
      body['prompt_audio_url'] = promptAudioUrl;
    }

    final promptText = config.promptText?.trim();
    if (promptText != null && promptText.isNotEmpty) {
      body['prompt_text'] = promptText;
    }

    if (config.speed != null) {
      // 模力方舟 speed 需为整数，向最近的整数取整即可 (S)
      body['speed'] = config.speed!.round();
    }

    return body;
  }

  /// 构建请求头
  Map<String, String> _buildHeaders() {
    final headers = <String, String>{
      'Content-Type': 'application/json',
    };

    final apiKey = config.apiKey?.trim();
    if (apiKey != null && apiKey.isNotEmpty) {
      headers['Authorization'] = 'Bearer $apiKey';
    }

    return headers;
  }

  /// 从接口返回数据中解析出音频地址
  TtsConvertResult _parseResponse(Map<String, dynamic> data) {
    String? audioUrl;

    if (data.containsKey('audio_url')) {
      audioUrl = data['audio_url'] as String?;
    } else if (data.containsKey('url')) {
      audioUrl = data['url'] as String?;
    } else if (data.containsKey('result')) {
      final result = data['result'] as Map<String, dynamic>;
      audioUrl =
          result['audio_url'] as String? ?? result['url'] as String?;
    } else if (data.containsKey('output')) {
      // 模力方舟 IndexTTS-2: { output: { file_url: "..."} }
      final output = data['output'];
      if (output is Map<String, dynamic>) {
        audioUrl = output['file_url'] as String? ??
            output['audio_url'] as String? ??
            output['url'] as String?;
      }
    }

    if (audioUrl == null || audioUrl.isEmpty) {
      throw TtsException('TTS 响应中未找到音频地址');
    }

    return TtsConvertResult(
      audioUrl: audioUrl,
      text: '',
      success: true,
    );
  }
}

/// TTS 转换结果
class TtsConvertResult {
  /// 音频地址
  final String audioUrl;

  /// 原始文本
  final String text;

  /// 是否转换成功
  final bool success;

  /// 错误信息（失败时）
  final String? error;

  TtsConvertResult({
    required this.audioUrl,
    required this.text,
    required this.success,
    this.error,
  });

  Map<String, dynamic> toJson() {
    return {
      'audioUrl': audioUrl,
      'text': text,
      'success': success,
      'error': error,
    };
  }

  factory TtsConvertResult.fromJson(Map<String, dynamic> json) {
    return TtsConvertResult(
      audioUrl: json['audioUrl'] as String,
      text: json['text'] as String,
      success: json['success'] as bool,
      error: json['error'] as String?,
    );
  }
}

/// TTS 相关异常
class TtsException implements Exception {
  final String message;

  TtsException(this.message);

  @override
  String toString() => 'TtsException: $message';
}
