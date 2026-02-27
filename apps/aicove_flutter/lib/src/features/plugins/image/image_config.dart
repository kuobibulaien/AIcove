/// 画师串预设
class ArtistPreset {
  final String name;
  final String content;

  const ArtistPreset({required this.name, required this.content});

  Map<String, dynamic> toJson() => {'name': name, 'content': content};

  factory ArtistPreset.fromJson(Map<String, dynamic> json) => ArtistPreset(
        name: json['name'] as String? ?? '',
        content: json['content'] as String? ?? '',
      );
}

/// 绘图系统提示词预设
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

class ImageConfig {
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
  final List<ArtistPreset> artistPresets;
  final String? selectedArtistPresetName;

  /// 内置默认画师串预设
  static const defaultArtistPresets = [
    ArtistPreset(
      name: '防冻液',
      content:
          '[[omochi monaka]] ,{{kele mimi}} ,[ruriri], [[[[[d omm]]]]] ,[[[[[[[tianliang_duohe_fangdongye]]]]]] ,Ningen Mame, {{year 2024}},',
    ),
  ];

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
      name: 'NovelAI 通用',
      content: defaultDrawingSystemPrompt,
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
    this.drawingSystemPrompt = defaultDrawingSystemPrompt,
    this.systemPromptPresets = defaultSystemPromptPresets,
    this.selectedSystemPromptPresetName,
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
      drawingSystemPrompt:
          json['drawingSystemPrompt'] as String? ?? defaultDrawingSystemPrompt,
      systemPromptPresets: (json['systemPromptPresets'] as List<dynamic>?)
              ?.map((e) =>
                  DrawingPromptPreset.fromJson(e as Map<String, dynamic>))
              .toList() ??
          defaultSystemPromptPresets,
      selectedSystemPromptPresetName:
          json['selectedSystemPromptPresetName'] as String?,
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

  /// 获取当前选中的画师串预设（如果有）
  ArtistPreset? get selectedArtistPreset {
    if (selectedArtistPresetName == null) return null;
    return artistPresets
        .where((p) => p.name == selectedArtistPresetName)
        .firstOrNull;
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
