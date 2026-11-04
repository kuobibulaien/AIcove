part of 'agent_api.dart';

/// NovelAI 模型族：V5 / V4（含 V4.5）/ V3（含 Furry V3）。
enum _NovelAiModelFamily { v5, v4, v3 }

class _AgentImageApiSupport {
  const _AgentImageApiSupport(this._owner);

  static const String _novelAiDefaultBase = 'https://image.novelai.net';
  static const String _novelAiLegacyBase = 'https://api.novelai.net';
  static const String _novelAiDefaultModel = 'nai-diffusion-5-full';
  static const Map<String, String> _novelAiModelAliases = <String, String>{
    'nai-diffusion-4-5-curated-preview': 'nai-diffusion-4-5-curated',
  };
  static const Set<String> _novelAiStructuredReservedParameterKeys = <String>{
    'params_version',
    'width',
    'height',
    'n_samples',
    'steps',
    'scale',
    'negative_prompt',
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
    'negative_prompt',
    'use_coords',
    'characterPrompts',
    'v4_prompt',
    'v4_negative_prompt',
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
    final trimmedKey = providerApiKey?.trim() ?? '';

    final normalizedProvider = ImageProviderAdapterFactory.resolveProvider(
      provider,
      customConfig: customConfig,
    );
    if (trimmedKey.isEmpty && normalizedProvider != 'comfyui') {
      throw StateError('Missing providerApiKey for image generation');
    }
    if (normalizedProvider == 'comfyui' &&
        (trimmedBase == null || trimmedBase.isEmpty)) {
      throw StateError('请先配置 ComfyUI 服务地址');
    }
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
      // 显式选择的模型失败即返回，不做跨模型静默降级。
      return ImageRequestGate.shared.run(
        _imageChannelKey(normalizedProvider, base, trimmedKey),
        1,
        () => _generateImageWithNovelAI(
          provider: normalizedProvider,
          model: normalizedNovelAiModel,
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
        ),
      );
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
    final target = normalizedProvider == 'comfyui'
        ? ComfyUIImageAdapter.endpoint(baseUrl, '').toString().replaceFirst(
            RegExp(r'/+$'), '',
          )
        : OpenAICompatibleImageAdapter.resolveEndpoint(
            baseUrl: baseUrl,
            customConfig: customConfig,
          );
    return ImageRequestGate.shared.run(
      _imageChannelKey(normalizedProvider, target, trimmedKey),
      normalizedProvider == 'comfyui' ? 1 : 2,
      () async {
        final startedAt = DateTime.now();
        AppLogger.info(
          'AgentApiClient',
          '图片请求开始',
          metadata: {
            ...logMetadata,
            'requestFormat': 'adapter',
            'adapter': adapter.name,
          },
        );
        try {
          final result = await adapter.generate(
            client: _client,
            timeout: timeout,
            request: request,
          );
          RequestControl.cancellation?.throwIfCancelled();
          final durationMs = DateTime.now().difference(startedAt).inMilliseconds;
          AppLogger.info(
            'AgentApiClient',
            '图片请求完成',
            metadata: {
              ...logMetadata,
              'requestFormat': 'adapter',
              'adapter': adapter.name,
              'durationMs': durationMs,
              'imageCount': result.images.length,
            },
          );
          return ImageGenerationResult(
            images: result.images,
            provider: normalizedProvider,
            model: model,
            rawResponse: result.rawResponse,
          );
        } catch (e) {
          final durationMs = DateTime.now().difference(startedAt).inMilliseconds;
          AppLogger.warning(
            'AgentApiClient',
            '图片请求失败',
            metadata: {
              ...logMetadata,
              'requestFormat': 'adapter',
              'adapter': adapter.name,
              'durationMs': durationMs,
              'phase': 'adapter_generate',
              'error': e.toString(),
            },
          );
          rethrow;
        }
      },
    );
  }

  String _imageChannelKey(String provider, String target, String apiKey) {
    final digest = sha256.convert(utf8.encode(apiKey)).toString().substring(0, 12);
    // Uri canonicalizes scheme/host case and omits HTTP(S) default ports.
    // Trim only the path: query values and meaningful path case remain intact.
    final uri = Uri.parse(target);
    final normalizedTarget = uri
        .replace(
          scheme: uri.scheme.toLowerCase(),
          host: uri.host.toLowerCase(),
          path: uri.path.replaceFirst(RegExp(r'/+$'), ''),
        )
        .toString();
    return '$provider|$normalizedTarget|$digest';
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

  _NovelAiModelFamily _novelAiModelFamily(String model) {
    final value = model.toLowerCase().trim();
    if (value.startsWith('nai-diffusion-5')) return _NovelAiModelFamily.v5;
    if (value.startsWith('nai-diffusion-4')) return _NovelAiModelFamily.v4;
    // V3 / Furry V3 以及未知 NovelAI 模型走 legacy 分支。
    return _NovelAiModelFamily.v3;
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
    final family = _novelAiModelFamily(model);
    final compiledPrompt = family == _NovelAiModelFamily.v3 && !MangaPromptSanitizer.hasSections(prompt)
        ? _NovelAiCompiledPrompt.plain(prompt)
        : _compileNovelAiStructuredPrompt(prompt);
    final combinedNegative = [if (negativePromptValue != null) negativePromptValue, compiledPrompt.pageNegative]
        .where((value) => value.isNotEmpty).join(', ');
    var effectivePrompt = compiledPrompt.baseCaption;
    if (family == _NovelAiModelFamily.v3 && compiledPrompt.charCaptions.isNotEmpty) {
      final captions = compiledPrompt.charCaptions
          .map((caption) => (caption['char_caption'] as String).trim())
          .where((caption) => caption.isNotEmpty).toList();
      if (captions.isNotEmpty) {
        final dialogueStart = effectivePrompt.indexOf('\nText:');
        final visual = dialogueStart < 0 ? effectivePrompt : effectivePrompt.substring(0, dialogueStart);
        final dialogue = dialogueStart < 0 ? '' : effectivePrompt.substring(dialogueStart);
        effectivePrompt = [visual, ...captions].where((value) => value.isNotEmpty).join(', ') + dialogue;
      }
    }
    var effectiveWidth = width;
    var effectiveHeight = height;
    if (normalizedRequestSource != 'regenerate_image' &&
        compiledPrompt.isDoublePageSpread && effectiveWidth < effectiveHeight) {
      final swapped = effectiveWidth;
      effectiveWidth = effectiveHeight;
      effectiveHeight = swapped;
    }
    final params = _buildNovelAiParameters(
      model: model,
      prompt: compiledPrompt.baseCaption,
      compiledPrompt: compiledPrompt,
      negativePrompt: compiledPrompt.isSectionProtocol
          ? MangaPromptSanitizer.negative(combinedNegative) : negativePromptValue,
      width: effectiveWidth,
      height: effectiveHeight,
      count: count,
      steps: steps,
      guidanceScale: guidanceScale,
      seed: seed,
      sampler: samplerValue,
    );
    _mergeNovelAiExtraParameters(
      params,
      customConfig?['image_parameters'],
      reservedKeys: family == _NovelAiModelFamily.v3
          ? _novelAiV3ReservedParameterKeys
          : _novelAiStructuredReservedParameterKeys,
    );
    if (compiledPrompt.isSectionProtocol) {
      params['qualityToggle'] ??= false;
      params['ucPreset'] ??= 3;
    }
    final payload = <String, dynamic>{
      'input': effectivePrompt,
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
      'width': effectiveWidth,
      'height': effectiveHeight,
      'count': count,
      'hasNegativePrompt': negativePromptValue?.isNotEmpty == true,
    };
    var phase = 'prepare_request';
    var apiLogWritten = false;

    AppLogger.info(
      'AgentApiClient',
      '图片请求准备发送',
      metadata: {
        ...baseMetadata,
        'phase': phase,
        'requestBodyBytes': requestBodyBytes,
        'requestBodyPreview': ApiLogger.safeSnippet(requestBodyJson, max: 2000),
      },
    );

    try {
      phase = 'wait_headers';
      final response = await sendMediaRequestWithRetry(
        send: () {
          phase = 'wait_headers';
          final request = RequestControl.request('POST', Uri.parse(endpoint))
            ..headers.addAll(<String, String>{
              'Authorization': 'Bearer $apiKey',
              'Content-Type': 'application/json',
              'Accept': 'application/zip',
            })
            ..body = requestBodyJson;
          return _client.send(request).then((response) {
            RequestControl.cancellation?.throwIfCancelled();
            final headersElapsed = DateTime.now().difference(startedAt);
            AppLogger.info(
              'AgentApiClient',
              '图片请求收到响应头',
              metadata: {
                ...baseMetadata,
                'phase': phase,
                'statusCode': response.statusCode,
                'durationMs': headersElapsed.inMilliseconds,
                'contentType': response.headers['content-type'],
                'contentLength': response.headers['content-length'],
              },
            );
            phase = 'read_body';
            return response;
          });
        },
        policy: MediaRetryPolicy.submission,
        remaining: () => _remainingImageTimeout(startedAt),
        phase: 'novelai_submit',
      );
      final bytes = response.bodyBytes;
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
        ApiLogger.add(
          ApiLogEntry(
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
          ),
        );
        AppLogger.warning(
          'AgentApiClient',
          '图片请求返回非成功状态',
          metadata: {
            ...baseMetadata,
            'phase': phase,
            'statusCode': response.statusCode,
            'durationMs': durationMs,
            'contentType': contentType,
            'bodyBytes': bytes.length,
            'friendlyError': friendlyError,
            'errorBodyPreview': ApiLogger.safeSnippet(errorBody, max: 800),
          },
        );
        throw Exception(friendlyError);
      }

      phase = 'decode_body';
      final images = await _extractImageBytesFromNovelAIResponse(
        bytes,
        response.headers,
      );
      apiLogWritten = true;
      ApiLogger.add(
        ApiLogEntry(
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
        ),
      );
      AppLogger.info(
        'AgentApiClient',
        '图片请求完成',
        metadata: {
          ...baseMetadata,
          'phase': phase,
          'statusCode': response.statusCode,
          'durationMs': durationMs,
          'contentType': contentType,
          'bodyBytes': bytes.length,
          'imageCount': images.length,
        },
      );
      return ImageGenerationResult(
        images: images,
        provider: provider,
        model: model,
      );
    } on TimeoutException catch (e) {
      final durationMs = DateTime.now().difference(startedAt).inMilliseconds;
      if (!apiLogWritten) {
        ApiLogger.add(
          ApiLogEntry(
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
          ),
        );
      }
      AppLogger.warning(
        'AgentApiClient',
        '图片请求超时',
        metadata: {
          ...baseMetadata,
          'phase': phase,
          'durationMs': durationMs,
          'error': e.toString(),
        },
      );
      rethrow;
    } catch (e) {
      final durationMs = DateTime.now().difference(startedAt).inMilliseconds;
      if (!apiLogWritten) {
        ApiLogger.add(
          ApiLogEntry(
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
          ),
        );
      }
      AppLogger.warning(
        'AgentApiClient',
        '图片请求失败',
        metadata: {
          ...baseMetadata,
          'phase': phase,
          'durationMs': durationMs,
          'error': e.toString(),
        },
      );
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
    Map<String, String> headers,
  ) {
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
    _NovelAiCompiledPrompt? compiledPrompt,
    required int width,
    required int height,
    required int count,
    String? negativePrompt,
    int? steps,
    double? guidanceScale,
    int? seed,
    String? sampler,
  }) {
    final family = _novelAiModelFamily(model);
    final params = <String, dynamic>{
      'params_version': family == _NovelAiModelFamily.v5 ? 4 : 3,
      'width': width.clamp(256, 2048),
      'height': height.clamp(256, 2048),
      'n_samples': count.clamp(1, 4),
      'steps': (steps ?? 23).clamp(1, 50),
      'scale': (guidanceScale ?? (family == _NovelAiModelFamily.v5 ? 7.0 : 5.0))
          .clamp(0.0, 10.0),
      'sampler': (sampler != null && sampler.isNotEmpty)
          ? sampler
          : 'k_euler_ancestral',
      if (seed != null) 'seed': seed,
      if (negativePrompt != null && negativePrompt.isNotEmpty)
        'negative_prompt': negativePrompt,
    };
    // V5 与 V4 / V4.5 共用结构化提示词请求体，不携带 V3 legacy 字段。
    if (family != _NovelAiModelFamily.v3) {
      final compiled =
          compiledPrompt ?? _compileNovelAiStructuredPrompt(prompt);
      final v4Negative = (negativePrompt == null || negativePrompt.isEmpty)
          ? 'lowres'
          : negativePrompt;
      params.addAll(<String, dynamic>{
        if (compiled.isSectionProtocol) 'qualityToggle': false,
        if (compiled.isSectionProtocol) 'ucPreset': 3,
        'use_coords': compiled.useCoords,
        'characterPrompts': const <dynamic>[],
        'v4_prompt': <String, dynamic>{
          'caption': <String, dynamic>{
            'base_caption': compiled.baseCaption,
            'char_captions': compiled.charCaptions,
          },
          'use_coords': compiled.useCoords,
          'use_order': true,
        },
        'v4_negative_prompt': <String, dynamic>{
          'legacy_uc': false,
          'caption': <String, dynamic>{
            'base_caption': v4Negative,
            'char_captions': compiled.negativeCharCaptions,
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

  Future<List<Uint8List>> _extractImageBytesFromNovelAIResponse(
    Uint8List bytes, Map<String, String> headers,
  ) async {
    RequestControl.cancellation?.throwIfCancelled();
    final contentType = headers['content-type']?.toLowerCase() ?? '';
    final images = await _decodeNovelAiImageBytesInWorker(bytes, contentType);
    RequestControl.cancellation?.throwIfCancelled();
    return images;
  }

  _NovelAiCompiledPrompt _compileNovelAiStructuredPrompt(String prompt) {
    final sectionCompiled = _tryCompileNovelAiSectionProtocol(prompt);
    if (sectionCompiled != null) {
      return sectionCompiled;
    }
    final pipeSegments = _splitUnescapedPipeSegments(prompt);
    if (pipeSegments.length > 1) {
      final base = pipeSegments.first;
      final chars = pipeSegments.skip(1).toList(growable: false);
      return _NovelAiCompiledPrompt(
        baseCaption: base,
        charCaptions: <Map<String, dynamic>>[
          for (final c in chars)
            <String, dynamic>{
              'char_caption': c,
              'centers': const <Map<String, double>>[
                <String, double>{'x': 0.5, 'y': 0.5},
              ],
            },
        ],
        negativeCharCaptions: <Map<String, dynamic>>[
          for (var i = 0; i < chars.length; i++)
            <String, dynamic>{
              'char_caption': '',
              'centers': const <Map<String, double>>[
                <String, double>{'x': 0.5, 'y': 0.5},
              ],
            },
        ],
        useCoords: false,
      );
    }
    return _NovelAiCompiledPrompt.plain(prompt);
  }

  _NovelAiCompiledPrompt? _tryCompileNovelAiSectionProtocol(String raw) {
    final startMatch = RegExp(
      r'(?:^|(?:,\s*|\n))[ \t]*(@(?:page|panel|character|position)\b)',
      multiLine: true,
      caseSensitive: false,
    ).firstMatch(raw);
    if (startMatch == null) return null;
    final markerStart = raw.indexOf('@', startMatch.start);
    final variableRegex = RegExp(r'@c\d+(?:_[a-z0-9_]+)?\b\s*[,，]?\s*', caseSensitive: false);
    final unknownDirectiveRegex = RegExp(r'^\s*@[a-z_][a-z0-9_]*(?:[ \t]+[^,，\n]*)?$', caseSensitive: false);
    final leadingPrefix = raw.substring(0, markerStart).split('\n')
        .map((line) => line.replaceAll(variableRegex, ''))
        .where((line) => !unknownDirectiveRegex.hasMatch(line))
        .join('\n').trim().replaceFirst(RegExp(r'[,，]\s*$'), '').trim();
    final body = raw.substring(markerStart);
    final lines = body.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');
    final markerRegex = RegExp(
      r'^\s*@(page|panel|character|negative|non_character|position|center)\b(?:[ \t]+(.*?))?[ \t]*$',
      caseSensitive: false,
    );

    var useCoords = false;
    var pageBase = '';
    var pageNegative = '';
    var pageNonCharacter = '';
    final panels = <_NovelAiPanelDraft>[];
    _NovelAiPanelDraft? currentPanel;
    _NovelAiCharDraft? currentChar;
    var targetKind = 'page_base';
    final buffer = <String>[];

    void flush() {
      if (targetKind.isEmpty) {
        buffer.clear();
        return;
      }
      final content = buffer.join('\n').trim();
      buffer.clear();
      switch (targetKind) {
        case 'page_base':
          pageBase = [pageBase, content].where((s) => s.isNotEmpty).join('\n');
        case 'page_neg':
          pageNegative = [pageNegative, content].where((s) => s.isNotEmpty).join(', ');
        case 'page_non_char':
          pageNonCharacter = [pageNonCharacter, content].where((s) => s.isNotEmpty).join('\n');
        case 'panel_desc':
          if (currentPanel != null) currentPanel.description = [currentPanel.description, content].where((s) => s.isNotEmpty).join('\n');
        case 'panel_non_char':
          if (currentPanel != null) currentPanel.nonCharacter = [currentPanel.nonCharacter, content].where((s) => s.isNotEmpty).join('\n');
        case 'char_pos':
          if (currentChar != null) currentChar.positive = [currentChar.positive, content].where((s) => s.isNotEmpty).join('\n');
        case 'char_neg':
          if (currentChar != null) currentChar.negative = [currentChar.negative, content].where((s) => s.isNotEmpty).join('\n');
      }
    }

    for (final line in lines) {
      final match = markerRegex.firstMatch(line);
      if (match == null) {
        final cleanedLine = line.replaceAll(variableRegex, '');
        if (unknownDirectiveRegex.hasMatch(cleanedLine)) continue;
        if (targetKind.isNotEmpty) {
          buffer.add(cleanedLine);
        }
        continue;
      }
      flush();
      final kind = match.group(1)!.toLowerCase();
      final value = (match.group(2) ?? '').trim();
      switch (kind) {
        case 'position':
          useCoords = value.toLowerCase() == 'manual';
        case 'page':
          currentPanel = null;
          currentChar = null;
          targetKind = 'page_base';
        case 'panel':
          currentPanel = _NovelAiPanelDraft();
          panels.add(currentPanel);
          currentChar = null;
          targetKind = 'panel_desc';
        case 'character':
          if (currentPanel == null) {
              currentPanel = _NovelAiPanelDraft();
            panels.add(currentPanel);
          }
          currentChar = _NovelAiCharDraft();
          currentPanel.characters.add(currentChar);
          targetKind = 'char_pos';
        case 'negative':
          targetKind = currentChar == null ? 'page_neg' : 'char_neg';
        case 'non_character':
          currentChar = null;
          targetKind = currentPanel != null ? 'panel_non_char' : 'page_non_char';
        case 'center':
          if (currentChar != null) {
            final parts = value.split(RegExp(r'[,，]'));
            if (parts.length == 2) {
              final x = double.tryParse(parts[0].trim());
              final y = double.tryParse(parts[1].trim());
              if (x != null && y != null) {
                currentChar.centerX = x.clamp(0.0, 1.0);
                currentChar.centerY = y.clamp(0.0, 1.0);
              }
            }
          }
      }
    }
    flush();

    (String, List<String>) splitCaption(String raw) {
      final visuals = <String>[];
      final texts = <String>[];
      for (final line in raw.split('\n')) {
        final marker = RegExp(r'\bText[ \t]*[:：]', caseSensitive: false).firstMatch(line);
        if (marker == null) {
          visuals.add(line);
          continue;
        }
        final visual = line.substring(0, marker.start).trim().replaceFirst(RegExp(r'[,，]\s*$'), '');
        if (visual.isNotEmpty) visuals.add(visual);
        var dialogue = line.substring(marker.end).trim();
        if (dialogue.length >= 2 && ((dialogue.startsWith('"') && dialogue.endsWith('"')) || (dialogue.startsWith('“') && dialogue.endsWith('”')) || (dialogue.startsWith('「') && dialogue.endsWith('」')) || (dialogue.startsWith('『') && dialogue.endsWith('』')))) {
          dialogue = dialogue.substring(1, dialogue.length - 1).trim();
        }
        if (dialogue.isNotEmpty) texts.add(dialogue);
      }
      return (visuals.join('\n').trim(), texts);
    }

    final visuals = <String>[if (leadingPrefix.isNotEmpty) MangaPromptSanitizer.positive(leadingPrefix, raw)];
    final texts = <String>[];
    void addBase(String raw) {
      final (visual, dialogue) = splitCaption(raw);
      if (visual.isNotEmpty) visuals.add(visual.replaceFirst(RegExp(r'[,，]\s*$'), '').trim());
      texts.addAll(dialogue);
    }
    final (pageVisual, pageTexts) = splitCaption(pageBase);
    final (negativeVisual, negativeTexts) = splitCaption(pageNegative);
    pageNegative = negativeVisual;
    pageTexts.addAll(negativeTexts);
    addBase(MangaPromptSanitizer.positive(pageVisual, raw));
    texts.addAll(pageTexts);
    addBase(pageNonCharacter);
    final charCaptions = <Map<String, dynamic>>[];
    final negativeCharCaptions = <Map<String, dynamic>>[];
    for (final panel in panels) {
      addBase(panel.description);
      addBase(panel.nonCharacter);
      for (final c in panel.characters) {
        final (rawPos, dialogue) = splitCaption(c.positive);
        final pos = MangaPromptSanitizer.positive(rawPos, raw);
        final (rawNeg, negativeDialogue) = splitCaption(c.negative);
        texts.addAll(dialogue);
        texts.addAll(negativeDialogue);
        if (pos.isEmpty) continue;
        final center = <String, double>{'x': c.centerX, 'y': c.centerY};
        charCaptions.add(<String, dynamic>{'char_caption': pos, 'centers': <Map<String, double>>[center]});
        negativeCharCaptions.add(<String, dynamic>{'char_caption': MangaPromptSanitizer.negative(rawNeg), 'centers': <Map<String, double>>[center]});
      }
    }
    if (texts.isNotEmpty && !RegExp(r'(?:^|[,\n])\s*text\s*(?:[,\n]|$)', caseSensitive: false).hasMatch(visuals.join(', '))) visuals.add('text');
    if (texts.isNotEmpty && RegExp(r'[\u4e00-\u9fff]').hasMatch(texts.join('\n')) && !RegExp(r'(?:^|[,\n])\s*chinese text\s*(?:[,\n]|$)', caseSensitive: false).hasMatch(visuals.join(', '))) visuals.add('chinese text');
    final baseCaption = visuals.join(', ') + (texts.isNotEmpty ? '\nText: ${texts.join('\n\n')}' : '');
    return _NovelAiCompiledPrompt(
      baseCaption: baseCaption,
      isSectionProtocol: true,
      pageNegative: pageNegative,
      charCaptions: charCaptions,
      negativeCharCaptions: negativeCharCaptions,
      useCoords: useCoords,
    );
  }

  List<String> _splitUnescapedPipeSegments(String text) {
    if (!text.contains('|')) return <String>[text];
    final segments = <String>[];
    final buffer = StringBuffer();
    var escaped = false;
    for (var i = 0; i < text.length; i++) {
      final ch = text[i];
      if (escaped) {
        buffer.write(ch);
        escaped = false;
        continue;
      }
      if (ch == '\\') {
        buffer.write(ch);
        escaped = true;
        continue;
      }
      if (ch == '|') {
        final seg = buffer.toString().trim();
        if (seg.isNotEmpty) segments.add(seg);
        buffer.clear();
        continue;
      }
      buffer.write(ch);
    }
    final tail = buffer.toString().trim();
    if (tail.isNotEmpty) segments.add(tail);
    return segments;
  }
}

class _NovelAiCompiledPrompt {
  const _NovelAiCompiledPrompt({
    required this.baseCaption,
    required this.charCaptions,
    required this.negativeCharCaptions,
    required this.useCoords,
    this.isSectionProtocol = false,
    this.pageNegative = '',
  });

  factory _NovelAiCompiledPrompt.plain(String prompt) => _NovelAiCompiledPrompt(
        baseCaption: prompt,
        charCaptions: const <dynamic>[],
        negativeCharCaptions: const <dynamic>[],
        useCoords: false,
      );

  final String baseCaption;
  final String pageNegative;
  final List<dynamic> charCaptions;
  final List<dynamic> negativeCharCaptions;
  final bool useCoords;
  final bool isSectionProtocol;

  bool get isDoublePageSpread => RegExp(
        r'(?:見開きページ|2ページ見開き|見開き)|(?:double-page spread|2-page spread|wide spread)',
        caseSensitive: false,
      ).hasMatch(baseCaption);
}

class _NovelAiPanelDraft {
  String description = '';
  String nonCharacter = '';
  final List<_NovelAiCharDraft> characters = <_NovelAiCharDraft>[];
}

class _NovelAiCharDraft {
  String positive = '';
  String negative = '';
  double centerX = 0.5;
  double centerY = 0.5;
}

List<Uint8List> _decodeNovelAiImageBytes(Uint8List bytes, String contentType) {
    final isZip =
        contentType.contains('zip') ||
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

Future<List<Uint8List>> _decodeNovelAiImageBytesInWorker(Uint8List bytes, String contentType) =>
    Isolate.run(() => _decodeNovelAiImageBytes(bytes, contentType));
