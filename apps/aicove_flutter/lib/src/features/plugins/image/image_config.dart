import 'dart:convert';

import '../../../core/prompts/prompt_builtin_defaults.g.dart';

/// 画师串预设（正面 + 负面提示词）
class ArtistPreset {
  final String name;

  /// 正面提示词部分，拼在 AI prompt 前面
  final String content;

  /// 负面提示词部分，合并到 negative prompt
  final String negativeContent;

  const ArtistPreset({
    required this.name,
    required this.content,
    this.negativeContent = '',
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'content': content,
        'negativeContent': negativeContent,
      };

  factory ArtistPreset.fromJson(Map<String, dynamic> json) => ArtistPreset(
        name: json['name'] as String? ?? '',
        content: json['content'] as String? ?? '',
        negativeContent: json['negativeContent'] as String? ?? '',
      );
}

/// 绘图提示词预设
class DrawingPromptPreset {
  final String name;
  final String content;

  const DrawingPromptPreset({required this.name, required this.content});

  Map<String, dynamic> toJson() => {'name': name, 'content': content};

  factory DrawingPromptPreset.fromJson(Map<String, dynamic> json) =>
      DrawingPromptPreset(
        name: json['name'] as String? ?? '',
        content: json['content'] as String? ?? '',
      );
}

/// draw_image 工具描述固定块
class DrawImageToolDescriptionBlocks {
  final String toolDescription;
  final String promptDescription;
  final String negativePromptDescription;
  final String widthDescription;
  final String heightDescription;

  const DrawImageToolDescriptionBlocks({
    this.toolDescription = ImageConfig.defaultToolDescription,
    this.promptDescription = ImageConfig.defaultPromptDescription,
    this.negativePromptDescription =
        ImageConfig.defaultNegativePromptDescription,
    this.widthDescription = ImageConfig.defaultWidthDescription,
    this.heightDescription = ImageConfig.defaultHeightDescription,
  });

  DrawImageToolDescriptionBlocks copyWith({
    String? toolDescription,
    String? promptDescription,
    String? negativePromptDescription,
    String? widthDescription,
    String? heightDescription,
  }) {
    return DrawImageToolDescriptionBlocks(
      toolDescription: toolDescription ?? this.toolDescription,
      promptDescription: promptDescription ?? this.promptDescription,
      negativePromptDescription:
          negativePromptDescription ?? this.negativePromptDescription,
      widthDescription: widthDescription ?? this.widthDescription,
      heightDescription: heightDescription ?? this.heightDescription,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'schema': 'draw_image_tool_description_v1',
      'toolDescription': toolDescription,
      'promptDescription': promptDescription,
      'negativePromptDescription': negativePromptDescription,
      'widthDescription': widthDescription,
      'heightDescription': heightDescription,
    };
  }

  factory DrawImageToolDescriptionBlocks.fromJson(Map<String, dynamic> json) {
    String read(List<String> keys, String fallback) {
      for (final key in keys) {
        final value = json[key];
        if (value is String && value.trim().isNotEmpty) {
          return value.trim();
        }
      }
      return fallback;
    }

    return DrawImageToolDescriptionBlocks(
      toolDescription: read(
        const ['toolDescription', 'description'],
        ImageConfig.defaultToolDescription,
      ),
      promptDescription: read(
        const ['promptDescription', 'prompt'],
        ImageConfig.defaultPromptDescription,
      ),
      negativePromptDescription: read(
        const ['negativePromptDescription', 'negativePrompt'],
        ImageConfig.defaultNegativePromptDescription,
      ),
      widthDescription: read(
        const ['widthDescription', 'width'],
        ImageConfig.defaultWidthDescription,
      ),
      heightDescription: read(
        const ['heightDescription', 'height'],
        ImageConfig.defaultHeightDescription,
      ),
    );
  }
}

class ImageConfig {
  static const String defaultToolDescriptionPresetMarker =
      '__DRAW_IMAGE_TOOL_DESCRIPTION_V2_DEFAULT__';
  static const String defaultToolDescription =
      PromptBuiltinDefaults.imageToolDescriptionDefault;
  static const String defaultPromptDescription =
      PromptBuiltinDefaults.imageToolPromptDescriptionDefault;
  static const String defaultNegativePromptDescription =
      PromptBuiltinDefaults.imageToolNegativePromptDescriptionDefault;
  static const String defaultWidthDescription =
      PromptBuiltinDefaults.imageToolWidthDescriptionDefault;
  static const String defaultHeightDescription =
      PromptBuiltinDefaults.imageToolHeightDescriptionDefault;
  static const DrawImageToolDescriptionBlocks defaultToolDescriptionBlocks =
      DrawImageToolDescriptionBlocks();
  static DrawImageToolDescriptionBlocks
      get runtimeDefaultToolDescriptionBlocks => DrawImageToolDescriptionBlocks(
            toolDescription: PromptBuiltinDefaults.requireTemplate(
              'image.tool.description.default',
            ),
            promptDescription: PromptBuiltinDefaults.requireTemplate(
              'image.tool.prompt_description.default',
            ),
            negativePromptDescription: PromptBuiltinDefaults.requireTemplate(
              'image.tool.negative_prompt_description.default',
            ),
            widthDescription: PromptBuiltinDefaults.requireTemplate(
              'image.tool.width_description.default',
            ),
            heightDescription: PromptBuiltinDefaults.requireTemplate(
              'image.tool.height_description.default',
            ),
          );

  final String? selectedProviderId;
  final String? selectedModelId;
  final String defaultNegativePrompt;
  final int defaultWidth;
  final int defaultHeight;
  final int defaultSteps;
  final double defaultGuidanceScale;
  final int defaultCount;
  final int timeoutSeconds;
  final String drawingSystemPrompt;
  final List<DrawingPromptPreset> systemPromptPresets;
  final String? selectedSystemPromptPresetName;
  final List<DrawingPromptPreset> fastPromptPresets;
  final String? selectedFastPromptPresetName;
  final List<ArtistPreset> artistPresets;
  final String? selectedArtistPresetName;

  /// 内置默认画师串预设
  static const defaultArtistPresets = [
    ArtistPreset(
      name: '防冻液',
      content:
          '[[omochi monaka]] ,{{kele mimi}} ,[ruriri], [[[[[d omm]]]]] ,[[[[[[[tianliang_duohe_fangdongye]]]]]] ,Ningen Mame, {{year 2024}},',
      negativeContent:
          'worst quality, low quality, jpeg artifacts, watermark, text',
    ),
  ];

  /// 快速模式默认提示词模板
  static const String defaultInlinePromptTemplate =
      PromptBuiltinDefaults.imageInlineDefault;
  static String get runtimeDefaultInlinePromptTemplate =>
      PromptBuiltinDefaults.requireTemplate('image.inline.default');

  /// NovelAI 生图提示词规范（默认值），作为 system prompt 注入给 AI。
  static const defaultDrawingSystemPrompt =
      PromptBuiltinDefaults.imageSystemDefault;
  static String get runtimeDefaultDrawingSystemPrompt =>
      PromptBuiltinDefaults.requireTemplate('image.system.default');

  /// 内置系统提示词预设
  static const defaultSystemPromptPresets = [
    DrawingPromptPreset(
      name: '默认',
      content: defaultToolDescriptionPresetMarker,
    ),
  ];

  /// 内置快速模式提示词预设
  static const defaultInlinePromptPresets = [
    DrawingPromptPreset(
      name: '默认',
      content: defaultInlinePromptTemplate,
    ),
  ];

  const ImageConfig({
    this.selectedProviderId,
    this.selectedModelId,
    this.defaultNegativePrompt = '',
    this.defaultWidth = 832,
    this.defaultHeight = 1216,
    this.defaultSteps = 28,
    this.defaultGuidanceScale = 5.0,
    this.defaultCount = 1,
    this.timeoutSeconds = 30,
    this.drawingSystemPrompt = defaultToolDescriptionPresetMarker,
    this.systemPromptPresets = defaultSystemPromptPresets,
    this.selectedSystemPromptPresetName,
    this.fastPromptPresets = defaultInlinePromptPresets,
    this.selectedFastPromptPresetName,
    this.artistPresets = defaultArtistPresets,
    this.selectedArtistPresetName,
  });

  ImageConfig copyWith({
    String? selectedProviderId,
    bool clearSelectedProviderId = false,
    String? selectedModelId,
    bool clearSelectedModelId = false,
    String? defaultNegativePrompt,
    int? defaultWidth,
    int? defaultHeight,
    int? defaultSteps,
    double? defaultGuidanceScale,
    int? defaultCount,
    int? timeoutSeconds,
    String? drawingSystemPrompt,
    List<DrawingPromptPreset>? systemPromptPresets,
    String? selectedSystemPromptPresetName,
    bool clearSelectedSystemPromptPreset = false,
    List<DrawingPromptPreset>? fastPromptPresets,
    String? selectedFastPromptPresetName,
    bool clearSelectedFastPromptPreset = false,
    List<ArtistPreset>? artistPresets,
    String? selectedArtistPresetName,
    bool clearSelectedArtistPreset = false,
  }) {
    return ImageConfig(
      selectedProviderId: clearSelectedProviderId
          ? null
          : (selectedProviderId ?? this.selectedProviderId),
      selectedModelId: clearSelectedModelId
          ? null
          : (selectedModelId ?? this.selectedModelId),
      defaultNegativePrompt:
          defaultNegativePrompt ?? this.defaultNegativePrompt,
      defaultWidth: defaultWidth ?? this.defaultWidth,
      defaultHeight: defaultHeight ?? this.defaultHeight,
      defaultSteps: defaultSteps ?? this.defaultSteps,
      defaultGuidanceScale: defaultGuidanceScale ?? this.defaultGuidanceScale,
      defaultCount: defaultCount ?? this.defaultCount,
      timeoutSeconds: timeoutSeconds ?? this.timeoutSeconds,
      drawingSystemPrompt: drawingSystemPrompt ?? this.drawingSystemPrompt,
      systemPromptPresets: systemPromptPresets ?? this.systemPromptPresets,
      selectedSystemPromptPresetName: clearSelectedSystemPromptPreset
          ? null
          : (selectedSystemPromptPresetName ??
              this.selectedSystemPromptPresetName),
      fastPromptPresets: fastPromptPresets ?? this.fastPromptPresets,
      selectedFastPromptPresetName: clearSelectedFastPromptPreset
          ? null
          : (selectedFastPromptPresetName ?? this.selectedFastPromptPresetName),
      artistPresets: artistPresets ?? this.artistPresets,
      selectedArtistPresetName: clearSelectedArtistPreset
          ? null
          : (selectedArtistPresetName ?? this.selectedArtistPresetName),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'selectedProviderId': selectedProviderId,
      'selectedModelId': selectedModelId,
      'defaultNegativePrompt': defaultNegativePrompt,
      'defaultWidth': defaultWidth,
      'defaultHeight': defaultHeight,
      'defaultSteps': defaultSteps,
      'defaultGuidanceScale': defaultGuidanceScale,
      'defaultCount': defaultCount,
      'timeoutSeconds': timeoutSeconds,
      'drawingSystemPrompt': drawingSystemPrompt,
      'systemPromptPresets':
          systemPromptPresets.map((e) => e.toJson()).toList(),
      'selectedSystemPromptPresetName': selectedSystemPromptPresetName,
      'fastPromptPresets': fastPromptPresets.map((e) => e.toJson()).toList(),
      'selectedFastPromptPresetName': selectedFastPromptPresetName,
      'artistPresets': artistPresets.map((e) => e.toJson()).toList(),
      'selectedArtistPresetName': selectedArtistPresetName,
    };
  }

  factory ImageConfig.fromJson(Map<String, dynamic> json) {
    return ImageConfig(
      selectedProviderId: json['selectedProviderId'] as String?,
      selectedModelId: json['selectedModelId'] as String?,
      defaultNegativePrompt: json['defaultNegativePrompt'] as String? ?? '',
      defaultWidth: (json['defaultWidth'] as num?)?.toInt() ?? 832,
      defaultHeight: (json['defaultHeight'] as num?)?.toInt() ?? 1216,
      defaultSteps: (json['defaultSteps'] as num?)?.toInt() ?? 28,
      defaultGuidanceScale:
          (json['defaultGuidanceScale'] as num?)?.toDouble() ?? 5.0,
      defaultCount: (json['defaultCount'] as num?)?.toInt() ?? 1,
      timeoutSeconds: (json['timeoutSeconds'] as num?)?.toInt() ?? 30,
      drawingSystemPrompt: json['drawingSystemPrompt'] as String? ??
          defaultToolDescriptionPresetMarker,
      systemPromptPresets: (json['systemPromptPresets'] as List<dynamic>?)
              ?.map((e) =>
                  DrawingPromptPreset.fromJson(e as Map<String, dynamic>))
              .toList() ??
          defaultSystemPromptPresets,
      selectedSystemPromptPresetName:
          json['selectedSystemPromptPresetName'] as String?,
      fastPromptPresets: (json['fastPromptPresets'] as List<dynamic>?)
              ?.map((e) =>
                  DrawingPromptPreset.fromJson(e as Map<String, dynamic>))
              .toList() ??
          defaultInlinePromptPresets,
      selectedFastPromptPresetName:
          json['selectedFastPromptPresetName'] as String?,
      artistPresets: (json['artistPresets'] as List<dynamic>?)
              ?.map((e) => ArtistPreset.fromJson(e as Map<String, dynamic>))
              .toList() ??
          defaultArtistPresets,
      selectedArtistPresetName: json['selectedArtistPresetName'] as String?,
    );
  }

  /// 获取当前选中的系统提示词预设（如果有）
  DrawingPromptPreset? get selectedSystemPromptPreset {
    if (selectedSystemPromptPresetName == null) return null;
    return systemPromptPresets
        .where((p) => p.name == selectedSystemPromptPresetName)
        .firstOrNull;
  }

  /// 获取当前选中的快速模式提示词预设（如果有）
  DrawingPromptPreset? get selectedFastPromptPreset {
    if (selectedFastPromptPresetName != null) {
      final matched = fastPromptPresets
          .where((p) => p.name == selectedFastPromptPresetName)
          .firstOrNull;
      if (matched != null) return matched;
    }
    return fastPromptPresets.firstOrNull;
  }

  /// 获取当前选中的画师串预设（如果有）
  ArtistPreset? get selectedArtistPreset {
    if (selectedArtistPresetName == null) return null;
    return artistPresets
        .where((p) => p.name == selectedArtistPresetName)
        .firstOrNull;
  }

  static String encodeToolDescriptionBlocks(
    DrawImageToolDescriptionBlocks blocks,
  ) {
    return jsonEncode(blocks.toJson());
  }

  static DrawImageToolDescriptionBlocks? decodeToolDescriptionBlocks(
    String raw,
  ) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    if (trimmed == defaultToolDescriptionPresetMarker) {
      return runtimeDefaultToolDescriptionBlocks;
    }
    try {
      final decoded = _decodeJsonMap(trimmed);
      if (decoded == null) return null;
      return DrawImageToolDescriptionBlocks.fromJson(decoded);
    } catch (_) {
      return null;
    }
  }

  DrawImageToolDescriptionBlocks get manualToolDescriptionBlocks {
    final parsed = decodeToolDescriptionBlocks(drawingSystemPrompt);
    if (parsed != null) return parsed;
    return _legacyTextToBlocks(drawingSystemPrompt);
  }

  DrawImageToolDescriptionBlocks? get selectedToolDescriptionPresetBlocks {
    final preset = selectedSystemPromptPreset;
    if (preset == null) return null;
    final parsed = decodeToolDescriptionBlocks(preset.content);
    if (parsed != null) return parsed;
    return _legacyTextToBlocks(preset.content);
  }

  DrawImageToolDescriptionBlocks get effectiveToolDescriptionBlocks {
    return selectedToolDescriptionPresetBlocks ?? manualToolDescriptionBlocks;
  }

  String get effectiveInlinePromptTemplate {
    final selectedPreset = selectedFastPromptPreset;
    if (selectedPreset != null && selectedPreset.content.trim().isNotEmpty) {
      final content = selectedPreset.content.trim();
      if (content == defaultInlinePromptTemplate.trim()) {
        return runtimeDefaultInlinePromptTemplate;
      }
      return content;
    }
    return runtimeDefaultInlinePromptTemplate;
  }

  bool get isManualToolDescriptionDefault {
    final blocks = manualToolDescriptionBlocks;
    return blocks.toolDescription ==
            defaultToolDescriptionBlocks.toolDescription &&
        blocks.promptDescription ==
            defaultToolDescriptionBlocks.promptDescription &&
        blocks.negativePromptDescription ==
            defaultToolDescriptionBlocks.negativePromptDescription &&
        blocks.widthDescription ==
            defaultToolDescriptionBlocks.widthDescription &&
        blocks.heightDescription ==
            defaultToolDescriptionBlocks.heightDescription;
  }

  String buildPresetPreview(DrawingPromptPreset preset, {int max = 42}) {
    final blocks = decodeToolDescriptionBlocks(preset.content) ??
        _legacyTextToBlocks(preset.content);
    return _buildTextPreview(blocks.promptDescription, max: max);
  }

  String buildInlinePresetPreview(DrawingPromptPreset preset, {int max = 42}) {
    return _buildTextPreview(preset.content, max: max);
  }

  static DrawImageToolDescriptionBlocks _legacyTextToBlocks(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty ||
        trimmed == defaultToolDescriptionPresetMarker ||
        trimmed == defaultDrawingSystemPrompt) {
      return runtimeDefaultToolDescriptionBlocks;
    }
    return runtimeDefaultToolDescriptionBlocks.copyWith(
      promptDescription: trimmed,
    );
  }

  static Map<String, dynamic>? _decodeJsonMap(String raw) {
    try {
      if (!raw.startsWith('{')) return null;
      final dynamic parsed = jsonDecode(raw);
      if (parsed is Map<String, dynamic>) return parsed;
      if (parsed is Map) return parsed.cast<String, dynamic>();
      return null;
    } catch (_) {
      return null;
    }
  }

  static String _buildTextPreview(String raw, {required int max}) {
    final text = raw.replaceAll('\n', ' ').trim();
    if (text.length <= max) return text;
    return '${text.substring(0, max)}...';
  }

  /// 组合最终发送给 AI 的 system prompt（纯提示词规范，不含画师串）
  String get effectiveSystemPrompt {
    final selectedPreset = selectedSystemPromptPreset;
    if (selectedPreset != null && selectedPreset.content.trim().isNotEmpty) {
      return selectedPreset.content;
    }
    final base = drawingSystemPrompt.trim().isNotEmpty
        ? drawingSystemPrompt
        : defaultDrawingSystemPrompt;
    if (base == defaultToolDescriptionPresetMarker ||
        base == defaultDrawingSystemPrompt) {
      return runtimeDefaultDrawingSystemPrompt;
    }
    return base;
  }
}
