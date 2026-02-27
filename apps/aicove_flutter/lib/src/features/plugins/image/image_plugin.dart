import 'dart:convert';
import 'dart:typed_data';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../../core/api/agent_api.dart';
import '../../../core/app_logger.dart';
import '../../settings/app_settings.dart';
import '../domain/index.dart';
import 'image_config.dart';

class ImagePlugin extends BasePlugin {
  static final _metadata = PluginMetadata(
    id: 'image',
    name: '绘图工具',
    description: '允许 AI 通过原生工具调用生成图片',
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

  ImagePlugin(this._config, this._ref) : super(metadata: _metadata);

  @override
  bool get enabled {
    final settings = _ref.read(appSettingsProvider).valueOrNull;
    return settings?.imageGenerationEnabled ?? false;
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
    if (!enabled || !supportsToolCalling) return null;
    final settings = _ref.read(appSettingsProvider).valueOrNull;
    if (settings == null || _resolveTarget(settings) == null) return null;
    return _config.effectiveSystemPrompt;
  }

  @override
  List<AITool> getTools() {
    if (!enabled) return [];
    final settings = _ref.read(appSettingsProvider).valueOrNull;
    if (settings == null || _resolveTarget(settings) == null) return [];
    return [_drawImageTool];
  }

  @override
  Future<PluginProcessResult> processResponse(String text) async {
    return PluginProcessResult(
      processedText: text,
      events: const [],
      contents: const [],
    );
  }

  AITool get _drawImageTool => AITool(
        name: 'draw_image',
        description:
            '根据提示词生成图片。以 Danbooru 标签为骨架，场景或姿势越复杂越需要用英文自然语言补充细节。多角色用 | 分隔基底和各角色段，交互用 source#/target#/mutual# 前缀。权重：{} 加强、[] 减弱、1.4::...:: 数值权重。',
        parameters: {
          'prompt': ToolParameter(
            type: 'string',
            description: '图片提示词。Danbooru tag + 可选英文短句。多角色用 | 分隔。',
            required: true,
          ),
          'negative_prompt': ToolParameter(
            type: 'string',
            description: '负面提示词，排除不想出现的元素。',
            required: false,
          ),
          'width': ToolParameter(
            type: 'integer',
            description: '图片宽度。竖图 832，横图 1216，方图 1024。',
            required: false,
          ),
          'height': ToolParameter(
            type: 'integer',
            description: '图片高度。竖图 1216，横图 832，方图 1024。',
            required: false,
          ),
        },
        handler: _handleDrawImage,
      );

  Future<String?> _handleDrawImage(Map<String, dynamic> args) async {
    final rawPrompt = (args['prompt'] as String?)?.trim() ?? '';
    if (rawPrompt.isEmpty) {
      return jsonEncode({'success': false, 'error': 'prompt is empty'});
    }

    _ImageTarget? resolvedTarget;
    try {
      final settings = await _ref.read(appSettingsProvider.future);
      if (!settings.imageGenerationEnabled) {
        return jsonEncode(
            {'success': false, 'error': 'image plugin is disabled'});
      }

      resolvedTarget = _resolveTarget(settings);
      if (resolvedTarget == null) {
        return jsonEncode({
          'success': false,
          'error': 'no configured image provider/model in provider settings',
        });
      }

      // 画师串自动拼接：如果用户选了画师串预设，拼在 prompt 前面
      final artistPreset = _config.selectedArtistPreset;
      final prompt = artistPreset != null && artistPreset.content.trim().isNotEmpty
          ? '${artistPreset.content.trim()}, $rawPrompt'
          : rawPrompt;

      final width = _readInt(args['width'], _config.defaultWidth, 256, 2048);
      final height = _readInt(args['height'], _config.defaultHeight, 256, 2048);
      // 功能参数直接读配置固定值，不由模型决定
      final steps = _config.defaultSteps;
      final count = _config.defaultCount;
      final guidanceScale = _config.defaultGuidanceScale;

      final negativePrompt = _mergeNegativePrompts(
        _config.defaultNegativePrompt,
        (args['negative_prompt'] as String?)?.trim(),
      );

      final client = AgentApiClient(
        timeout: Duration(seconds: _config.timeoutSeconds),
      );
      final requestProvider = _resolveRequestProvider(resolvedTarget.provider);
      final result = await client.generateImage(
        provider: requestProvider,
        model: resolvedTarget.modelId,
        prompt: prompt,
        negativePrompt: negativePrompt,
        width: width,
        height: height,
        count: count,
        steps: steps,
        guidanceScale: guidanceScale,
        providerApiBase: resolvedTarget.provider.apiBaseUrl,
        providerApiKey: resolvedTarget.apiKey,
        customConfig: resolvedTarget.provider.customConfig,
      );

      if (result.images.isEmpty) {
        return jsonEncode({
          'success': false,
          'error': 'provider returned no images',
          'provider': resolvedTarget.provider.id,
          'model': resolvedTarget.modelId,
        });
      }

      final saved = await _saveImages(
        bytesList: result.images,
        providerId: resolvedTarget.provider.id,
        modelId: resolvedTarget.modelId,
      );

      AppLogger.info('ImagePlugin', 'Image generated by tool', metadata: {
        'provider': resolvedTarget.provider.id,
        'model': resolvedTarget.modelId,
        'count': saved.length,
      });

      return jsonEncode({
        'success': true,
        'provider': resolvedTarget.provider.id,
        'model': resolvedTarget.modelId,
        'prompt': prompt,
        'images': [
          for (final localPath in saved)
            {
              'localPath': localPath,
              'caption': prompt,
            }
        ],
        'message': 'image generated',
      });
    } catch (e) {
      AppLogger.warning('ImagePlugin', 'draw_image failed', metadata: {
        'error': e.toString(),
        'selectedProviderId': _config.selectedProviderId,
        'selectedModelId': _config.selectedModelId,
        'resolvedProviderId': resolvedTarget?.provider.id,
        'resolvedModelId': resolvedTarget?.modelId,
        'resolvedProviderApiBase': resolvedTarget?.provider.apiBaseUrl,
        'resolvedRequestProvider': resolvedTarget == null
            ? null
            : _resolveRequestProvider(resolvedTarget.provider),
      });
      return jsonEncode({
        'success': false,
        'error': e.toString(),
      });
    }
  }

  _ImageTarget? _resolveTarget(AppSettings settings) {
    ProviderAuth? provider;
    if (_config.selectedProviderId != null &&
        _config.selectedProviderId!.trim().isNotEmpty) {
      provider = settings.providers
          .where((p) => p.id == _config.selectedProviderId)
          .firstOrNull;
      if (provider != null && !_isProviderUsable(provider)) {
        provider = null;
      }
    }

    provider ??= settings.providers.firstWhere(
      (p) => _isProviderUsable(p) && _imageModelsOf(settings, p).isNotEmpty,
      orElse: () => const ProviderAuth(id: '', apiBaseUrl: '', apiKeys: []),
    );
    if (provider.id.isEmpty) return null;

    final allModels = _imageModelsOf(settings, provider);
    final selectedModel = _config.selectedModelId?.trim();
    final configuredModel =
        provider.customConfig['defaultImageModel']?.toString().trim();
    final modelId = () {
      if (selectedModel != null &&
          selectedModel.isNotEmpty &&
          allModels.contains(selectedModel)) {
        return selectedModel;
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

    final apiKey = provider.apiKeys.isNotEmpty ? provider.apiKeys.first : '';
    if (apiKey.trim().isEmpty) return null;
    return _ImageTarget(
      provider: provider,
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
    final models = provider.visibleModels.isNotEmpty
        ? provider.visibleModels
        : provider.models;
    return models
        .where((modelId) =>
            settings
                .getModelType(settings.buildModelRef(provider.id, modelId)) ==
            ModelType.image)
        .toList();
  }

  String _resolveRequestProvider(ProviderAuth provider) {
    final requestFormat = (provider.customConfig['requestFormat'] as String?)
        ?.trim()
        .toLowerCase();
    if (requestFormat == 'novelai' || requestFormat == 'nai') {
      return 'novelai';
    }
    final providerId = provider.id.trim().toLowerCase();
    if (providerId == 'novelai' || providerId == 'nai') {
      return 'novelai';
    }
    return provider.id;
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

  int _readInt(dynamic value, int fallback, int min, int max) {
    final parsed = value is int
        ? value
        : value is num
            ? value.toInt()
            : int.tryParse(value?.toString() ?? '');
    return (parsed ?? fallback).clamp(min, max);
  }

  int? _readOptionalInt(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value.toString());
  }

  double _readDouble(dynamic value, double fallback, double min, double max) {
    final parsed = value is double
        ? value
        : value is num
            ? value.toDouble()
            : double.tryParse(value?.toString() ?? '');
    return (parsed ?? fallback).clamp(min, max);
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
