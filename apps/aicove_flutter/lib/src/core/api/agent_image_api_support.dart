part of 'agent_api.dart';

class _AgentImageApiSupport {
  const _AgentImageApiSupport(this._owner);

  static const String _novelAiDefaultBase = 'https://image.novelai.net';
  static const String _novelAiLegacyBase = 'https://api.novelai.net';
  static const String _novelAiDefaultModel = 'nai-diffusion-4-5-curated';
  static const Map<String, String> _novelAiModelAliases = <String, String>{
    'nai-diffusion-4-5-curated-preview': 'nai-diffusion-4-5-curated',
  };
  static const List<String> _novelAiModelFallbackOrder = <String>[
    'nai-diffusion-4-5-curated',
    'nai-diffusion-4-5-full',
    'nai-diffusion-3',
  ];
  static const Set<String> _novelAiV4ReservedParameterKeys = <String>{
    'params_version',
    'width',
    'height',
    'n_samples',
    'steps',
    'scale',
    'sampler',
    'seed',
    'negative_prompt',
    'qualityToggle',
    'ucPreset',
    'legacy',
    'legacy_v3_extend',
    'noise_schedule',
    'sm',
    'sm_dyn',
    'dynamic_thresholding',
    'add_original_image',
    'cfg_rescale',
    'prefer_brownian',
    'deliberate_euler_ancestral_bug',
    'autoSmea',
    'use_coords',
    'characterPrompts',
    'v4_prompt',
    'v4_negative_prompt',
  };
  static const Set<String> _novelAiV3ReservedParameterKeys = <String>{
    'params_version',
    'width',
    'height',
    'n_samples',
    'steps',
    'scale',
    'sampler',
    'seed',
    'negative_prompt',
    'qualityToggle',
    'ucPreset',
    'legacy',
    'legacy_v3_extend',
    'noise_schedule',
    'sm',
    'sm_dyn',
    'dynamic_thresholding',
  };

  final AgentApiClient _owner;

  http.Client get _client => _owner._client;
  Duration get timeout => _owner.timeout;

  Future<ImageGenerationResult> generateImage({
    required String provider,
    required String model,
    required String prompt,
    String? negativePrompt,
    int width = 1024,
    int height = 1024,
    int count = 1,
    int? steps,
    double? guidanceScale,
    int? seed,
    String? sampler,
    String? providerApiBase,
    String? providerApiKey,
    Map<String, dynamic>? customConfig,
    String? requestId,
    String? requestSource,
    String? flowMode,
  }) async {
    final trimmedBase = providerApiBase?.trim();
    final trimmedKey = providerApiKey?.trim();
    if (trimmedKey == null || trimmedKey.isEmpty) {
      throw StateError('Missing providerApiKey for image generation');
    }

    final normalizedProvider = ImageProviderAdapterFactory.resolveProvider(
      provider,
      customConfig: customConfig,
    );
    final normalizedRequestId = _normalizeImageRequestId(requestId);
    final normalizedRequestSource = requestSource?.trim();
    final normalizedFlowMode = flowMode?.trim();
    final isNovelAi =
        normalizedProvider == 'novelai' || normalizedProvider == 'nai';
    if (isNovelAi) {
      final base = _normalizeNovelAiBaseUrl(trimmedBase);
      final normalizedNovelAiModel = _normalizeNovelAiModel(
        model,
        customConfig: customConfig,
      );
      final candidates = _buildNovelAiModelCandidates(normalizedNovelAiModel);
      Object? lastError;
      for (final candidate in candidates) {
        try {
          return await _generateImageWithNovelAI(
            provider: normalizedProvider,
            model: candidate,
            prompt: prompt,
            negativePrompt: negativePrompt,
            width: width,
            height: height,
            count: count,
            steps: steps,
            guidanceScale: guidanceScale,
            seed: seed,
            sampler: sampler,
            baseUrl: base,
            apiKey: trimmedKey,
            customConfig: customConfig,
            requestId: normalizedRequestId,
            requestSource: normalizedRequestSource,
            flowMode: normalizedFlowMode,
          );
        } catch (e) {
          lastError = e;
          if (!_isNovelAiModelEnumError(e) || candidate == candidates.last) {
            rethrow;
          }
          _owner._evt(
            'image:novelai_model_retry',
            <String, Object?>{
              'reason': 'enum_error',
              'from': candidate,
              'to': candidates[candidates.indexOf(candidate) + 1],
              'baseUrl': base,
            },
            level: 'WARN',
          );
        }
      }
      if (lastError != null) {
        throw lastError;
      }
    }

    final baseUrl = (trimmedBase == null || trimmedBase.isEmpty)
        ? 'https://api.openai.com/v1'
        : trimmedBase;
    final adapter = ImageProviderAdapterFactory.getAdapter(
      normalizedProvider,
      customConfig: customConfig,
    );
    final request = ImageProviderRequest(
      provider: normalizedProvider,
      model: model,
      prompt: prompt,
      negativePrompt: negativePrompt,
      width: width,
      height: height,
      count: count,
      steps: steps,
      guidanceScale: guidanceScale,
      seed: seed,
      sampler: sampler,
      baseUrl: baseUrl,
      apiKey: trimmedKey,
      customConfig: customConfig,
    );
    final logMetadata = <String, dynamic>{
      'requestId': normalizedRequestId,
      if (normalizedRequestSource != null && normalizedRequestSource.isNotEmpty)
        'requestSource': normalizedRequestSource,
      if (normalizedFlowMode != null && normalizedFlowMode.isNotEmpty)
        'flowMode': normalizedFlowMode,
      'provider': normalizedProvider,
      'model': model,
      'baseUrl': baseUrl,
      'timeoutMs': timeout.inMilliseconds,
      'width': width,
      'height': height,
      'count': count,
      'hasNegativePrompt': negativePrompt?.trim().isNotEmpty == true,
    };
    final startedAt = DateTime.now();
    AppLogger.info('AgentApiClient', '图片请求开始', metadata: {
      ...logMetadata,
      'requestFormat': 'adapter',
      'adapter': adapter.name,
    });
    try {
      final result = await adapter.generate(
        client: _client,
        timeout: timeout,
        request: request,
      );
      final durationMs = DateTime.now().difference(startedAt).inMilliseconds;
      AppLogger.info('AgentApiClient', '图片请求完成', metadata: {
        ...logMetadata,
        'requestFormat': 'adapter',
        'adapter': adapter.name,
        'durationMs': durationMs,
        'imageCount': result.images.length,
      });
      return ImageGenerationResult(
        images: result.images,
        provider: normalizedProvider,
        model: model,
        rawResponse: result.rawResponse,
      );
    } catch (e) {
      final durationMs = DateTime.now().difference(startedAt).inMilliseconds;
      AppLogger.warning('AgentApiClient', '图片请求失败', metadata: {
        ...logMetadata,
        'requestFormat': 'adapter',
        'adapter': adapter.name,
        'durationMs': durationMs,
        'phase': 'adapter_generate',
        'error': e.toString(),
      });
      rethrow;
    }
  }

  String _normalizeNovelAiModel(
    String model, {
    Map<String, dynamic>? customConfig,
  }) {
    final explicit = model.trim();
    final fromConfig =
        customConfig?['defaultImageModel']?.toString().trim() ?? '';
    final candidate = explicit.isNotEmpty ? explicit : fromConfig;
    if (candidate.isEmpty) return _novelAiDefaultModel;
    return _novelAiModelAliases[candidate] ?? candidate;
  }

  String _normalizeNovelAiBaseUrl(String? baseUrl) {
    final trimmed = baseUrl?.trim() ?? '';
    if (trimmed.isEmpty) return _novelAiDefaultBase;
    final lowered = trimmed.toLowerCase();
    if (lowered.startsWith(_novelAiLegacyBase)) {
      return _novelAiDefaultBase + trimmed.substring(_novelAiLegacyBase.length);
    }
    try {
      final uri = Uri.parse(trimmed);
      if (uri.host.toLowerCase() == 'api.novelai.net') {
        return uri.replace(host: 'image.novelai.net').toString();
      }
    } catch (_) {}
    return trimmed;
  }

  List<String> _buildNovelAiModelCandidates(String primary) {
    final normalizedPrimary = _novelAiModelAliases[primary] ?? primary;
    final candidates = <String>[];

    void add(String modelId) {
      final fixed = (_novelAiModelAliases[modelId] ?? modelId).trim();
      if (fixed.isEmpty || candidates.contains(fixed)) return;
      candidates.add(fixed);
    }

    add(normalizedPrimary);
    for (final fallback in _novelAiModelFallbackOrder) {
      add(fallback);
    }
    if (candidates.isEmpty) {
      return const <String>[_novelAiDefaultModel];
    }
    return candidates;
  }

  bool _isNovelAiModelEnumError(Object error) {
    final message = error.toString().toLowerCase();
    return message.contains('model must be a valid enum value');
  }

  Future<ImageGenerationResult> _generateImageWithNovelAI({
    required String provider,
    required String model,
    required String prompt,
    required int width,
    required int height,
    required int count,
    required String baseUrl,
    required String apiKey,
    String? negativePrompt,
    int? steps,
    double? guidanceScale,
    int? seed,
    String? sampler,
    Map<String, dynamic>? customConfig,
    String? requestId,
    String? requestSource,
    String? flowMode,
  }) async {
    final normalizedRequestId = _normalizeImageRequestId(requestId);
    final normalizedRequestSource = requestSource?.trim();
    final normalizedFlowMode = flowMode?.trim();
    final normalized = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    final endpoint = '$normalized/ai/generate-image';
    final samplerValue = sampler?.trim();
    final negativePromptValue = negativePrompt?.trim();
    final isV4 = _isNovelAiV4Model(model);
    final params = _buildNovelAiParameters(
      model: model,
      prompt: prompt,
      negativePrompt: negativePromptValue,
      width: width,
      height: height,
      count: count,
      steps: steps,
      guidanceScale: guidanceScale,
      seed: seed,
      sampler: samplerValue,
    );
    _mergeNovelAiExtraParameters(
      params,
      customConfig?['image_parameters'],
      reservedKeys: isV4
          ? _novelAiV4ReservedParameterKeys
          : _novelAiV3ReservedParameterKeys,
    );
    final payload = <String, dynamic>{
      'input': prompt,
      'model': model,
      'action': 'generate',
      'parameters': params,
    };
    final requestBodyJson = jsonEncode(payload);
    final requestBodyBytes = utf8.encode(requestBodyJson).length;
    final startedAt = DateTime.now();
    final baseMetadata = <String, dynamic>{
      'requestId': normalizedRequestId,
      if (normalizedRequestSource != null && normalizedRequestSource.isNotEmpty)
        'requestSource': normalizedRequestSource,
      if (normalizedFlowMode != null && normalizedFlowMode.isNotEmpty)
        'flowMode': normalizedFlowMode,
      'provider': provider,
      'model': model,
      'endpoint': endpoint,
      'timeoutMs': timeout.inMilliseconds,
      'width': width,
      'height': height,
      'count': count,
      'hasNegativePrompt': negativePromptValue?.isNotEmpty == true,
    };
    var phase = 'prepare_request';
    var apiLogWritten = false;

    AppLogger.info('AgentApiClient', '图片请求准备发送', metadata: {
      ...baseMetadata,
      'phase': phase,
      'requestBodyBytes': requestBodyBytes,
      'requestBodyPreview': ApiLogger.safeSnippet(requestBodyJson, max: 2000),
    });

    try {
      final request = http.Request('POST', Uri.parse(endpoint))
        ..headers.addAll(<String, String>{
          'Authorization': 'Bearer $apiKey',
          'Content-Type': 'application/json',
          'Accept': 'application/zip',
        })
        ..body = requestBodyJson;
      phase = 'wait_headers';
      final response = await _client.send(request).timeout(timeout);
      final headersElapsed = DateTime.now().difference(startedAt);
      AppLogger.info('AgentApiClient', '图片请求收到响应头', metadata: {
        ...baseMetadata,
        'phase': phase,
        'statusCode': response.statusCode,
        'durationMs': headersElapsed.inMilliseconds,
        'contentType': response.headers['content-type'],
        'contentLength': response.headers['content-length'],
      });

      final remaining = _remainingImageTimeout(startedAt);
      if (remaining == Duration.zero) {
        throw TimeoutException('Image response body timed out', timeout);
      }

      phase = 'read_body';
      final bytes = await response.stream.toBytes().timeout(remaining);
      final durationMs = DateTime.now().difference(startedAt).inMilliseconds;
      final contentType = response.headers['content-type']?.trim();

      if (response.statusCode < 200 || response.statusCode >= 300) {
        final errorBody = utf8.decode(bytes);
        final friendlyError = _formatImageHttpError(
          statusCode: response.statusCode,
          provider: provider,
          body: errorBody,
        );
        apiLogWritten = true;
        ApiLogger.add(ApiLogEntry(
          time: startedAt,
          method: 'POST',
          url: endpoint,
          status: response.statusCode,
          durationMs: durationMs,
          requestBody: ApiLogger.safeSnippet(requestBodyJson),
          responseBody: ApiLogger.safeSnippet(errorBody, max: 1200),
          ok: false,
          rawRequestBody: requestBodyJson,
          rawResponseBody: jsonEncode({
            'kind': 'error',
            'phase': phase,
            'requestId': normalizedRequestId,
            'statusCode': response.statusCode,
            'contentType': contentType,
            'bodyBytes': bytes.length,
            'headers': _compactImageResponseHeaders(response.headers),
            'bodyPreview': ApiLogger.safeSnippet(errorBody, max: 2000),
          }),
          eventType: 'image_generation',
          source: 'AgentApiClient',
        ));
        AppLogger.warning('AgentApiClient', '图片请求返回非成功状态', metadata: {
          ...baseMetadata,
          'phase': phase,
          'statusCode': response.statusCode,
          'durationMs': durationMs,
          'contentType': contentType,
          'bodyBytes': bytes.length,
          'friendlyError': friendlyError,
          'errorBodyPreview': ApiLogger.safeSnippet(errorBody, max: 800),
        });
        throw Exception(friendlyError);
      }

      phase = 'decode_body';
      final images =
          _extractImageBytesFromNovelAIResponse(bytes, response.headers);
      apiLogWritten = true;
      ApiLogger.add(ApiLogEntry(
        time: startedAt,
        method: 'POST',
        url: endpoint,
        status: response.statusCode,
        durationMs: durationMs,
        requestBody: ApiLogger.safeSnippet(requestBodyJson),
        responseBody: '[image binary] ${bytes.length} bytes',
        ok: true,
        rawRequestBody: requestBodyJson,
        rawResponseBody: jsonEncode({
          'kind': 'binary',
          'phase': phase,
          'requestId': normalizedRequestId,
          'statusCode': response.statusCode,
          'contentType': contentType,
          'bodyBytes': bytes.length,
          'headers': _compactImageResponseHeaders(response.headers),
          'imageCount': images.length,
        }),
        eventType: 'image_generation',
        source: 'AgentApiClient',
      ));
      AppLogger.info('AgentApiClient', '图片请求完成', metadata: {
        ...baseMetadata,
        'phase': phase,
        'statusCode': response.statusCode,
        'durationMs': durationMs,
        'contentType': contentType,
        'bodyBytes': bytes.length,
        'imageCount': images.length,
      });
      return ImageGenerationResult(
        images: images,
        provider: provider,
        model: model,
      );
    } on TimeoutException catch (e) {
      final durationMs = DateTime.now().difference(startedAt).inMilliseconds;
      if (!apiLogWritten) {
        ApiLogger.add(ApiLogEntry(
          time: startedAt,
          method: 'POST',
          url: endpoint,
          status: null,
          durationMs: durationMs,
          requestBody: ApiLogger.safeSnippet(requestBodyJson),
          responseBody: ApiLogger.safeSnippet(e.toString(), max: 1200),
          ok: false,
          rawRequestBody: requestBodyJson,
          rawResponseBody: jsonEncode({
            'kind': 'timeout',
            'phase': phase,
            'requestId': normalizedRequestId,
            'durationMs': durationMs,
            'timeoutMs': timeout.inMilliseconds,
            'error': e.toString(),
          }),
          eventType: 'image_generation',
          source: 'AgentApiClient',
        ));
      }
      AppLogger.warning('AgentApiClient', '图片请求超时', metadata: {
        ...baseMetadata,
        'phase': phase,
        'durationMs': durationMs,
        'error': e.toString(),
      });
      rethrow;
    } catch (e) {
      final durationMs = DateTime.now().difference(startedAt).inMilliseconds;
      if (!apiLogWritten) {
        ApiLogger.add(ApiLogEntry(
          time: startedAt,
          method: 'POST',
          url: endpoint,
          status: null,
          durationMs: durationMs,
          requestBody: ApiLogger.safeSnippet(requestBodyJson),
          responseBody: ApiLogger.safeSnippet(e.toString(), max: 1200),
          ok: false,
          rawRequestBody: requestBodyJson,
          rawResponseBody: jsonEncode({
            'kind': 'exception',
            'phase': phase,
            'requestId': normalizedRequestId,
            'durationMs': durationMs,
            'error': e.toString(),
          }),
          eventType: 'image_generation',
          source: 'AgentApiClient',
        ));
      }
      AppLogger.warning('AgentApiClient', '图片请求失败', metadata: {
        ...baseMetadata,
        'phase': phase,
        'durationMs': durationMs,
        'error': e.toString(),
      });
      rethrow;
    }
  }

  String _normalizeImageRequestId(String? requestId) {
    final trimmed = requestId?.trim() ?? '';
    if (trimmed.isNotEmpty) return trimmed;
    return 'imgreq_${DateTime.now().microsecondsSinceEpoch}';
  }

  Duration _remainingImageTimeout(DateTime startedAt) {
    final elapsed = DateTime.now().difference(startedAt);
    final remaining = timeout - elapsed;
    if (remaining.isNegative || remaining == Duration.zero) {
      return Duration.zero;
    }
    return remaining;
  }

  Map<String, String> _compactImageResponseHeaders(
      Map<String, String> headers) {
    if (headers.isEmpty) return const <String, String>{};
    return <String, String>{
      for (final entry in headers.entries)
        if (const <String>{
          'content-type',
          'content-length',
          'content-disposition',
          'transfer-encoding',
          'content-encoding',
        }.contains(entry.key.toLowerCase()))
          entry.key: entry.value,
    };
  }

  bool _isNovelAiV4Model(String model) {
    final value = model.toLowerCase().trim();
    return value.startsWith('nai-diffusion-4');
  }

  String _formatImageHttpError({
    required int statusCode,
    required String provider,
    required String body,
  }) {
    final trimmedBody = body.trim();
    final bodySuffix = trimmedBody.isEmpty ? '' : ': $trimmedBody';
    final normalizedProvider = provider.trim().toLowerCase();
    if (statusCode == 401) {
      if (normalizedProvider == 'novelai' || normalizedProvider == 'nai') {
        return 'NovelAI 鉴权失败 (HTTP 401)：请检查绘图渠道的 API Token 是否正确、未过期，并确认账号可使用图片生成$bodySuffix';
      }
      return '图片生成鉴权失败 (HTTP 401)：请检查当前绘图渠道的 API Key 或 Token$bodySuffix';
    }
    if (statusCode == 403) {
      return '图片生成权限不足 (HTTP 403)：请检查当前账号、模型权限或额度$bodySuffix';
    }
    return 'HTTP $statusCode$bodySuffix';
  }

  Map<String, dynamic> _buildNovelAiParameters({
    required String model,
    required String prompt,
    required int width,
    required int height,
    required int count,
    String? negativePrompt,
    int? steps,
    double? guidanceScale,
    int? seed,
    String? sampler,
  }) {
    final params = <String, dynamic>{
      'params_version': 3,
      'width': width.clamp(256, 2048),
      'height': height.clamp(256, 2048),
      'n_samples': count.clamp(1, 4),
      'steps': (steps ?? 23).clamp(1, 50),
      'scale': guidanceScale ?? 5.0,
      'sampler': (sampler != null && sampler.isNotEmpty)
          ? sampler
          : 'k_euler_ancestral',
      if (seed != null) 'seed': seed,
      if (negativePrompt != null && negativePrompt.isNotEmpty)
        'negative_prompt': negativePrompt,
    };
    if (_isNovelAiV4Model(model)) {
      final v4Negative = (negativePrompt == null || negativePrompt.isEmpty)
          ? 'lowres'
          : negativePrompt;
      params.addAll(<String, dynamic>{
        'use_coords': false,
        'characterPrompts': const <dynamic>[],
        'v4_prompt': <String, dynamic>{
          'caption': <String, dynamic>{
            'base_caption': prompt,
            'char_captions': const <dynamic>[],
          },
          'use_coords': false,
          'use_order': true,
        },
        'v4_negative_prompt': <String, dynamic>{
          'caption': <String, dynamic>{
            'base_caption': v4Negative,
            'char_captions': const <dynamic>[],
          },
        },
      });
      return params;
    }
    params.addAll(<String, dynamic>{
      'qualityToggle': true,
      'ucPreset': 0,
      'legacy': false,
      'legacy_v3_extend': false,
      'noise_schedule': 'karras',
      'sm': false,
      'sm_dyn': false,
      'dynamic_thresholding': false,
    });
    return params;
  }

  void _mergeNovelAiExtraParameters(
    Map<String, dynamic> params,
    dynamic extra, {
    required Set<String> reservedKeys,
  }) {
    if (extra is! Map) return;
    for (final entry in extra.entries) {
      final key = entry.key?.toString().trim() ?? '';
      if (key.isEmpty || reservedKeys.contains(key)) {
        continue;
      }
      params[key] = entry.value;
    }
  }

  List<Uint8List> _extractImageBytesFromNovelAIResponse(
    Uint8List bytes,
    Map<String, String> headers,
  ) {
    final contentType = headers['content-type']?.toLowerCase() ?? '';
    final isZip = contentType.contains('zip') ||
        (bytes.length > 3 && bytes[0] == 0x50 && bytes[1] == 0x4B);
    if (isZip) {
      final archive = ZipDecoder().decodeBytes(bytes, verify: false);
      final results = <Uint8List>[];
      for (final file in archive.files) {
        if (!file.isFile) continue;
        final content = file.content;
        if (content is List<int>) {
          results.add(Uint8List.fromList(content));
        }
      }
      return results;
    }

    try {
      final data = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      final image = data['image']?.toString();
      if (image != null && image.isNotEmpty) {
        return <Uint8List>[base64Decode(image)];
      }
      final dataList = data['data'];
      if (dataList is List) {
        final results = <Uint8List>[];
        for (final item in dataList) {
          if (item is! Map<String, dynamic>) continue;
          final b64 = item['b64_json']?.toString();
          if (b64 != null && b64.isNotEmpty) {
            results.add(base64Decode(b64));
          }
        }
        return results;
      }
    } catch (_) {}
    return const <Uint8List>[];
  }
}
