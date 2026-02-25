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
import '../../../../features/settings/settings_models.dart';
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
              fontWeight: MoeFontWeights.emphasis,
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
          fontWeight: MoeFontWeights.emphasis,
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
    final fgColor =
        isDark ? capability.color.withValues(alpha: 0.9) : capability.color;

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
              fontWeight: MoeFontWeights.emphasis,
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

  static ModelFeature? fromValue(String value) {
    final normalized = value.trim().toLowerCase();
    for (final feature in ModelFeature.values) {
      if (feature.value == normalized) return feature;
    }
    return null;
  }

  static List<ModelFeature> fromValues(Iterable<String> values) {
    final result = <ModelFeature>[];
    for (final value in values) {
      final feature = fromValue(value);
      if (feature != null && !result.contains(feature)) {
        result.add(feature);
      }
    }
    return result;
  }
}

// 视觉模型匹配规则（参考 Cherry Studio）
List<ModelFeature> inferModelFeatures(String modelId) {
  final capabilities = inferChatModelCapabilities(modelId);
  return capabilities
      .map((cap) => ModelFeature.fromValue(cap.value))
      .whereType<ModelFeature>()
      .toList();
}

class ModelFeatureChips extends StatelessWidget {
  const ModelFeatureChips({
    super.key,
    required this.modelId,
    this.features,
    this.size = CapabilityChipSize.sm,
    this.showIcon = false,
    this.maxShow,
  });

  /// 模型ID（用于推断特性）
  final String modelId;
  final List<ModelFeature>? features;

  /// 标签尺寸
  final CapabilityChipSize size;

  /// 是否显示图标
  final bool showIcon;

  /// 最多显示数量
  final int? maxShow;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final resolvedFeatures = features ?? inferModelFeatures(modelId);

    if (resolvedFeatures.isEmpty) return const SizedBox.shrink();

    final displayFeatures =
        maxShow != null && resolvedFeatures.length > maxShow!
            ? resolvedFeatures.take(maxShow!).toList()
            : resolvedFeatures;
    final extraCount = maxShow != null ? resolvedFeatures.length - maxShow! : 0;

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
    final fgColor =
        isDark ? feature.color.withValues(alpha: 0.9) : feature.color;

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
              fontWeight: MoeFontWeights.emphasis,
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
          fontWeight: MoeFontWeights.emphasis,
          height: 1,
        ),
      ),
    );
  }
}
