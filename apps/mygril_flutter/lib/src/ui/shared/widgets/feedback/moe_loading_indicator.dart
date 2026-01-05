/// MoeLoadingIndicator - 加载指示器组件
/// 
/// 统一的加载状态显示。
/// 
/// 设计特点：
/// - 支持多种尺寸
/// - 可选的加载文字
/// - 颜色跟随主题
/// 
/// 使用示例：
/// ```dart
/// MoeLoadingIndicator(
///   message: '加载中...',
/// )
/// ```
/// 
/// 更新记录：
/// - 2025-12-31: 创建加载指示器组件
library;

import 'package:flutter/material.dart';
import '../../../theme/tokens.dart';

/// 加载指示器尺寸枚举
enum MoeLoadingSize { sm, md, lg }

/// 加载指示器组件
class MoeLoadingIndicator extends StatelessWidget {
  const MoeLoadingIndicator({
    super.key,
    this.message,
    this.size = MoeLoadingSize.md,
    // === 样式接口 ===
    this.color,
    this.textColor,
    this.strokeWidth,
  });

  /// 加载提示文字（可选）
  final String? message;

  /// 指示器尺寸
  final MoeLoadingSize size;

  // === 样式接口 ===
  
  /// 指示器颜色
  final Color? color;

  /// 文字颜色
  final Color? textColor;

  /// 线条宽度
  final double? strokeWidth;

  double get _indicatorSize {
    switch (size) {
      case MoeLoadingSize.sm:
        return 16;
      case MoeLoadingSize.md:
        return 24;
      case MoeLoadingSize.lg:
        return 36;
    }
  }

  double get _strokeWidth {
    switch (size) {
      case MoeLoadingSize.sm:
        return 2;
      case MoeLoadingSize.md:
        return 2.5;
      case MoeLoadingSize.lg:
        return 3;
    }
  }

  double get _fontSize {
    switch (size) {
      case MoeLoadingSize.sm:
        return 12;
      case MoeLoadingSize.md:
        return 14;
      case MoeLoadingSize.lg:
        return 16;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final indicatorColor = color ?? colors.focus;
    final messageColor = textColor ?? colors.muted;
    final stroke = strokeWidth ?? _strokeWidth;

    return Column(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        SizedBox(
          width: _indicatorSize,
          height: _indicatorSize,
          child: CircularProgressIndicator(
            strokeWidth: stroke,
            valueColor: AlwaysStoppedAnimation(indicatorColor),
          ),
        ),
        if (message != null) ...[
          const SizedBox(height: 12),
          Text(
            message!,
            style: TextStyle(
              fontSize: _fontSize,
              color: messageColor,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ],
    );
  }
}
