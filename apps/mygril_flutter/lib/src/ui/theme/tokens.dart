import 'package:flutter/material.dart';

// ===== 主题色预设 =====

/// 主题色枚举 - 用于全局 AppBar、主按钮等强调色
/// 
/// 可通过设置界面切换，未来可扩展更多颜色
enum MoeAccentColor {
  /// 经典粉红（默认 MoeTalk 风格）
  pink('pink', '粉红', Color(0xFFFC96AA), Color(0xFFF8869D)),
  /// 淡蓝色（清爽风格）
  blue('blue', '淡蓝', Color(0xFF4A90E2), Color(0xFF3A7BD5)),
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


// MoeTalk 风格 Token（来自 MoeTalk 官方 CSS）

// ===== 浅色模式 =====
const moePrimary = Color(0xFF4A90E2); // Momotalk User Bubble Blue
const moeSurface = Color(0xFFF3F6F8); // 表面背景色
const moeSurfaceAlt = Color(0xFFE8EDF2); // 次级表面背景色（略深）
const moePanel = Colors.white; // 容器背景（卡片/聊天面板）
const moeBgMain = Color(0xFFF3F6F8); // 主背景色（与 surface 统一）
const moeText = Color(0xFF222529); // 主文本颜色
const moeTextSecondary = Color(0xFF454E59); // 次要文本颜色（时间戳等）
const moeMuted = Color(0xFF7A8591); // 弱化文本颜色
const moeBorder = Color(0xFFDAE1E5); // 分割线颜色
const moeBorderLight = Color(0xFFE6E9EB); // 淡色边框
// 更柔和的分割线颜色（比 moeBorderLight 更浅一档）
const moeDividerColor = Color(0xFFEDF1F4);
const moeFocus = Color(0xFF4A90E2); // 聚焦/按钮颜色

// ===== 暗色模式 =====
const moePrimaryDark = Color(0xFF6BA1D8); // 主色调蓝色（暗色版，稍微降低亮度）
const moeSurfaceDark = Color(0xFF1C1C1C); // 表面背景色（深色背景）
const moeSurfaceAltDark = Color(0xFF232830); // 次级表面背景色（略深）
const moePanelDark = Color(0xFF333333); // 容器背景（卡片/聊天面板）
const moeBgMainDark = Color(0xFF1C1C1C); // 主背景色
const moeTextDark = Color(0xFFE5E8EB); // 主文本颜色（浅色文字）
const moeTextSecondaryDark = Color(0xFFADB5BD); // 次要文本颜色
const moeMutedDark = Color(0xFF8B95A1); // 弱化文本颜色
const moeBorderDark = Color(0xFF3A404A); // 分割线颜色
const moeBorderLightDark = Color(0xFF2F3540); // 淡色边框
const moeDividerColorDark = Color(0xFF282D35); // 更柔和的分割线颜色
const moeFocusDark = Color(0xFF6BA1D8); // 聚焦/按钮颜色

// 分割线宽度（使用 1 物理像素的细线，贴近 MoeTalk 样式）
// 说明：0.5 个逻辑像素在常见屏幕密度下等于 1px，视觉更轻且不会产生明显空隙。
const double borderWidth = 0.5;

// 统一底部栏高度（BottomNavigationBar和Composer保持一致）
const double bottomBarHeight = 56.0; // Material Design标准底部导航条高度

const moeHeaderPink = Color(0xFFFC96AA); // Momotalk Pink Header
const moeHeaderContentLight = Color(0xFFFFFFFF); // Header text color (on pink)

const moeHeaderGradientStart = Color(0xFFFC96AA); // 标题栏渐变起点（已弃用，使用 MoeAccentColor）
const moeHeaderGradientEnd = Color(0xFFF8869D);   // 标题栏渐变终点（已弃用，使用 MoeAccentColor）

// 气泡 - MoeTalk 配色（浅色模式）
const moeBubbleLeftBg = Color(0xFF4D5B75); // AI 消息背景（深蓝灰色）
const moeBubbleLeftBorder = Color(0xFF4D5B75); // 边框同色
const moeBubbleLeftFg = Color(0xFFFFFFFF); // 文字白色
const moeBubbleRightBg = moePrimary; // 用户消息背景（主蓝色）
const moeBubbleRightBorder = moePrimary;

// 气泡 - 暗色模式
const moeBubbleLeftBgDark = Color(0xFF3A4555); // AI 消息背景（暗色）
const moeBubbleLeftBorderDark = Color(0xFF3A4555);
const moeBubbleLeftFgDark = Color(0xFFE5E8EB);
const moeBubbleRightBgDark = moePrimaryDark; // 用户消息背景（主蓝色暗色版）
const moeBubbleRightBorderDark = moePrimaryDark;

// 强调色
const moeAccent = Color(0xFFFC879B);
const moeAccentDark = Color(0xFFFC879B); // 暗色模式强调色保持一致

// 弹窗专用色（MeoTalk 风格）- 浅色模式
const moeDialogWarning = Color(0xFFFFD60A);  // 黄色确认按钮（警告/确认操作）
const moeDialogCancel = Color(0xFF8BBBE9);   // 蓝灰色取消按钮
const moeDialogAccentLine = Color(0xFFFFD60A); // 黄色装饰线（标题下划线）
const moeDialogOverlay = Color(0x80000000);  // 半透明黑色遮罩 (50% opacity)

// 弹窗专用色 - 暗色模式
const moeDialogWarningDark = Color(0xFFFFC629);  // 黄色确认按钮（稍微调亮）
const moeDialogCancelDark = Color(0xFF6BA1D8);   // 蓝灰色取消按钮
const moeDialogAccentLineDark = Color(0xFFFFC629); // 黄色装饰线
const moeDialogOverlayDark = Color(0xB0000000);  // 半透明黑色遮罩（暗色模式稍深）

// 圆角 - MoeTalk 使用 10px
const radiusBubble = Radius.circular(10);
const radiusAvatar = 64.0; // MoeTalk 头像 4rem

// 颜色方案（Material3）
final moeTalkColorScheme = ColorScheme.fromSeed(
  seedColor: moePrimary,
  brightness: Brightness.light,
  primary: moePrimary,
  surface: moePanel,
  onSurface: moeText,
);

final moeTalkColorSchemeDark = ColorScheme.fromSeed(
  seedColor: moePrimaryDark,
  brightness: Brightness.dark,
  primary: moePrimaryDark,
  surface: moePanelDark,
  onSurface: moeTextDark,
);

// 公共阴影
final cardShadow = [
  BoxShadow(color: Colors.black.withValues(alpha: 0.06), blurRadius: 8, offset: const Offset(0, 2)),
];

// 响应式断点（统一管理窄屏/宽屏切换阈值，KISS/DRY）
// 说明：小于该宽度使用 MainPage（窄屏），否则使用 SplitChatPage（宽屏）
const double layoutBreakpoint = 768.0; // 原 900，改小以适配更窄窗口

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
  /// 主题强调色（用于 AppBar、主按钮等）
  final Color accentColor;
  /// 组件公共背景色（用于设置分组、卡片等容器）
  final Color componentBackground;


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
    required this.accentColor,
    required this.componentBackground,
  });

  // 浅色主题
  static MoeColors light({Color? accentColor}) {
    final color = accentColor ?? const Color(0xFFFC96AA);
    return MoeColors(
    // primary/focus 代表"全局强调色"（按钮/选中态等），应跟随用户选择的主题色
    primary: color,
    surface: moeSurface,
    surfaceAlt: moeSurfaceAlt,
    panel: moePanel,
    bgMain: moeBgMain,
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
    headerColor: color,
    headerContentColor: moeHeaderContentLight,
    accentColor: color,
    componentBackground: Colors.white,
  );
  }

  // 暗色主题
  static MoeColors dark({Color? accentColor}) {
    final color = accentColor ?? const Color(0xFFFC96AA);
    // 暗色模式下稍微降低饱和度
    final hsl = HSLColor.fromColor(color);
    final darkColor = hsl.withLightness((hsl.lightness * 0.9).clamp(0.0, 1.0)).toColor();
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
    headerColor: darkColor,
    headerContentColor: moeTextDark,
    accentColor: darkColor,
    componentBackground: moePanelDark,
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
    Color? accentColor,
    Color? componentBackground,
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
      accentColor: accentColor ?? this.accentColor,
      componentBackground: componentBackground ?? this.componentBackground,
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
      bubbleLeftBorder: Color.lerp(bubbleLeftBorder, other.bubbleLeftBorder, t)!,
      bubbleLeftFg: Color.lerp(bubbleLeftFg, other.bubbleLeftFg, t)!,
      bubbleRightBg: Color.lerp(bubbleRightBg, other.bubbleRightBg, t)!,
      bubbleRightBorder: Color.lerp(bubbleRightBorder, other.bubbleRightBorder, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      dialogWarning: Color.lerp(dialogWarning, other.dialogWarning, t)!,
      dialogCancel: Color.lerp(dialogCancel, other.dialogCancel, t)!,
      dialogAccentLine: Color.lerp(dialogAccentLine, other.dialogAccentLine, t)!,
      dialogOverlay: Color.lerp(dialogOverlay, other.dialogOverlay, t)!,
      headerColor: Color.lerp(headerColor, other.headerColor, t)!,
      headerContentColor: Color.lerp(headerContentColor, other.headerContentColor, t)!,
      accentColor: Color.lerp(accentColor, other.accentColor, t)!,
      componentBackground: Color.lerp(componentBackground, other.componentBackground, t)!,
    );
  }
}

// 便捷访问方法
extension MoeColorsExtension on BuildContext {
  MoeColors get moeColors => Theme.of(this).extension<MoeColors>() ?? MoeColors.light();
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
const Duration kAnimPage = Duration(milliseconds: 400);
/// 页面关闭动画
const Duration kAnimPageReverse = Duration(milliseconds: 350);
/// 较长动画（如滚动同步、复杂展开）
const Duration kAnimLong = Duration(milliseconds: 1200);
/// Toast 默认显示时长
const Duration kDurationToast = Duration(milliseconds: 1500);

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
