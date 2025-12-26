/// MoeTalkSkin - 简约 MoeTalk 风格皮肤
/// 
/// 特点：
/// - 粉色头部（浅色模式）
/// - 纯色背景，无模糊
/// - 圆角 10px
/// - 细边框 0.5px
/// 
/// 更新记录：
/// - 2025-12-06: 从 tokens.dart 迁移，作为默认皮肤实现
import 'package:flutter/material.dart';
import '../skin_config.dart';
import '../tokens.dart';

class MoeTalkSkin extends SkinConfig {
  const MoeTalkSkin() : super();
  
  // ===== 基础信息 =====
  
  @override
  String get id => 'moetalk';
  
  @override
  String get displayName => 'MoeTalk';
  
  @override
  String get description => '简约蓝色风格，经典 MoeTalk 外观';
  
  // ===== 颜色方案 =====
  
  @override
  MoeColors get lightColors => MoeColors.light;
  
  @override
  MoeColors get darkColors => MoeColors.dark;
  
  // ===== 形状参数 =====
  
  @override
  double get cardRadius => 10.0;
  
  @override
  double get bubbleRadius => 10.0;
  
  @override
  double get buttonRadius => 8.0;
  
  @override
  double get borderWidth => 0.5;
  
  @override
  double get avatarRadius => 64.0;
  
  // ===== 特效配置 =====
  
  @override
  bool get useBlurEffect => false;
  
  @override
  double get blurSigma => 0;
  
  // ===== 装饰工厂方法 =====
  
  @override
  BoxDecoration appBarDecoration(MoeColors colors) {
    return BoxDecoration(
      color: colors.headerColor,
      border: Border(
        bottom: BorderSide(color: colors.divider, width: borderWidth),
      ),
    );
  }
  
  @override
  BoxDecoration cardDecoration(MoeColors colors) {
    return BoxDecoration(
      color: colors.panel,
      borderRadius: BorderRadius.circular(cardRadius),
      border: Border.all(color: colors.border, width: borderWidth),
    );
  }
  
  @override
  BoxDecoration panelDecoration(MoeColors colors) {
    return BoxDecoration(
      color: colors.surface,
      border: Border(
        right: BorderSide(color: colors.divider, width: borderWidth),
      ),
    );
  }
  
  @override
  BoxDecoration toastDecoration(Color bgColor) {
    return BoxDecoration(
      color: bgColor.withOpacity(0.95),
      borderRadius: BorderRadius.circular(12),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withOpacity(0.2),
          blurRadius: 12,
          offset: const Offset(0, 4),
        ),
      ],
    );
  }
  
  @override
  BoxDecoration bubbleDecoration(MoeColors colors, {required bool isMe}) {
    return BoxDecoration(
      color: isMe ? colors.bubbleRightBg : colors.bubbleLeftBg,
      borderRadius: BorderRadius.circular(bubbleRadius),
      border: Border.all(
        color: isMe ? colors.bubbleRightBorder : colors.bubbleLeftBorder,
        width: borderWidth,
      ),
    );
  }
  
  @override
  BoxDecoration bottomNavDecoration(MoeColors colors) {
    return BoxDecoration(
      color: colors.surface,
      border: Border(
        top: BorderSide(color: colors.divider, width: borderWidth),
      ),
    );
  }
  
  @override
  BoxDecoration inputDecoration(MoeColors colors) {
    return BoxDecoration(
      color: colors.surface,
      borderRadius: BorderRadius.circular(buttonRadius),
      border: Border.all(color: colors.border, width: borderWidth),
    );
  }
}
