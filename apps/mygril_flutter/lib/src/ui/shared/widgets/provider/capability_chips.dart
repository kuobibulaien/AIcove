/// CapabilityChips - 能力标签组件
/// 
/// 显示供应商支持的模型用途标签。
/// 
/// 设计特点：
/// - 小圆角 Chip 水平排列
/// - 每种用途有独特的图标和颜色
/// - 支持亮/暗色模式
/// 
/// 使用示例：
/// ```dart
/// CapabilityChips(
///   capabilities: ['chat', 'embedding'],
/// )
/// ```
/// 
/// 更新记录：
/// - 2026-01-21: 创建能力标签组件
library;

import 'package:flutter/material.dart';
import '../../../theme/tokens.dart';
import '../../effects/smooth_clip.dart';

/// 模型能力类型
enum ModelCapability {
  chat('chat', '对话', Icons.chat_bubble_outline, Color(0xFF4A90E2)),
  embedding('embedding', '嵌入', Icons.link, Color(0xFF10B981)),
  image('image', '图片', Icons.image_outlined, Color(0xFFF59E0B)),
  tts('tts', '语音', Icons.volume_up_outlined, Color(0xFFEC4899)),
  tools('tools', '工具调用', Icons.build_outlined, Color(0xFF8B5CF6));

  const ModelCapability(this.value, this.label, this.icon, this.color);
  
  /// API 值
  final String value;
  /// 显示标签
  final String label;
  /// 图标
  final IconData icon;
  /// 主题色
  final Color color;

  /// 从字符串解析
  static ModelCapability? fromValue(String value) {
    for (final cap in ModelCapability.values) {
      if (cap.value == value) return cap;
    }
    return null;
  }

  /// 从字符串列表解析
  static List<ModelCapability> fromValues(List<String> values) {
    return values
        .map((v) => fromValue(v))
        .whereType<ModelCapability>()
        .toList();
  }
}

/// 能力标签尺寸
enum CapabilityChipSize {
  /// 小尺寸 - 列表项
  sm(16, 10, 4, 6, 2),
  /// 中尺寸 - 默认
  md(20, 12, 6, 8, 4);

  const CapabilityChipSize(
    this.height,
    this.fontSize,
    this.iconSize,
    this.paddingH,
    this.spacing,
  );
  
  final double height;
  final double fontSize;
  final double iconSize;
  final double paddingH;
  final double spacing;
}

/// 能力标签组件
class CapabilityChips extends StatelessWidget {
  const CapabilityChips({
    super.key,
    required this.capabilities,
    this.size = CapabilityChipSize.sm,
    this.showIcon = true,
    this.maxShow,
  });

  /// 能力列表（字符串）
  final List<String> capabilities;

  /// 标签尺寸
  final CapabilityChipSize size;

  /// 是否显示图标
  final bool showIcon;

  /// 最多显示数量（超出显示 +N）
  final int? maxShow;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final caps = ModelCapability.fromValues(capabilities);
    
    if (caps.isEmpty) return const SizedBox.shrink();

    final displayCaps = maxShow != null && caps.length > maxShow!
        ? caps.take(maxShow!).toList()
        : caps;
    final extraCount = maxShow != null ? caps.length - maxShow! : 0;

    return Wrap(
      spacing: size.spacing,
      runSpacing: size.spacing,
      children: [
        ...displayCaps.map((cap) => _buildChip(context, cap, isDark)),
        if (extraCount > 0) _buildExtraChip(context, extraCount, isDark),
      ],
    );
  }

  Widget _buildChip(BuildContext context, ModelCapability cap, bool isDark) {
    final bgColor = cap.color.withValues(alpha: isDark ? 0.2 : 0.12);
    final fgColor = isDark ? cap.color.withValues(alpha: 0.9) : cap.color;

    return Container(
      height: size.height,
      padding: EdgeInsets.symmetric(horizontal: size.paddingH),
      decoration: MoeG2Decoration(
        radius: size.height / 2,
        color: bgColor,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showIcon) ...[
            Icon(cap.icon, size: size.iconSize, color: fgColor),
            SizedBox(width: size.spacing),
          ],
          Text(
            cap.label,
            style: TextStyle(
              fontSize: size.fontSize,
              color: fgColor,
              fontWeight: FontWeight.w500,
              height: 1,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildExtraChip(BuildContext context, int count, bool isDark) {
    final colors = context.moeColors;
    
    return Container(
      height: size.height,
      padding: EdgeInsets.symmetric(horizontal: size.paddingH),
      decoration: MoeG2Decoration(
        radius: size.height / 2,
        color: colors.border.withValues(alpha: 0.5),
      ),
      child: Text(
        '+$count',
        style: TextStyle(
          fontSize: size.fontSize,
          color: colors.textSecondary,
          fontWeight: FontWeight.w500,
          height: 1,
        ),
      ),
    );
  }
}

/// 单个能力标签（用于独立显示）
class CapabilityChip extends StatelessWidget {
  const CapabilityChip({
    super.key,
    required this.capability,
    this.size = CapabilityChipSize.sm,
    this.showIcon = true,
  });

  /// 能力类型
  final ModelCapability capability;

  /// 标签尺寸
  final CapabilityChipSize size;

  /// 是否显示图标
  final bool showIcon;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = capability.color.withValues(alpha: isDark ? 0.2 : 0.12);
    final fgColor = isDark ? capability.color.withValues(alpha: 0.9) : capability.color;

    return Container(
      height: size.height,
      padding: EdgeInsets.symmetric(horizontal: size.paddingH),
      decoration: MoeG2Decoration(
        radius: size.height / 2,
        color: bgColor,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showIcon) ...[
            Icon(capability.icon, size: size.iconSize, color: fgColor),
            SizedBox(width: size.spacing),
          ],
          Text(
            capability.label,
            style: TextStyle(
              fontSize: size.fontSize,
              color: fgColor,
              fontWeight: FontWeight.w500,
              height: 1,
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// 模型特性标签（Model Features）- 基于模型名称自动推断
// ============================================================================

/// 模型特性类型（基于模型名称推断）
enum ModelFeature {
  vision('vision', '视觉', Icons.visibility_outlined, Color(0xFF8B5CF6)),
  tools('tools', '工具', Icons.build_outlined, Color(0xFF10B981)),
  reasoning('reasoning', '思考', Icons.psychology_outlined, Color(0xFFF59E0B)),
  web('web', '联网', Icons.language_outlined, Color(0xFF3B82F6));

  const ModelFeature(this.value, this.label, this.icon, this.color);
  
  final String value;
  final String label;
  final IconData icon;
  final Color color;
}

// 视觉模型匹配规则（参考 Cherry Studio）
final _visionPatterns = RegExp(
  r'\b('
  r'vision|'
  r'vl\b|'              // qwen-vl, deepseek-vl
  r'4o|'                // gpt-4o 系列
  r'gpt-4-turbo|'
  r'gpt-4\.1|'
  r'gpt-5|'
  r'claude-3|'
  r'claude-.*-4|'       // claude-sonnet-4 等
  r'gemini|'
  r'gemma-3|'
  r'glm-4v|'
  r'qvq|'
  r'o1(?!-mini)|'       // o1 但不是 o1-mini
  r'o3(?!-mini)|'       // o3 但不是 o3-mini
  r'o4|'
  r'grok-vision|'
  r'grok-4|'
  r'pixtral|'
  r'llava|'
  r'moondream|'
  r'minicpm|'
  r'internvl'
  r')\b',
  caseSensitive: false,
);

// 工具调用模型匹配规则
final _toolsPatterns = RegExp(
  r'\b('
  r'gpt-4|'
  r'gpt-3\.5-turbo|'
  r'gpt-5|'
  r'o1|o3|o4|'
  r'claude|'
  r'qwen|'
  r'deepseek(?!-vl)|'   // deepseek 但不是 deepseek-vl（纯视觉）
  r'glm-4|'
  r'gemini|'
  r'grok|'
  r'hunyuan|'
  r'doubao|'
  r'minimax|'
  r'kimi'
  r')\b',
  caseSensitive: false,
);

// 思考/推理模型匹配规则
final _reasoningPatterns = RegExp(
  r'\b('
  r'o1|o3|o4|'
  r'qwq|'
  r'reasoner|'
  r'reasoning|'
  r'thinking|'
  r'think\b|'
  r'r1\b|'
  r'hunyuan-t1|'
  r'glm-zero|'
  r'deepseek-r|'
  r'marco-o1'
  r')\b',
  caseSensitive: false,
);

// 联网搜索模型匹配规则
final _webPatterns = RegExp(
  r'\b('
  r'search|'
  r'online|'
  r'web|'
  r'sonar|'
  r'realtime|'
  r'perplexity'
  r')\b',
  caseSensitive: false,
);

/// 根据模型ID推断其特性
List<ModelFeature> inferModelFeatures(String modelId) {
  final features = <ModelFeature>[];
  final id = modelId.toLowerCase();
  
  if (_visionPatterns.hasMatch(id)) {
    features.add(ModelFeature.vision);
  }
  if (_toolsPatterns.hasMatch(id)) {
    features.add(ModelFeature.tools);
  }
  if (_reasoningPatterns.hasMatch(id)) {
    features.add(ModelFeature.reasoning);
  }
  if (_webPatterns.hasMatch(id)) {
    features.add(ModelFeature.web);
  }
  
  return features;
}

/// 模型特性标签组件
class ModelFeatureChips extends StatelessWidget {
  const ModelFeatureChips({
    super.key,
    required this.modelId,
    this.size = CapabilityChipSize.sm,
    this.showIcon = false,
    this.maxShow,
  });

  /// 模型ID（用于推断特性）
  final String modelId;

  /// 标签尺寸
  final CapabilityChipSize size;

  /// 是否显示图标
  final bool showIcon;

  /// 最多显示数量
  final int? maxShow;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final features = inferModelFeatures(modelId);
    
    if (features.isEmpty) return const SizedBox.shrink();

    final displayFeatures = maxShow != null && features.length > maxShow!
        ? features.take(maxShow!).toList()
        : features;
    final extraCount = maxShow != null ? features.length - maxShow! : 0;

    return Wrap(
      spacing: size.spacing,
      runSpacing: size.spacing,
      children: [
        ...displayFeatures.map((f) => _buildChip(context, f, isDark)),
        if (extraCount > 0) _buildExtraChip(context, extraCount, isDark),
      ],
    );
  }

  Widget _buildChip(BuildContext context, ModelFeature feature, bool isDark) {
    final bgColor = feature.color.withValues(alpha: isDark ? 0.2 : 0.12);
    final fgColor = isDark ? feature.color.withValues(alpha: 0.9) : feature.color;

    return Container(
      height: size.height,
      padding: EdgeInsets.symmetric(horizontal: size.paddingH),
      decoration: MoeG2Decoration(
        radius: size.height / 2,
        color: bgColor,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showIcon) ...[
            Icon(feature.icon, size: size.iconSize, color: fgColor),
            SizedBox(width: size.spacing),
          ],
          Text(
            feature.label,
            style: TextStyle(
              fontSize: size.fontSize,
              color: fgColor,
              fontWeight: FontWeight.w500,
              height: 1,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildExtraChip(BuildContext context, int count, bool isDark) {
    final colors = context.moeColors;
    
    return Container(
      height: size.height,
      padding: EdgeInsets.symmetric(horizontal: size.paddingH),
      decoration: MoeG2Decoration(
        radius: size.height / 2,
        color: colors.border.withValues(alpha: 0.5),
      ),
      child: Text(
        '+$count',
        style: TextStyle(
          fontSize: size.fontSize,
          color: colors.textSecondary,
          fontWeight: FontWeight.w500,
          height: 1,
        ),
      ),
    );
  }
}
