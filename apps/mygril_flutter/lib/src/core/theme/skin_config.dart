/// SkinConfig - 皮肤配置抽象接口
/// 
/// 定义可换肤组件的外观配置，每种皮肤风格实现此接口。
/// 
/// 支持的皮肤：
/// - MoeTalkSkin：简约 MoeTalk 风格（默认）
/// - GlassmorphismSkin：高斯模糊现代风格（待实现）
/// - ForestBookSkin：森林之书风格（待实现）
/// 
/// 更新记录：
/// - 2025-12-06: 创建皮肤系统抽象接口
import 'dart:ui';
import 'package:flutter/material.dart';
import 'tokens.dart';

/// 皮肤配置抽象类
abstract class SkinConfig {
  const SkinConfig();
  // ===== 基础信息 =====
  
  /// 皮肤唯一标识（用于持久化）
  String get id;
  
  /// 显示名称
  String get displayName;
  
  /// 皮肤描述
  String get description;
  
  // ===== 颜色方案 =====
  
  /// 浅色模式颜色
  MoeColors get lightColors;
  
  /// 深色模式颜色
  MoeColors get darkColors;
  
  // ===== 形状参数 =====
  
  /// 卡片圆角半径
  double get cardRadius;
  
  /// 气泡圆角半径
  double get bubbleRadius;
  
  /// 按钮圆角半径
  double get buttonRadius;
  
  /// 边框宽度
  double get borderWidth;
  
  /// 头像圆角半径
  double get avatarRadius;
  
  // ===== 装饰工厂方法 =====
  
  /// AppBar 装饰（头部背景）
  BoxDecoration appBarDecoration(MoeColors colors);
  
  /// 卡片装饰
  BoxDecoration cardDecoration(MoeColors colors);
  
  /// 面板装饰（设置面板、侧边栏）
  BoxDecoration panelDecoration(MoeColors colors);
  
  /// Toast 装饰
  BoxDecoration toastDecoration(Color bgColor);
  
  /// 消息气泡装饰
  BoxDecoration bubbleDecoration(MoeColors colors, {required bool isMe});
  
  /// 底部导航栏装饰
  BoxDecoration bottomNavDecoration(MoeColors colors);
  
  /// 输入框装饰
  BoxDecoration inputDecoration(MoeColors colors);
  
  // ===== 特效配置 =====
  
  /// 是否启用毛玻璃效果
  bool get useBlurEffect;
  
  /// 模糊强度（0 = 关闭）
  double get blurSigma;
  
  /// 背景滤镜（用于毛玻璃）
  ImageFilter? get backgroundFilter => useBlurEffect 
      ? ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma)
      : null;
  
  // ===== 辅助方法 =====
  
  /// 根据亮度获取对应颜色
  MoeColors colorsFor(Brightness brightness) {
    return brightness == Brightness.dark ? darkColors : lightColors;
  }
}

/// 皮肤装饰包装器（用于需要模糊效果的组件）
class SkinDecoratedBox extends StatelessWidget {
  final SkinConfig skin;
  final MoeColors colors;
  final BoxDecoration Function(MoeColors) decorationBuilder;
  final Widget child;
  
  const SkinDecoratedBox({
    super.key,
    required this.skin,
    required this.colors,
    required this.decorationBuilder,
    required this.child,
  });
  
  @override
  Widget build(BuildContext context) {
    final decoration = decorationBuilder(colors);
    
    if (skin.useBlurEffect && skin.backgroundFilter != null) {
      return ClipRRect(
        borderRadius: decoration.borderRadius as BorderRadius? ?? BorderRadius.zero,
        child: BackdropFilter(
          filter: skin.backgroundFilter!,
          child: Container(
            decoration: decoration,
            child: child,
          ),
        ),
      );
    }
    
    return Container(
      decoration: decoration,
      child: child,
    );
  }
}
