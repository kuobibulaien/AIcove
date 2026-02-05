/// 阿里云声音复刻服务
///
/// 支持两种阿里云 TTS 模型的声音复刻：
/// - Qwen-TTS：支持本地文件上传（Base64），音色即时可用
/// - CosyVoice：需要公网 URL，音色需要审核（轮询状态）
///
/// 文档参考：
/// - Qwen-TTS: https://help.aliyun.com/zh/model-studio/qwen-tts-voice-cloning
/// - CosyVoice: https://help.aliyun.com/zh/model-studio/cosyvoice-clone-api
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../../../core/app_logger.dart';

/// 阿里云声音复刻服务
class AliyunVoiceCloneService {
  final String apiKey;

  static const int _maxAudioBytes = 10 * 1024 * 1024; // 10MB（按文档要求）
  static const Set<String> _jsdelivrHosts = {
    'cdn.jsdelivr.net',
    'fastly.jsdelivr.net',
    'gcore.jsdelivr.net',
  };

  /// API 端点（中国内地）
  static const String _baseUrl =
      'https://dashscope.aliyuncs.com/api/v1/services/audio/tts/customization';

  AliyunVoiceCloneService({required this.apiKey});

  void _validatePublicAudioUrl(String audioUrl) {
    final trimmed = audioUrl.trim();
    final uri = Uri.tryParse(trimmed);
    if (uri == null ||
        !uri.isAbsolute ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      throw VoiceCloneException('音频 URL 不合法，请确认是可公网访问的 http(s) 直链: $audioUrl');
    }

    // jsDelivr GitHub 直链: /gh/user/repo@version/file
    if (_jsdelivrHosts.contains(uri.host.toLowerCase()) &&
        uri.pathSegments.isNotEmpty &&
        uri.pathSegments.first == 'gh' &&
        uri.pathSegments.length < 4) {
      throw VoiceCloneException(
        '音频 URL 看起来不是有效的 jsDelivr GitHub 直链（应为 /gh/用户/仓库@版本/文件）: $audioUrl',
      );
    }
  }

  List<Uri> _candidateAudioDownloadUris(String audioUrl) {
    final uri = Uri.parse(audioUrl.trim());
    final host = uri.host.toLowerCase();
    if (!_jsdelivrHosts.contains(host)) return [uri];

    final candidates = <Uri>[uri];
    final seen = <String>{uri.toString()};
    for (final mirrorHost in const [
      'gcore.jsdelivr.net',
      'fastly.jsdelivr.net',
      'cdn.jsdelivr.net'
    ]) {
      if (mirrorHost == host) continue;
      final candidate = uri.replace(host: mirrorHost);
      if (seen.add(candidate.toString())) {
        candidates.add(candidate);
      }
    }
    return candidates;
  }

  Future<_DownloadedAudio> _downloadAudioForEnrollment(
    String audioUrl, {
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final candidates = _candidateAudioDownloadUris(audioUrl);
    VoiceCloneException? lastException;

    for (var i = 0; i < candidates.length; i++) {
      final candidate = candidates[i];
      try {
        return await _downloadAudioOnce(candidate, timeout: timeout);
      } on VoiceCloneException catch (e) {
        lastException = e;
        if (i < candidates.length - 1) {
          AppLogger.warning('AliyunVoiceClone', '下载音频失败，尝试备用地址', metadata: {
            'audioUrl': audioUrl,
            'failedUrl': candidate.toString(),
            'nextUrl': candidates[i + 1].toString(),
            'error': e.toString(),
          });
        }
      }
    }

    throw lastException ?? VoiceCloneException('下载音频失败: $audioUrl');
  }

  Future<_DownloadedAudio> _downloadAudioOnce(
    Uri uri, {
    required Duration timeout,
  }) async {
    final client = http.Client();
    try {
      final request = http.Request('GET', uri);
      final streamed = await client.send(request).timeout(timeout);

      if (streamed.statusCode != 200) {
        final bytes = await streamed.stream
            .toBytes()
            .timeout(const Duration(seconds: 10));
        final bodyPreview = utf8.decode(bytes, allowMalformed: true);
        throw VoiceCloneException(
          '下载音频失败 (${streamed.statusCode}): $bodyPreview',
        );
      }

      final contentLengthHeader = streamed.headers['content-length'];
      final contentLength = int.tryParse(contentLengthHeader ?? '');
      if (contentLength != null && contentLength > _maxAudioBytes) {
        throw VoiceCloneException(
          '音频文件过大（$contentLength 字节），请控制在 10MB 以内',
        );
      }

      final bytes = await _readStreamWithLimit(streamed.stream, _maxAudioBytes)
          .timeout(timeout);
      final mimeType = _normalizeMimeType(streamed.headers['content-type']) ??
          _guessMimeTypeFromUrl(uri.toString());

      AppLogger.info('AliyunVoiceClone', '已下载音频用于声音复刻', metadata: {
        'audioUrl': uri.toString(),
        'bytes': bytes.length,
        'mimeType': mimeType,
      });

      return _DownloadedAudio(bytes: bytes, mimeType: mimeType);
    } finally {
      client.close();
    }
  }

  String _preferAudioUrlForAliyunFetch(String audioUrl) {
    final trimmed = audioUrl.trim();
    final uri = Uri.tryParse(trimmed);
    if (uri == null || !uri.isAbsolute) return trimmed;
    final host = uri.host.toLowerCase();
    if (!_jsdelivrHosts.contains(host)) return trimmed;
    return uri.replace(host: 'gcore.jsdelivr.net').toString();
  }

  Future<Uint8List> _readStreamWithLimit(
    Stream<List<int>> stream,
    int maxBytes,
  ) async {
    final builder = BytesBuilder(copy: false);
    var total = 0;
    await for (final chunk in stream) {
      total += chunk.length;
      if (total > maxBytes) {
        throw VoiceCloneException('音频文件过大，请控制在 10MB 以内');
      }
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  String? _normalizeMimeType(String? contentType) {
    final value = contentType?.trim();
    if (value == null || value.isEmpty) return null;
    final mime = value.split(';').first.trim().toLowerCase();
    if (mime.isEmpty) return null;
    return mime;
  }

  String _guessMimeTypeFromUrl(String audioUrl) {
    final uri = Uri.tryParse(audioUrl);
    final path = uri?.path ?? audioUrl;
    return _getMimeTypeFromPath(path);
  }

  // ========== Qwen-TTS 声音复刻 ==========

  /// 使用本地文件创建 Qwen-TTS 音色（Base64 上传）
  ///
  /// [audioBytes] 音频文件的二进制数据
  /// [mimeType] 音频 MIME 类型（如 audio/mpeg、audio/wav）
  /// [preferredName] 音色名称前缀（仅允许数字、大小写字母和下划线，不超过16个字符）
  /// [targetModel] 驱动音色的语音合成模型，默认 qwen3-tts-vc-realtime-2026-01-15
  /// [promptText] 可选，与音频内容对应的文本
  /// [language] 可选，音频语种（zh/en/de/it/pt/es/ja/ko/fr/ru）
  ///
  /// 返回创建的音色 ID（voice）
  Future<QwenVoiceCreateResult> createQwenVoiceFromBytes({
    required Uint8List audioBytes,
    required String mimeType,
    required String preferredName,
    String targetModel = 'qwen3-tts-vc-realtime-2026-01-15',
    String? promptText,
    String? language,
  }) async {
    // 转换为 Base64 Data URL
    final base64Audio = base64Encode(audioBytes);
    final dataUri = 'data:$mimeType;base64,$base64Audio';

    return _createQwenVoice(
      audioData: dataUri,
      preferredName: preferredName,
      targetModel: targetModel,
      promptText: promptText,
      language: language,
    );
  }

  /// 使用本地文件路径创建 Qwen-TTS 音色
  Future<QwenVoiceCreateResult> createQwenVoiceFromFile({
    required String filePath,
    required String preferredName,
    String targetModel = 'qwen3-tts-vc-realtime-2026-01-15',
    String? promptText,
    String? language,
  }) async {
    final file = File(filePath);
    if (!await file.exists()) {
      throw VoiceCloneException('音频文件不存在: $filePath');
    }

    final bytes = await file.readAsBytes();
    final mimeType = _getMimeTypeFromPath(filePath);

    return createQwenVoiceFromBytes(
      audioBytes: bytes,
      mimeType: mimeType,
      preferredName: preferredName,
      targetModel: targetModel,
      promptText: promptText,
      language: language,
    );
  }

  /// 使用公网 URL 创建 Qwen-TTS 音色
  Future<QwenVoiceCreateResult> createQwenVoiceFromUrl({
    required String audioUrl,
    required String preferredName,
    String targetModel = 'qwen3-tts-vc-realtime-2026-01-15',
    String? promptText,
    String? language,
  }) async {
    _validatePublicAudioUrl(audioUrl);

    // 优先用“客户端下载音频 -> Base64上传”的方式，避免阿里云侧拉取外链超时（500 Response timeout）。
    try {
      final downloaded = await _downloadAudioForEnrollment(audioUrl);
      return createQwenVoiceFromBytes(
        audioBytes: downloaded.bytes,
        mimeType: downloaded.mimeType,
        preferredName: preferredName,
        targetModel: targetModel,
        promptText: promptText,
        language: language,
      );
    } catch (e) {
      AppLogger.warning('AliyunVoiceClone', '下载音频失败，回退为阿里云拉取 URL', metadata: {
        'audioUrl': audioUrl,
        'error': e.toString(),
      });

      return _createQwenVoice(
        audioData: _preferAudioUrlForAliyunFetch(audioUrl),
        preferredName: preferredName,
        targetModel: targetModel,
        promptText: promptText,
        language: language,
      );
    }
  }

  /// 内部方法：创建 Qwen-TTS 音色
  Future<QwenVoiceCreateResult> _createQwenVoice({
    required String audioData,
    required String preferredName,
    required String targetModel,
    String? promptText,
    String? language,
  }) async {
    if (!audioData.startsWith('data:')) {
      _validatePublicAudioUrl(audioData);
    }

    final payload = <String, dynamic>{
      'model': 'qwen-voice-enrollment', // 固定值
      'input': {
        'action': 'create',
        'target_model': targetModel,
        'preferred_name': _sanitizeName(preferredName),
        'audio': {'data': audioData},
        if (promptText != null && promptText.isNotEmpty) 'text': promptText,
        if (language != null && language.isNotEmpty) 'language': language,
      },
    };

    AppLogger.info('AliyunVoiceClone', '创建 Qwen-TTS 音色', metadata: {
      'targetModel': targetModel,
      'preferredName': preferredName,
      'hasPromptText': promptText != null,
      'language': language,
      'audioDataType': audioData.startsWith('data:') ? 'base64' : 'url',
    });

    final response = await _postRequest(
      payload,
      timeout: const Duration(seconds: 120),
    );

    final output = response['output'] as Map<String, dynamic>?;
    if (output == null || !output.containsKey('voice')) {
      throw VoiceCloneException('响应中未找到 voice 字段: $response');
    }

    final voiceId = output['voice'] as String;
    final responseTargetModel = output['target_model'] as String?;

    AppLogger.info('AliyunVoiceClone', 'Qwen-TTS 音色创建成功', metadata: {
      'voiceId': voiceId,
      'targetModel': responseTargetModel,
    });

    return QwenVoiceCreateResult(
      voiceId: voiceId,
      targetModel: responseTargetModel ?? targetModel,
      requestId: response['request_id'] as String?,
    );
  }

  /// 查询 Qwen-TTS 音色列表
  ///
  /// [pageIndex] 页码索引，从 0 开始
  /// [pageSize] 每页数量，默认 10
  ///
  /// 返回音色列表
  Future<List<QwenVoiceInfo>> listQwenVoices({
    int pageIndex = 0,
    int pageSize = 10,
  }) async {
    final payload = <String, dynamic>{
      'model': 'qwen-voice-enrollment',
      'input': {
        'action': 'list',
        'page_index': pageIndex,
        'page_size': pageSize,
      },
    };

    AppLogger.info('AliyunVoiceClone', '查询 Qwen-TTS 音色列表', metadata: {
      'pageIndex': pageIndex,
      'pageSize': pageSize,
    });

    final response = await _postRequest(payload);
    final output = response['output'] as Map<String, dynamic>?;
    final voiceList = output?['voice_list'] as List<dynamic>? ?? [];

    final voices = voiceList.map((item) {
      final voice = item as Map<String, dynamic>;
      return QwenVoiceInfo(
        voiceId: voice['voice'] as String,
        targetModel: voice['target_model'] as String?,
        gmtCreate: voice['gmt_create'] as String?,
      );
    }).toList();

    AppLogger.info('AliyunVoiceClone', 'Qwen-TTS 音色列表查询成功', metadata: {
      'count': voices.length,
    });

    return voices;
  }

  /// 删除 Qwen-TTS 音色
  ///
  /// [voiceId] 要删除的音色 ID
  Future<void> deleteQwenVoice(String voiceId) async {
    final payload = <String, dynamic>{
      'model': 'qwen-voice-enrollment',
      'input': {
        'action': 'delete',
        'voice': voiceId,
      },
    };

    AppLogger.info('AliyunVoiceClone', '删除 Qwen-TTS 音色', metadata: {
      'voiceId': voiceId,
    });

    await _postRequest(payload);

    AppLogger.info('AliyunVoiceClone', 'Qwen-TTS 音色已删除', metadata: {
      'voiceId': voiceId,
    });
  }

  // ========== CosyVoice 声音复刻 ==========

  /// 创建 CosyVoice 音色（需要公网 URL）
  ///
  /// [audioUrl] 公网可访问的音频 URL
  /// [prefix] 音色名称前缀（仅允许数字和小写字母，不超过10个字符）
  /// [targetModel] 驱动音色的语音合成模型，推荐 cosyvoice-v3-plus 或 cosyvoice-v3-flash
  /// [languageHints] 可选，音频语种提示（zh/en/fr/de/ja/ko/ru）
  ///
  /// 返回创建的音色 ID（voice_id），注意需要轮询状态等待审核通过
  Future<CosyVoiceCreateResult> createCosyVoice({
    required String audioUrl,
    required String prefix,
    String targetModel = 'cosyvoice-v3-plus',
    List<String>? languageHints,
  }) async {
    _validatePublicAudioUrl(audioUrl);

    final payload = <String, dynamic>{
      'model': 'voice-enrollment', // 固定值
      'input': {
        'action': 'create_voice',
        'target_model': targetModel,
        'prefix': _sanitizeName(prefix, maxLength: 10, lowercase: true),
        'url': audioUrl,
        if (languageHints != null && languageHints.isNotEmpty)
          'language_hints': languageHints,
      },
    };

    AppLogger.info('AliyunVoiceClone', '创建 CosyVoice 音色', metadata: {
      'targetModel': targetModel,
      'prefix': prefix,
      'audioUrl': audioUrl,
      'languageHints': languageHints,
    });

    final response = await _postRequest(
      payload,
      timeout: const Duration(seconds: 120),
    );

    final output = response['output'] as Map<String, dynamic>?;
    if (output == null || !output.containsKey('voice_id')) {
      throw VoiceCloneException('响应中未找到 voice_id 字段: $response');
    }

    final voiceId = output['voice_id'] as String;

    AppLogger.info('AliyunVoiceClone', 'CosyVoice 音色创建已提交', metadata: {
      'voiceId': voiceId,
      'note': '需要轮询状态等待审核',
    });

    return CosyVoiceCreateResult(
      voiceId: voiceId,
      targetModel: targetModel,
      status: 'DEPLOYING', // 初始状态
      requestId: response['request_id'] as String?,
    );
  }

  /// 查询 CosyVoice 音色状态
  ///
  /// 返回音色详情，包含状态（DEPLOYING/OK/UNDEPLOYED）
  Future<CosyVoiceInfo> queryCosyVoice(String voiceId) async {
    final payload = <String, dynamic>{
      'model': 'voice-enrollment',
      'input': {
        'action': 'query_voice',
        'voice_id': voiceId,
      },
    };

    final response = await _postRequest(payload);
    final output = response['output'] as Map<String, dynamic>?;

    if (output == null) {
      throw VoiceCloneException('响应中未找到 output 字段: $response');
    }

    return CosyVoiceInfo(
      voiceId: voiceId,
      status: output['status'] as String? ?? 'UNKNOWN',
      targetModel: output['target_model'] as String?,
      resourceLink: output['resource_link'] as String?,
      gmtCreate: output['gmt_create'] as String?,
      gmtModified: output['gmt_modified'] as String?,
    );
  }

  /// 轮询等待 CosyVoice 音色就绪
  ///
  /// [voiceId] 音色 ID
  /// [maxAttempts] 最大轮询次数，默认 30
  /// [pollInterval] 轮询间隔，默认 10 秒
  /// [onStatusChange] 状态变化回调
  ///
  /// 返回最终的音色信息，如果超时或失败则抛出异常
  Future<CosyVoiceInfo> waitForCosyVoiceReady(
    String voiceId, {
    int maxAttempts = 30,
    Duration pollInterval = const Duration(seconds: 10),
    void Function(String status, int attempt)? onStatusChange,
  }) async {
    for (int attempt = 1; attempt <= maxAttempts; attempt++) {
      final info = await queryCosyVoice(voiceId);

      onStatusChange?.call(info.status, attempt);

      AppLogger.info('AliyunVoiceClone', 'CosyVoice 状态轮询', metadata: {
        'voiceId': voiceId,
        'status': info.status,
        'attempt': '$attempt/$maxAttempts',
      });

      if (info.status == 'OK') {
        return info;
      }

      if (info.status == 'UNDEPLOYED') {
        throw VoiceCloneException('音色审核未通过，请检查音频质量或联系支持');
      }

      // 继续等待
      if (attempt < maxAttempts) {
        await Future.delayed(pollInterval);
      }
    }

    throw VoiceCloneException('音色创建超时，请稍后重试');
  }

  /// 查询 CosyVoice 音色列表
  Future<List<CosyVoiceInfo>> listCosyVoices({
    String? prefix,
    int pageIndex = 0,
    int pageSize = 10,
  }) async {
    final payload = <String, dynamic>{
      'model': 'voice-enrollment',
      'input': {
        'action': 'list_voice',
        if (prefix != null) 'prefix': prefix,
        'page_index': pageIndex,
        'page_size': pageSize,
      },
    };

    final response = await _postRequest(payload);
    final output = response['output'] as Map<String, dynamic>?;
    final voiceList = output?['voice_list'] as List<dynamic>? ?? [];

    return voiceList.map((item) {
      final voice = item as Map<String, dynamic>;
      return CosyVoiceInfo(
        voiceId: voice['voice_id'] as String,
        status: voice['status'] as String? ?? 'UNKNOWN',
        gmtCreate: voice['gmt_create'] as String?,
        gmtModified: voice['gmt_modified'] as String?,
      );
    }).toList();
  }

  /// 删除 CosyVoice 音色
  Future<void> deleteCosyVoice(String voiceId) async {
    final payload = <String, dynamic>{
      'model': 'voice-enrollment',
      'input': {
        'action': 'delete_voice',
        'voice_id': voiceId,
      },
    };

    await _postRequest(payload);

    AppLogger.info('AliyunVoiceClone', 'CosyVoice 音色已删除', metadata: {
      'voiceId': voiceId,
    });
  }

  // ========== 通用方法 ==========

  /// 发送 POST 请求
  Future<Map<String, dynamic>> _postRequest(
    Map<String, dynamic> payload, {
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final headers = {
      'Authorization': 'Bearer $apiKey',
      'Content-Type': 'application/json',
    };

    try {
      final response = await http
          .post(
            Uri.parse(_baseUrl),
            headers: headers,
            body: jsonEncode(payload),
          )
          .timeout(timeout);

      final data = jsonDecode(response.body) as Map<String, dynamic>;

      if (response.statusCode != 200) {
        final errorMsg = data['message'] ?? data['error'] ?? response.body;
        if (response.statusCode == 500 &&
            errorMsg.toString().toLowerCase().contains('response timeout')) {
          throw VoiceCloneException(
            '请求失败 (500): 阿里云服务端处理超时（Response timeout）。常见原因：阿里云侧无法访问你提供的音频 URL，建议把音频上传到 OSS（北京地域）并使用公网直链。原始错误: $errorMsg',
          );
        }
        throw VoiceCloneException('请求失败 (${response.statusCode}): $errorMsg');
      }

      return data;
    } on TimeoutException {
      throw VoiceCloneException(
        '请求超时（${timeout.inSeconds}s），请检查网络连接/音频链接是否可访问',
      );
    } on http.ClientException catch (e) {
      throw VoiceCloneException('网络错误: $e');
    }
  }

  /// 清理名称（移除非法字符）
  String _sanitizeName(String name,
      {int maxLength = 16, bool lowercase = false}) {
    var sanitized = name.replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '');
    if (lowercase) {
      sanitized = sanitized.toLowerCase();
    }
    if (sanitized.length > maxLength) {
      sanitized = sanitized.substring(0, maxLength);
    }
    if (sanitized.isEmpty) {
      sanitized = 'voice';
    }
    return sanitized;
  }

  /// 根据文件路径获取 MIME 类型
  String _getMimeTypeFromPath(String path) {
    final ext = path.toLowerCase().split('.').last;
    switch (ext) {
      case 'wav':
        return 'audio/wav';
      case 'mp3':
        return 'audio/mpeg';
      case 'm4a':
        return 'audio/mp4';
      case 'ogg':
        return 'audio/ogg';
      default:
        return 'audio/mpeg'; // 默认
    }
  }
}

// ========== 结果类 ==========

/// Qwen-TTS 音色创建结果
class QwenVoiceCreateResult {
  /// 音色 ID（用于语音合成的 voice 参数）
  final String voiceId;

  /// 驱动音色的语音合成模型
  final String targetModel;

  /// 请求 ID
  final String? requestId;

  QwenVoiceCreateResult({
    required this.voiceId,
    required this.targetModel,
    this.requestId,
  });
}

/// Qwen-TTS 音色信息（用于列表查询）
class QwenVoiceInfo {
  /// 音色 ID
  final String voiceId;

  /// 驱动音色的语音合成模型
  final String? targetModel;

  /// 创建时间
  final String? gmtCreate;

  QwenVoiceInfo({
    required this.voiceId,
    this.targetModel,
    this.gmtCreate,
  });
}

class _DownloadedAudio {
  final Uint8List bytes;
  final String mimeType;

  const _DownloadedAudio({
    required this.bytes,
    required this.mimeType,
  });
}

/// CosyVoice 音色创建结果
class CosyVoiceCreateResult {
  /// 音色 ID
  final String voiceId;

  /// 驱动音色的语音合成模型
  final String targetModel;

  /// 音色状态（DEPLOYING/OK/UNDEPLOYED）
  final String status;

  /// 请求 ID
  final String? requestId;

  CosyVoiceCreateResult({
    required this.voiceId,
    required this.targetModel,
    required this.status,
    this.requestId,
  });
}

/// CosyVoice 音色信息
class CosyVoiceInfo {
  /// 音色 ID
  final String voiceId;

  /// 音色状态（DEPLOYING/OK/UNDEPLOYED）
  final String status;

  /// 驱动音色的语音合成模型
  final String? targetModel;

  /// 原始音频 URL
  final String? resourceLink;

  /// 创建时间
  final String? gmtCreate;

  /// 修改时间
  final String? gmtModified;

  CosyVoiceInfo({
    required this.voiceId,
    required this.status,
    this.targetModel,
    this.resourceLink,
    this.gmtCreate,
    this.gmtModified,
  });

  /// 是否可用
  bool get isReady => status == 'OK';

  /// 是否审核中
  bool get isDeploying => status == 'DEPLOYING';

  /// 是否审核失败
  bool get isFailed => status == 'UNDEPLOYED';
}

/// 声音复刻异常
class VoiceCloneException implements Exception {
  final String message;

  VoiceCloneException(this.message);

  @override
  String toString() => 'VoiceCloneException: $message';
}
