import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../../core/app_logger.dart';
import '../../../core/utils/mime_utils.dart';
import 'providers/tts_provider_factory.dart';
import 'aliyun_qwen_tts_websocket.dart';
import 'aliyun_voice_clone_service.dart';
import 'synthesis/minimax_tts_synthesis_adapter.dart';
import 'synthesis/openai_compatible_tts_synthesis_adapter.dart';
import 'synthesis/siliconflow_tts_synthesis_adapter.dart';
import 'synthesis/tts_synthesis_adapter.dart';
import 'tts_config.dart';

/// TTS 服务：在客户端直接调用第三方 TTS 渠道商
///
/// 重构说明：API Key 和 URL 现在作为独立参数传入，
/// 与 TtsConfig 中的业务配置分离。
/// 支持的请求格式：openai_tts、siliconflow_indextts、aliyun_cosyvoice、aliyun_qwen_tts
///
/// 2026-01-25: 添加 model 参数，支持用户选择具体模型
/// 2026-01-26: 阿里云格式支持自动创建音色
/// 2026-01-27: 添加硅基流动 IndexTTS-2 支持
class TtsService {
  static const TtsSynthesisAdapter _openAiCompatibleSynthesisAdapter =
      OpenAiCompatibleTtsSynthesisAdapter();
  static const TtsSynthesisAdapter _siliconFlowSynthesisAdapter =
      SiliconFlowTtsSynthesisAdapter();
  static const TtsSynthesisAdapter _minimaxSynthesisAdapter =
      MinimaxTtsSynthesisAdapter();

  final TtsConfig config;
  final String? apiKey;
  final String requestUrl;
  final String requestFormat; // 请求格式标识
  final String? model; // 用户选择的模型

  /// 音色创建回调，用于保存自动创建的阿里云音色
  final Future<void> Function(VoicePreset updatedPreset)? onVoiceCreated;

  /// 缓存已创建的阿里云音色 ID（避免重复创建）
  static final Map<String, String> _aliyunVoiceCache = {};

  /// 缓存“创建中”的请求，避免同一音色并发重复创建
  static final Map<String, Future<String?>> _aliyunVoiceCreateInFlight = {};

  TtsService({
    required this.config,
    this.apiKey,
    required this.requestUrl,
    this.requestFormat = 'openai_tts',
    this.model,
    this.onVoiceCreated,
  });

  /// 单次文本转换为语音（同步接口）
  ///
  /// 同步接口直接返回音频二进制数据，转换为 Data URL 供播放器使用
  Future<TtsConvertResult> convert(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      throw TtsException('TTS 文本不能为空');
    }

    final url = requestUrl.trim();
    if (url.isEmpty) {
      throw TtsException('TTS API URL 未配置');
    }

    final effectiveFormat = _resolveRequestFormat(url);
    final synthesisContext = _buildSynthesisContext(
      text: trimmed,
      rawUrl: url,
      effectiveFormat: effectiveFormat,
    );
    final synthesisAdapter = _resolveSynthesisAdapter(synthesisContext);

    // 检查是否需要使用 WebSocket（阿里云 Qwen-TTS 声音复刻模型）
    final effectiveModel = model ?? config.model ?? '';
    if (effectiveFormat == 'aliyun_qwen_tts' &&
        AliyunQwenTtsWebSocket.requiresWebSocket(effectiveModel)) {
      return _convertViaWebSocket(trimmed, effectiveModel);
    }

    final speechUri = synthesisAdapter != null
        ? synthesisAdapter.buildSpeechUri(synthesisContext)
        : _buildSpeechUri(url, effectiveFormat);
    final timeout = synthesisAdapter != null
        ? synthesisAdapter.resolveTimeout(synthesisContext)
        : _resolveTimeout(effectiveFormat);
    final requestBody = synthesisAdapter != null
        ? synthesisAdapter.buildRequestBody(synthesisContext)
        : await _buildRequestBodyAsync(trimmed, effectiveFormat);
    final headers = synthesisAdapter != null
        ? synthesisAdapter.buildHeaders(synthesisContext)
        : _buildHeaders();
    final requestBodyJson = jsonEncode(requestBody);
    final sw = Stopwatch()..start();
    String stage = 'waiting_headers';
    int? headersReceivedMs;

    // 详细日志：记录完整请求信息
    AppLogger.info('TTS', '【请求详情】TTS 请求准备发送', metadata: {
      'url': speechUri.toString(),
      'method': 'POST',
      'headers': headers
          .map((k, v) => MapEntry(k, k == 'Authorization' ? 'Bearer ***' : v)),
      'requestFormat': effectiveFormat,
      'configuredRequestFormat': requestFormat,
      if (synthesisContext.providerId != null)
        'resolvedProviderId': synthesisContext.providerId,
      'timeoutSeconds': timeout.inSeconds,
      'selectedVoicePresetId': config.selectedVoicePresetId,
      'selectedVoicePresetName': config.selectedVoicePreset?.name,
      'effectivePromptAudioUrl': config.effectivePromptAudioUrl,
      'effectivePromptText': config.effectivePromptText,
      'requestBody（完整）': requestBody,
      'requestBodyJson': requestBodyJson,
    });

    try {
      final client = http.Client();
      http.Response resp;
      try {
        final req = http.Request('POST', speechUri);
        req.headers.addAll(headers);
        req.body = requestBodyJson;

        final streamed = await client.send(req).timeout(timeout);
        headersReceivedMs = sw.elapsedMilliseconds;
        stage = 'downloading_body';

        final remaining = timeout - Duration(milliseconds: headersReceivedMs);
        if (remaining <= Duration.zero) {
          throw TimeoutException('TTS response body not completed', timeout);
        }

        final bytes = await streamed.stream.toBytes().timeout(remaining);
        sw.stop();

        resp = http.Response.bytes(
          bytes,
          streamed.statusCode,
          headers: streamed.headers,
          request: streamed.request,
          isRedirect: streamed.isRedirect,
          persistentConnection: streamed.persistentConnection,
          reasonPhrase: streamed.reasonPhrase,
        );
      } finally {
        client.close();
      }

      // 详细日志：记录响应信息
      final contentType = resp.headers['content-type'] ?? '';
      final isAudio = contentType.contains('audio/') ||
          contentType.contains('application/octet-stream');

      AppLogger.info('TTS', '【响应详情】TTS 收到响应', metadata: {
        'statusCode': resp.statusCode,
        'contentType': contentType,
        'isAudioResponse': isAudio,
        'responseBodyLength': resp.bodyBytes.length,
        'elapsedMs': sw.elapsedMilliseconds,
        'headersReceivedMs': headersReceivedMs,
        'responseBody（非音频时）': isAudio ? '(音频数据，已省略)' : resp.body,
      });

      if (resp.statusCode != 200) {
        throw TtsException(
          'TTS 请求失败: ${resp.statusCode} - ${resp.body}',
        );
      }

      // 如果是音频数据，转换为 Data URL
      if (isAudio) {
        final audioBytes = resp.bodyBytes;
        if (audioBytes.isEmpty) {
          throw TtsException('TTS 返回的音频数据为空');
        }

        final mimeType =
            MimeUtils.resolveAudioMimeType(contentType, audioBytes);

        // 转换为 Data URL
        final base64Audio = base64Encode(audioBytes);
        final dataUrl = 'data:$mimeType;base64,$base64Audio';

        AppLogger.info('TTS', 'TTS 音频生成成功', metadata: {
          'audioSize': audioBytes.length,
          'mimeType': mimeType,
          'responseContentType': contentType,
        });

        return TtsConvertResult(
          audioUrl: dataUrl,
          text: trimmed,
          success: true,
        );
      }

      // 如果是 JSON 响应，按原来的方式解析
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      return _parseResponse(data);
    } on TtsException {
      rethrow;
    } on TimeoutException catch (e) {
      sw.stop();
      AppLogger.error('TTS', 'TTS 请求超时', metadata: {
        'error': e.toString(),
        'stage': stage,
        if (headersReceivedMs != null) 'headersReceivedMs': headersReceivedMs,
        'elapsedMs': sw.elapsedMilliseconds,
      });
      throw TtsException('TTS 请求超时，请稍后重试');
    } catch (e) {
      sw.stop();
      AppLogger.error('TTS', 'TTS 请求异常', metadata: {
        'error': e.toString(),
        'elapsedMs': sw.elapsedMilliseconds,
      });
      throw TtsException('TTS 请求异常: $e');
    }
  }

  /// 通过 WebSocket 进行语音合成（用于阿里云 Qwen-TTS 声音复刻模型）
  ///
  /// qwen3-tts-vc-realtime 系列模型只支持 WebSocket 接口
  Future<TtsConvertResult> _convertViaWebSocket(
    String text,
    String targetModel,
  ) async {
    if (apiKey == null || apiKey!.isEmpty) {
      throw TtsException('WebSocket TTS 需要配置 API Key');
    }

    final preset = config.selectedVoicePreset;
    String? voiceId;

    // 检查是否已有匹配当前模型的音色ID
    if (preset?.aliyunVoiceId != null && preset!.aliyunVoiceId!.isNotEmpty) {
      // 检查模型是否匹配（音色ID必须与创建时的模型一致）
      if (_isAliyunVoiceModelMatch(preset.aliyunTargetModel, targetModel)) {
        voiceId = preset.aliyunVoiceId;
        AppLogger.info('TTS', '使用已保存的阿里云音色ID', metadata: {
          'voiceId': voiceId,
          'savedModel': preset.aliyunTargetModel,
          'targetModel': targetModel,
        });
      } else {
        AppLogger.warning('TTS', '已保存的音色ID与当前模型不匹配，需要重新创建', metadata: {
          'savedVoiceId': preset.aliyunVoiceId,
          'savedModel': preset.aliyunTargetModel,
          'targetModel': targetModel,
        });
      }
    }

    // 如果没有可用的 voiceId，尝试自动创建
    if (voiceId == null || voiceId.isEmpty) {
      // 优先使用本地文件
      final localPath = preset?.localAudioPath;
      if (localPath != null && localPath.isNotEmpty) {
        voiceId = await _getOrCreateAliyunVoiceFromLocal(
          preset: preset,
          localPath: localPath,
          targetModel: targetModel,
        );
      } else {
        // 其次使用公网 URL
        final audioUrl =
            preset?.promptAudioUrl ?? config.effectivePromptAudioUrl;
        if (audioUrl != null && audioUrl.isNotEmpty) {
          voiceId = await _getOrCreateAliyunVoice(
            preset: preset,
            audioUrl: audioUrl,
            targetModel: targetModel,
            isCosyVoice: false,
          );
        }
      }
    }

    if (voiceId == null || voiceId.isEmpty) {
      throw TtsException('WebSocket TTS 需要配置音色，请在音色管理中添加音色并确保已创建音色 ID');
    }

    AppLogger.info('TTS', '使用 WebSocket 进行语音合成', metadata: {
      'model': targetModel,
      'voiceId': voiceId,
      'textLength': text.length,
    });

    try {
      final wsService = AliyunQwenTtsWebSocket(
        apiKey: apiKey!,
        model: targetModel,
      );

      // realtime 模型只支持 pcm 格式
      final pcmBytes = await wsService.synthesize(
        text: text,
        voiceId: voiceId,
        responseFormat: 'pcm',
        sampleRate: 24000,
        languageType: 'Chinese',
      );

      if (pcmBytes.isEmpty) {
        throw TtsException('WebSocket TTS 返回的音频数据为空');
      }

      // 将 PCM 转换为 WAV（添加 WAV 头）
      final wavBytes = _pcmToWav(pcmBytes,
          sampleRate: 24000, channels: 1, bitsPerSample: 16);

      // 转换为 Data URL
      final base64Audio = base64Encode(wavBytes);
      final dataUrl = 'data:audio/wav;base64,$base64Audio';

      AppLogger.info('TTS', 'WebSocket TTS 音频生成成功', metadata: {
        'pcmSize': pcmBytes.length,
        'wavSize': wavBytes.length,
      });

      return TtsConvertResult(
        audioUrl: dataUrl,
        text: text,
        success: true,
      );
    } on AliyunTtsWebSocketException catch (e) {
      throw TtsException('WebSocket TTS 失败: ${e.message}');
    }
  }

  /// 将 PCM 数据转换为 WAV 格式（添加 WAV 头）
  List<int> _pcmToWav(
    List<int> pcmData, {
    required int sampleRate,
    required int channels,
    required int bitsPerSample,
  }) {
    final byteRate = sampleRate * channels * bitsPerSample ~/ 8;
    final blockAlign = channels * bitsPerSample ~/ 8;
    final dataSize = pcmData.length;
    final fileSize = 36 + dataSize;

    final header = <int>[
      // RIFF header
      0x52, 0x49, 0x46, 0x46, // "RIFF"
      fileSize & 0xff, (fileSize >> 8) & 0xff, (fileSize >> 16) & 0xff,
      (fileSize >> 24) & 0xff,
      0x57, 0x41, 0x56, 0x45, // "WAVE"
      // fmt subchunk
      0x66, 0x6d, 0x74, 0x20, // "fmt "
      16, 0, 0, 0, // Subchunk1Size (16 for PCM)
      1, 0, // AudioFormat (1 for PCM)
      channels & 0xff, (channels >> 8) & 0xff,
      sampleRate & 0xff, (sampleRate >> 8) & 0xff, (sampleRate >> 16) & 0xff,
      (sampleRate >> 24) & 0xff,
      byteRate & 0xff, (byteRate >> 8) & 0xff, (byteRate >> 16) & 0xff,
      (byteRate >> 24) & 0xff,
      blockAlign & 0xff, (blockAlign >> 8) & 0xff,
      bitsPerSample & 0xff, (bitsPerSample >> 8) & 0xff,
      // data subchunk
      0x64, 0x61, 0x74, 0x61, // "data"
      dataSize & 0xff, (dataSize >> 8) & 0xff, (dataSize >> 16) & 0xff,
      (dataSize >> 24) & 0xff,
    ];

    return [...header, ...pcmData];
  }

  Duration _resolveTimeout(String effectiveFormat) {
    switch (effectiveFormat) {
      case 'siliconflow_indextts':
        return const Duration(seconds: 30);
      case 'aliyun_cosyvoice':
      case 'aliyun_qwen_tts':
        return const Duration(seconds: 60); // 阿里云可能需要更长时间
      default:
        return const Duration(seconds: 30);
    }
  }

  /// 根据配置构造同步语音接口地址
  ///
  /// 兼容多种写法：
  /// - 只填基础地址（会自动补齐语音端点）
  /// - 直接填完整语音地址（保留原路径）
  /// - 阿里云使用专用端点
  /// - 硅基流动使用 /audio/speech 端点
  Uri _buildSpeechUri(String rawUrl, String effectiveFormat) {
    final uri = Uri.parse(rawUrl);
    final path = uri.path;

    // 阿里云 Qwen-TTS 使用 multimodal-generation 端点
    if (effectiveFormat == 'aliyun_qwen_tts') {
      const qwenTtsPath =
          '/api/v1/services/aigc/multimodal-generation/generation';
      if (path.contains('multimodal-generation')) {
        return uri.replace(query: null);
      }
      // 构建阿里云 Qwen-TTS 端点
      return Uri.parse('https://dashscope.aliyuncs.com$qwenTtsPath');
    }

    // 阿里云 CosyVoice 使用 text2audio 端点（非流式）
    if (effectiveFormat == 'aliyun_cosyvoice') {
      const cosyVoicePath = '/api/v1/services/aigc/text2audio/generation';
      if (path.contains('text2audio')) {
        return uri.replace(query: null);
      }
      // 构建阿里云 CosyVoice 端点
      return Uri.parse('https://dashscope.aliyuncs.com$cosyVoicePath');
    }

    // 硅基流动使用标准 /audio/speech 端点
    // OpenAI 兼容格式也使用 /audio/speech
    const speechPath = '/audio/speech';
    if (path.contains(speechPath)) {
      // 已经是完整路径，直接使用
      return uri.replace(query: null);
    }

    String newPath;
    if (path.isEmpty || path == '/') {
      newPath = speechPath;
    } else if (path.endsWith('/')) {
      newPath = '$path${speechPath.substring(1)}';
    } else {
      newPath = '$path$speechPath';
    }

    return uri.replace(path: newPath, query: null);
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

  String _resolveRequestFormat(String rawUrl) {
    final configured = requestFormat.trim();
    if (configured.isNotEmpty && configured != 'openai_tts') {
      return configured;
    }

    if (_looksLikeSiliconFlow(rawUrl)) {
      return 'siliconflow_indextts';
    }

    if (_looksLikeAliyunDashscope(rawUrl)) {
      // 根据模型名称判断是 CosyVoice 还是 Qwen-TTS
      final effectiveModel = model ?? config.model ?? '';
      if (effectiveModel.contains('cosyvoice')) {
        return 'aliyun_cosyvoice';
      } else if (effectiveModel.contains('qwen')) {
        return 'aliyun_qwen_tts';
      }
      // 默认使用 CosyVoice
      return 'aliyun_cosyvoice';
    }

    return configured.isEmpty ? 'openai_tts' : configured;
  }

  bool _looksLikeSiliconFlow(String rawUrl) {
    final lower = rawUrl.toLowerCase();
    if (lower.contains('siliconflow.cn') || lower.contains('siliconflow.com')) {
      return true;
    }
    try {
      final uri = Uri.parse(rawUrl);
      final host = uri.host.toLowerCase();
      return host.contains('siliconflow');
    } catch (_) {
      return false;
    }
  }

  bool _looksLikeAliyunDashscope(String rawUrl) {
    final lower = rawUrl.toLowerCase();
    if (lower.contains('dashscope.aliyuncs.com')) return true;
    try {
      final uri = Uri.parse(rawUrl);
      return uri.host.toLowerCase().contains('dashscope');
    } catch (_) {
      return false;
    }
  }

  TtsSynthesisContext _buildSynthesisContext({
    required String text,
    required String rawUrl,
    required String effectiveFormat,
  }) {
    final resolution = TtsProviderFactory.resolve(
      providerId: config.selectedProviderId,
      apiUrl: rawUrl,
      requestFormat: effectiveFormat,
    );

    return TtsSynthesisContext(
      config: config,
      text: text,
      rawUrl: rawUrl,
      providerId: resolution.voiceProvider?.providerId,
      requestFormat: effectiveFormat,
      model: model,
      apiKey: apiKey,
    );
  }

  TtsSynthesisAdapter? _resolveSynthesisAdapter(TtsSynthesisContext context) {
    final normalizedProviderId =
        TtsSynthesisAdapter.normalizeIdentifier(context.providerId);
    if (normalizedProviderId == _minimaxSynthesisAdapter.providerId) {
      return _minimaxSynthesisAdapter;
    }

    if (_siliconFlowSynthesisAdapter.supports(context)) {
      return _siliconFlowSynthesisAdapter;
    }

    if (_openAiCompatibleSynthesisAdapter.supports(context)) {
      return _openAiCompatibleSynthesisAdapter;
    }

    return null;
  }

  /// 构建请求体（根据 requestFormat 选择不同格式）
  /// 阿里云格式需要异步处理（可能需要自动创建音色）
  Future<Map<String, dynamic>> _buildRequestBodyAsync(
      String text, String effectiveFormat) async {
    switch (effectiveFormat) {
      case 'openai_tts':
        return _buildOpenAiTtsBody(text);
      case 'siliconflow_indextts':
        return _buildSiliconFlowIndexTtsBody(text);
      case 'aliyun_cosyvoice':
        return await _buildAliyunCosyVoiceBodyAsync(text);
      case 'aliyun_qwen_tts':
        return await _buildAliyunQwenTtsBodyAsync(text);
      default:
        return _buildOpenAiTtsBody(text);
    }
  }

  /// OpenAI TTS 格式: {model, input, voice, speed}
  Map<String, dynamic> _buildOpenAiTtsBody(String text) {
    final body = <String, dynamic>{
      'model': model ?? config.model ?? 'tts-1', // 优先使用用户选择的模型
      'input': text,
      'voice': config.voice ?? 'alloy',
    };
    if (config.speed != null && config.speed != 1.0) {
      body['speed'] = config.speed;
    }
    return body;
  }

  /// 硅基流动 IndexTTS-2 格式
  /// 文档: https://docs.siliconflow.cn/cn/userguide/capabilities/text-to-speech
  ///
  /// 支持两种音色方式：
  /// 1. 系统预置音色: voice 参数为 "模型名:音色ID"，如 FunAudioLLM/CosyVoice2-0.5B:alex
  /// 2. 用户预置音色: voice 参数为上传后返回的 URI，如 speech:xxx:xxx
  /// 3. 动态音色: voice 为空，通过 references 传入参考音频（实时克隆）
  Map<String, dynamic> _buildSiliconFlowIndexTtsBody(String text) {
    final effectiveModel = model ?? config.model ?? 'IndexTeam/IndexTTS-2';
    final preset = config.selectedVoicePreset;

    final body = <String, dynamic>{
      'model': effectiveModel,
      'input': text,
      'response_format': 'mp3',
    };

    // 添加可选参数
    if (config.speed != null && config.speed != 1.0) {
      body['speed'] = config.speed;
    }

    // 判断使用哪种音色方式
    final siliconFlowVoiceUri = preset?.siliconFlowVoiceUri;
    final configVoice = config.voice;

    // 1. 优先使用音色预设中的硅基流动 URI（用户上传的音色）
    if (siliconFlowVoiceUri != null && siliconFlowVoiceUri.isNotEmpty) {
      body['voice'] = siliconFlowVoiceUri;
      return body;
    }

    // 2. 使用配置的 voice（可能是系统预置音色 ID 或完整的 voice 参数）
    if (configVoice != null && configVoice.isNotEmpty) {
      // 如果 voice 已经包含冒号（如 FunAudioLLM/CosyVoice2-0.5B:alex），直接使用
      // 如果只是简单的音色 ID（如 alex），则拼接模型名
      if (configVoice.contains(':') || configVoice.startsWith('speech:')) {
        body['voice'] = configVoice;
      } else {
        // 拼接模型名和音色 ID
        body['voice'] = '$effectiveModel:$configVoice';
      }
      return body;
    }

    // 3. 使用动态音色（通过 references 传入参考音频）
    final promptAudioUrl = config.effectivePromptAudioUrl?.trim();
    final promptText = config.effectivePromptText?.trim();

    if (promptAudioUrl != null && promptAudioUrl.isNotEmpty) {
      // 使用动态音色模式
      body['voice'] = ''; // 传入空值表示使用动态音色
      body['references'] = [
        {
          'audio': promptAudioUrl,
          if (promptText != null && promptText.isNotEmpty) 'text': promptText,
        }
      ];
    } else {
      // 没有配置任何音色，使用默认的系统预置音色
      body['voice'] = 'FunAudioLLM/CosyVoice2-0.5B:alex';
    }

    return body;
  }

  /// 阿里云 CosyVoice 格式
  /// 文档: https://help.aliyun.com/zh/model-studio/cosyvoice-tts-api
  ///
  /// 如果音色有公网 URL 但没有 aliyunVoiceId，会自动创建音色
  Future<Map<String, dynamic>> _buildAliyunCosyVoiceBodyAsync(
      String text) async {
    final preset = config.selectedVoicePreset;
    final targetModel = model ?? config.model ?? 'cosyvoice-v3-plus';
    String? voiceId;

    // 调试日志：检查当前音色预设的状态
    AppLogger.debug('TTS', 'CosyVoice 音色预设检查', metadata: {
      'presetId': preset?.id,
      'presetName': preset?.name,
      'aliyunVoiceId': preset?.aliyunVoiceId,
      'aliyunTargetModel': preset?.aliyunTargetModel,
      'aliyunVoiceStatus': preset?.aliyunVoiceStatus,
      'targetModel': targetModel,
    });

    // 检查是否已有匹配当前模型的音色ID
    if (preset?.aliyunVoiceId != null && preset!.aliyunVoiceId!.isNotEmpty) {
      if (_isAliyunVoiceModelMatch(preset.aliyunTargetModel, targetModel)) {
        // CosyVoice 还需要检查状态是否为 OK
        if (preset.aliyunVoiceStatus == 'OK') {
          voiceId = preset.aliyunVoiceId;
          AppLogger.info('TTS', '使用已保存的阿里云音色ID (CosyVoice)', metadata: {
            'voiceId': voiceId,
            'savedModel': preset.aliyunTargetModel,
            'targetModel': targetModel,
          });
        } else {
          AppLogger.warning('TTS', 'CosyVoice 音色状态不是 OK，无法使用', metadata: {
            'savedVoiceId': preset.aliyunVoiceId,
            'status': preset.aliyunVoiceStatus,
          });
        }
      } else {
        AppLogger.warning('TTS', '已保存的音色ID与当前模型不匹配，需要重新创建 (CosyVoice)',
            metadata: {
              'savedVoiceId': preset.aliyunVoiceId,
              'savedModel': preset.aliyunTargetModel,
              'targetModel': targetModel,
            });
      }
    }

    // 如果没有可用的 voiceId，尝试自动创建
    if (voiceId == null || voiceId.isEmpty) {
      final audioUrl = preset?.promptAudioUrl ?? config.effectivePromptAudioUrl;
      if (audioUrl != null && audioUrl.isNotEmpty && apiKey != null) {
        voiceId = await _getOrCreateAliyunVoice(
          preset: preset,
          audioUrl: audioUrl,
          targetModel: targetModel,
          isCosyVoice: true,
        );
      }
    }

    if (voiceId == null || voiceId.isEmpty) {
      throw TtsException('CosyVoice 需要配置音色，请在音色管理中添加音色');
    }

    return {
      'model': targetModel,
      'input': {
        'text': text,
      },
      'parameters': {
        'voice': voiceId,
        if (config.speed != null) 'rate': config.speed,
      },
    };
  }

  /// 阿里云 Qwen-TTS 格式（实时语音合成）
  /// 文档: https://help.aliyun.com/zh/model-studio/qwen-tts-api
  ///
  /// 如果音色有公网 URL 或本地文件但没有 aliyunVoiceId，会自动创建音色
  Future<Map<String, dynamic>> _buildAliyunQwenTtsBodyAsync(String text) async {
    final preset = config.selectedVoicePreset;
    final targetModel = model ?? config.model ?? 'qwen3-tts-flash';
    String? voiceId;

    // 调试日志：检查当前音色预设的状态
    AppLogger.debug('TTS', 'Qwen-TTS 音色预设检查', metadata: {
      'presetId': preset?.id,
      'presetName': preset?.name,
      'aliyunVoiceId': preset?.aliyunVoiceId,
      'aliyunTargetModel': preset?.aliyunTargetModel,
      'targetModel': targetModel,
    });

    // 检查是否已有匹配当前模型的音色ID
    if (preset?.aliyunVoiceId != null && preset!.aliyunVoiceId!.isNotEmpty) {
      if (_isAliyunVoiceModelMatch(preset.aliyunTargetModel, targetModel)) {
        voiceId = preset.aliyunVoiceId;
        AppLogger.info('TTS', '使用已保存的阿里云音色ID (Qwen-TTS)', metadata: {
          'voiceId': voiceId,
          'savedModel': preset.aliyunTargetModel,
          'targetModel': targetModel,
        });
      } else {
        AppLogger.warning('TTS', '已保存的音色ID与当前模型不匹配，需要重新创建 (Qwen-TTS)',
            metadata: {
              'savedVoiceId': preset.aliyunVoiceId,
              'savedModel': preset.aliyunTargetModel,
              'targetModel': targetModel,
            });
      }
    }

    // 如果没有可用的 voiceId，尝试自动创建
    if (voiceId == null || voiceId.isEmpty) {
      if (apiKey != null) {
        // 优先使用本地文件（Qwen-TTS 支持本地文件上传）
        final localPath = preset?.localAudioPath;
        if (localPath != null && localPath.isNotEmpty) {
          voiceId = await _getOrCreateAliyunVoiceFromLocal(
            preset: preset,
            localPath: localPath,
            targetModel: targetModel,
          );
        } else {
          // 其次使用公网 URL
          final audioUrl =
              preset?.promptAudioUrl ?? config.effectivePromptAudioUrl;
          if (audioUrl != null && audioUrl.isNotEmpty) {
            voiceId = await _getOrCreateAliyunVoice(
              preset: preset,
              audioUrl: audioUrl,
              targetModel: targetModel,
              isCosyVoice: false,
            );
          }
        }
      }
    }

    if (voiceId == null || voiceId.isEmpty) {
      throw TtsException('Qwen-TTS 需要配置音色，请在音色管理中添加音色');
    }

    // Qwen-TTS 请求格式：input 包含 text、voice、language_type
    return {
      'model': targetModel,
      'input': {
        'text': text,
        'voice': voiceId,
        'language_type': 'Chinese', // 默认中文
      },
    };
  }

  /// 获取或创建阿里云音色
  Future<String?> _getOrCreateAliyunVoice({
    required VoicePreset? preset,
    required String audioUrl,
    required String targetModel,
    required bool isCosyVoice,
  }) async {
    // 生成缓存 key：音频URL + 目标模型
    final cacheKey = '${audioUrl}_$targetModel';

    // 检查缓存
    if (_aliyunVoiceCache.containsKey(cacheKey)) {
      AppLogger.info('TTS', '使用缓存的阿里云音色', metadata: {
        'cacheKey': cacheKey,
        'voiceId': _aliyunVoiceCache[cacheKey],
      });
      return _aliyunVoiceCache[cacheKey];
    }

    // 并发去重：同一份音色（audioUrl + targetModel）同一时刻只创建一次
    final inFlight = _aliyunVoiceCreateInFlight[cacheKey];
    if (inFlight != null) {
      AppLogger.info('TTS', '等待进行中的阿里云音色创建', metadata: {
        'cacheKey': cacheKey,
        'audioUrl': audioUrl,
        'targetModel': targetModel,
        'isCosyVoice': isCosyVoice,
      });
      return await inFlight;
    }

    final completer = Completer<String?>();
    _aliyunVoiceCreateInFlight[cacheKey] = completer.future;

    // 创建新音色
    AppLogger.info('TTS', '自动创建阿里云音色', metadata: {
      'audioUrl': audioUrl,
      'targetModel': targetModel,
      'isCosyVoice': isCosyVoice,
    });

    try {
      final service = AliyunVoiceCloneService(apiKey: apiKey!);
      String voiceId;

      if (isCosyVoice) {
        final result = await service.createCosyVoice(
          audioUrl: audioUrl,
          prefix: _sanitizeVoiceName(preset?.name ?? 'voice'),
          targetModel: targetModel,
        );
        voiceId = result.voiceId;

        // CosyVoice 需要等待审核，这里先返回 ID，后续请求可能会失败
        AppLogger.info('TTS', 'CosyVoice 音色已创建，等待审核', metadata: {
          'voiceId': voiceId,
          'status': result.status,
        });
      } else {
        final result = await service.createQwenVoiceFromUrl(
          audioUrl: audioUrl,
          preferredName: _sanitizeVoiceName(preset?.name ?? 'voice'),
          targetModel: targetModel,
          promptText: preset?.promptText,
        );
        voiceId = result.voiceId;

        AppLogger.info('TTS', 'Qwen-TTS 音色创建成功', metadata: {
          'voiceId': voiceId,
        });
      }

      // 缓存音色 ID
      _aliyunVoiceCache[cacheKey] = voiceId;

      // 回调保存音色（如果有）
      AppLogger.info('TTS', '准备保存音色ID到预设', metadata: {
        'voiceId': voiceId,
        'presetId': preset?.id,
        'presetName': preset?.name,
        'hasOnVoiceCreated': onVoiceCreated != null,
      });

      if (onVoiceCreated != null && preset != null) {
        final updatedPreset = preset.copyWith(
          aliyunVoiceId: voiceId,
          aliyunTargetModel: targetModel,
          aliyunVoiceStatus: isCosyVoice ? 'DEPLOYING' : 'OK',
        );
        AppLogger.info('TTS', '调用 onVoiceCreated 回调', metadata: {
          'presetId': updatedPreset.id,
          'aliyunVoiceId': updatedPreset.aliyunVoiceId,
        });
        await onVoiceCreated!(updatedPreset);
      } else {
        AppLogger.warning('TTS', '无法保存音色ID：preset 或 onVoiceCreated 为空',
            metadata: {
              'presetIsNull': preset == null,
              'onVoiceCreatedIsNull': onVoiceCreated == null,
            });
      }

      if (!completer.isCompleted) completer.complete(voiceId);
      return voiceId;
    } catch (e, st) {
      AppLogger.warning('TTS', '自动创建阿里云音色失败', metadata: {
        'error': e.toString(),
      });
      final ex = TtsException('自动创建阿里云音色失败: $e');
      if (!completer.isCompleted) completer.completeError(ex, st);
      throw ex;
    } finally {
      _aliyunVoiceCreateInFlight.remove(cacheKey);
    }
  }

  /// 从本地文件创建阿里云音色（仅 Qwen-TTS 支持）
  Future<String?> _getOrCreateAliyunVoiceFromLocal({
    required VoicePreset? preset,
    required String localPath,
    required String targetModel,
  }) async {
    // 生成缓存 key：本地文件路径 + 目标模型
    final cacheKey = 'local_${localPath}_$targetModel';

    // 检查缓存
    if (_aliyunVoiceCache.containsKey(cacheKey)) {
      AppLogger.info('TTS', '使用缓存的阿里云音色（本地文件）', metadata: {
        'cacheKey': cacheKey,
        'voiceId': _aliyunVoiceCache[cacheKey],
      });
      return _aliyunVoiceCache[cacheKey];
    }

    // 并发去重
    final inFlight = _aliyunVoiceCreateInFlight[cacheKey];
    if (inFlight != null) {
      AppLogger.info('TTS', '等待进行中的阿里云音色创建（本地文件）', metadata: {
        'cacheKey': cacheKey,
      });
      return await inFlight;
    }

    final completer = Completer<String?>();
    _aliyunVoiceCreateInFlight[cacheKey] = completer.future;

    AppLogger.info('TTS', '从本地文件自动创建阿里云音色', metadata: {
      'localPath': localPath,
      'targetModel': targetModel,
    });

    try {
      final service = AliyunVoiceCloneService(apiKey: apiKey!);
      final result = await service.createQwenVoiceFromFile(
        filePath: localPath,
        preferredName: _sanitizeVoiceName(preset?.name ?? 'voice'),
        targetModel: targetModel,
        promptText: preset?.promptText,
      );

      final voiceId = result.voiceId;

      AppLogger.info('TTS', 'Qwen-TTS 音色创建成功（本地文件）', metadata: {
        'voiceId': voiceId,
      });

      // 缓存音色 ID
      _aliyunVoiceCache[cacheKey] = voiceId;

      // 回调保存音色
      if (onVoiceCreated != null && preset != null) {
        final updatedPreset = preset.copyWith(
          aliyunVoiceId: voiceId,
          aliyunTargetModel: targetModel,
          aliyunVoiceStatus: 'OK',
        );
        await onVoiceCreated!(updatedPreset);
      }

      if (!completer.isCompleted) completer.complete(voiceId);
      return voiceId;
    } catch (e, st) {
      AppLogger.warning('TTS', '从本地文件创建阿里云音色失败', metadata: {
        'error': e.toString(),
      });
      final ex = TtsException('从本地文件创建阿里云音色失败: $e');
      if (!completer.isCompleted) completer.completeError(ex, st);
      throw ex;
    } finally {
      _aliyunVoiceCreateInFlight.remove(cacheKey);
    }
  }

  /// 检查已保存的阿里云音色模型是否与目标模型匹配
  ///
  /// 阿里云音色ID必须与创建时的模型一致才能使用。
  /// 例如：用 qwen3-tts-vc-realtime-2025-11-27 创建的音色不能用于 qwen3-tts-vc-realtime-2026-01-15
  bool _isAliyunVoiceModelMatch(String? savedModel, String targetModel) {
    if (savedModel == null || savedModel.isEmpty) return false;

    // 完全匹配
    if (savedModel == targetModel) return true;

    // 对于 Qwen-TTS 声音复刻模型，需要严格匹配（包含日期版本）
    // 例如：qwen3-tts-vc-realtime-2025-11-27 和 qwen3-tts-vc-realtime-2026-01-15 是不同的
    if (savedModel.contains('qwen') && targetModel.contains('qwen')) {
      // 声音复刻模型（带 vc）需要严格匹配
      if (savedModel.contains('-vc-') || targetModel.contains('-vc-')) {
        return savedModel == targetModel;
      }
      // 普通 Qwen-TTS 模型可以宽松匹配（只比较基础模型名）
      final savedBase = savedModel.split('-').take(2).join('-');
      final targetBase = targetModel.split('-').take(2).join('-');
      return savedBase == targetBase;
    }

    // 对于 CosyVoice 模型，比较基础模型名
    if (savedModel.contains('cosyvoice') && targetModel.contains('cosyvoice')) {
      // cosyvoice-v3-plus 和 cosyvoice-v3-flash 是不同的
      return savedModel == targetModel;
    }

    return false;
  }

  /// 清理音色名称（用于阿里云 API）
  String _sanitizeVoiceName(String name) {
    var sanitized = name.replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '');
    if (sanitized.isEmpty) sanitized = 'voice';
    if (sanitized.length > 10) sanitized = sanitized.substring(0, 10);
    return sanitized.toLowerCase();
  }

  /// 构建请求头
  Map<String, String> _buildHeaders() {
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'X-Failover-Enabled': 'true', // 算力不足时自动兜底转移
    };

    final key = apiKey?.trim();
    if (key != null && key.isNotEmpty) {
      headers['Authorization'] = 'Bearer $key';
    }

    return headers;
  }

  /// 从接口返回数据中解析出音频地址
  TtsConvertResult _parseResponse(Map<String, dynamic> data) {
    final embeddedAudioResult = _tryParseEmbeddedAudio(data);
    if (embeddedAudioResult != null) {
      return embeddedAudioResult;
    }

    String? audioUrl;

    if (data.containsKey('audio_url')) {
      audioUrl = data['audio_url'] as String?;
    } else if (data.containsKey('url')) {
      audioUrl = data['url'] as String?;
    } else if (data.containsKey('result')) {
      final result = data['result'] as Map<String, dynamic>;
      audioUrl = result['audio_url'] as String? ?? result['url'] as String?;
    } else if (data.containsKey('output')) {
      final output = data['output'];
      if (output is Map<String, dynamic>) {
        // 阿里云 Qwen-TTS 格式: { output: { audio: { url: "..." } } }
        final audio = output['audio'];
        if (audio is Map<String, dynamic>) {
          audioUrl = audio['url'] as String?;
        }
        // 兼容 output 中的多种字段命名
        audioUrl ??= output['file_url'] as String? ??
            output['audio_url'] as String? ??
            output['url'] as String?;
      }
    }

    if (audioUrl == null || audioUrl.isEmpty) {
      throw TtsException('TTS 响应中未找到音频地址: ${jsonEncode(data)}');
    }

    return TtsConvertResult(
      audioUrl: audioUrl,
      text: '',
      success: true,
    );
  }

  TtsConvertResult? _tryParseEmbeddedAudio(Map<String, dynamic> data) {
    final embeddedData = data['data'];
    if (embeddedData is! Map<String, dynamic>) {
      return null;
    }

    final audioPayload = embeddedData['audio'];
    if (audioPayload is! String || audioPayload.trim().isEmpty) {
      return null;
    }

    final trimmedPayload = audioPayload.trim();
    if (_looksLikeRemoteAudioUrl(trimmedPayload)) {
      return TtsConvertResult(
        audioUrl: trimmedPayload,
        text: '',
        success: true,
      );
    }

    final audioBytes = _decodeHexAudio(trimmedPayload);
    if (audioBytes.isEmpty) {
      return null;
    }

    final extraInfo = data['extra_info'];
    final format = extraInfo is Map<String, dynamic>
        ? extraInfo['audio_format'] as String?
        : null;
    final mimeType = MimeUtils.guessAudioMimeType(
      'audio.${format ?? 'mp3'}',
    );
    final base64Audio = base64Encode(audioBytes);

    return TtsConvertResult(
      audioUrl: 'data:$mimeType;base64,$base64Audio',
      text: '',
      success: true,
    );
  }

  bool _looksLikeRemoteAudioUrl(String value) {
    return value.startsWith('http://') ||
        value.startsWith('https://') ||
        value.startsWith('data:');
  }

  List<int> _decodeHexAudio(String hexValue) {
    final normalized = hexValue.replaceAll(RegExp(r'\s+'), '');
    if (normalized.isEmpty || normalized.length.isOdd) {
      return const <int>[];
    }

    final bytes = <int>[];
    for (var index = 0; index < normalized.length; index += 2) {
      final byte = int.tryParse(
        normalized.substring(index, index + 2),
        radix: 16,
      );
      if (byte == null) {
        return const <int>[];
      }
      bytes.add(byte);
    }
    return bytes;
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
