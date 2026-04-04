/// ProviderAvatar - 供应商品牌头像组件
///
/// 显示 AI 服务供应商的品牌标识。
///
/// 设计特点：
/// - 优先显示品牌 Logo（从 assets 加载）
/// - 无 Logo 时显示名称首字母
/// - 支持亮/暗色模式
/// - 圆角矩形外观
///
/// 使用示例：
/// ```dart
/// ProviderAvatar(
///   providerName: 'OpenAI',
///   size: 40,
/// )
/// ```
///
/// 更新记录：
/// - 2026-01-21: 创建供应商头像组件
library;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../../../theme/tokens.dart';
import '../../effects/smooth_clip.dart';

/// 供应商头像尺寸枚举
enum ProviderAvatarSize {
  /// 小尺寸 (32px) - 列表项
  sm(32, 12, 8),

  /// 中尺寸 (40px) - 默认
  md(40, 14, 10),

  /// 大尺寸 (56px) - 详情页
  lg(56, 20, 12);

  const ProviderAvatarSize(this.size, this.fontSize, this.radius);
  final double size;
  final double fontSize;
  final double radius;
}

/// 预设供应商品牌配色
class _ProviderBrand {
  final Color bgColor;
  final Color fgColor;

  const _ProviderBrand({
    required this.bgColor,
    required this.fgColor,
  });
}

/// 供应商品牌头像组件
class ProviderAvatar extends StatelessWidget {
  const ProviderAvatar({
    super.key,
    required this.providerName,
    this.size = ProviderAvatarSize.md,
    this.customBgColor,
    this.customFgColor,
  });

  /// 供应商名称
  final String providerName;

  /// 头像尺寸
  final ProviderAvatarSize size;

  /// 自定义背景色（覆盖预设）
  final Color? customBgColor;

  /// 自定义前景色（覆盖预设）
  final Color? customFgColor;

  /// 预设品牌配色映射
  static final Map<String, _ProviderBrand> _brands = {
    'openai': const _ProviderBrand(
      bgColor: Color(0xFF10A37F),
      fgColor: Colors.white,
    ),
    'claude': const _ProviderBrand(
      bgColor: Color(0xFFD97706),
      fgColor: Colors.white,
    ),
    'anthropic': const _ProviderBrand(
      bgColor: Color(0xFFD97706),
      fgColor: Colors.white,
    ),
    'gemini': const _ProviderBrand(
      bgColor: Color(0xFF4285F4),
      fgColor: Colors.white,
    ),
    'vertex': const _ProviderBrand(
      bgColor: Color(0xFF1A73E8),
      fgColor: Colors.white,
    ),
    'google': const _ProviderBrand(
      bgColor: Color(0xFF4285F4),
      fgColor: Colors.white,
    ),
    'deepseek': const _ProviderBrand(
      bgColor: Color(0xFF0066FF),
      fgColor: Colors.white,
    ),
    'doubao': const _ProviderBrand(
      bgColor: Color(0xFF00D6B9),
      fgColor: Colors.white,
    ),
    '豆包': const _ProviderBrand(
      bgColor: Color(0xFF00D6B9),
      fgColor: Colors.white,
    ),
    'qwen': const _ProviderBrand(
      bgColor: Color(0xFF6366F1),
      fgColor: Colors.white,
    ),
    '通义': const _ProviderBrand(
      bgColor: Color(0xFF6366F1),
      fgColor: Colors.white,
    ),
    'siliconflow': const _ProviderBrand(
      bgColor: Color(0xFF8B5CF6),
      fgColor: Colors.white,
    ),
    'moonshot': const _ProviderBrand(
      bgColor: Color(0xFF1A1A2E),
      fgColor: Colors.white,
    ),
    'kimi': const _ProviderBrand(
      bgColor: Color(0xFF1A1A2E),
      fgColor: Colors.white,
    ),
    'zhipu': const _ProviderBrand(
      bgColor: Color(0xFF3B82F6),
      fgColor: Colors.white,
    ),
    '智谱': const _ProviderBrand(
      bgColor: Color(0xFF3B82F6),
      fgColor: Colors.white,
    ),
    'baichuan': const _ProviderBrand(
      bgColor: Color(0xFFEC4899),
      fgColor: Colors.white,
    ),
    '百川': const _ProviderBrand(
      bgColor: Color(0xFFEC4899),
      fgColor: Colors.white,
    ),
    'minimax': const _ProviderBrand(
      bgColor: Color(0xFFE73562),
      fgColor: Colors.white,
    ),
    'ollama': const _ProviderBrand(
      bgColor: Color(0xFF000000),
      fgColor: Colors.white,
    ),
    'groq': const _ProviderBrand(
      bgColor: Color(0xFFF55036),
      fgColor: Colors.white,
    ),
    'mistral': const _ProviderBrand(
      bgColor: Color(0xFFFF7000),
      fgColor: Colors.white,
    ),
    'cohere': const _ProviderBrand(
      bgColor: Color(0xFF39594D),
      fgColor: Colors.white,
    ),
    'openrouter': const _ProviderBrand(
      bgColor: Color(0xFF6366F1),
      fgColor: Colors.white,
    ),
    'azure': const _ProviderBrand(
      bgColor: Color(0xFF0078D4),
      fgColor: Colors.white,
    ),
    'aliyun': const _ProviderBrand(
      bgColor: Color(0xFFFF6A00),
      fgColor: Colors.white,
    ),
    '阿里云': const _ProviderBrand(
      bgColor: Color(0xFFFF6A00),
      fgColor: Colors.white,
    ),
    'grok': const _ProviderBrand(
      bgColor: Color(0xFF000000),
      fgColor: Colors.white,
    ),
    'volcengine': const _ProviderBrand(
      bgColor: Color(0xFF3370FF),
      fgColor: Colors.white,
    ),
    '火山': const _ProviderBrand(
      bgColor: Color(0xFF3370FF),
      fgColor: Colors.white,
    ),
  };

  /// SVG 图标路径映射
  static const Map<String, String> _iconPaths = {
    'openai': 'assets/icons/providers/openai.svg',
    'openrouter': 'assets/icons/providers/openrouter.svg',
    'claude': 'assets/icons/providers/claude-color.svg',
    'anthropic': 'assets/icons/providers/claude-color.svg',
    'gemini': 'assets/icons/providers/gemini-color.svg',
    'vertex': 'assets/icons/providers/gemini-color.svg',
    'deepseek': 'assets/icons/providers/deepseek-color.svg',
    'minimax': 'assets/icons/providers/minimax-color.svg',
    'kimi': 'assets/icons/providers/kimi-color.svg',
    'moonshot': 'assets/icons/providers/kimi-color.svg',
    'siliconflow': 'assets/icons/providers/siliconflow-color.svg',
    '硅基流动': 'assets/icons/providers/siliconflow-color.svg',
    'aliyun': 'assets/icons/providers/alibabacloud-color.svg',
    '阿里云': 'assets/icons/providers/alibabacloud-color.svg',
    'volcengine': 'assets/icons/providers/bytedance-color.svg',
    '火山引擎': 'assets/icons/providers/bytedance-color.svg',
    '火山': 'assets/icons/providers/bytedance-color.svg',
  };

  /// 根据名称匹配品牌
  _ProviderBrand? _matchBrand(String name) {
    final lower = name.toLowerCase();
    for (final entry in _brands.entries) {
      if (lower.contains(entry.key)) {
        return entry.value;
      }
    }
    return null;
  }

  /// 根据名称匹配图标路径
  String? _matchIconPath(String name) {
    final lower = name.toLowerCase();
    for (final entry in _iconPaths.entries) {
      if (lower.contains(entry.key.toLowerCase())) {
        return entry.value;
      }
    }
    return null;
  }

  /// 根据名称生成默认颜色
  Color _generateColor(String name) {
    final hash = name.hashCode.abs();
    final hue = (hash % 360).toDouble();
    return HSLColor.fromAHSL(1.0, hue, 0.5, 0.45).toColor();
  }

  /// 获取首字母
  String _getInitials(String name) {
    if (name.isEmpty) return '?';

    // 尝试获取英文首字母
    final words = name.split(RegExp(r'[\s\-_]+'));
    if (words.length >= 2) {
      return '${words[0][0]}${words[1][0]}'.toUpperCase();
    }

    // 单词或中文，取第一个字符
    return name[0].toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final brand = _matchBrand(providerName);
    final iconPath = _matchIconPath(providerName);
    final bgColor =
        customBgColor ?? brand?.bgColor ?? _generateColor(providerName);
    final fgColor = customFgColor ?? brand?.fgColor ?? Colors.white;
    final initials = _getInitials(providerName);

    // 有 SVG 图标时优先使用图标
    if (iconPath != null) {
      final isDark = Theme.of(context).brightness == Brightness.dark;
      final containerBg = isDark ? const Color(0xFF2A2A2A) : Colors.white;
      return MoeG2ClipRRect(
        radius: size.radius,
        child: Container(
          width: size.size,
          height: size.size,
          color: containerBg,
          padding: EdgeInsets.all(size.size * 0.15),
          child: SvgPicture.asset(
            iconPath,
            fit: BoxFit.contain,
          ),
        ),
      );
    }

    // 无图标时显示首字母
    return Container(
      width: size.size,
      height: size.size,
      decoration: MoeG2Decoration(
        radius: size.radius,
        color: bgColor,
      ),
      alignment: Alignment.center,
      child: Text(
        initials,
        style: TextStyle(
          color: fgColor,
          fontSize: size.fontSize,
          fontWeight: MoeFontWeights.emphasis,
          height: 1,
        ),
      ),
    );
  }
}
