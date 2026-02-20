class ImageConfig {
  final String? selectedProviderId;
  final String? selectedModelId;
  final String defaultNegativePrompt;
  final int defaultWidth;
  final int defaultHeight;
  final int defaultSteps;
  final double defaultGuidanceScale;
  final int defaultCount;
  final String drawingSystemPrompt;

  /// NovelAI 生图提示词规范（默认值），作为 system prompt 注入给 AI。
  static const defaultDrawingSystemPrompt = '''
当用户明确要求"画图/生成图片/做一张图/插画/海报/壁纸"时，请优先调用 `draw_image` 工具，不要只返回文字描述。
你可以先澄清关键需求（风格、主体、构图、尺寸），然后再调用工具。
工具执行后，用一句简短自然的话说明"图已生成"即可。

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
    this.defaultWidth = 1024,
    this.defaultHeight = 1024,
    this.defaultSteps = 28,
    this.defaultGuidanceScale = 5.0,
    this.defaultCount = 1,
    this.drawingSystemPrompt = defaultDrawingSystemPrompt,
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
    String? drawingSystemPrompt,
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
      drawingSystemPrompt: drawingSystemPrompt ?? this.drawingSystemPrompt,
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
      'drawingSystemPrompt': drawingSystemPrompt,
    };
  }

  factory ImageConfig.fromJson(Map<String, dynamic> json) {
    return ImageConfig(
      selectedProviderId: json['selectedProviderId'] as String?,
      selectedModelId: json['selectedModelId'] as String?,
      defaultNegativePrompt: json['defaultNegativePrompt'] as String? ?? '',
      defaultWidth: (json['defaultWidth'] as num?)?.toInt() ?? 1024,
      defaultHeight: (json['defaultHeight'] as num?)?.toInt() ?? 1024,
      defaultSteps: (json['defaultSteps'] as num?)?.toInt() ?? 28,
      defaultGuidanceScale:
          (json['defaultGuidanceScale'] as num?)?.toDouble() ?? 5.0,
      defaultCount: (json['defaultCount'] as num?)?.toInt() ?? 1,
      drawingSystemPrompt:
          json['drawingSystemPrompt'] as String? ?? defaultDrawingSystemPrompt,
    );
  }
}
