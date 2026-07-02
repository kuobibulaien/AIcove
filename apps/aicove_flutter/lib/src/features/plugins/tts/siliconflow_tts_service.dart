import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import '../../../core/app_logger.dart';
import '../../../core/utils/mime_utils.dart';

/// 硅基流动 TTS 服务
///
/// 封装硅基流动的 TTS 相关 API：
/// - 上传音频创建音色
/// - 获取音色列表
/// - 删除音色
/// - 生成语音（由 TtsService 统一处理）
///
/// 文档：https://docs.siliconflow.cn/cn/userguide/capabilities/text-to-speech
class SiliconFlowTtsService {
  static const String _baseUrl = 'https://api.siliconflow.cn/v1';

  final String apiKey;

  SiliconFlowTtsService({required this.apiKey});

  /// 系统预置音色列表
  ///
  /// 格式: 模型名:音色名，如 FunAudioLLM/CosyVoice2-0.5B:alex
  static const List<SiliconFlowPresetVoice> presetVoices = [
    // 男声
    SiliconFlowPresetVoice(
      id: 'alex',
      name: '沉稳男声',
      gender: 'male',
      model: 'FunAudioLLM/CosyVoice2-0.5B',
    ),
    SiliconFlowPresetVoice(
      id: 'benjamin',
      name: '低沉男声',
      gender: 'male',
      model: 'FunAudioLLM/CosyVoice2-0.5B',
    ),
    SiliconFlowPresetVoice(
      id: 'charles',
      name: '磁性男声',
      gender: 'male',
      model: 'FunAudioLLM/CosyVoice2-0.5B',
    ),
    SiliconFlowPresetVoice(
      id: 'david',
      name: '欢快男声',
      gender: 'male',
      model: 'FunAudioLLM/CosyVoice2-0.5B',
    ),
    // 女声
    SiliconFlowPresetVoice(
      id: 'anna',
      name: '沉稳女声',
      gender: 'female',
      model: 'FunAudioLLM/CosyVoice2-0.5B',
    ),
    SiliconFlowPresetVoice(
      id: 'bella',
      name: '激情女声',
      gender: 'female',
      model: 'FunAudioLLM/CosyVoice2-0.5B',
    ),
    SiliconFlowPresetVoice(
      id: 'claire',
      name: '温柔女声',
      gender: 'female',
      model: 'FunAudioLLM/CosyVoice2-0.5B',
    ),
    SiliconFlowPresetVoice(
      id: 'diana',
      name: '欢快女声',
      gender: 'female',
      model: 'FunAudioLLM/CosyVoice2-0.5B',
    ),
  ];

  /// 支持的 TTS 模型列表
  static const List<String> supportedModels = [
    'FunAudioLLM/CosyVoice2-0.5B',
    'IndexTeam/IndexTTS-2',
  ];

  /// 上传音频文件创建用户音色
  ///
  /// [audioBytes] 音频文件字节数据
  /// [fileName] 文件名（用于确定 MIME 类型）
  /// [customName] 自定义音色名称
  /// [text] 参考音频对应的文本内容
  /// [model] 目标模型，默认 IndexTeam/IndexTTS-2
  ///
  /// 返回音色 URI，格式如: speech:your-voice-name:xxx:xxx
  Future<SiliconFlowVoiceUploadResult> uploadVoiceFromBytes({
    required Uint8List audioBytes,
    required String fileName,
    required String customName,
    required String text,
    String model = 'IndexTeam/IndexTTS-2',
  }) async {
    final uri = Uri.parse('$_baseUrl/uploads/audio/voice');

    // 构建 multipart 请求
    final request = http.MultipartRequest('POST', uri);
    request.headers['Authorization'] = 'Bearer $apiKey';

    // 添加文件
    final mimeType = MimeUtils.guessAudioMimeType(fileName);
    request.files.add(http.MultipartFile.fromBytes(
      'file',
      audioBytes,
      filename: fileName,
      contentType: MediaType.parse(mimeType),
    ));

    // 添加表单字段
    request.fields['model'] = model;
    request.fields['customName'] = customName;
    request.fields['text'] = text;

    AppLogger.info('SiliconFlowTTS', '上传音色', metadata: {
      'model': model,
      'customName': customName,
      'textLength': text.length,
      'fileSize': audioBytes.length,
      'fileName': fileName,
    });

    try {
      final streamedResponse = await request.send().timeout(
        const Duration(seconds: 60),
      );
      final response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode != 200) {
        throw SiliconFlowTtsException(
          '上传音色失败: ${response.statusCode} - ${response.body}',
        );
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final voiceUri = data['uri'] as String?;

      if (voiceUri == null || voiceUri.isEmpty) {
        throw SiliconFlowTtsException('上传音色失败: 返回的 URI 为空');
      }

      AppLogger.info('SiliconFlowTTS', '音色上传成功', metadata: {
        'uri': voiceUri,
      });

      return SiliconFlowVoiceUploadResult(
        uri: voiceUri,
        customName: customName,
        model: model,
      );
    } catch (e) {
      if (e is SiliconFlowTtsException) rethrow;
      throw SiliconFlowTtsException('上传音色异常: $e');
    }
  }

  /// 通过 Base64 编码上传音频创建用户音色
  ///
  /// [audioBase64] 音频的 Base64 编码（需要带 data:audio/xxx;base64, 前缀）
  /// [customName] 自定义音色名称
  /// [text] 参考音频对应的文本内容
  /// [model] 目标模型，默认 IndexTeam/IndexTTS-2
  Future<SiliconFlowVoiceUploadResult> uploadVoiceFromBase64({
    required String audioBase64,
    required String customName,
    required String text,
    String model = 'IndexTeam/IndexTTS-2',
  }) async {
    final uri = Uri.parse('$_baseUrl/uploads/audio/voice');

    final body = {
      'model': model,
      'customName': customName,
      'text': text,
      'audio': audioBase64,
    };

    AppLogger.info('SiliconFlowTTS', '上传音色 (Base64)', metadata: {
      'model': model,
      'customName': customName,
      'textLength': text.length,
    });

    try {
      final response = await http.post(
        uri,
        headers: {
          'Authorization': 'Bearer $apiKey',
          'Content-Type': 'application/json',
        },
        body: jsonEncode(body),
      ).timeout(const Duration(seconds: 60));

      if (response.statusCode != 200) {
        throw SiliconFlowTtsException(
          '上传音色失败: ${response.statusCode} - ${response.body}',
        );
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final voiceUri = data['uri'] as String?;

      if (voiceUri == null || voiceUri.isEmpty) {
        throw SiliconFlowTtsException('上传音色失败: 返回的 URI 为空');
      }

      AppLogger.info('SiliconFlowTTS', '音色上传成功', metadata: {
        'uri': voiceUri,
      });

      return SiliconFlowVoiceUploadResult(
        uri: voiceUri,
        customName: customName,
        model: model,
      );
    } catch (e) {
      if (e is SiliconFlowTtsException) rethrow;
      throw SiliconFlowTtsException('上传音色异常: $e');
    }
  }

  /// 获取用户音色列表
  Future<List<SiliconFlowVoice>> getVoiceList() async {
    final uri = Uri.parse('$_baseUrl/audio/voice/list');

    AppLogger.info('SiliconFlowTTS', '获取音色列表');

    try {
      final response = await http.get(
        uri,
        headers: {
          'Authorization': 'Bearer $apiKey',
        },
      ).timeout(const Duration(seconds: 30));

      if (response.statusCode != 200) {
        throw SiliconFlowTtsException(
          '获取音色列表失败: ${response.statusCode} - ${response.body}',
        );
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final results = data['results'] as List<dynamic>? ?? [];

      final voices = results.map((item) {
        final map = item as Map<String, dynamic>;
        return SiliconFlowVoice(
          uri: map['uri'] as String? ?? '',
          customName: map['customName'] as String? ?? '',
          model: map['model'] as String? ?? '',
          text: map['text'] as String?,
        );
      }).toList();

      AppLogger.info('SiliconFlowTTS', '获取音色列表成功', metadata: {
        'count': voices.length,
      });

      return voices;
    } catch (e) {
      if (e is SiliconFlowTtsException) rethrow;
      throw SiliconFlowTtsException('获取音色列表异常: $e');
    }
  }

  /// 删除用户音色
  ///
  /// [voiceUri] 音色 URI，格式如: speech:your-voice-name:xxx:xxx
  Future<void> deleteVoice(String voiceUri) async {
    final uri = Uri.parse('$_baseUrl/audio/voice/deletions');

    AppLogger.info('SiliconFlowTTS', '删除音色', metadata: {
      'uri': voiceUri,
    });

    try {
      final response = await http.post(
        uri,
        headers: {
          'Authorization': 'Bearer $apiKey',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'uri': voiceUri}),
      ).timeout(const Duration(seconds: 30));

      if (response.statusCode != 200) {
        throw SiliconFlowTtsException(
          '删除音色失败: ${response.statusCode} - ${response.body}',
        );
      }

      AppLogger.info('SiliconFlowTTS', '音色删除成功', metadata: {
        'uri': voiceUri,
      });
    } catch (e) {
      if (e is SiliconFlowTtsException) rethrow;
      throw SiliconFlowTtsException('删除音色异常: $e');
    }
  }

  /// 根据文件名获取 MIME 类型
}

/// 硅基流动预置音色
class SiliconFlowPresetVoice {
  final String id;
  final String name;
  final String gender;
  final String model;

  const SiliconFlowPresetVoice({
    required this.id,
    required this.name,
    required this.gender,
    required this.model,
  });

  /// 获取完整的 voice 参数值
  /// 格式: 模型名:音色ID，如 FunAudioLLM/CosyVoice2-0.5B:alex
  String get voiceParam => '$model:$id';
}

/// 硅基流动用户音色
class SiliconFlowVoice {
  final String uri;
  final String customName;
  final String model;
  final String? text;

  const SiliconFlowVoice({
    required this.uri,
    required this.customName,
    required this.model,
    this.text,
  });

  Map<String, dynamic> toJson() => {
        'uri': uri,
        'customName': customName,
        'model': model,
        'text': text,
      };

  factory SiliconFlowVoice.fromJson(Map<String, dynamic> json) {
    return SiliconFlowVoice(
      uri: json['uri'] as String? ?? '',
      customName: json['customName'] as String? ?? '',
      model: json['model'] as String? ?? '',
      text: json['text'] as String?,
    );
  }
}

/// 音色上传结果
class SiliconFlowVoiceUploadResult {
  final String uri;
  final String customName;
  final String model;

  const SiliconFlowVoiceUploadResult({
    required this.uri,
    required this.customName,
    required this.model,
  });
}

/// 硅基流动 TTS 异常
class SiliconFlowTtsException implements Exception {
  final String message;

  SiliconFlowTtsException(this.message);

  @override
  String toString() => 'SiliconFlowTtsException: $message';
}
