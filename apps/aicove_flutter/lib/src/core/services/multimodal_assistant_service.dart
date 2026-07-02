library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/settings/app_settings.dart';
import '../api/agent_api.dart';
import '../app_logger.dart';
import '../models/message_block.dart';
import '../prompts/prompt_builtin_defaults.g.dart';
import '../utils/mime_utils.dart';

typedef ReadMultimodalAssistantImageAsBase64 = Future<String?> Function(
  String imagePath,
);
typedef CreateMultimodalAssistantAgentClient = AgentApiClient Function();

final multimodalAssistantServiceProvider =
    Provider<MultimodalAssistantService>((ref) {
  return MultimodalAssistantService();
});

class MultimodalAssistantAuth {
  const MultimodalAssistantAuth({
    required this.modelRef,
    required this.providerApiBase,
    required this.providerApiKey,
    required this.customConfig,
  });

  final String modelRef;
  final String providerApiBase;
  final String providerApiKey;
  final Map<String, dynamic> customConfig;
}

class MultimodalAssistantService {
  MultimodalAssistantService({
    ReadMultimodalAssistantImageAsBase64? readImageAsBase64,
    CreateMultimodalAssistantAgentClient? createAgentClient,
  })  : _readImageAsBase64 =
            readImageAsBase64 ?? MultimodalAssistantService._defaultReadImage,
        _createAgentClient = createAgentClient ??
            (() => AgentApiClient(timeout: const Duration(seconds: 30)));

  static const String _logTag = 'MultimodalAssistantService';
  static const int _maxImageDescriptionCacheSize = 128;
  static String get visionDescriptionSystemPrompt =>
      PromptBuiltinDefaults.requireTemplate('multimodal.vision.system');
  static String get audioAnalysisSystemPrompt =>
      PromptBuiltinDefaults.requireTemplate('multimodal.audio.system');
  static String get videoAnalysisSystemPrompt =>
      PromptBuiltinDefaults.requireTemplate('multimodal.video.system');

  final ReadMultimodalAssistantImageAsBase64 _readImageAsBase64;
  final CreateMultimodalAssistantAgentClient _createAgentClient;
  final Map<String, String> _imageDescriptionCache = <String, String>{};

  Future<String?> describeImageBlock({
    required ImageBlock imageBlock,
    required AppSettings settings,
  }) async {
    final existingPrompt = imageBlock.prompt?.trim();
    if (existingPrompt != null && existingPrompt.isNotEmpty) {
      return existingPrompt;
    }

    final cacheKey = _buildImageDescriptionCacheKey(imageBlock);
    final cachedDescription =
        cacheKey == null ? null : _imageDescriptionCache[cacheKey];
    final cached = cachedDescription?.trim();
    if (cached != null && cached.isNotEmpty) {
      return cached;
    }

    final auth = resolveAssistantModelAuth(
        settings: settings, modelRef: settings.defaultVisionModel);
    if (auth == null) return null;

    final imagePart = await _buildImagePart(imageBlock);
    if (imagePart == null) return null;

    final messages = buildImageAssistantMessages(imagePart: imagePart);
    try {
      final text = await _runAssistantRequest(
        auth: auth,
        agentId: 'system_vision',
        sessionPrefix: 'vision_translate',
        messages: messages,
      );
      if (text.isEmpty) return null;
      if (cacheKey != null) {
        _cacheImageDescription(cacheKey, text);
      }
      return text;
    } catch (e) {
      AppLogger.warning(
        _logTag,
        'Vision translation failed',
        metadata: {'error': e.toString()},
      );
      return null;
    }
  }

  Future<String?> transcribeAudioFile({
    required FileBlock fileBlock,
    required AppSettings settings,
  }) async {
    final auth = resolveAssistantModelAuth(
      settings: settings,
      modelRef: settings.defaultVisionModel,
    );
    if (auth == null || !_supportsGeminiNativeParts(settings, auth.modelRef)) {
      return null;
    }

    final audioPart = await _buildGeminiFilePart(
      filePath: fileBlock.filePath,
      mimeType: fileBlock.mimeType,
    );
    if (audioPart == null) return null;

    final text = await _runAssistantRequest(
      auth: auth,
      agentId: 'system_audio',
      sessionPrefix: 'audio_analyze',
      messages: buildGeminiMediaAssistantMessages(
        systemPrompt: audioAnalysisSystemPrompt,
        mediaPart: audioPart,
        taskText: '请分析这个音频并按 JSON 输出。',
      ),
    );
    return _sanitizeAssistantJsonText(text);
  }

  Future<String?> summarizeVideoFile({
    required FileBlock fileBlock,
    required AppSettings settings,
  }) async {
    final auth = resolveAssistantModelAuth(
      settings: settings,
      modelRef: settings.defaultVisionModel,
    );
    if (auth == null || !_supportsGeminiNativeParts(settings, auth.modelRef)) {
      return null;
    }

    final videoPart = await _buildGeminiFilePart(
      filePath: fileBlock.filePath,
      mimeType: fileBlock.mimeType,
    );
    if (videoPart == null) return null;

    final text = await _runAssistantRequest(
      auth: auth,
      agentId: 'system_video',
      sessionPrefix: 'video_analyze',
      messages: buildGeminiMediaAssistantMessages(
        systemPrompt: videoAnalysisSystemPrompt,
        mediaPart: videoPart,
        taskText: '请分析这个视频并按 JSON 输出。',
      ),
    );
    return _sanitizeAssistantJsonText(text);
  }

  MultimodalAssistantAuth? resolveAssistantModelAuth({
    required AppSettings settings,
    required String? modelRef,
  }) {
    final normalizedModelRef = modelRef?.trim();
    if (normalizedModelRef == null || normalizedModelRef.isEmpty) {
      return null;
    }

    final providerId = settings.getModelProviderId(normalizedModelRef);
    final rawModelId = settings.getRawModelId(normalizedModelRef);
    if (providerId == null || rawModelId.isEmpty) {
      return null;
    }

    final provider = settings.providers.firstWhere(
      (p) => p.id == providerId,
      orElse: () =>
          const ProviderAuth(id: '', apiKeys: <String>[], apiBaseUrl: ''),
    );
    if (provider.id.isEmpty || provider.apiKeys.isEmpty) {
      return null;
    }

    final apiKey = provider.apiKeys.first.trim();
    if (apiKey.isEmpty) return null;

    return MultimodalAssistantAuth(
      modelRef: normalizedModelRef,
      providerApiBase: provider.apiBaseUrl.trim(),
      providerApiKey: apiKey,
      customConfig: provider.customConfig,
    );
  }

  static List<Map<String, dynamic>> buildImageAssistantMessages({
    required Map<String, dynamic> imagePart,
  }) {
    return <Map<String, dynamic>>[
      {
        'role': 'system',
        'content': visionDescriptionSystemPrompt,
      },
      {
        'role': 'user',
        'content': [imagePart],
      }
    ];
  }

  static List<Map<String, dynamic>> buildGeminiMediaAssistantMessages({
    required String systemPrompt,
    required Map<String, dynamic> mediaPart,
    required String taskText,
  }) {
    return <Map<String, dynamic>>[
      {
        'role': 'system',
        'content': systemPrompt,
      },
      {
        'role': 'user',
        'parts': [
          mediaPart,
          {'text': taskText},
        ],
      },
    ];
  }

  Future<Map<String, dynamic>?> _buildImagePart(ImageBlock block) async {
    final url = block.url?.trim();
    if (url != null && url.isNotEmpty) {
      return {
        'type': 'image_url',
        'image_url': {'url': url}
      };
    }

    final base64 = block.base64?.trim();
    if (base64 != null && base64.isNotEmpty) {
      return {
        'type': 'image_url',
        'image_url': {'url': 'data:image/jpeg;base64,$base64'},
      };
    }

    final localPath = block.localPath?.trim();
    if (localPath == null || localPath.isEmpty) {
      return null;
    }

    final encoded = await _readImageAsBase64(localPath);
    if (encoded == null || encoded.isEmpty) {
      return null;
    }
    final mime = MimeUtils.guessImageMimeType(localPath);
    return {
      'type': 'image_url',
      'image_url': {'url': 'data:$mime;base64,$encoded'},
    };
  }

  Future<Map<String, dynamic>?> _buildGeminiFilePart({
    required String filePath,
    required String mimeType,
  }) async {
    final normalizedPath = filePath.trim();
    if (normalizedPath.isEmpty) return null;

    final normalizedMime = MimeUtils.normalizeContentType(mimeType) ??
        MimeUtils.guessAttachmentMimeType(normalizedPath);
    if (normalizedPath.startsWith('http://') ||
        normalizedPath.startsWith('https://')) {
      return {
        'fileData': {
          'mimeType': normalizedMime,
          'fileUri': normalizedPath,
        },
      };
    }

    try {
      final bytes = await File(normalizedPath).readAsBytes();
      return {
        'inlineData': {
          'mimeType': normalizedMime,
          'data': base64Encode(bytes),
        },
      };
    } catch (e) {
      AppLogger.warning(
        _logTag,
        '读取多模态文件失败',
        metadata: {'path': normalizedPath, 'error': e.toString()},
      );
      return null;
    }
  }

  String? _buildImageDescriptionCacheKey(ImageBlock block) {
    final url = block.url?.trim();
    if (url != null && url.isNotEmpty) return 'url:$url';

    final localPath = block.localPath?.trim();
    if (localPath != null && localPath.isNotEmpty) return 'local:$localPath';

    final base64 = block.base64?.trim();
    if (base64 != null && base64.isNotEmpty) {
      if (base64.length <= 160) return 'b64:$base64';
      final head = base64.substring(0, 80);
      final tail = base64.substring(base64.length - 80);
      return 'b64:${base64.length}:$head:$tail';
    }
    return null;
  }

  void _cacheImageDescription(String cacheKey, String description) {
    final trimmed = description.trim();
    if (trimmed.isEmpty) return;

    if (_imageDescriptionCache.containsKey(cacheKey)) {
      _imageDescriptionCache.remove(cacheKey);
    }
    _imageDescriptionCache[cacheKey] = trimmed;
    while (_imageDescriptionCache.length > _maxImageDescriptionCacheSize) {
      _imageDescriptionCache.remove(_imageDescriptionCache.keys.first);
    }
  }

  bool _supportsGeminiNativeParts(AppSettings settings, String modelRef) {
    final providerId = settings.getModelProviderId(modelRef);
    return providerId == 'gemini';
  }

  Future<String> _runAssistantRequest({
    required MultimodalAssistantAuth auth,
    required String agentId,
    required String sessionPrefix,
    required List<Map<String, dynamic>> messages,
  }) async {
    final result = await _createAgentClient().sendMessageRich(
      agentId: agentId,
      sessionId: '${sessionPrefix}_${DateTime.now().millisecondsSinceEpoch}',
      modelFullId: auth.modelRef,
      messages: messages,
      userText: '',
      providerApiBase: auth.providerApiBase,
      providerApiKey: auth.providerApiKey,
      customConfig: auth.customConfig,
    );
    return result.text.trim();
  }

  String? _sanitizeAssistantJsonText(String? text) {
    final trimmed = text?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    if (!trimmed.startsWith('```')) {
      return trimmed;
    }

    final withoutFenceStart = trimmed.replaceFirst(
        RegExp(r'^```(?:json)?\s*', caseSensitive: false), '');
    final withoutFenceEnd =
        withoutFenceStart.replaceFirst(RegExp(r'\s*```$'), '');
    final normalized = withoutFenceEnd.trim();
    return normalized.isEmpty ? null : normalized;
  }

  static Future<String?> _defaultReadImage(String imagePath) async {
    try {
      final bytes = await File(imagePath).readAsBytes();
      return base64Encode(bytes);
    } catch (e) {
      AppLogger.error(_logTag, '读取图片失败: $e');
      return null;
    }
  }
}
