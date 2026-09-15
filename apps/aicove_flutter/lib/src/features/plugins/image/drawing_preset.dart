import 'dart:convert';

import '../../chat/domain/persona_prompt_codec.dart';
import 'image_config.dart';

/// 单个绘图预设。复用已有请求配置值对象，不再维护平行的参数模型。
class DrawingPreset {
  final String id;
  final String name;
  final ImageConfig config;

  const DrawingPreset({
    required this.id,
    required this.name,
    required this.config,
  });

  DrawingPreset copyWith({String? id, String? name, ImageConfig? config}) =>
      DrawingPreset(
        id: id ?? this.id,
        name: name ?? this.name,
        config: config ?? this.config,
      );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'config': config.toJson(),
  };
  factory DrawingPreset.fromJson(Map<String, dynamic> json) => DrawingPreset(
    id: json['id'] as String,
    name: json['name'] as String,
    config: ImageConfig.fromJson(
      Map<String, dynamic>.from(json['config'] as Map),
    ),
  );

  /// 将旧的多个选择收成预设自身的值，不再跟随旧全局列表变化。
  static ImageConfig flatten(
    ImageConfig source, {
    String? toolName,
    String? artistName,
  }) {
    final tool = source.systemPromptPresets
        .where((p) => p.name == toolName)
        .firstOrNull;
    final artist = PersonaPromptCodec.isArtistPresetDisabledBinding(artistName)
        ? null
        : artistName != null && artistName.isNotEmpty
        ? source.artistPresets.where((p) => p.name == artistName).firstOrNull
        : source.selectedArtistPreset;
    final blocks = tool == null
        ? source.effectiveToolDescriptionBlocks
        : source
              .copyWith(selectedSystemPromptPresetName: tool.name)
              .effectiveToolDescriptionBlocks;
    final modelRef = source.selectedModelId;
    final separator = modelRef?.indexOf(':') ?? -1;
    return source.copyWith(
      selectedProviderId: separator > 0
          ? modelRef!.substring(0, separator)
          : source.selectedProviderId,
      drawingSystemPrompt: ImageConfig.encodeToolDescriptionBlocks(blocks),
      systemPromptPresets: const [],
      clearSelectedSystemPromptPreset: true,
      fastPromptPresets: [
        DrawingPromptPreset(
          name: '辅助提示词',
          content: source.effectiveInlinePromptTemplate,
        ),
      ],
      selectedFastPromptPresetName: '辅助提示词',
      artistPresets: artist == null ? const [] : [artist],
      selectedArtistPresetName: artist?.name,
      clearSelectedArtistPreset: artist == null,
    );
  }
}

class DrawingPresetCatalog {
  final List<DrawingPreset> presets;
  final String defaultPresetId;

  /// 首次迁移时冻结旧配置；旧角色/旧导入文件仍可无损渐进迁移。
  final ImageConfig legacyConfig;

  DrawingPresetCatalog({
    required List<DrawingPreset> presets,
    required this.defaultPresetId,
    required this.legacyConfig,
  }) : presets = List.unmodifiable(presets);

  factory DrawingPresetCatalog.migrate(ImageConfig old) {
    var catalog = DrawingPresetCatalog(
      presets: [
        DrawingPreset(
          id: 'drawing_default',
          name: '默认绘图',
          config: DrawingPreset.flatten(old),
        ),
      ],
      defaultPresetId: 'drawing_default',
      legacyConfig: old,
    );
    // 单项旧收藏也转换，避免未绑定角色的自定义风格从新界面消失。
    for (final artist in old.artistPresets) {
      catalog = catalog.upsert(
        catalog.resolve(
          PersonaPromptParts(
            userPrompt: '',
            customDrawingPrompt: '',
            drawingArtistPresetName: artist.name,
          ),
        ),
      );
    }
    for (final tool in old.systemPromptPresets) {
      catalog = catalog.upsert(
        catalog.resolve(
          PersonaPromptParts(
            userPrompt: '',
            customDrawingPrompt: '',
            drawingToolPresetName: tool.name,
          ),
        ),
      );
    }
    for (final fast in old.fastPromptPresets) {
      if (fast.name == old.selectedFastPromptPreset?.name) continue;
      catalog = catalog.upsert(
        DrawingPreset(
          id: 'legacy_fast_${base64Url.encode(utf8.encode(fast.name))}',
          name: '旧快速提示 · ${fast.name}',
          config: DrawingPreset.flatten(
            old.copyWith(selectedFastPromptPresetName: fast.name),
          ),
        ),
      );
    }
    return catalog;
  }

  DrawingPreset resolve(PersonaPromptParts parts) {
    final explicit = parts.drawingPresetId;
    if (explicit != null && explicit.isNotEmpty) return require(explicit);
    final tool = parts.drawingToolPresetName;
    final artist = parts.drawingArtistPresetName;
    if ((tool == null || tool.isEmpty) && (artist == null || artist.isEmpty)) {
      return require(defaultPresetId);
    }
    final id =
        'legacy_${base64Url.encode(utf8.encode(jsonEncode([tool, artist])))}';
    final saved = presets.where((p) => p.id == id).firstOrNull;
    if (saved != null) return saved;
    if (tool != null &&
        tool.isNotEmpty &&
        !legacyConfig.systemPromptPresets.any((p) => p.name == tool)) {
      throw StateError('旧绘图提示词预设「$tool」已丢失，请重新选择绘图预设');
    }
    if (artist != null &&
        artist.isNotEmpty &&
        !PersonaPromptCodec.isArtistPresetDisabledBinding(artist) &&
        !legacyConfig.artistPresets.any((p) => p.name == artist)) {
      throw StateError('旧画师串「$artist」已丢失，请重新选择绘图预设');
    }
    final name = [
      if (artist != null && artist.isNotEmpty)
        PersonaPromptCodec.isArtistPresetDisabledBinding(artist)
            ? '无画师串'
            : artist,
      if (tool != null && tool.isNotEmpty) tool,
    ].join(' · ');
    return DrawingPreset(
      id: id,
      name: '旧配置 · $name',
      config: DrawingPreset.flatten(
        legacyConfig,
        toolName: tool,
        artistName: artist,
      ),
    );
  }

  DrawingPreset require(String id) =>
      presets.where((p) => p.id == id).firstOrNull ??
      (throw StateError('绘图预设已失效，请在角色卡重新选择'));

  DrawingPresetCatalog upsert(DrawingPreset preset) => DrawingPresetCatalog(
    presets: [...presets.where((p) => p.id != preset.id), preset],
    defaultPresetId: defaultPresetId,
    legacyConfig: legacyConfig,
  );

  DrawingPresetCatalog withDefault(String id) {
    require(id);
    return DrawingPresetCatalog(
      presets: presets,
      defaultPresetId: id,
      legacyConfig: legacyConfig,
    );
  }

  Map<String, dynamic> toJson() => {
    'version': 1,
    'presets': presets.map((p) => p.toJson()).toList(),
    'defaultPresetId': defaultPresetId,
    'legacyConfig': legacyConfig.toJson(),
  };
  factory DrawingPresetCatalog.fromJson(Map<String, dynamic> json) {
    if (json['version'] != 1) throw const FormatException('不支持的绘图预设版本');
    final result = DrawingPresetCatalog(
      presets: (json['presets'] as List)
          .map(
            (p) => DrawingPreset.fromJson(Map<String, dynamic>.from(p as Map)),
          )
          .toList(),
      defaultPresetId: json['defaultPresetId'] as String,
      legacyConfig: ImageConfig.fromJson(
        Map<String, dynamic>.from(json['legacyConfig'] as Map),
      ),
    );
    result.require(result.defaultPresetId);
    if (result.presets.map((p) => p.id).toSet().length !=
        result.presets.length) {
      throw const FormatException('绘图预设 ID 重复');
    }
    return result;
  }
}
