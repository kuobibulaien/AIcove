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

## 提示词书写规范（NovelAI V4/V4.5）
你传给 draw_image 工具的 prompt 必须遵循以下格式，不要写自然语言段落：

### 格式
使用英文逗号分隔的 tag 列表，例如：
1girl, long hair, blue eyes, school uniform, standing, cherry blossoms, outdoors, wind, masterpiece, best quality, very aesthetic

### Tag 顺序（重要性由前到后递减）
1. 人物数量：1girl / 1boy / 2girls / no humans …
2. 角色特征：发色、瞳色、发型、服装等
3. 动作与表情：standing, smile, looking at viewer …
4. 场景与背景：outdoors, city, night sky …
5. 构图与镜头：upper body, cowboy shot, close-up, from above …
6. 光影与氛围：sunlight, dramatic lighting, lens flare …
7. 质量标签（放在末尾）：masterpiece, best quality, very aesthetic, absurdres

### 质量标签参考
- V4.5 Full 末尾追加: location, very aesthetic, masterpiece, no text
- V4.5 Curated 末尾追加: location, masterpiece, no text, rating:general
- V4 Full 末尾追加: no text, best quality, very aesthetic, absurdres
- V4 Curated 末尾追加: rating:general, amazing quality, very aesthetic, absurdres
- 如果不确定模型版本，使用通用组合: masterpiece, best quality, very aesthetic, absurdres

### 负面提示词
通过 negative_prompt 参数单独传入，常用负面 tag：
lowres, bad anatomy, bad hands, missing fingers, extra digits, fewer digits, cropped, worst quality, low quality, normal quality, jpeg artifacts, blurry, watermark, text, error

### 注意事项
- 不要在 prompt 里写完整英文句子，用 tag 即可
- Tag 越靠前权重越高，把最重要的特征放前面
- 用户没有指定风格时默认使用动漫风格
- 图片尺寸：人像竖图推荐 832x1216，横图推荐 1216x832，方图 1024x1024''';

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
    List<ArtistPreset>? artistPresets,
    String? selectedArtistPresetName,
    bool clearSelectedArtistPreset = false,
  }) {
    return ImageConfig(
      selectedProviderId: clearSelectedProviderId
          ? null
          : (selectedProviderId ?? this.selectedProviderId),
      selectedModelId:
          clearSelectedModelId ? null : (selectedModelId ?? this.selectedModelId),
      defaultNegativePrompt:
          defaultNegativePrompt ?? this.defaultNegativePrompt,
      defaultWidth: defaultWidth ?? this.defaultWidth,
      defaultHeight: defaultHeight ?? this.defaultHeight,
      defaultSteps: defaultSteps ?? this.defaultSteps,
      defaultGuidanceScale: defaultGuidanceScale ?? this.defaultGuidanceScale,
      defaultCount: defaultCount ?? this.defaultCount,
      timeoutSeconds: timeoutSeconds ?? this.timeoutSeconds,
      drawingSystemPrompt: drawingSystemPrompt ?? this.drawingSystemPrompt,
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
      artistPresets: (json['artistPresets'] as List<dynamic>?)
              ?.map((e) => ArtistPreset.fromJson(e as Map<String, dynamic>))
              .toList() ??
          defaultArtistPresets,
      selectedArtistPresetName:
          json['selectedArtistPresetName'] as String?,
    );
  }

  /// 获取当前选中的画师串预设（如果有）
  ArtistPreset? get selectedArtistPreset {
    if (selectedArtistPresetName == null) return null;
    return artistPresets
        .where((p) => p.name == selectedArtistPresetName)
        .firstOrNull;
  }

  /// 组合最终发送给 AI 的 system prompt（含画师串预设提示）
  String get effectiveSystemPrompt {
    final base = drawingSystemPrompt.trim().isNotEmpty
        ? drawingSystemPrompt
        : defaultDrawingSystemPrompt;
    final preset = selectedArtistPreset;
    if (preset == null) return base;
    return '$base\n\n## 用户默认画师串预设\n'
        '用户设置的默认画师串预设是：\n${preset.content}\n'
        '如果没有其他需要，请在生成图片的 prompt 前面加上这段画师串。';
  }
}
