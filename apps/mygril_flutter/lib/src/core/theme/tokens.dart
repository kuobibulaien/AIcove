import 'package:flutter/material.dart';

// MoeTalk 风格 Token（来自 MoeTalk 官方 CSS）

// ===== 浅色模式 =====
const moePrimary = Color(0xFF4A90E2); // Momotalk User Bubble Blue
const moeSurface = Color(0xFFF3F6F8); // 表面背景色
const moeSurfaceAlt = Color(0xFFE8EDF2); // 次级表面背景色（略深）
const moePanel = Color(0xFFDAE5F1); // 容器背景（卡片/聊天面板）
const moeBgMain = Color(0xFFDAE1E5); // 主背景色
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
const moeSurfaceDark = Color(0xFF1A1D23); // 表面背景色（深色背景）
const moeSurfaceAltDark = Color(0xFF232830); // 次级表面背景色（略深）
const moePanelDark = Color(0xFF2C323B); // 容器背景（卡片/聊天面板）
const moeBgMainDark = Color(0xFF25292F); // 主背景色
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

const moeHeaderGradientStart = Color(0xFFFC96AA); // 标题栏渐变起点
const moeHeaderGradientEnd = Color(0xFFF8869D);   // 标题栏渐变终点

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
  BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 8, offset: const Offset(0, 2)),
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
  });

  // 浅色主题
  static const light = MoeColors(
    primary: moePrimary,
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
    focus: moeFocus,
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
    headerColor: moeHeaderPink,
    headerContentColor: moeHeaderContentLight,
  );

  // 暗色主题
  static const dark = MoeColors(
    primary: moePrimaryDark,
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
    focus: moeFocusDark,
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
    headerColor: moeSurfaceDark, // 暗色模式下Header跟随Surface
    headerContentColor: moeTextDark,
  );

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
    );
  }
}

// 便捷访问方法
extension MoeColorsExtension on BuildContext {
  MoeColors get moeColors => Theme.of(this).extension<MoeColors>() ?? MoeColors.light;
}
