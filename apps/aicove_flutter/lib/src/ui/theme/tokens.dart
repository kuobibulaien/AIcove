import 'package:flutter/material.dart';

export 'moe_glass_theme.dart';
export 'moe_liquid_glass_service.dart';

// ===== 主题色预设 =====

/// 主题色枚举 - 用于全局 AppBar、主按钮等强调色
///
/// 可通过设置界面切换，未来可扩展更多颜色
enum MoeAccentColor {
  /// 经典粉红（默认 MoeTalk 风格）
  pink('pink', '粉红', Color(0xFFFC96AA), Color(0xFFF8869D)),

  /// 淡蓝色（清爽风格）
  blue('blue', '淡蓝', Color(0xFF3390EC), Color(0xFF3A7BD5)),

  /// 薄荷绿
  mint('mint', '薄荷', Color(0xFF4ECDC4), Color(0xFF44A08D)),

  /// 薰衣草紫
  lavender('lavender', '薰衣草', Color(0xFFB39DDB), Color(0xFF9575CD)),

  /// 珊瑚橙
  coral('coral', '珊瑚', Color(0xFFFF8A65), Color(0xFFFF7043));

  const MoeAccentColor(this.value, this.label, this.color, this.colorDark);

  /// 用于持久化的字符串值
  final String value;

  /// 显示名称
  final String label;

  /// 浅色模式颜色（标题栏、主按钮背景）
  final Color color;

  /// 深色模式颜色（或渐变终点）
  final Color colorDark;

  /// 从字符串值解析
  static MoeAccentColor fromValue(String? value) {
    for (final accent in MoeAccentColor.values) {
      if (accent.value == value) return accent;
    }
    return MoeAccentColor.pink; // 默认粉红
  }
}

// 统一界面 Token；保留历史符号名，默认外观参考 Telegram。

// ===== 浅色模式 =====
const moePrimary = Color(0xFF3390EC); // 强调蓝色
const moeSurface = Color(0xFFFFFFFF); // 表面背景色（全局纯白）
const moeSurfaceAlt = moeSurface; // 次级表面沿用统一基础色
const moePanel = moeSurface; // 容器背景（卡片/聊天面板）
const moeBgMain = moeSurface; // 主背景色（与 surface 统一）
const moeText = Color(0xFF222222); // 主文本颜色
const moeTextSecondary = Color(0xFF707579); // 次要文本颜色（时间戳等）
const moeMuted = Color(0xFF8A8A8A); // 弱化文本颜色
const moeBorder = Color(0xFFDAE1E5); // 分割线颜色
const moeBorderLight = Color(0xFFE6E9EB); // 淡色边框
// 更柔和的分割线颜色（比 moeBorderLight 更浅一档）
const moeDividerColor = Color(0xFFEDF1F4);
const moeFocus = Color(0xFF3390EC); // 聚焦/按钮颜色

// ===== 暗色模式 =====
const moePrimaryDark = Color(0xFF6BA1D8); // 主色调蓝色（暗色版，稍微降低亮度）
const moeSurfaceDark = Color(0xFF000000); // 表面背景色（纯黑）
const moeSurfaceAltDark = moeSurfaceDark; // 次级表面沿用统一基础色
const moePanelDark = moeSurfaceDark; // 容器背景（卡片/聊天面板）
const moeBgMainDark = moeSurfaceDark; // 主背景色
const moeTextDark = Color(0xFFE5E8EB); // 主文本颜色（浅色文字）
const moeTextSecondaryDark = Color(0xFFADB5BD); // 次要文本颜色
const moeMutedDark = Color(0xFF8B95A1); // 弱化文本颜色
const moeBorderDark = Color(0xFF38383A); // 分割线颜色
const moeBorderLightDark = Color(0xFF2C2C2E); // 淡色边框
const moeDividerColorDark = Color(0xFF1F1F1F); // 更柔和的分割线颜色
const moeFocusDark = Color(0xFF6BA1D8); // 聚焦/按钮颜色

// 分割线宽度（使用 1 物理像素的细线，贴近 MoeTalk 样式）
// 说明：0.5 个逻辑像素在常见屏幕密度下等于 1px，视觉更轻且不会产生明显空隙。
const double borderWidth = 0.5;

// 统一底部栏高度（BottomNavigationBar和Composer保持一致）
const double bottomBarHeight = 56.0; // Material Design标准底部导航条高度

const moeHeaderPink = Color(0xFFFC96AA); // Momotalk Pink Header
const moeHeaderContentLight = Color(0xFFFFFFFF); // Header text color (on pink)

const moeHeaderGradientStart = Color(
  0xFFFC96AA,
); // 标题栏渐变起点（已弃用，使用 MoeAccentColor）
const moeHeaderGradientEnd = Color(
  0xFFF8869D,
); // 标题栏渐变终点（已弃用，使用 MoeAccentColor）

// 气泡 - MoeTalk 配色（浅色模式）
const moeBubbleLeftBg = Color(0xFF4D5B75); // AI 消息背景（深蓝灰色）
const moeBubbleLeftBorder = Color(0xFF4D5B75); // 边框同色
const moeBubbleLeftFg = Color(0xFFFFFFFF); // 文字白色
const moeBubbleRightBg = Color(0xFF4A90E2); // 用户消息背景（主蓝色）
const moeBubbleRightBorder = Color(0xFF4A90E2);

// 气泡 - 暗色模式
const moeBubbleLeftBgDark = Color(0xFF3A4555); // AI 消息背景（暗色）
const moeBubbleLeftBorderDark = Color(0xFF3A4555);
const moeBubbleLeftFgDark = Color(0xFFE5E8EB);
const moeBubbleRightBgDark = moePrimaryDark; // 用户消息背景（主蓝色暗色版）
const moeBubbleRightBorderDark = moePrimaryDark;

// 强调色
const moeAccent = Color(0xFFFC879B);
const moeAccentDark = Color(0xFFD4AF37); // 暗色模式强调色（金属金，配纯黑背景）

// Toast 语义色 - 浅色模式
const moeToastSuccess = Color(0xFF4CAF50); // 成功（绿）
const moeToastError = Color(0xFFE53935); // 错误（红）
const moeToastWarning = Color(0xFFFF9800); // 警告（橙）
const moeToastInfo = Color(0xFF424242); // 信息（灰）

// Toast 语义色 - 暗色模式
const moeToastSuccessDark = Color(0xFF1B5E20);
const moeToastErrorDark = Color(0xFFB71C1C);
const moeToastWarningDark = Color(0xFFE65100);
const moeToastInfoDark = Color(0xFF37474F);

// 弹窗专用色（MeoTalk 风格）- 浅色模式
const moeDialogWarning = Color(0xFFFFD60A); // 黄色确认按钮（警告/确认操作）
const moeDialogCancel = Color(0xFF8BBBE9); // 蓝灰色取消按钮
const moeDialogAccentLine = Color(0xFFFFD60A); // 黄色装饰线（标题下划线）
const moeDialogOverlay = Color(0x80000000); // 半透明黑色遮罩 (50% opacity)

// 弹窗专用色 - 暗色模式
const moeDialogWarningDark = Color(0xFFFFC629); // 黄色确认按钮（稍微调亮）
const moeDialogCancelDark = Color(0xFF6BA1D8); // 蓝灰色取消按钮
const moeDialogAccentLineDark = Color(0xFFFFC629); // 黄色装饰线
const moeDialogOverlayDark = Color(0xB0000000); // 半透明黑色遮罩（暗色模式稍深）

// 圆角 - MoeTalk 使用 10px
const radiusBubble = Radius.circular(10);
const radiusAvatar = 64.0; // MoeTalk 头像 4rem

// 颜色方案（Material3）
final moeTalkColorScheme = ColorScheme.fromSeed(
  seedColor: moePrimary,
  brightness: Brightness.light,
  primary: moePrimary,
  surface: moePanel,
  surfaceDim: moePanel,
  surfaceBright: moePanel,
  surfaceContainerLowest: moePanel,
  surfaceContainerLow: moePanel,
  surfaceContainer: moePanel,
  surfaceContainerHigh: moePanel,
  surfaceContainerHighest: moePanel,
  onSurface: moeText,
);

final moeTalkColorSchemeDark = ColorScheme.fromSeed(
  seedColor: moePrimaryDark,
  brightness: Brightness.dark,
  primary: moePrimaryDark,
  surface: moePanelDark,
  surfaceDim: moePanelDark,
  surfaceBright: moePanelDark,
  surfaceContainerLowest: moePanelDark,
  surfaceContainerLow: moePanelDark,
  surfaceContainer: moePanelDark,
  surfaceContainerHigh: moePanelDark,
  surfaceContainerHighest: moePanelDark,
  onSurface: moeTextDark,
);

// 公共阴影
final cardShadow = [
  BoxShadow(
    color: Colors.black.withValues(alpha: 0.06),
    blurRadius: 8,
    offset: const Offset(0, 2),
  ),
];

// 响应式断点（统一管理窄屏/宽屏切换阈值，KISS/DRY）
// 同一导航栈按可用宽度切换单栏与主从双栏。
const double layoutBreakpoint = 900.0;

const double telegramPrimaryWidth = 360;
const double telegramPrimaryMinWidth = 320;
const double telegramPrimaryMaxWidth = 440;
const double telegramDetailMinWidth = 460;
const double telegramWorkspaceInset = 12;
const double telegramPrimaryRadius = 28;
const double telegramCompactTitleBarHeight = 40;
const double telegramChatHeaderHeight = 48;
const double telegramChatHeaderVerticalInset = 6;
const double telegramChatHeaderGap = 8;
const double telegramChatHeaderAvatarSize = 32;
const double telegramChatHeaderTitleSize = 16;
const double telegramChatHeaderStatusSize = 11;
const telegramChatBackground = moeSurface;
const telegramChatBackgroundDark = moeSurfaceDark;

// === 玻璃材质效果常量 ===
/// 毛玻璃模糊默认值（逻辑像素 sigma）
const double kDefaultGlassBlurSigma = 16.0;
const double kMinGlassBlurSigma = 0.0;
const double kMaxGlassBlurSigma = 32.0;

const double kMaxContentSurfaceBlurSigma = 8.0;

/// Per-component minimums; floating controls intentionally have no baseline.
@immutable
class MoeMaterialBaseline {
  const MoeMaterialBaseline({this.blurFactor = 0, this.tintOpacity = 0})
    : assert(blurFactor >= 0 && blurFactor <= 1),
      assert(tintOpacity >= 0 && tintOpacity <= 1);

  static const none = MoeMaterialBaseline();
  static const background = MoeMaterialBaseline(
    blurFactor: 0.1,
    tintOpacity: 0.1,
  );
  static const text = MoeMaterialBaseline(blurFactor: 0.25, tintOpacity: 0.25);

  final double blurFactor;
  final double tintOpacity;

  /// Setting strength in 0..1 after this component's minimum is applied.
  double strength(double sigma) =>
      blurFactor +
      (1 - blurFactor) * (sigma / kMaxGlassBlurSigma).clamp(0.0, 1.0);

  /// Rendered backdrop blur for the glass material.
  ///
  /// iOS 26 Liquid Glass reads through: refraction and specular edges carry
  /// the material, blur only softens. The stored 0..32 setting is mapped onto
  /// a squared curve so the lower half stays nearly clear, the midpoint lands
  /// on liquid_glass_widgets' iOS-calibrated default (sigma 3), and the
  /// heaviest step stays well below the frosted popup recipe (sigma 30).
  double blurSigma(double sigma) {
    final s = strength(sigma);
    return kMaxLiquidGlassBlurSigma * s * s;
  }
}

/// Upper bound of [MoeMaterialBaseline.blurSigma] for the glass material.
const double kMaxLiquidGlassBlurSigma = 12.0;

// ===== 主题扩展 - 让整个应用响应暗色模式 =====
class MoeColors extends ThemeExtension<MoeColors> {
  final Color primary;
  final Color surface;
  final Color surfaceAlt;
  final Color panel;
  final Color bgMain;
  final Color text;
  final Color textSecondary;
  final Color muted;
  final Color border;
  final Color borderLight;
  final Color divider;
  final Color focus;
  final Color bubbleLeftBg;
  final Color bubbleLeftBorder;
  final Color bubbleLeftFg;
  final Color bubbleRightBg;
  final Color bubbleRightBorder;
  final Color accent;
  final Color dialogWarning;
  final Color dialogCancel;
  final Color dialogAccentLine;
  final Color dialogOverlay;
  final Color headerColor;
  final Color headerContentColor;

  /// 悬浮控制面板底色（玻璃材质）
  final Color glassSurface;

  /// Blend from the component minimum to the existing light/dark tint token.
  Color glassTintForSigma(
    double sigma, {
    MoeMaterialBaseline baseline = MoeMaterialBaseline.none,
  }) => surface.withValues(
    alpha:
        baseline.tintOpacity +
        (1 - baseline.tintOpacity) *
            glassSurface.a *
            (sigma / kMaxGlassBlurSigma).clamp(0.0, 1.0),
  );

  /// Subtle theme-aware backing painted above text-bearing materials.
  Color get textMaterialTint => surface.withValues(alpha: 0.06);

  /// 悬浮面板细边框
  final Color glassBorder;

  /// 悬浮面板阴影颜色
  final Color glassShadow;

  BorderSide get floatingBorder => BorderSide(
    color: glassBorder.withValues(alpha: glassBorder.a * 0.55),
    width: 0.6,
  );

  List<BoxShadow> get floatingShadows => [
    BoxShadow(
      color: glassShadow.withValues(alpha: glassShadow.a * 0.55),
      blurRadius: 16,
      offset: const Offset(0, 4),
    ),
    BoxShadow(
      color: glassShadow.withValues(alpha: glassShadow.a * 0.35),
      blurRadius: 3,
      offset: const Offset(0, 1),
    ),
  ];

  /// 主题强调色（用于 AppBar、主按钮等）
  final Color accentColor;

  /// 组件公共背景色（用于设置分组、卡片等容器）
  final Color componentBackground;

  // Toast 语义色
  final Color toastSuccess;
  final Color toastError;
  final Color toastWarning;
  final Color toastInfo;

  const MoeColors({
    required this.primary,
    required this.surface,
    required this.surfaceAlt,
    required this.panel,
    required this.bgMain,
    required this.text,
    required this.textSecondary,
    required this.muted,
    required this.border,
    required this.borderLight,
    required this.divider,
    required this.focus,
    required this.bubbleLeftBg,
    required this.bubbleLeftBorder,
    required this.bubbleLeftFg,
    required this.bubbleRightBg,
    required this.bubbleRightBorder,
    required this.accent,
    required this.dialogWarning,
    required this.dialogCancel,
    required this.dialogAccentLine,
    required this.dialogOverlay,
    required this.headerColor,
    required this.headerContentColor,
    required this.glassSurface,
    required this.glassBorder,
    required this.glassShadow,
    required this.accentColor,
    required this.componentBackground,
    required this.toastSuccess,
    required this.toastError,
    required this.toastWarning,
    required this.toastInfo,
  });

  // 浅色主题
  static MoeColors light({Color? accentColor, Color? globalBgColor}) {
    final color = accentColor ?? const Color(0xFFFC96AA);
    final bg = globalBgColor ?? moeSurface;
    return MoeColors(
      // primary/focus 代表"全局强调色"（按钮/选中态等），应跟随用户选择的主题色
      primary: color,
      surface: bg,
      surfaceAlt: moeSurfaceAlt,
      panel: moePanel,
      bgMain: bg,
      text: moeText,
      textSecondary: moeTextSecondary,
      muted: moeMuted,
      border: moeBorder,
      borderLight: moeBorderLight,
      divider: moeDividerColor,
      focus: color,
      bubbleLeftBg: moeBubbleLeftBg,
      bubbleLeftBorder: moeBubbleLeftBorder,
      bubbleLeftFg: moeBubbleLeftFg,
      bubbleRightBg: moeBubbleRightBg,
      bubbleRightBorder: moeBubbleRightBorder,
      accent: moeAccent,
      dialogWarning: moeDialogWarning,
      dialogCancel: moeDialogCancel,
      dialogAccentLine: moeDialogAccentLine,
      dialogOverlay: moeDialogOverlay,
      headerColor: moeSurface,
      headerContentColor: moeText,
      glassSurface: Colors.white.withValues(alpha: 0.36),
      glassBorder: Colors.white.withValues(alpha: 0.55),
      glassShadow: Colors.black.withValues(alpha: 0.06),
      accentColor: color,
      componentBackground: moePanel,
      toastSuccess: moeToastSuccess,
      toastError: moeToastError,
      toastWarning: moeToastWarning,
      toastInfo: moeToastInfo,
    );
  }

  // 暗色主题
  static MoeColors dark({Color? accentColor}) {
    // 传入值已是暗色成品色（皮肤预设或自定义降亮后的颜色）
    final darkColor = accentColor ?? moeAccentDark;
    return MoeColors(
      // primary/focus 代表"全局强调色"（按钮/选中态等），应跟随用户选择的主题色
      primary: darkColor,
      surface: moeSurfaceDark,
      surfaceAlt: moeSurfaceAltDark,
      panel: moePanelDark,
      bgMain: moeBgMainDark,
      text: moeTextDark,
      textSecondary: moeTextSecondaryDark,
      muted: moeMutedDark,
      border: moeBorderDark,
      borderLight: moeBorderLightDark,
      divider: moeDividerColorDark,
      focus: darkColor,
      bubbleLeftBg: moeBubbleLeftBgDark,
      bubbleLeftBorder: moeBubbleLeftBorderDark,
      bubbleLeftFg: moeBubbleLeftFgDark,
      bubbleRightBg: moeBubbleRightBgDark,
      bubbleRightBorder: moeBubbleRightBorderDark,
      accent: moeAccentDark,
      dialogWarning: moeDialogWarningDark,
      dialogCancel: moeDialogCancelDark,
      dialogAccentLine: moeDialogAccentLineDark,
      dialogOverlay: moeDialogOverlayDark,
      headerColor: moeSurfaceDark,
      headerContentColor: moeTextDark,
      glassSurface: const Color(0xFF202020).withValues(alpha: 0.30),
      glassBorder: Colors.white.withValues(alpha: 0.14),
      glassShadow: Colors.black.withValues(alpha: 0.16),
      accentColor: darkColor,
      componentBackground: moePanelDark,
      toastSuccess: moeToastSuccessDark,
      toastError: moeToastErrorDark,
      toastWarning: moeToastWarningDark,
      toastInfo: moeToastInfoDark,
    );
  }

  @override
  MoeColors copyWith({
    Color? primary,
    Color? surface,
    Color? surfaceAlt,
    Color? panel,
    Color? bgMain,
    Color? text,
    Color? textSecondary,
    Color? muted,
    Color? border,
    Color? borderLight,
    Color? divider,
    Color? focus,
    Color? bubbleLeftBg,
    Color? bubbleLeftBorder,
    Color? bubbleLeftFg,
    Color? bubbleRightBg,
    Color? bubbleRightBorder,
    Color? accent,
    Color? dialogWarning,
    Color? dialogCancel,
    Color? dialogAccentLine,
    Color? dialogOverlay,
    Color? headerColor,
    Color? headerContentColor,
    Color? glassSurface,
    Color? glassBorder,
    Color? glassShadow,
    Color? accentColor,
    Color? componentBackground,
    Color? toastSuccess,
    Color? toastError,
    Color? toastWarning,
    Color? toastInfo,
  }) {
    return MoeColors(
      primary: primary ?? this.primary,
      surface: surface ?? this.surface,
      surfaceAlt: surfaceAlt ?? this.surfaceAlt,
      panel: panel ?? this.panel,
      bgMain: bgMain ?? this.bgMain,
      text: text ?? this.text,
      textSecondary: textSecondary ?? this.textSecondary,
      muted: muted ?? this.muted,
      border: border ?? this.border,
      borderLight: borderLight ?? this.borderLight,
      divider: divider ?? this.divider,
      focus: focus ?? this.focus,
      bubbleLeftBg: bubbleLeftBg ?? this.bubbleLeftBg,
      bubbleLeftBorder: bubbleLeftBorder ?? this.bubbleLeftBorder,
      bubbleLeftFg: bubbleLeftFg ?? this.bubbleLeftFg,
      bubbleRightBg: bubbleRightBg ?? this.bubbleRightBg,
      bubbleRightBorder: bubbleRightBorder ?? this.bubbleRightBorder,
      accent: accent ?? this.accent,
      dialogWarning: dialogWarning ?? this.dialogWarning,
      dialogCancel: dialogCancel ?? this.dialogCancel,
      dialogAccentLine: dialogAccentLine ?? this.dialogAccentLine,
      dialogOverlay: dialogOverlay ?? this.dialogOverlay,
      headerColor: headerColor ?? this.headerColor,
      headerContentColor: headerContentColor ?? this.headerContentColor,
      glassSurface: glassSurface ?? this.glassSurface,
      glassBorder: glassBorder ?? this.glassBorder,
      glassShadow: glassShadow ?? this.glassShadow,
      accentColor: accentColor ?? this.accentColor,
      componentBackground: componentBackground ?? this.componentBackground,
      toastSuccess: toastSuccess ?? this.toastSuccess,
      toastError: toastError ?? this.toastError,
      toastWarning: toastWarning ?? this.toastWarning,
      toastInfo: toastInfo ?? this.toastInfo,
    );
  }

  @override
  MoeColors lerp(ThemeExtension<MoeColors>? other, double t) {
    if (other is! MoeColors) return this;
    return MoeColors(
      primary: Color.lerp(primary, other.primary, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      surfaceAlt: Color.lerp(surfaceAlt, other.surfaceAlt, t)!,
      panel: Color.lerp(panel, other.panel, t)!,
      bgMain: Color.lerp(bgMain, other.bgMain, t)!,
      text: Color.lerp(text, other.text, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
      muted: Color.lerp(muted, other.muted, t)!,
      border: Color.lerp(border, other.border, t)!,
      borderLight: Color.lerp(borderLight, other.borderLight, t)!,
      divider: Color.lerp(divider, other.divider, t)!,
      focus: Color.lerp(focus, other.focus, t)!,
      bubbleLeftBg: Color.lerp(bubbleLeftBg, other.bubbleLeftBg, t)!,
      bubbleLeftBorder: Color.lerp(
        bubbleLeftBorder,
        other.bubbleLeftBorder,
        t,
      )!,
      bubbleLeftFg: Color.lerp(bubbleLeftFg, other.bubbleLeftFg, t)!,
      bubbleRightBg: Color.lerp(bubbleRightBg, other.bubbleRightBg, t)!,
      bubbleRightBorder: Color.lerp(
        bubbleRightBorder,
        other.bubbleRightBorder,
        t,
      )!,
      accent: Color.lerp(accent, other.accent, t)!,
      dialogWarning: Color.lerp(dialogWarning, other.dialogWarning, t)!,
      dialogCancel: Color.lerp(dialogCancel, other.dialogCancel, t)!,
      dialogAccentLine: Color.lerp(
        dialogAccentLine,
        other.dialogAccentLine,
        t,
      )!,
      dialogOverlay: Color.lerp(dialogOverlay, other.dialogOverlay, t)!,
      headerColor: Color.lerp(headerColor, other.headerColor, t)!,
      headerContentColor: Color.lerp(
        headerContentColor,
        other.headerContentColor,
        t,
      )!,
      glassSurface: Color.lerp(glassSurface, other.glassSurface, t)!,
      glassBorder: Color.lerp(glassBorder, other.glassBorder, t)!,
      glassShadow: Color.lerp(glassShadow, other.glassShadow, t)!,
      accentColor: Color.lerp(accentColor, other.accentColor, t)!,
      componentBackground: Color.lerp(
        componentBackground,
        other.componentBackground,
        t,
      )!,
      toastSuccess: Color.lerp(toastSuccess, other.toastSuccess, t)!,
      toastError: Color.lerp(toastError, other.toastError, t)!,
      toastWarning: Color.lerp(toastWarning, other.toastWarning, t)!,
      toastInfo: Color.lerp(toastInfo, other.toastInfo, t)!,
    );
  }
}

// 便捷访问方法
extension MoeColorsExtension on BuildContext {
  MoeColors get moeColors =>
      Theme.of(this).extension<MoeColors>() ?? MoeColors.light();
}

// ===== Design Tokens =====

/// 极速动画（键盘适配、即时反馈）
const Duration kAnimXFast = Duration(milliseconds: 100);

/// 快速动画（按压反馈、微交互）
const Duration kAnimFast = Duration(milliseconds: 150);

/// 标准动画（过渡、切换）
const Duration kAnim = Duration(milliseconds: 240);

/// 慢速动画（复杂过渡、展开效果）
const Duration kAnimSlow = Duration(milliseconds: 320);

/// 页面打开动画
const Duration kAnimPage = Duration(milliseconds: 320);

/// 页面关闭动画
const Duration kAnimPageReverse = Duration(milliseconds: 280);

/// 较长动画（如滚动同步、复杂展开）
const Duration kAnimLong = Duration(milliseconds: 1200);

/// Toast 默认显示时长
const Duration kDurationToast = Duration(milliseconds: 1500);

// === 字重系统 ===
/// 统一字重常量，全局集中管理
/// 修改这里即可一次性调整全 App 的字体粗细
class MoeFontWeights {
  MoeFontWeights._();

  /// 强调文字（标题、按钮、选中态等）
  static const FontWeight emphasis = FontWeight.w500;

  /// 普通文字（正文、未选中态、次要内容）
  static const FontWeight normal = FontWeight.w400;
}

// === 间距系统 ===
/// 统一间距常量，遵循 4px 基准
class MoeSpacing {
  MoeSpacing._();

  static const double xxs = 4;
  static const double xs = 8;
  static const double sm = 12;
  static const double md = 16;
  static const double lg = 20;
  static const double xl = 24;
  static const double xxl = 32;
}

// === 圆角变体 ===
/// 统一圆角常量
class MoeRadii {
  MoeRadii._();

  /// 超小圆角（4px）- 用于小型元素
  static const double xs = 4;

  /// 小圆角（8px）- 用于按钮、输入框
  static const double sm = 8;

  /// 中等圆角（12px）- 用于卡片、面板
  static const double md = 12;

  /// 大圆角（16px）- 用于弹窗、大卡片
  static const double lg = 16;

  /// 超大圆角（20px）- 用于特殊效果
  static const double xl = 20;

  /// 卡片专用（25px）- 保持与现有 radiusCard 一致
  static const double card = 25;

  /// 胶囊形圆角
  static const double capsule = 9999;

  // BorderRadius 便捷方法
  static BorderRadius get borderXs => BorderRadius.circular(xs);
  static BorderRadius get borderSm => BorderRadius.circular(sm);
  static BorderRadius get borderMd => BorderRadius.circular(md);
  static BorderRadius get borderLg => BorderRadius.circular(lg);
  static BorderRadius get borderXl => BorderRadius.circular(xl);
  static BorderRadius get borderCard => BorderRadius.circular(card);
  static BorderRadius get borderCapsule => BorderRadius.circular(capsule);
}

// === iOS 超椭圆圆角常量 ===
/// iOS 风格平滑圆角（Squircle）专用常量
///
/// 与 MoeRadii 区分：这里的值用于 SmoothClipRRect/SmoothRectDecoration（旧）以及 MoeG2ClipRRect/MoeG2Decoration（推荐）。
/// 由于超椭圆曲线更饱满，同样的数值看起来会比普通圆角更"圆"。
class MoeSmoothRadii {
  MoeSmoothRadii._();

  /// 小容器（12px）- 简介气泡、小卡片
  static const double sm = 12;

  /// 卡片类（20px）- 角色卡、毛玻璃卡片
  static const double md = 20;

  /// 弹窗类（24px）- 确认弹窗、底部面板
  static const double lg = 24;

  /// 特殊大卡片（28px）- 全屏卡片、封面
  static const double xl = 28;
}

// === 阴影预设 ===
/// 统一阴影样式
class MoeShadows {
  MoeShadows._();

  /// 轻微阴影（卡片、按钮）
  static List<BoxShadow> get soft => [
    BoxShadow(
      color: Colors.black.withValues(alpha: 0.04),
      blurRadius: 4,
      offset: const Offset(0, 1),
    ),
  ];

  /// 普通阴影（浮动元素）
  static List<BoxShadow> get card => [
    BoxShadow(
      color: Colors.black.withValues(alpha: 0.06),
      blurRadius: 8,
      offset: const Offset(0, 2),
    ),
  ];

  /// 强调阴影（弹窗、悬浮按钮）
  static List<BoxShadow> get elevated => [
    BoxShadow(
      color: Colors.black.withValues(alpha: 0.1),
      blurRadius: 16,
      offset: const Offset(0, 4),
    ),
  ];

  /// 深度阴影（模态框）
  static List<BoxShadow> get modal => [
    BoxShadow(
      color: Colors.black.withValues(alpha: 0.15),
      blurRadius: 24,
      offset: const Offset(0, 8),
    ),
  ];
}

// === 按钮尺寸预设 ===
/// 按钮高度常量
class MoeButtonSizes {
  MoeButtonSizes._();

  /// 小按钮高度
  static const double sm = 32;

  /// 标准按钮高度
  static const double md = 44;

  /// 大按钮高度
  static const double lg = 52;

  /// 最小触控区域（无障碍标准）
  static const double minTouchTarget = 44;
}

// === 输入框尺寸预设 ===
/// 输入框高度常量
class MoeInputSizes {
  MoeInputSizes._();

  /// 小输入框高度
  static const double sm = 36;

  /// 标准输入框高度
  static const double md = 44;

  /// 大输入框高度
  static const double lg = 52;
}

class MoeSettingsLayout {
  MoeSettingsLayout._();

  static const double maxContentWidth = 760;
  static const double insetFraction = 0.04;
  static const double minInset = 12;
  static const double maxInset = 32;
  static const double cardRadius = 20;
  static const double sectionGap = 16;
  static const EdgeInsets verticalListPadding = EdgeInsets.only(
    top: 16,
    bottom: 24,
  );
  static const EdgeInsets contentPadding = EdgeInsets.all(16);

  static double insetFor(double panelWidth) =>
      (panelWidth * insetFraction).clamp(minInset, maxInset);

  static double contentWidthFor(double panelWidth) =>
      (panelWidth - 2 * insetFor(panelWidth)).clamp(0.0, maxContentWidth);
}
