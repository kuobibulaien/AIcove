library;

/// 人物提示词拆分结果：
/// - [userPrompt]：基础人设提示词（AIcove酱的只读系统提示词）
/// - [extraPrompt]：附加提示词（AIcove酱的可编辑部分）
/// - [customDrawingPrompt]：自定义绘图提示（仅在绘图插件启用时拼到系统提示词末尾）
/// - [drawingToolPresetName]：角色绑定的绘图工具描述预设名称
/// - [drawingArtistPresetName]：角色绑定的画师串预设名称
class PersonaPromptParts {
  final String userPrompt;
  final String extraPrompt;
  final String customDrawingPrompt;
  final String? drawingToolPresetName;
  final String? drawingArtistPresetName;
  final String? drawingPresetId;
  final String? drawingPromptPackId;

  const PersonaPromptParts({
    required this.userPrompt,
    required this.customDrawingPrompt,
    this.extraPrompt = '',
    this.drawingToolPresetName,
    this.drawingArtistPresetName,
    this.drawingPresetId,
    this.drawingPromptPackId,
  });

  /// 发给模型的角色人设：基础人设与附加提示词，绘图配置不参与。
  String get rolePrompt => [
    userPrompt.trim(),
    extraPrompt.trim(),
  ].where((part) => part.isNotEmpty).join('\n\n');
}

/// 人物提示词编解码器。
///
/// 说明：
/// - 为避免数据库迁移，使用同一个 personaPrompt 字段保存各段文本。
/// - 通过内部标记将附加提示词、绘图提示与普通人设提示词分离。
class PersonaPromptCodec {
  static const String _extraStartMarker = '<<AICOVE_EXTRA_PROMPT_START>>';
  static const String _extraEndMarker = '<<AICOVE_EXTRA_PROMPT_END>>';
  static const String artistPresetDisabledBinding =
      '__AICOVE_DRAWING_ARTIST_PRESET_DISABLED__';
  static const String _presetStartMarker = '<<AICOVE_DRAWING_PRESET_ID_START>>';
  static const String _presetEndMarker = '<<AICOVE_DRAWING_PRESET_ID_END>>';
  static const String _packStartMarker =
      '<<AICOVE_DRAWING_PROMPT_PACK_ID_START>>';
  static const String _packEndMarker = '<<AICOVE_DRAWING_PROMPT_PACK_ID_END>>';
  static const String _drawingStartMarker = '<<AICOVE_DRAWING_PROMPT_START>>';
  static const String _drawingEndMarker = '<<AICOVE_DRAWING_PROMPT_END>>';
  static const String _toolPresetStartMarker =
      '<<AICOVE_DRAWING_TOOL_PRESET_START>>';
  static const String _toolPresetEndMarker =
      '<<AICOVE_DRAWING_TOOL_PRESET_END>>';
  static const String _artistPresetStartMarker =
      '<<AICOVE_DRAWING_ARTIST_PRESET_START>>';
  static const String _artistPresetEndMarker =
      '<<AICOVE_DRAWING_ARTIST_PRESET_END>>';

  static final _markerPattern = RegExp(r'<<AICOVE_[A-Z_]+_(?:START|END)>>');

  /// Removes internal markers from user-typed text so it cannot split into
  /// other segments; repeats until stripping no longer forms a new marker.
  static String stripMarkers(String text) {
    var current = text;
    while (true) {
      final next = current.replaceAll(_markerPattern, '');
      if (next == current) return current;
      current = next;
    }
  }

  static PersonaPromptParts parse(String rawPrompt) {
    final raw = rawPrompt.trim();
    if (raw.isEmpty) {
      return const PersonaPromptParts(userPrompt: '', customDrawingPrompt: '');
    }

    var remaining = raw;
    final extraExtract = _extractMarkedBlock(
      remaining,
      _extraStartMarker,
      _extraEndMarker,
    );
    remaining = extraExtract.remaining;
    final drawingExtract = _extractMarkedBlock(
      remaining,
      _drawingStartMarker,
      _drawingEndMarker,
    );
    remaining = drawingExtract.remaining;

    final toolPresetExtract = _extractMarkedBlock(
      remaining,
      _toolPresetStartMarker,
      _toolPresetEndMarker,
    );
    remaining = toolPresetExtract.remaining;

    final artistPresetExtract = _extractMarkedBlock(
      remaining,
      _artistPresetStartMarker,
      _artistPresetEndMarker,
    );
    remaining = artistPresetExtract.remaining;

    final presetExtract = _extractMarkedBlock(
      remaining,
      _presetStartMarker,
      _presetEndMarker,
    );
    remaining = presetExtract.remaining;
    final packExtract = _extractMarkedBlock(
      remaining,
      _packStartMarker,
      _packEndMarker,
    );
    remaining = packExtract.remaining;
    return PersonaPromptParts(
      drawingPromptPackId: packExtract.value,
      drawingPresetId: presetExtract.value,
      userPrompt: remaining.trim(),
      extraPrompt: extraExtract.value ?? '',
      customDrawingPrompt: drawingExtract.value ?? '',
      drawingToolPresetName: toolPresetExtract.value,
      drawingArtistPresetName: artistPresetExtract.value,
    );
  }

  static String compose({
    required String userPrompt,
    String? extraPrompt,
    String? customDrawingPrompt,
    String? drawingToolPresetName,
    String? drawingArtistPresetName,
    String? drawingPresetId,
    String? drawingPromptPackId,
  }) {
    final user = userPrompt.trim();
    final extra = stripMarkers(extraPrompt ?? '').trim();
    final drawing = (customDrawingPrompt ?? '').trim();
    final toolPreset = (drawingToolPresetName ?? '').trim();
    final artistPreset = (drawingArtistPresetName ?? '').trim();

    final preset = (drawingPresetId ?? '').trim();
    final pack = stripMarkers(drawingPromptPackId ?? '').trim();
    final segments = <String>[
      if (user.isNotEmpty) user,
      if (extra.isNotEmpty) '$_extraStartMarker\n$extra\n$_extraEndMarker',
      if (preset.isNotEmpty) '$_presetStartMarker\n$preset\n$_presetEndMarker',
      if (pack.isNotEmpty) '$_packStartMarker\n$pack\n$_packEndMarker',
      if (drawing.isNotEmpty)
        '$_drawingStartMarker\n$drawing\n$_drawingEndMarker',
      if (toolPreset.isNotEmpty)
        '$_toolPresetStartMarker\n$toolPreset\n$_toolPresetEndMarker',
      if (artistPreset.isNotEmpty)
        '$_artistPresetStartMarker\n$artistPreset\n$_artistPresetEndMarker',
    ];
    return segments.join('\n\n');
  }

  static bool isArtistPresetDisabledBinding(String? value) {
    return value?.trim() == artistPresetDisabledBinding;
  }

  static _MarkerExtractResult _extractMarkedBlock(
    String raw,
    String startMarker,
    String endMarker,
  ) {
    final startIndex = raw.indexOf(startMarker);
    if (startIndex < 0) {
      return _MarkerExtractResult(remaining: raw, value: null);
    }

    final endIndex = raw.indexOf(endMarker, startIndex + startMarker.length);
    if (endIndex < 0) {
      // 标记不完整时保持原文，避免误删用户文本。
      return _MarkerExtractResult(remaining: raw, value: null);
    }

    final value = raw
        .substring(startIndex + startMarker.length, endIndex)
        .trim();
    final before = raw.substring(0, startIndex).trim();
    final after = raw.substring(endIndex + endMarker.length).trim();
    final remainingSegments = <String>[
      if (before.isNotEmpty) before,
      if (after.isNotEmpty) after,
    ];

    return _MarkerExtractResult(
      remaining: remainingSegments.join('\n\n').trim(),
      value: value.isEmpty ? null : value,
    );
  }
}

class _MarkerExtractResult {
  final String remaining;
  final String? value;

  const _MarkerExtractResult({required this.remaining, required this.value});
}
