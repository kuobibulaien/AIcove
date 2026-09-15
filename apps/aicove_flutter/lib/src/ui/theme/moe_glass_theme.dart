import 'package:flutter/material.dart';

/// 全局玻璃材质效果配置（用于控制悬浮栏、导航背景等的毛玻璃效果和模糊强度）
enum MoeSurfaceMaterial {
  solid('纯色'),
  frosted('模糊'),
  liquid('玻璃');

  const MoeSurfaceMaterial(this.label);
  final String label;

  static MoeSurfaceMaterial fromFlags({
    required bool enabled,
    required bool liquid,
  }) => !enabled ? solid : (liquid ? MoeSurfaceMaterial.liquid : frosted);
}

/// Ordered glass presets. Existing stored sigma values use the nearest preset
/// for display and rendering without rewriting preferences on read.
enum MoeGlassThickness {
  clear('通透', 0),
  medium('中等', 16),
  heavy('厚重', 32);

  const MoeGlassThickness(this.label, this.sigma);
  final String label;
  final double sigma;

  static MoeGlassThickness fromSigma(double sigma) =>
      values[(sigma / 16).round().clamp(0, 2)];
}

class MoeGlassTheme extends InheritedWidget {
  const MoeGlassTheme({
    super.key,
    required this.enabled,
    required this.blurSigma,
    this.useLiquidGlass = false,
    required super.child,
  });

  /// 是否启用玻璃材质（毛玻璃背景模糊）
  final bool enabled;

  /// 毛玻璃模糊强度（sigma）
  final double blurSigma;

  /// 是否使用液态玻璃材质（透镜物理折射，关闭时回退常规毛玻璃）
  final bool useLiquidGlass;

  MoeSurfaceMaterial get material =>
      MoeSurfaceMaterial.fromFlags(enabled: enabled, liquid: useLiquidGlass);

  /// 获取当前环境的 [MoeGlassTheme]，若未找到则返回 null
  static MoeGlassTheme? maybeOf(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<MoeGlassTheme>();
  }

  /// 获取当前环境的 [MoeGlassTheme]
  static MoeGlassTheme of(BuildContext context) {
    final theme = maybeOf(context);
    assert(theme != null, 'No MoeGlassTheme found in context');
    return theme!;
  }

  @override
  bool updateShouldNotify(MoeGlassTheme oldWidget) {
    return enabled != oldWidget.enabled ||
        blurSigma != oldWidget.blurSigma ||
        useLiquidGlass != oldWidget.useLiquidGlass;
  }
}
