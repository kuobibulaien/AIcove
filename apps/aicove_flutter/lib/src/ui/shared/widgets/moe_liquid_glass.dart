import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
// 1.4.4 exposes the live-transform scope only through its renderer entrypoint.
// ignore: implementation_imports
import 'package:liquid_glass_widgets/src/renderer/liquid_glass_renderer.dart'
    show LiquidGlassSelfScaleScope;

import '../../theme/tokens.dart';
import '../../theme/moe_frosted_material.dart';
import 'moe_surface_motion.dart';

/// AICove 液态玻璃材质组件 (材质 2)
///
/// 专用于悬浮胶囊、特殊 Hero 展示等场景，具备透镜物理折射、光泽与色散能力。
/// 与材质 1 (原生毛玻璃) 共享项目的 [MoeColors] 和 [MoeGlassTheme]，
/// 并在不支持、关闭效果、高对比度或无障碍模式下平滑回退到项目原生材质。
class MoeLiquidGlass extends StatelessWidget {
  const MoeLiquidGlass({
    super.key,
    required this.child,
    this.shape,
    this.radius = 20.0,
    this.borderRadius,
    this.shadows,
    this.border,
    this.thickness,
    this.refractiveIndex = 1.5,
    this.blurSigma,
    this.baseline = MoeMaterialBaseline.component,
    this.quality = GlassQuality.premium,
    this.settings,
    this.enabled,
    this.padding,
    this.margin,
    this.width,
    this.height,
    this.clipBehavior = Clip.antiAlias,
    this.useOwnLayer = true,
    this.keepPremiumWhileScrolling = false,
    this.solidBackdrop,
  }) : assert(radius >= 0),
       assert(thickness == null || thickness >= 0),
       assert(blurSigma == null || blurSigma >= 0);

  /// 内部子组件（内容保持清晰，并在表面提供透明 Material 以承载点击和焦点）
  final Widget child;

  /// 自定义液态形状（未提供时默认根据 [radius] 生成超椭圆）
  final LiquidShape? shape;

  /// 圆角半径（当未提供自定义 [shape] 时生效）
  final double radius;
  final BorderRadius? borderRadius;
  final List<BoxShadow>? shadows;
  final BorderSide? border;

  /// 玻璃厚度（产生物理折射扭曲）。为 null 时按短边自适应，见 [adaptiveThickness]。
  final double? thickness;

  /// 折射率（艺术控制透镜扭曲强度，默认 1.5）
  final double refractiveIndex;

  /// Edge lens width as a share of the shorter side, in logical pixels.
  static const double adaptiveRimRatio = 0.2;
  static const double adaptiveRimMin = 7;
  static const double adaptiveRimMax = 14;

  /// Thickness whose lens band scales with the surface, the way system glass
  /// bends small capsules strongly and large panels only at a thin rim.
  /// liquid_glass_widgets draws the band `thickness / 3` logical pixels wide.
  static double adaptiveThickness(Size size) {
    final shortest = size.shortestSide;
    if (!shortest.isFinite || shortest <= 0) return adaptiveRimMin * 3;
    return (shortest * adaptiveRimRatio).clamp(adaptiveRimMin, adaptiveRimMax) *
        3;
  }

  /// 模糊强度（未显式指定时继承全局 [MoeGlassTheme.blurSigma]）
  final double? blurSigma;

  /// Blur minimum of this layer; tint always follows the global fill.
  final MoeMaterialBaseline baseline;

  /// 请求质量档位，默认 [GlassQuality.premium] 请求完整着色器管道
  final GlassQuality quality;

  /// 显式传入的完整 [LiquidGlassSettings]（优先级高于从主题自动推导）
  final LiquidGlassSettings? settings;

  /// 是否启用液态效果（为 null 时跟随全局设置 [MoeGlassTheme.enabled]）
  final bool? enabled;

  /// 内边距
  final EdgeInsetsGeometry? padding;

  /// 外边距
  final EdgeInsetsGeometry? margin;

  /// 宽度
  final double? width;

  /// 高度
  final double? height;

  /// 裁剪行为
  final Clip clipBehavior;

  /// 是否使用独立图层合成
  final bool useOwnLayer;

  /// Keep [GlassQuality.premium] inside scroll views instead of stepping
  /// down to the scroll-safe standard shader.
  final bool keepPremiumWhileScrolling;

  /// Known uniform opaque backdrop color directly behind this surface. When
  /// set, the Gaussian blur pass is skipped while keeping the full glass rim,
  /// Fresnel gradient, and backdrop saturation.
  final Color? solidBackdrop;

  static Color _saturateBt709(Color color, double sat) {
    const double rw = 0.2126, gw = 0.7152, bw = 0.0722;
    final r = color.r * 255.0;
    final g = color.g * 255.0;
    final b = color.b * 255.0;
    final outR =
        ((rw + (1 - rw) * sat) * r +
                (gw - gw * sat) * g +
                (bw - bw * sat) * b)
            .round()
            .clamp(0, 255);
    final outG =
        ((rw - rw * sat) * r +
                (gw + (1 - gw) * sat) * g +
                (bw - bw * sat) * b)
            .round()
            .clamp(0, 255);
    final outB =
        ((rw - rw * sat) * r +
                (gw - gw * sat) * g +
                (bw + (1 - bw) * sat) * b)
            .round()
            .clamp(0, 255);
    return Color.fromARGB((color.a * 255.0).round().clamp(0, 255), outR, outG, outB);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final glassTheme = MoeGlassTheme.maybeOf(context);
    final highContrast = MediaQuery.maybeHighContrastOf(context) ?? false;
    final accessibilityData = GlassAccessibilityData.of(context);
    final isAccessibilityDegraded =
        highContrast || accessibilityData.reduceTransparency;

    // 效果可用性：受显式参数、全局主题、平台能力及无障碍降级共同约束。
    // 随滚动移动的表面保留材质（模糊与玻璃在滚动中均正确，失效只来自已移除的
    // 安卓拉伸回弹）；拖动弹层、滑钮跟随层和排序代理仍回退实色。
    final isGlassEnabled =
        (enabled ?? glassTheme?.enabled ?? true) &&
        !moeSurfaceMovesWithContent(context, ignoreScrollables: true) &&
        !isAccessibilityDegraded;
    // premium 依赖纹理捕获，包文档注明在滚动中可能渲染错误；滚动内改用 standard。
    final effectiveQuality =
        quality == GlassQuality.premium &&
            !keepPremiumWhileScrolling &&
            moeSurfaceMovesWithContent(context)
        ? GlassQuality.standard
        : quality;
    final isFrosted = glassTheme?.material == MoeSurfaceMaterial.frosted;
    final isLiquidEnabled =
        isGlassEnabled &&
        !isFrosted &&
        !isAccessibilityDegraded &&
        MoeLiquidGlassService.isAvailable;

    final brightness = Theme.of(context).brightness;
    final effectiveSigma = isFrosted
        ? MoeFrostedMaterial.blurSigmaForSetting(
            glassTheme?.blurSigma ?? kDefaultGlassBlurSigma,
          )
        : blurSigma ?? glassTheme?.blurSigma ?? kDefaultGlassBlurSigma;
    final tintFill = glassTheme?.tintFill ?? kDefaultGlassTintFill;

    final effectiveShape =
        shape ??
        (borderRadius == null
            ? LiquidRoundedSuperellipse(borderRadius: radius)
            : LiquidVerticalRoundedRectangle(
                topRadius: borderRadius!.topLeft.x,
                bottomRadius: borderRadius!.bottomLeft.x,
              ));

    // LiquidOval in 1.4.4 drops its side when delegating paint. Use Flutter's
    // equivalent border so an explicit outline remains visible in both modes.
    final OutlinedBorder surfaceShape = effectiveShape is LiquidOval
        ? const OvalBorder()
        : effectiveShape;

    // 1. 内部内容封装：保留 padding，并在玻璃顶层挂载透明 Material 以承载点击水波纹、焦点和读屏语义
    Widget content = child;
    if (padding != null) {
      content = Padding(padding: padding!, child: content);
    }
    content = Material(type: MaterialType.transparency, child: content);

    Widget surfaceWidget;

    if (!isLiquidEnabled) {
      // ── 降级分支：平滑回退到项目原生毛玻璃 / 高对比度实体卡片 ──
      final rawTint = isFrosted
          ? MoeFrostedMaterial.surfaceTint(brightness, fill: tintFill)
          : colors.glassTintForFill(tintFill);
      final fallbackColor = !isGlassEnabled
          ? colors.componentBackground.withValues(alpha: 1)
          : solidBackdrop != null
          ? Color.alphaBlend(
              rawTint,
              isFrosted
                  ? MoeFrostedMaterial.saturateColor(
                      brightness,
                      solidBackdrop!,
                      fill: tintFill,
                    )
                  : solidBackdrop!,
            )
          : rawTint;
      final fallbackSurface = Material(
        color: fallbackColor,
        shape: surfaceShape.copyWith(
          side:
              border ??
              (isGlassEnabled
                  ? colors.floatingBorder
                  : BorderSide(
                      color: colors.borderLight.withValues(
                        alpha: colors.borderLight.a * 0.55,
                      ),
                      width: 0.6,
                    )),
        ),
        child: content,
      );

      surfaceWidget = DecoratedBox(
        decoration: ShapeDecoration(
          shape: surfaceShape,
          shadows: shadows ?? colors.floatingShadows,
        ),
        child: ClipPath(
          clipper: ShapeBorderClipper(shape: effectiveShape),
          clipBehavior: clipBehavior,
          // Frosted keeps its filter at zero blur for the fill's vibrancy.
          child:
              isGlassEnabled &&
                  solidBackdrop == null &&
                  (isFrosted || baseline.blurSigma(effectiveSigma) > 0)
              ? BackdropFilter(
                  filter: isFrosted
                      ? MoeFrostedMaterial.surfaceFilter(
                          brightness,
                          sigma: effectiveSigma,
                          fill: tintFill,
                        )
                      : ui.ImageFilter.blur(
                          sigmaX: baseline.blurSigma(effectiveSigma),
                          sigmaY: baseline.blurSigma(effectiveSigma),
                        ),
                  child: fallbackSurface,
                )
              : fallbackSurface,
        ),
      );
    } else {
      // ── 液态玻璃分支：GPU Fragment Shader 透镜折射 ──
      // 外层 DecoratedBox 已统一承载 ShapeDecoration 阴影，显式关闭 liquid_glass_widgets
      // 内部默认在浅色模式下额外叠加的 2 次 saveLayer + ImageFilter.blur + dstOut 阴影。
      LiquidGlassSettings settingsFor(Size size) {
        final base =
            settings ??
            LiquidGlassSettings(
              thickness: thickness ?? adaptiveThickness(size),
              refractiveIndex: refractiveIndex,
              blur: solidBackdrop != null
                  ? 0
                  : baseline.blurSigma(effectiveSigma),
              glassColor: colors.glassTintForFill(tintFill),
              bodyMode: GlassBodyMode.adaptive,
              shadowElevation: 0,
              shadow: const [],
            );
        final noShadow = base.shadow == null
            ? base.copyWith(shadowElevation: 0, shadow: const [])
            : base;
        if (solidBackdrop == null) return noShadow;
        final usesStandardShader =
            effectiveQuality != GlassQuality.premium ||
            !ui.ImageFilter.isShaderFilterSupported;
        return usesStandardShader
            ? noShadow.copyWith(
                blur: 0,
                backerColor: _saturateBt709(
                  solidBackdrop!,
                  noShadow.effectiveSaturation,
                ),
              )
            : noShadow.copyWith(blur: 0);
      }

      surfaceWidget = DecoratedBox(
        decoration: ShapeDecoration(
          shape: surfaceShape,
          shadows: shadows ?? colors.floatingShadows,
        ),
        child: DecoratedBox(
          position: DecorationPosition.foreground,
          decoration: ShapeDecoration(
            shape: surfaceShape.copyWith(side: border ?? colors.floatingBorder),
          ),
          // App surfaces follow live layout (global UI scale, scroll and popup
          // transitions), not CupertinoSheet's frozen backdrop coordinates.
          child: LiquidGlassSelfScaleScope(
            selfScaled: true,
            // Keep the backdrop separate from content. Nesting a second
            // backdrop inside the shader pass shifts its texture coordinates.
            child: Stack(
              fit: StackFit.passthrough,
              children: [
                // Positioned children skip intrinsic passes, so measuring here
                // is safe even when the surface sits in an intrinsic layout.
                Positioned.fill(
                  child: IgnorePointer(
                    child: LayoutBuilder(
                      builder: (context, constraints) => AdaptiveGlass(
                        shape: effectiveShape,
                        settings: settingsFor(constraints.biggest),
                        quality: effectiveQuality,
                        useOwnLayer: useOwnLayer,
                        clipBehavior: clipBehavior,
                        child: const SizedBox.expand(),
                      ),
                    ),
                  ),
                ),
                ClipPath(
                  clipper: ShapeBorderClipper(shape: effectiveShape),
                  clipBehavior: clipBehavior,
                  child: content,
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (width != null || height != null) {
      surfaceWidget = SizedBox(
        width: width,
        height: height,
        child: surfaceWidget,
      );
    }

    if (margin != null) {
      surfaceWidget = Padding(padding: margin!, child: surfaceWidget);
    }

    return surfaceWidget;
  }
}
