/// MiniMax TTS 服务
///
/// 封装 MiniMax 的 TTS 相关 API：
/// - 上传复刻音频
/// - 上传示例音频（可选）
/// - 快速复刻
/// - 获取音色列表
/// - 删除音色
///
/// 文档：https://platform.minimaxi.com/docs/api-reference/voice-cloning-intro
///
/// 2026-01-31: 创建 MiniMax TTS 服务
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import '../../../core/app_logger.dart';
import '../../../core/utils/mime_utils.dart';

/// MiniMax TTS 服务
class MinimaxTtsService {
  static const String _baseUrl = 'https://api.minimaxi.com/v1';

  final String apiKey;

  MinimaxTtsService({required this.apiKey});

  /// 支持的 TTS 模型列表
  static const List<String> supportedModels = [
    'speech-2.8-hd',
    'speech-2.8-turbo',
    'speech-2.6-hd',
    'speech-2.6-turbo',
    'speech-02-hd',
    'speech-02-turbo',
  ];

  /// 上传复刻音频
  ///
  /// [audioBytes] 音频文件字节数据
  /// [fileName] 文件名（用于确定 MIME 类型）
  ///
  /// 返回 file_id，用于后续调用复刻接口
  Future<int> uploadCloneAudio({
    required Uint8List audioBytes,
    required String fileName,
  }) async {
    final uri = Uri.parse('$_baseUrl/files/upload');

    final request = http.MultipartRequest('POST', uri);
    request.headers['Authorization'] = 'Bearer $apiKey';

    // 添加 purpose 字段
    request.fields['purpose'] = 'voice_clone';

    // 添加文件
    final mimeType = MimeUtils.guessAudioMimeType(fileName);
    request.files.add(http.MultipartFile.fromBytes(
      'file',
      audioBytes,
      filename: fileName,
      contentType: MediaType.parse(mimeType),
    ));

    AppLogger.info('MinimaxTTS', '上传复刻音频', metadata: {
      'fileName': fileName,
      'fileSize': audioBytes.length,
    });

    try {
      final streamedResponse = await request.send().timeout(
            const Duration(seconds: 120),
          );
      final response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode != 200) {
        throw MinimaxTtsException(
          '上传复刻音频失败: ${response.statusCode} - ${response.body}',
        );
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final fileInfo = data['file'] as Map<String, dynamic>?;
      final fileId = fileInfo?['file_id'] as int?;

      if (fileId == null) {
        throw MinimaxTtsException('上传复刻音频失败: 返回的 file_id 为空');
      }

      AppLogger.info('MinimaxTTS', '复刻音频上传成功', metadata: {
        'fileId': fileId,
      });

      return fileId;
    } catch (e) {
      if (e is MinimaxTtsException) rethrow;
      throw MinimaxTtsException('上传复刻音频异常: $e');
    }
  }

  /// 上传示例音频（可选，用于增强复刻效果）
  ///
  /// [audioBytes] 音频文件字节数据（时长 < 8s）
  /// [fileName] 文件名
  ///
  /// 返回 file_id
  Future<int> uploadPromptAudio({
    required Uint8List audioBytes,
    required String fileName,
  }) async {
    final uri = Uri.parse('$_baseUrl/files/upload');

    final request = http.MultipartRequest('POST', uri);
    request.headers['Authorization'] = 'Bearer $apiKey';

    // 示例音频使用不同的 purpose
    request.fields['purpose'] = 'voice_clone_prompt';

    final mimeType = MimeUtils.guessAudioMimeType(fileName);
    request.files.add(http.MultipartFile.fromBytes(
      'file',
      audioBytes,
      filename: fileName,
      contentType: MediaType.parse(mimeType),
    ));

    AppLogger.info('MinimaxTTS', '上传示例音频', metadata: {
      'fileName': fileName,
      'fileSize': audioBytes.length,
    });

    try {
      final streamedResponse = await request.send().timeout(
            const Duration(seconds: 60),
          );
      final response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode != 200) {
        throw MinimaxTtsException(
          '上传示例音频失败: ${response.statusCode} - ${response.body}',
        );
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final fileInfo = data['file'] as Map<String, dynamic>?;
      final fileId = fileInfo?['file_id'] as int?;

      if (fileId == null) {
        throw MinimaxTtsException('上传示例音频失败: 返回的 file_id 为空');
      }

      AppLogger.info('MinimaxTTS', '示例音频上传成功', metadata: {
        'fileId': fileId,
      });

      return fileId;
    } catch (e) {
      if (e is MinimaxTtsException) rethrow;
      throw MinimaxTtsException('上传示例音频异常: $e');
    }
  }

  /// 快速复刻音色
  ///
  /// [fileId] 复刻音频的 file_id
  /// [voiceId] 自定义的音色 ID
  /// [promptAudioFileId] 可选，示例音频的 file_id
  /// [promptText] 可选，示例音频对应的文本
  /// [testText] 可选，试听文本
  /// [model] 可选，试听使用的模型
  ///
  /// 返回复刻结果
  Future<MinimaxVoiceCloneResult> cloneVoice({
    required int fileId,
    required String voiceId,
    int? promptAudioFileId,
    String? promptText,
    String? testText,
    String? model,
    bool needNoiseReduction = false,
    bool needVolumeNormalization = false,
  }) async {
    final uri = Uri.parse('$_baseUrl/voice_clone');

    final body = <String, dynamic>{
      'file_id': fileId,
      'voice_id': voiceId,
      'need_noise_reduction': needNoiseReduction,
      'need_volume_normalization': needVolumeNormalization,
      'aigc_watermark': false,
      'continuous_sound': false,
    };

    // 添加示例音频参数
    if (promptAudioFileId != null) {
      body['clone_prompt'] = {
        'prompt_audio': promptAudioFileId,
        if (promptText != null) 'prompt_text': promptText,
      };
    }

    // 添加试听参数
    if (testText != null && testText.isNotEmpty) {
      body['text'] = testText;
      body['model'] = model ?? 'speech-2.8-hd';
    }

    AppLogger.info('MinimaxTTS', '快速复刻音色', metadata: {
      'fileId': fileId,
      'voiceId': voiceId,
      'hasPromptAudio': promptAudioFileId != null,
      'hasTestText': testText != null,
    });

    try {
      final response = await http
          .post(
            uri,
            headers: {
              'Authorization': 'Bearer $apiKey',
              'Content-Type': 'application/json',
            },
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 120));

      if (response.statusCode != 200) {
        throw MinimaxTtsException(
          '音色复刻失败: ${response.statusCode} - ${response.body}',
        );
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;

      // 检查响应状态
      final baseResp = data['base_resp'] as Map<String, dynamic>?;
      final statusCode = baseResp?['status_code'] as int?;
      if (statusCode != 0) {
        final statusMsg = baseResp?['status_msg'] as String? ?? '未知错误';
        throw MinimaxTtsException('音色复刻失败: $statusMsg');
      }

      final demoAudioUrl = data['demo_audio'] as String?;

      AppLogger.info('MinimaxTTS', '音色复刻成功', metadata: {
        'voiceId': voiceId,
        'hasDemoAudio': demoAudioUrl != null && demoAudioUrl.isNotEmpty,
      });

      return MinimaxVoiceCloneResult(
        voiceId: voiceId,
        demoAudioUrl: demoAudioUrl,
      );
    } catch (e) {
      if (e is MinimaxTtsException) rethrow;
      throw MinimaxTtsException('音色复刻异常: $e');
    }
  }

  /// 获取音色列表
  ///
  /// 返回系统音色和用户复刻的音色
  Future<MinimaxVoiceListResult> getVoiceList() async {
    final uri = Uri.parse('$_baseUrl/get_voice');

    AppLogger.info('MinimaxTTS', '获取音色列表');

    try {
      final response = await http
          .post(
            uri,
            headers: {
              'Authorization': 'Bearer $apiKey',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({'voice_type': 'all'}),
          )
          .timeout(const Duration(seconds: 30));

      if (response.statusCode != 200) {
        throw MinimaxTtsException(
          '获取音色列表失败: ${response.statusCode} - ${response.body}',
        );
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;

      // 检查响应状态
      final baseResp = data['base_resp'] as Map<String, dynamic>?;
      final statusCode = baseResp?['status_code'] as int?;
      if (statusCode != 0) {
        final statusMsg = baseResp?['status_msg'] as String? ?? '未知错误';
        throw MinimaxTtsException('获取音色列表失败: $statusMsg');
      }

      // 解析系统音色
      final systemVoices = <MinimaxVoice>[];
      final systemList = data['system_voice'] as List<dynamic>? ?? [];
      for (final item in systemList) {
        final map = item as Map<String, dynamic>;
        final descList = map['description'] as List<dynamic>?;
        systemVoices.add(MinimaxVoice(
          voiceId: map['voice_id'] as String? ?? '',
          name: map['voice_name'] as String?,
          description: descList?.isNotEmpty == true ? descList!.first as String? : null,
          isSystem: true,
        ));
      }

      // 解析复刻音色
      final clonedVoices = <MinimaxVoice>[];
      final clonedList = data['voice_cloning'] as List<dynamic>? ?? [];
      for (final item in clonedList) {
        final map = item as Map<String, dynamic>;
        clonedVoices.add(MinimaxVoice(
          voiceId: map['voice_id'] as String? ?? '',
          name: map['voice_id'] as String?, // 复刻音色用 voice_id 作为名称
          createdTime: map['created_time'] as String?,
          isSystem: false,
        ));
      }

      AppLogger.info('MinimaxTTS', '获取音色列表成功', metadata: {
        'systemCount': systemVoices.length,
        'clonedCount': clonedVoices.length,
      });

      return MinimaxVoiceListResult(
        systemVoices: systemVoices,
        clonedVoices: clonedVoices,
      );
    } catch (e) {
      if (e is MinimaxTtsException) rethrow;
      throw MinimaxTtsException('获取音色列表异常: $e');
    }
  }

  /// 删除音色
  ///
  /// [voiceId] 要删除的音色 ID
  Future<void> deleteVoice(String voiceId) async {
    final uri = Uri.parse('$_baseUrl/voice/delete');

    AppLogger.info('MinimaxTTS', '删除音色', metadata: {
      'voiceId': voiceId,
    });

    try {
      final response = await http
          .post(
            uri,
            headers: {
              'Authorization': 'Bearer $apiKey',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({'voice_id': voiceId}),
          )
          .timeout(const Duration(seconds: 30));

      if (response.statusCode != 200) {
        throw MinimaxTtsException(
          '删除音色失败: ${response.statusCode} - ${response.body}',
        );
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final baseResp = data['base_resp'] as Map<String, dynamic>?;
      final statusCode = baseResp?['status_code'] as int?;
      if (statusCode != 0) {
        final statusMsg = baseResp?['status_msg'] as String? ?? '未知错误';
        throw MinimaxTtsException('删除音色失败: $statusMsg');
      }

      AppLogger.info('MinimaxTTS', '音色删除成功', metadata: {
        'voiceId': voiceId,
      });
    } catch (e) {
      if (e is MinimaxTtsException) rethrow;
      throw MinimaxTtsException('删除音色异常: $e');
    }
  }

  /// 根据文件名获取 MIME 类型
}

/// MiniMax 用户音色
class MinimaxVoice {
  final String voiceId;
  final String? name;
  final String? description;
  final String? createdTime;
  final bool isSystem;

  const MinimaxVoice({
    required this.voiceId,
    this.name,
    this.description,
    this.createdTime,
    this.isSystem = false,
  });
}

/// 音色列表结果
class MinimaxVoiceListResult {
  final List<MinimaxVoice> systemVoices;
  final List<MinimaxVoice> clonedVoices;

  const MinimaxVoiceListResult({
    this.systemVoices = const [],
    this.clonedVoices = const [],
  });

  List<MinimaxVoice> get allVoices => [...systemVoices, ...clonedVoices];
}

/// 音色复刻结果
class MinimaxVoiceCloneResult {
  final String voiceId;
  final String? demoAudioUrl;

  const MinimaxVoiceCloneResult({
    required this.voiceId,
    this.demoAudioUrl,
  });
}

/// MiniMax TTS 异常
class MinimaxTtsException implements Exception {
  final String message;

  MinimaxTtsException(this.message);

  @override
  String toString() => 'MinimaxTtsException: $message';
}
