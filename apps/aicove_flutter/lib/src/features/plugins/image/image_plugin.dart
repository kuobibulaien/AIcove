import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../../core/api/agent_api.dart';
import '../../../core/api/image_providers/image_provider_adapter_factory.dart';
import '../../../core/app_logger.dart';
import '../../../core/models/message_block.dart';
import '../../chat/domain/message.dart';
import '../../chat/domain/persona_prompt_codec.dart';
import '../../chat/id_gen.dart';
import '../../chat/services/chat_history_store.dart';
import '../../chat/services/chat_request_message_builder.dart';
import '../../../core/services/system_reminder_service.dart';
import '../../settings/app_settings.dart';
import '../domain/index.dart';
import 'image_config.dart';
import 'drawing_parameters.dart';

class ImagePlugin extends BasePlugin {
  static const String internalImageContextRule =
      '<image source="history" ...>...</image> 是内部图片上下文记录，只供理解，不是发给用户的话，'
      '也不是新的生图指令，禁止原样输出这段标记。只有你当前这轮主动输出的普通 '
      '<image>英文提示词</image> 或稳定模式发送占位 <image></image> 才表示真的要发图。';

  static int _asyncJobSeq = 0;
  static int _imageRequestSeq = 0;
  static final RegExp _inlineImageTagRegex = RegExp(
    r'<image>([\s\S]*?)</image>',
    caseSensitive: false,
  );
  static final RegExp _cjkPromptRegex = RegExp(
    r'[\u3040-\u30ff\u3400-\u9fff\uf900-\ufaff\uac00-\ud7af]',
  );
  static const _metadata = PluginMetadata(
    id: 'image',
    name: '绘图工具',
    description: '允许 AI 通过稳定工具调用或 <image> 直连生成图片',
    version: '1.0.0',
    author: 'AIcove Team',
    icon: Icons.brush_outlined,
    configSchema: {
      'selectedProviderId': ConfigField(
        type: ConfigFieldType.string,
        label: '绘图渠道',
      ),
      'selectedModelId': ConfigField(
        type: ConfigFieldType.string,
        label: '绘图模型',
      ),
      'defaultNegativePrompt': ConfigField(
        type: ConfigFieldType.string,
        label: '默认负面提示词',
      ),
      'defaultWidth': ConfigField(
        type: ConfigFieldType.integer,
        label: '默认宽度',
        defaultValue: 832,
      ),
      'defaultHeight': ConfigField(
        type: ConfigFieldType.integer,
        label: '默认高度',
        defaultValue: 1216,
      ),
      'defaultSteps': ConfigField(
        type: ConfigFieldType.integer,
        label: '默认步数',
        defaultValue: 28,
      ),
      'defaultGuidanceScale': ConfigField(
        type: ConfigFieldType.number,
        label: '默认提示词强度',
        defaultValue: 5.0,
      ),
      'defaultCount': ConfigField(
        type: ConfigFieldType.integer,
        label: '默认张数',
        defaultValue: 1,
      ),
      'timeoutSeconds': ConfigField(
        type: ConfigFieldType.integer,
        label: '超时时间 (秒)',
        defaultValue: 30,
      ),
    },
  );

  ImageConfig _config;
  final Ref _ref;

  final AppSettings? requestSettings;
  final bool isRequestSnapshot;

  ImagePlugin(
    this._config,
    this._ref, {
    this.requestSettings,
    this.isRequestSnapshot = false,
  }) : super(metadata: _metadata);

  AppSettings? get _settings =>
      requestSettings ?? _ref.read(appSettingsProvider).valueOrNull;
  Future<AppSettings> get _readySettings async =>
      requestSettings ?? await _ref.read(appSettingsProvider.future);

  @override
  bool get enabled {
    return _settings?.imageGenerationEnabled ?? false;
  }

  @override
  Future<void> onInitialize() async {
    await super.onInitialize();
    AppLogger.info('ImagePlugin', 'Image plugin initialized');
  }

  @override
  Future<void> onConfigChanged(Map<String, dynamic> newConfig) async {
    _config = ImageConfig.fromJson(newConfig);
  }

  @override
  Future<String?> getSystemPrompt({
    String? userMessage,
    bool supportsToolCalling = false,
  }) async {
    return buildTagSemanticsPrompt();
  }

  /// All drawing tag instructions belong to the enabled drawing plugin.
  String? buildRequestSystemPrompt({
    required bool useFastRoute,
    String? customDrawingPrompt,
    bool hasInternalImageContext = false,
    bool hasFailureReminder = false,
  }) {
    if (!enabled) return null;
    final parts = <String>[
      if (useFastRoute)
        buildInlineImageSystemPrompt(customDrawingPrompt: customDrawingPrompt),
      if (hasInternalImageContext) internalImageContextRule,
      if (hasFailureReminder)
        const SystemReminderService().buildReminderSemanticsPrompt(),
    ];
    final prompt = parts.where((part) => part.trim().isNotEmpty).join('\n\n');
    return prompt.isEmpty ? null : prompt;
  }

  String? buildImageFailureReminderContent(List<Message> history) {
    if (!enabled) return null;
    Map<String, dynamic>? lastFailurePayload;
    for (final message in history) {
      final blocks = message.blocks;
      if (blocks == null || blocks.isEmpty) continue;
      for (final block in blocks) {
        if (block is! ToolBlock) continue;
        final payload =
            ChatRequestMessageBuilder.extractInternalImageContextPayloadFromToolBlock(
              block,
            );
        if (payload == null || !_isFailedImageContextPayload(payload)) {
          continue;
        }
        lastFailurePayload = payload;
      }
    }
    if (lastFailurePayload == null) {
      return null;
    }

    final fields = <SystemReminderField>[
      const SystemReminderField(name: 'image_generation_failed', value: 'true'),
    ];

    void addField(String name, Object? rawValue) {
      final value = rawValue?.toString().trim() ?? '';
      if (value.isEmpty) return;
      fields.add(SystemReminderField(name: name, value: value));
    }

    addField('image_generation_failure_reason', lastFailurePayload['reason']);
    addField(
      'image_generation_failure_raw_prompt',
      lastFailurePayload['raw_prompt'],
    );
    addField('image_generation_failure_prompt', lastFailurePayload['prompt']);

    return const SystemReminderService().buildReminderContent(
      SystemReminderPayload(fields: fields),
    );
  }

  bool _isFailedImageContextPayload(Map<String, dynamic> payload) {
    final status = payload['status']?.toString().trim().toLowerCase();
    return status == 'failed' || payload['generation_failed'] == true;
  }

  @override
  List<AITool> getTools() {
    if (!enabled) return [];
    final settings = _settings;
    if (settings == null ||
        settings.callFlowSettings.mode == CallFlowMode.fast ||
        (!isRequestSnapshot && _resolveTarget(settings) == null)) {
      return [];
    }
    return [_drawImageTool];
  }

  @override
  Future<PluginProcessResult> processResponse(String text) async {
    if (!enabled) {
      return PluginProcessResult(
        processedText: text,
        events: const [],
        contents: const [],
      );
    }

    final matches = _inlineImageTagRegex
        .allMatches(text)
        .toList(growable: false);
    if (matches.isEmpty) {
      return PluginProcessResult(
        processedText: text,
        events: const [],
        contents: const [],
      );
    }

    final events = <PluginEvent>[];
    for (final match in matches) {
      final prompt = (match.group(1) ?? '').trim();
      if (prompt.isEmpty) {
        continue;
      }
      events.add(
        PluginEvent(
          pluginId: id,
          type: 'image_generate',
          data: <String, dynamic>{
            'prompt': prompt,
            'tag': match.group(0),
            'markerStart': match.start,
            'markerEnd': match.end,
            if (isRequestSnapshot) 'drawingConfig': _config.toJson(),
          },
        ),
      );
    }

    if (events.isEmpty) {
      return PluginProcessResult(
        processedText: text,
        events: const [],
        contents: const [],
      );
    }

    final processedText = _normalizeProcessedText(
      text.replaceAllMapped(_inlineImageTagRegex, (match) {
        final prompt = (match.group(1) ?? '').trim();
        return prompt.isEmpty ? match.group(0)! : '';
      }),
    );

    AppLogger.info(
      'ImagePlugin',
      '解析到 <image> 直连生图标签',
      metadata: {'events': events.length, 'textLength': text.length},
    );

    return PluginProcessResult(
      processedText: processedText,
      events: events,
      contents: const [],
    );
  }

  String buildInlineImageSystemPrompt({String? customDrawingPrompt}) {
    var template = _config.effectiveInlinePromptTemplate.trim();
    final novelAi = _settings == null ? false : _isNovelAi(_settings!);
    if (isRequestSnapshot) {
      template = template.replaceAll(
        '<image> 内只能写英文正向提示词，不要写中文、解释、JSON、代码块、负面提示词或参数说明',
        '<image> 内可写英文正向提示词，或使用下文定义的参数 JSON；不要写解释或代码块',
      );
    }
    final baseTemplate = isRequestSnapshot
        ? '$template\n\n【本次绘图参数契约】需要调整参数时，<image> 内可传 JSON：'
              '{"prompt":"English prompt","width":${_config.defaultWidth},"height":${_config.defaultHeight},"count":${_config.defaultCount}'
              '${novelAi ? ',"steps":${_config.defaultSteps},"guidance_scale":${_config.defaultGuidanceScale}' : ''}}。'
              '以上是参考值，可合理调整。除 prompt 外均可省略，省略时使用角色绘图预设；negative_prompt 可选。'
              '宽高范围 256–2048，张数 count 范围 1–4。'
              '${novelAi ? '宽高必须是64的倍数，steps为1–100整数，guidance_scale范围0–10。' : '当前渠道不支持 steps、guidance_scale。'}'
              '本次格式以此契约为准，禁止传入渠道或模型选择参数。'
        : template;
    final extraRule = customDrawingPrompt?.trim() ?? '';
    if (extraRule.isEmpty) {
      return baseTemplate;
    }
    return '$baseTemplate\n\n角色专属生图要求：\n$extraRule';
  }

  String? buildTagSemanticsPrompt({String? customDrawingPrompt}) {
    if (!enabled) {
      return null;
    }
    final settings = _settings;
    if (settings == null ||
        settings.callFlowSettings.mode != CallFlowMode.fast ||
        (!isRequestSnapshot && _resolveTarget(settings) == null)) {
      return null;
    }
    return buildInlineImageSystemPrompt(
      customDrawingPrompt: customDrawingPrompt,
    );
  }

  Future<InlineImageGenerationResult> regenerateImage(
    ImageGenerationSnapshot snapshot, {
    Iterable<ArtistPreset> knownArtistPresets = const [],
  }) async {
    final settings = await _readySettings;
    if (!settings.imageGenerationEnabled) throw StateError('请先开启绘图插件');
    final target = _resolveTarget(settings);
    if (target == null ||
        target.provider.id != snapshot.providerId ||
        target.modelId != snapshot.modelId ||
        _resolveRequestProvider(target.provider) != snapshot.requestProvider) {
      throw StateError('原图渠道或模型已不可用，未改用默认参数');
    }
    final (basePrompt, baseNegativePrompt) = _regenerationBasePrompts(
      snapshot,
      knownArtistPresets,
    );
    final artist = _config.selectedArtistPreset;
    final prompt = _mergeNegativePrompts(artist?.content, basePrompt)!;
    final negativePrompt = _mergeNegativePrompts(
      artist?.negativeContent,
      baseNegativePrompt,
    );
    final parameters = snapshot.singleImageParameters;
    // OpenAI-compatible channels apply these overrides after the normal fields.
    // Replace a saved duplicate, but never discard a different content override.
    for (final entry in {
      'prompt': snapshot.prompt,
      'negative_prompt': snapshot.negativePrompt,
    }.entries) {
      if (parameters.containsKey(entry.key)) {
        if (parameters[entry.key] != entry.value) {
          throw StateError('原图包含独立提示词覆盖，无法可靠替换画师串，原图已保留');
        }
        parameters[entry.key] = entry.key == 'prompt'
            ? prompt
            : negativePrompt ?? '';
      }
    }
    final saved = await _generateAndSaveImages(
      requestProvider: snapshot.requestProvider,
      providerId: snapshot.providerId,
      modelId: snapshot.modelId,
      prompt: prompt,
      negativePrompt: negativePrompt,
      basePrompt: basePrompt,
      baseNegativePrompt: baseNegativePrompt,
      width: snapshot.width,
      height: snapshot.height,
      count: 1,
      steps: snapshot.steps,
      guidanceScale: snapshot.guidanceScale,
      providerApiBase: target.provider.apiBaseUrl,
      providerApiKey: target.apiKey,
      customConfig: {
        ...target.provider.customConfig,
        'image_parameters': parameters,
      },
      requestSource: 'regenerate_image',
    );
    return InlineImageGenerationResult.success(
      localPath: saved.paths.first,
      localPaths: saved.paths,
      rawPrompt: basePrompt,
      prompt: prompt,
      negativePrompt: negativePrompt,
      artistPresetName: artist?.name,
      artistPresetSource: artist == null ? 'none' : 'current_preset',
      generationSnapshot: saved.snapshot,
    );
  }

  (String, String?) _regenerationBasePrompts(
    ImageGenerationSnapshot snapshot,
    Iterable<ArtistPreset> knownArtists,
  ) {
    if (snapshot.basePrompt != null) {
      return (snapshot.basePrompt!, snapshot.baseNegativePrompt);
    }
    // Old snapshots only contain the combined prompt. Recover an exact known
    // prefix, including its negative prefix; never guess by splitting tags.
    final candidates = <(String, String?)>{};
    for (final artist in knownArtists) {
      final prefix = artist.content.trim();
      if (prefix.isEmpty || !snapshot.prompt.startsWith('$prefix, ')) continue;
      final base = snapshot.prompt.substring(prefix.length + 2);
      if (base.trim().isEmpty) continue;
      var negative = snapshot.negativePrompt;
      final artistNegative = artist.negativeContent.trim();
      if (artistNegative.isNotEmpty) {
        if (negative == artistNegative) {
          negative = null;
        } else if (negative?.startsWith('$artistNegative, ') ?? false) {
          negative = negative!.substring(artistNegative.length + 2);
        } else {
          continue;
        }
      }
      candidates.add((base, negative));
    }
    if (candidates.length == 1) return candidates.single;
    throw StateError('这张旧图未保存画师串分离信息，无法可靠替换画风。请用原画面提示词新生成一次');
  }

  Future<InlineImageGenerationResult> generateInlineImage({
    required String prompt,
    String? roleArtistPresetName,
  }) async {
    var rawPrompt = prompt.trim();
    var inlineArgs = <String, dynamic>{};
    // NovelAI 的 {{{pov}}} 等权重语法不是 JSON 对象。
    if (RegExp(r'^\{\s*"').hasMatch(rawPrompt)) {
      try {
        inlineArgs = Map<String, dynamic>.from(jsonDecode(rawPrompt) as Map);
        rawPrompt = (inlineArgs['prompt'] as String? ?? '').trim();
      } catch (_) {
        return const InlineImageGenerationResult.failure('图片参数 JSON 格式不正确');
      }
    }
    if (rawPrompt.isEmpty) {
      return const InlineImageGenerationResult.failure('prompt is empty');
    }
    if (_settings != null &&
        _isNovelAi(_settings!) &&
        _containsDisallowedPromptChars(rawPrompt)) {
      return const InlineImageGenerationResult.failure(
        'inline image prompt must be English for NovelAI',
      );
    }

    _ImageTarget? resolvedTarget;
    try {
      final settings = await _readySettings;
      if (!settings.imageGenerationEnabled) {
        return const InlineImageGenerationResult.failure(
          'image plugin is disabled',
        );
      }

      resolvedTarget = _resolveTarget(settings);
      if (resolvedTarget == null) {
        return const InlineImageGenerationResult.failure(
          'no configured image provider/model in provider settings',
        );
      }

      final promptBundle = _buildPromptBundle(
        rawPrompt: rawPrompt,
        runtimeNegativePrompt: inlineArgs['negative_prompt'] as String?,
        roleArtistPresetName: roleArtistPresetName,
      );
      final requestProvider = _resolveRequestProvider(resolvedTarget.provider);
      final parameters = DrawingParameters.resolve(
        _config,
        inlineArgs,
        novelAi: requestProvider == 'novelai',
      );
      final saved = await _generateAndSaveImages(
        requestProvider: requestProvider,
        providerId: resolvedTarget.provider.id,
        modelId: resolvedTarget.modelId,
        prompt: promptBundle.prompt,
        negativePrompt: promptBundle.negativePrompt,
        basePrompt: promptBundle.rawPrompt,
        baseNegativePrompt: promptBundle.baseNegativePrompt,
        width: parameters.width,
        height: parameters.height,
        count: parameters.count,
        steps: parameters.steps,
        guidanceScale: parameters.guidanceScale,
        providerApiBase: resolvedTarget.provider.apiBaseUrl,
        providerApiKey: resolvedTarget.apiKey,
        customConfig: resolvedTarget.provider.customConfig,
        requestSource: 'inline_image',
        flowMode: 'fast',
      );
      if (saved.paths.isEmpty) {
        return const InlineImageGenerationResult.failure(
          'provider returned no images',
        );
      }

      AppLogger.info(
        'ImagePlugin',
        '直连 <image> 生图完成',
        metadata: {
          'provider': resolvedTarget.provider.id,
          'model': resolvedTarget.modelId,
          'artistPresetName': promptBundle.artistPreset?.name,
        },
      );

      return InlineImageGenerationResult.success(
        localPath: saved.paths.first,
        localPaths: saved.paths,
        generationSnapshot: saved.snapshot,
        rawPrompt: rawPrompt,
        prompt: promptBundle.prompt,
        negativePrompt: promptBundle.negativePrompt,
        artistPresetName: promptBundle.artistPreset?.name,
        artistPresetSource: promptBundle.artistPresetSource,
      );
    } catch (e) {
      AppLogger.warning(
        'ImagePlugin',
        '直连 <image> 生图失败',
        metadata: {
          'error': e.toString(),
          'selectedProviderId': _config.selectedProviderId,
          'selectedModelId': _config.selectedModelId,
          'resolvedProviderId': resolvedTarget?.provider.id,
          'resolvedModelId': resolvedTarget?.modelId,
        },
      );
      return InlineImageGenerationResult.failure(e.toString());
    }
  }

  Future<String?> runDrawImageToolForDebug({
    required String prompt,
    String? negativePrompt,
    int? width,
    int? height,
  }) {
    return _handleDrawImage({
      'prompt': prompt,
      if (negativePrompt != null) 'negative_prompt': negativePrompt,
      'width': width ?? _config.defaultWidth,
      'height': height ?? _config.defaultHeight,
      '_aicove_flow_mode': 'settings_test',
    });
  }

  AITool get _drawImageTool => AITool(
    name: 'draw_image',
    description: _config.effectiveToolDescriptionBlocks.toolDescription,
    parameters: {
      'prompt': ToolParameter(
        type: 'string',
        description: _config.effectiveToolDescriptionBlocks.promptDescription,
        required: true,
      ),
      'negative_prompt': ToolParameter(
        type: 'string',
        description:
            _config.effectiveToolDescriptionBlocks.negativePromptDescription,
        required: false,
      ),
      'width': ToolParameter(
        type: 'integer',
        description:
            '${_config.effectiveToolDescriptionBlocks.widthDescription} 参考值 ${_config.defaultWidth}，可省略。',
        required: false,
      ),
      'height': ToolParameter(
        type: 'integer',
        description:
            '${_config.effectiveToolDescriptionBlocks.heightDescription} 参考值 ${_config.defaultHeight}，可省略。',
        required: false,
      ),
      'count': ToolParameter(
        type: 'integer',
        description: '生成张数 1–4，参考 ${_config.defaultCount}，可省略。',
      ),
      if (_settings != null && _isNovelAi(_settings!)) ...{
        'steps': ToolParameter(
          type: 'integer',
          description: '采样步数 1–100，参考 ${_config.defaultSteps}，可合理调整。',
        ),
        'guidance_scale': ToolParameter(
          type: 'number',
          description: '提示词强度 0–10，参考 ${_config.defaultGuidanceScale}，可合理调整。',
        ),
      },
    },
    handler: _handleDrawImage,
  );

  Future<String?> _handleDrawImage(Map<String, dynamic> rawArgs) async {
    final args = Map<String, dynamic>.from(rawArgs);
    final asyncRequested = _readInternalBool(args.remove('_aicove_async'));
    final flowMode = (args.remove('_aicove_flow_mode') ?? '').toString().trim();
    final sessionId = (args.remove('_aicove_session_id') ?? '')
        .toString()
        .trim();
    final turnId = (args.remove('_aicove_turn_id') ?? '').toString().trim();
    final roleToolPresetName =
        (args.remove('_aicove_role_tool_preset_name') ?? '').toString().trim();
    final roleArtistPresetName =
        (args.remove('_aicove_role_artist_preset_name') ?? '')
            .toString()
            .trim();

    final rawPrompt = (args['prompt'] as String?)?.trim() ?? '';
    if (rawPrompt.isEmpty) {
      return jsonEncode({'success': false, 'error': 'prompt is empty'});
    }

    _ImageTarget? resolvedTarget;
    try {
      final settings = await _readySettings;
      if (!settings.imageGenerationEnabled) {
        return jsonEncode({
          'success': false,
          'error': 'image plugin is disabled',
        });
      }

      resolvedTarget = _resolveTarget(settings);
      if (resolvedTarget == null) {
        return jsonEncode({
          'success': false,
          'error': 'no configured image provider/model in provider settings',
        });
      }

      final promptBundle = _buildPromptBundle(
        rawPrompt: rawPrompt,
        runtimeNegativePrompt: (args['negative_prompt'] as String?)?.trim(),
        roleArtistPresetName: roleArtistPresetName,
      );
      final prompt = promptBundle.prompt;

      final parameters = DrawingParameters.resolve(
        _config,
        args,
        novelAi: _resolveRequestProvider(resolvedTarget.provider) == 'novelai',
      );
      final width = parameters.width;
      final height = parameters.height;
      final steps = parameters.steps;
      final count = parameters.count;
      final guidanceScale = parameters.guidanceScale;
      final negativePrompt = promptBundle.negativePrompt;

      final requestProvider = _resolveRequestProvider(resolvedTarget.provider);
      final canRunAsync = asyncRequested && sessionId.isNotEmpty;
      if (canRunAsync) {
        final jobId = _nextAsyncJobId();
        AppLogger.info(
          'ImagePlugin',
          'Accepted async draw_image job',
          metadata: {
            'jobId': jobId,
            'sessionId': sessionId,
            'turnId': turnId,
            'flowMode': flowMode,
            'roleToolPreset': roleToolPresetName,
            'roleArtistPreset': roleArtistPresetName,
            'provider': resolvedTarget.provider.id,
            'model': resolvedTarget.modelId,
          },
        );
        unawaited(
          _runAsyncImageJob(
            jobId: jobId,
            sessionId: sessionId,
            turnId: turnId,
            flowMode: flowMode,
            providerId: resolvedTarget.provider.id,
            modelId: resolvedTarget.modelId,
            requestProvider: requestProvider,
            prompt: prompt,
            negativePrompt: negativePrompt,
            basePrompt: promptBundle.rawPrompt,
            baseNegativePrompt: promptBundle.baseNegativePrompt,
            width: width,
            height: height,
            count: count,
            steps: steps,
            guidanceScale: guidanceScale,
            providerApiBase: resolvedTarget.provider.apiBaseUrl,
            providerApiKey: resolvedTarget.apiKey,
            customConfig: resolvedTarget.provider.customConfig,
          ),
        );
        return jsonEncode({
          'success': true,
          'accepted': true,
          'status': 'pending',
          'job_id': jobId,
          'provider': resolvedTarget.provider.id,
          'model': resolvedTarget.modelId,
          'raw_prompt': rawPrompt,
          'prompt': prompt,
          'negative_prompt': negativePrompt,
          'artist_preset_name': promptBundle.artistPreset?.name,
          'artist_preset_source': promptBundle.artistPresetSource,
          if (promptBundle.artistPromptPrefix.isNotEmpty)
            'artist_prompt_prefix': promptBundle.artistPromptPrefix,
          if (promptBundle.artistNegativePrompt.isNotEmpty)
            'artist_negative_prompt': promptBundle.artistNegativePrompt,
          'image_count': 0,
          'message': 'image job accepted',
        });
      }

      final saved = await _generateAndSaveImages(
        requestProvider: requestProvider,
        providerId: resolvedTarget.provider.id,
        modelId: resolvedTarget.modelId,
        prompt: prompt,
        negativePrompt: negativePrompt,
        basePrompt: promptBundle.rawPrompt,
        baseNegativePrompt: promptBundle.baseNegativePrompt,
        width: width,
        height: height,
        count: count,
        steps: steps,
        guidanceScale: guidanceScale,
        providerApiBase: resolvedTarget.provider.apiBaseUrl,
        providerApiKey: resolvedTarget.apiKey,
        customConfig: resolvedTarget.provider.customConfig,
        requestSource: 'draw_image',
        flowMode: flowMode.isEmpty ? 'stable' : flowMode,
      );

      AppLogger.info(
        'ImagePlugin',
        'Image generated by tool',
        metadata: {
          'provider': resolvedTarget.provider.id,
          'model': resolvedTarget.modelId,
          'roleToolPreset': roleToolPresetName,
          'roleArtistPreset': roleArtistPresetName,
          'count': saved.paths.length,
        },
      );

      return jsonEncode({
        'success': true,
        'provider': resolvedTarget.provider.id,
        'model': resolvedTarget.modelId,
        'raw_prompt': rawPrompt,
        'prompt': prompt,
        'negative_prompt': negativePrompt,
        'artist_preset_name': promptBundle.artistPreset?.name,
        'artist_preset_source': promptBundle.artistPresetSource,
        if (promptBundle.artistPromptPrefix.isNotEmpty)
          'artist_prompt_prefix': promptBundle.artistPromptPrefix,
        if (promptBundle.artistNegativePrompt.isNotEmpty)
          'artist_negative_prompt': promptBundle.artistNegativePrompt,
        'images': [
          for (final localPath in saved.paths)
            {
              'localPath': localPath,
              'caption': prompt,
              if (saved.snapshot != null)
                'generationSnapshot': saved.snapshot!.toJson(),
            },
        ],
        'message': 'image generated',
      });
    } catch (e) {
      AppLogger.warning(
        'ImagePlugin',
        'draw_image failed',
        metadata: {
          'error': e.toString(),
          'asyncRequested': asyncRequested,
          'flowMode': flowMode,
          'sessionId': sessionId,
          'turnId': turnId,
          'selectedProviderId': _config.selectedProviderId,
          'selectedModelId': _config.selectedModelId,
          'resolvedProviderId': resolvedTarget?.provider.id,
          'resolvedModelId': resolvedTarget?.modelId,
          'resolvedProviderApiBase': resolvedTarget?.provider.apiBaseUrl,
          'resolvedRequestProvider': resolvedTarget == null
              ? null
              : _resolveRequestProvider(resolvedTarget.provider),
        },
      );
      return jsonEncode({'success': false, 'error': e.toString()});
    }
  }

  Future<_SavedImages> _generateAndSaveImages({
    required String requestProvider,
    required String providerId,
    required String modelId,
    required String prompt,
    required String? negativePrompt,
    required int width,
    required int height,
    required int count,
    required int steps,
    required double guidanceScale,
    required String providerApiBase,
    required String providerApiKey,
    required Map<String, dynamic> customConfig,
    required String basePrompt,
    required String? baseNegativePrompt,
    required String requestSource,
    String? flowMode,
  }) async {
    final requestId = _nextImageRequestId();
    final metadata = <String, dynamic>{
      'requestId': requestId,
      'requestSource': requestSource,
      if (flowMode != null && flowMode.trim().isNotEmpty)
        'flowMode': flowMode.trim(),
      'providerId': providerId,
      'requestProvider': requestProvider,
      'modelId': modelId,
      'promptLength': prompt.length,
      'negativePromptLength': negativePrompt?.length ?? 0,
      'width': width,
      'height': height,
      'count': count,
      'steps': steps,
      'guidanceScale': guidanceScale,
      'timeoutSeconds': _config.timeoutSeconds,
    };
    final snapshot = ImageGenerationSnapshot.tryRead({
      'version': 1,
      'providerId': providerId,
      'modelId': modelId,
      'requestProvider': requestProvider,
      'prompt': prompt,
      'negativePrompt': negativePrompt,
      'width': width,
      'height': height,
      'steps': steps,
      'guidanceScale': guidanceScale,
      'basePrompt': basePrompt,
      'baseNegativePrompt': baseNegativePrompt,
      'customParameters':
          customConfig['image_parameters'] ?? <String, dynamic>{},
    });
    AppLogger.info('ImagePlugin', '图片生成请求开始', metadata: metadata);
    final client = AgentApiClient(
      timeout: Duration(seconds: _config.timeoutSeconds),
    );
    late final ImageGenerationResult result;
    try {
      result = await client.generateImage(
        provider: requestProvider,
        model: modelId,
        prompt: prompt,
        negativePrompt: negativePrompt,
        width: width,
        height: height,
        count: count,
        steps: steps,
        guidanceScale: guidanceScale,
        providerApiBase: providerApiBase,
        providerApiKey: providerApiKey,
        customConfig: customConfig,
        requestId: requestId,
        requestSource: requestSource,
        flowMode: flowMode,
      );
    } catch (e) {
      AppLogger.warning(
        'ImagePlugin',
        '图片生成请求失败',
        metadata: {...metadata, 'error': e.toString()},
      );
      rethrow;
    }

    if (result.images.isEmpty) {
      AppLogger.warning('ImagePlugin', '图片生成请求返回空结果', metadata: metadata);
      throw StateError('provider returned no images');
    }

    AppLogger.info(
      'ImagePlugin',
      '图片生成请求成功',
      metadata: {...metadata, 'imageCount': result.images.length},
    );

    return _SavedImages(
      await _saveImages(
        bytesList: result.images,
        providerId: providerId,
        modelId: modelId,
      ),
      snapshot,
    );
  }

  Future<void> _runAsyncImageJob({
    required String jobId,
    required String sessionId,
    required String turnId,
    required String flowMode,
    required String providerId,
    required String modelId,
    required String requestProvider,
    required String prompt,
    required String? negativePrompt,
    required int width,
    required int height,
    required int count,
    required int steps,
    required double guidanceScale,
    required String providerApiBase,
    required String providerApiKey,
    required Map<String, dynamic> customConfig,
    required String basePrompt,
    required String? baseNegativePrompt,
  }) async {
    try {
      final saved = await _generateAndSaveImages(
        requestProvider: requestProvider,
        providerId: providerId,
        modelId: modelId,
        prompt: prompt,
        negativePrompt: negativePrompt,
        basePrompt: basePrompt,
        baseNegativePrompt: baseNegativePrompt,
        width: width,
        height: height,
        count: count,
        steps: steps,
        guidanceScale: guidanceScale,
        providerApiBase: providerApiBase,
        providerApiKey: providerApiKey,
        customConfig: customConfig,
        requestSource: 'draw_image_async',
        flowMode: flowMode.isEmpty ? 'fast' : flowMode,
      );

      await _appendGeneratedImagesToConversation(
        sessionId: sessionId,
        prompt: prompt,
        localPaths: saved.paths,
        generationSnapshot: saved.snapshot,
      );
      AppLogger.info(
        'ImagePlugin',
        'Async draw_image job completed',
        metadata: {
          'jobId': jobId,
          'sessionId': sessionId,
          'turnId': turnId,
          'provider': providerId,
          'model': modelId,
          'count': saved.paths.length,
        },
      );
    } catch (e) {
      AppLogger.warning(
        'ImagePlugin',
        'Async draw_image job failed',
        metadata: {
          'jobId': jobId,
          'sessionId': sessionId,
          'turnId': turnId,
          'provider': providerId,
          'model': modelId,
          'error': e.toString(),
        },
      );
    }
  }

  Future<void> _appendGeneratedImagesToConversation({
    required String sessionId,
    required String prompt,
    required List<String> localPaths,
    ImageGenerationSnapshot? generationSnapshot,
  }) async {
    if (localPaths.isEmpty || sessionId.isEmpty) return;
    final now = DateTime.now();
    final appended = <Message>[
      for (final localPath in localPaths)
        () {
          final messageId = genId('img');
          return Message.fromBlocks(
            id: messageId,
            role: 'assistant',
            blocks: [
              ImageBlock(
                messageId: messageId,
                localPath: localPath,
                prompt: prompt,
                generationSnapshot: generationSnapshot,
              ),
            ],
            createdAt: now,
            status: 'sent',
          );
        }(),
    ];

    for (final message in appended) {
      await _ref
          .read(chatHistoryStoreProvider)
          .appendMessage(
            conversationId: sessionId,
            message: message,
            lastMessagePreview: message.displayText,
          );
    }
  }

  _ImageTarget? _resolveTarget(AppSettings settings) {
    final selectedModelRef = _config.selectedModelId?.trim();
    final selectedProviderIdFromModel =
        selectedModelRef == null || selectedModelRef.isEmpty
        ? null
        : settings.getModelProviderId(selectedModelRef);
    final selectedRawModelId =
        selectedModelRef == null || selectedModelRef.isEmpty
        ? null
        : settings.getRawModelId(selectedModelRef);

    final selectedProviderId = _config.selectedProviderId?.trim();
    if (selectedProviderId != null &&
        selectedProviderId.isNotEmpty &&
        selectedProviderIdFromModel != null &&
        selectedProviderIdFromModel.isNotEmpty &&
        selectedProviderId != selectedProviderIdFromModel) {
      return null;
    }
    ProviderAuth? provider;
    if (selectedProviderIdFromModel != null &&
        selectedProviderIdFromModel.isNotEmpty) {
      provider = settings.providers
          .where((p) => p.id == selectedProviderIdFromModel)
          .firstOrNull;
      if (provider != null && !_isProviderUsable(provider)) {
        provider = null;
      }
    }

    if (provider == null &&
        _config.selectedProviderId != null &&
        _config.selectedProviderId!.trim().isNotEmpty) {
      provider = settings.providers
          .where((p) => p.id == _config.selectedProviderId)
          .firstOrNull;
      if (provider != null && !_isProviderUsable(provider)) {
        provider = null;
      }
    }

    // 显式绑定失效必须报错，禁止换到其它渠道消耗额度。
    if (provider == null &&
        ((selectedModelRef?.isNotEmpty ?? false) ||
            (_config.selectedProviderId?.isNotEmpty ?? false))) {
      return null;
    }
    provider ??= settings.providers.firstWhere(
      (p) => _isProviderUsable(p) && _imageModelsOf(settings, p).isNotEmpty,
      orElse: () => const ProviderAuth(id: '', apiBaseUrl: '', apiKeys: []),
    );
    if (provider.id.isEmpty) return null;
    final resolvedProvider = provider;

    final allModels = _imageModelsOf(settings, resolvedProvider);
    final configuredModel = resolvedProvider.customConfig['defaultImageModel']
        ?.toString()
        .trim();
    final modelId = () {
      if (selectedRawModelId != null &&
          selectedRawModelId.isNotEmpty &&
          (selectedProviderIdFromModel == null ||
              selectedProviderIdFromModel == resolvedProvider.id)) {
        return allModels.contains(selectedRawModelId) ? selectedRawModelId : '';
      }
      if (configuredModel != null &&
          configuredModel.isNotEmpty &&
          allModels.contains(configuredModel)) {
        return configuredModel;
      }
      if (allModels.isNotEmpty) return allModels.first;
      return '';
    }();
    if (modelId.isEmpty) return null;

    final apiKey = resolvedProvider.apiKeys.isNotEmpty
        ? resolvedProvider.apiKeys.first
        : '';
    if (apiKey.trim().isEmpty) return null;
    return _ImageTarget(
      provider: resolvedProvider,
      modelId: modelId,
      apiKey: apiKey.trim(),
    );
  }

  bool _isProviderUsable(ProviderAuth provider) {
    if (!provider.enabled) return false;
    if (provider.apiKeys.isEmpty || provider.apiKeys.first.trim().isEmpty) {
      return false;
    }
    return true;
  }

  List<String> _imageModelsOf(AppSettings settings, ProviderAuth provider) {
    return settings.getProviderVisibleModelsByType(
      provider.id,
      type: ModelType.image,
    );
  }

  String _resolveRequestProvider(ProviderAuth provider) {
    return ImageProviderAdapterFactory.resolveProvider(
      provider.id,
      customConfig: provider.customConfig,
    );
  }

  Future<List<String>> _saveImages({
    required List<Uint8List> bytesList,
    required String providerId,
    required String modelId,
  }) async {
    final appDir = await getApplicationDocumentsDirectory();
    final outputDir = Directory(
      p.join(appDir.path, 'generated_images', providerId, modelId),
    );
    if (!await outputDir.exists()) {
      await outputDir.create(recursive: true);
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    final paths = <String>[];
    for (var i = 0; i < bytesList.length; i++) {
      final ext = _guessImageExtension(bytesList[i]);
      final filePath = p.join(outputDir.path, '${now}_${i + 1}.$ext');
      final file = File(filePath);
      await file.writeAsBytes(bytesList[i], flush: true);
      paths.add(file.path);
    }
    return paths;
  }

  String _guessImageExtension(Uint8List bytes) {
    if (bytes.length > 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      return 'png';
    }
    if (bytes.length > 3 && bytes[0] == 0xFF && bytes[1] == 0xD8) {
      return 'jpg';
    }
    if (bytes.length > 12 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return 'webp';
    }
    return 'png';
  }

  bool _isNovelAi(AppSettings settings) {
    final target = _resolveTarget(settings);
    return target != null &&
        _resolveRequestProvider(target.provider) == 'novelai';
  }

  bool _readInternalBool(dynamic value) {
    if (value is bool) return value;
    final text = value?.toString().trim().toLowerCase();
    return text == 'true' || text == '1' || text == 'yes';
  }

  String _nextAsyncJobId() {
    _asyncJobSeq += 1;
    return 'image_job_${DateTime.now().microsecondsSinceEpoch}_$_asyncJobSeq';
  }

  String _nextImageRequestId() {
    _imageRequestSeq += 1;
    return 'img_${DateTime.now().microsecondsSinceEpoch}_$_imageRequestSeq';
  }

  _ImagePromptBundle _buildPromptBundle({
    required String rawPrompt,
    String? runtimeNegativePrompt,
    String? roleArtistPresetName,
  }) {
    if (isRequestSnapshot) roleArtistPresetName = null;
    ArtistPreset? artistPreset = _config.selectedArtistPreset;
    var artistPresetSource = 'none';
    final normalizedRoleArtistPresetName = roleArtistPresetName?.trim() ?? '';
    if (normalizedRoleArtistPresetName ==
        PersonaPromptCodec.artistPresetDisabledBinding) {
      artistPreset = null;
      artistPresetSource = 'role_disabled';
    } else if (normalizedRoleArtistPresetName.isNotEmpty) {
      artistPreset = _config.artistPresets
          .where((preset) => preset.name == normalizedRoleArtistPresetName)
          .firstOrNull;
      artistPresetSource = artistPreset == null
          ? 'role_bound_missing'
          : 'role_bound';
    } else if (artistPreset != null) {
      artistPresetSource = 'global_selected';
    }

    final artistPromptPrefix = artistPreset?.content.trim() ?? '';
    final prompt = artistPromptPrefix.isNotEmpty
        ? '$artistPromptPrefix, $rawPrompt'
        : rawPrompt;
    final artistNegativePrompt = artistPreset?.negativeContent.trim() ?? '';
    final baseNegativePrompt = _mergeNegativePrompts(
      _config.defaultNegativePrompt,
      runtimeNegativePrompt,
    );
    final negativePrompt = _mergeNegativePrompts(
      artistNegativePrompt,
      baseNegativePrompt,
    );

    return _ImagePromptBundle(
      rawPrompt: rawPrompt,
      prompt: prompt,
      negativePrompt: negativePrompt,
      baseNegativePrompt: baseNegativePrompt,
      artistPreset: artistPreset,
      artistPresetSource: artistPresetSource,
      artistPromptPrefix: artistPromptPrefix,
      artistNegativePrompt: artistNegativePrompt,
    );
  }

  String? _mergeNegativePrompts(String? defaultText, String? runtimeText) {
    final a = defaultText?.trim() ?? '';
    final b = runtimeText?.trim() ?? '';
    if (a.isEmpty && b.isEmpty) return null;
    if (a.isEmpty) return b;
    if (b.isEmpty) return a;
    return '$a, $b';
  }

  @override
  void updateConfig(Map<String, dynamic> config) {
    _config = ImageConfig.fromJson(config);
  }

  @override
  Map<String, dynamic> getConfig() => _config.toJson();

  bool _containsDisallowedPromptChars(String text) =>
      _cjkPromptRegex.hasMatch(text);

  String _normalizeProcessedText(String text) {
    var normalized = text;
    normalized = normalized.replaceAll(RegExp(r'[ \t]{2,}'), ' ');
    normalized = normalized.replaceAll(RegExp(r'\n{3,}'), '\n\n');
    return normalized.trim();
  }
}

class _ImageTarget {
  final ProviderAuth provider;
  final String modelId;
  final String apiKey;

  const _ImageTarget({
    required this.provider,
    required this.modelId,
    required this.apiKey,
  });
}

class _ImagePromptBundle {
  final String rawPrompt;
  final String prompt;
  final String? negativePrompt;
  final String? baseNegativePrompt;
  final ArtistPreset? artistPreset;
  final String artistPresetSource;
  final String artistPromptPrefix;
  final String artistNegativePrompt;

  const _ImagePromptBundle({
    required this.rawPrompt,
    required this.prompt,
    required this.negativePrompt,
    required this.artistPreset,
    required this.baseNegativePrompt,
    required this.artistPresetSource,
    required this.artistPromptPrefix,
    required this.artistNegativePrompt,
  });
}

class InlineImageGenerationResult {
  final bool success;
  final String? localPath;
  final List<String> localPaths;
  final String? rawPrompt;
  final String? prompt;
  final String? negativePrompt;
  final String? artistPresetName;
  final String? artistPresetSource;
  final String? error;
  final ImageGenerationSnapshot? generationSnapshot;

  const InlineImageGenerationResult.success({
    required this.localPath,
    this.localPaths = const [],
    required this.rawPrompt,
    required this.prompt,
    required this.negativePrompt,
    required this.artistPresetName,
    required this.artistPresetSource,
    this.generationSnapshot,
  }) : success = true,
       error = null;

  const InlineImageGenerationResult.failure(this.error)
    : success = false,
      localPath = null,
      localPaths = const [],
      rawPrompt = null,
      prompt = null,
      negativePrompt = null,
      artistPresetName = null,
      artistPresetSource = null,
      generationSnapshot = null;
}

class _SavedImages {
  const _SavedImages(this.paths, this.snapshot);
  final List<String> paths;
  final ImageGenerationSnapshot? snapshot;
}
