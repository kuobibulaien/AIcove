import 'dart:convert';

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
      '如果对话场景涉及到生成图片，可调用此工具。你可以自行使用此工具提升角色扮演效果，如生成自拍或生活图片等，自行决定用途。上下文中如果出现［图片］标签，意思是这个地方有一个图片占位，这意味着你需要配合语境发起一次图片工具调用，而不是单纯地回复文本标签。';
  static const String defaultPromptDescription =
      '【核心规范】仅限英文，<512 tokens。以 Danbooru 标签为骨架，复杂细节用自然语言补充。推荐顺序：视角->主体->外貌设定->姿势标签->场景光影->自然语言细节->质量标签(masterpiece, best quality, very aesthetic)。【权重语法】{加强}，[减弱]，或用 1.4::tag::，负权重用 -1::tag::。【多人交互(两人以上)】必须用 \'|\' 分隔。格式：基底提示词 | 角色1 | 角色2。基底写人数/场景/自然语言关系，不写外貌。角色段独立写外貌动作。【交互动作指定】在角色段用前缀：source#动作(发起方), target#动作(承受方), mutual#动作(共同)。如: ... A girl and a boy are hugging. | girl, ... target#hug | boy, ... source#hug。【POV 第一人称视角特别说明】以 {{{pov}}} 放开头并加权，可加 {pov_hands} 或 head out of frame，避免 full body 等第三方词汇，观者不需要单独的角色描述，只描述对方。';
  static const String defaultNegativePromptDescription =
      '【负面提示词】精简为主，只写必要提示词，防止白熊效应。可选基础负面提示词示例:lowres, artistic error, scan artifacts, worst quality, bad quality, jpeg artifacts, multiple views, very displeasing, too many watermarks, negative space, blank page。注意：在负面内容中，{} 和 [] 的权重语义与正面提示词是反转的。';
  static const String defaultWidthDescription =
      '图片宽度。严格遵循以下标准：竖图人像 832；横图 1216；方图 1024。';
  static const String defaultHeightDescription =
      '图片高度。严格遵循以下标准：竖图人像 1216；横图 832；方图 1024。';
  static const DrawImageToolDescriptionBlocks defaultToolDescriptionBlocks =
      DrawImageToolDescriptionBlocks();

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
  static const String defaultInlinePromptTemplate = '''
你可以使用 <image>英文正向提示词</image> 直接触发一次图片生成。

当前生图使用 NovelAI，<image> 标签里的内容会被直接当作正向提示词使用。

使用规则：
1. 只有你真的要生成并发送图片时，才输出 <image>...</image>
2. <image> 内只能写英文正向提示词，不要写中文、解释、JSON、代码块、负面提示词或参数说明
3. 一轮最多输出 1 个 <image>...</image>
4. 如果只是文字里提到图片，不要输出 <image> 标签

提示词规范参考：
【快速模式正向提示词】只写单张图片的英文正向提示词，不要写负面提示词、尺寸、步数或额外解释。
【推荐顺序】镜头/视角 -> 主体人数 -> 外貌服装 -> 动作表情 -> 场景光影 -> 自然语言细节 -> 质量标签(masterpiece, best quality, very aesthetic)。
【POV/自拍】需要第一人称视角时，把 {{{pov}}} 放在前面，可按需加 {pov_hands} 或 head out of frame。
【多人】多人场景可用 | 分隔基底与各角色描述。''';

  /// NovelAI 生图提示词规范（默认值），作为 system prompt 注入给 AI。
  static const defaultDrawingSystemPrompt = '''
如果对话场景涉及到生成图片，可调用`draw_image` 工具。你可以自行使用此工具提升角色扮演效果，如生成自拍或生活图片等。自行决定使用用途。
上下文中如果出现［图片］标签，意思是这个地方有一个图片占位，这意味着一次图片工具调用，而不是一个单纯的文本标签。

## 提示词书写规范（NovelAI V4.5）
以 Danbooru 标签为骨架，场景或姿势越复杂，越需要用英文自然语言来精确描述细节（如肢体关系、人物互动、空间布局等）。提示词只用英文，不要用中文。总长度控制在 512 tokens 以内。

### 推荐 Tag 结构（不必每次都写满）
1. 视角/镜头：pov, close-up, cowboy shot, full body, from below, dutch angle
2. 人数/主体：1girl, solo / 2girls / 1boy 1girl
3. 人物核心设定：发型、发色、瞳色、服装、表情
4. 动作/姿势骨架(tag)：standing, kneeling, running, leaning forward
5. 场景与光：street, night, neon lights, rim light, dramatic lighting
6. 自然语言补关键细节：She is reaching forward with her left hand.
7. 质量标签：masterpiece, best quality, very aesthetic

示例：
1girl, solo, kneeling, low angle, foreshortening, dynamic pose, full body, city night, dramatic lighting, She is kneeling on one knee with her right hand on the ground and left hand reaching forward. masterpiece, best quality, very aesthetic

### 权重语法
- {tag} 加强(×1.05/层)，[tag] 减弱(÷1.05/层)，可多层嵌套
- 数值权重：1.4::low angle, foreshortening:: = 该段×1.4
- 负权重(V4.5)：-1::hat:: = 强力移除
- 注意：Undesired Content 中 {} 和 [] 语义反转

### POV 第一人称视角
用于自拍、主观镜头等场景：
- {{{pov}}} 放最前面并加权，pov_hands 显示观者的手
- 加 head out of frame 隐藏观者头部
- 避免 full body 等暗示第三方镜头的词
- POV + 多人互动时，观者不需要单独的角色描述，只描述对方

示例（男主视角拥抱女主）：
{{{pov}}}, {pov_hands}, close-up, upper body, indoor, soft warm lighting, The viewer's arms wrap around her waist. | 1girl, long hair, white shirt, target#hug, eyes closed, smiling, face close to camera

### 多角色（2人及以上）
用 | 分隔：基底提示词 | 角色1 | 角色2
- 基底：放角色总数、场景、构图、质量标签，以及人物间关系的自然语言描述。不放角色外貌
- 各角色段：以 girl/boy/other 开头，独立描述外貌、服装、动作
- 角色顺序 = 画面从左到右

示例：
2girls, indoor, bedroom, warm lighting, depth of field, A girl and a boy are hugging each other. The girl rests her head on his chest. masterpiece, best quality | girl, long black hair, white dress, target#hug, eyes closed, smiling | boy, short brown hair, casual clothes, source#hug, arms around her back

### 角色交互动作
在角色段中用前缀指定主被动：
- source#动作 = 发起方，target#动作 = 承受方，mutual#动作 = 双方共同
- 常用：hug, mutual_hug, hug_from_behind, holding hands, carrying, headpat, pointing at another, kissing, leaning on another

### 负面提示词
精简为主。按场景选用：
- 基础：worst quality, low quality, blurry, watermark, bad anatomy, bad hands, missing fingers
- POV 场景追加：selfie, mirror, third-person view, full body
- 多人场景追加：extra people, wrong eye color, wrong hair color

### 图片尺寸
竖图人像：832×1216，横图：1216×832，方图：1024×1024''';

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
      return defaultToolDescriptionBlocks;
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
      return selectedPreset.content.trim();
    }
    return defaultInlinePromptTemplate;
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
      return defaultToolDescriptionBlocks;
    }
    return defaultToolDescriptionBlocks.copyWith(promptDescription: trimmed);
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
    return base;
  }
}
