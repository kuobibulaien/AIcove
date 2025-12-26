/// MoeAppBar - 统一的 AppBar 样式组件
/// 
/// 遵循 DRY 原则：封装可换肤的 AppBar 样式
/// 
/// 特性：
/// - 从 SkinConfig 读取装饰样式
/// - 支持皮肤切换
/// - 统一的标题样式（粗体、24号字）
/// 
/// 更新记录：
/// - 2025-12-06: 从多个页面抽取公共 AppBar 样式
/// - 2025-12-06: 接入皮肤系统
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/skin_provider.dart';
import '../theme/tokens.dart';

/// MoeTalk 风格 AppBar
/// 
/// 用法：
/// ```dart
/// Scaffold(
///   appBar: MoeAppBar(
///     title: '设置',
///     actions: [...],
///   ),
///   body: ...,
/// )
/// ```
class MoeAppBar extends StatelessWidget implements PreferredSizeWidget {
  /// 标题文本
  final String title;
  
  /// 是否显示返回按钮（默认 false，用于一级页面）
  final bool showBackButton;
  
  /// 自定义 leading 组件（优先级高于 showBackButton）
  final Widget? leading;
  
  /// leading 区域宽度
  final double? leadingWidth;
  
  /// 右侧操作按钮
  final List<Widget>? actions;
  
  /// 标题是否居中
  final bool centerTitle;
  
  /// 标题左侧内边距（当有 leading 时生效）
  final double titleLeftPadding;

  const MoeAppBar({
    super.key,
    required this.title,
    this.showBackButton = false,
    this.leading,
    this.leadingWidth,
    this.actions,
    this.centerTitle = false,
    this.titleLeftPadding = 12,
  });

  @override
  Size get preferredSize => Size.fromHeight(kToolbarHeight + borderWidth);

  @override
  Widget build(BuildContext context) {
    final skin = context.skin;
    final colors = context.moeColors;
    final decoration = skin.appBarDecoration(colors);
    
    // 计算 leading 相关配置
    // 无自定义 leading 且不显示返回按钮时：设置 leadingWidth=0 消除左侧空白
    final hasLeading = leading != null || showBackButton;
    final effectiveLeadingWidth = leadingWidth ?? (hasLeading ? null : 0);
    
    // 状态栏样式：颜色与 AppBar 同步
    final appBarColor = decoration.color ?? colors.headerColor;
    final systemOverlayStyle = SystemUiOverlayStyle(
      statusBarColor: appBarColor,
      statusBarIconBrightness: Brightness.light, // 粉色背景用白色图标
      statusBarBrightness: Brightness.dark, // iOS: 状态栏内容为浅色
    );

    return AppBar(
      systemOverlayStyle: systemOverlayStyle,
      backgroundColor: appBarColor,
      foregroundColor: colors.headerContentColor,
      elevation: 0,
      leadingWidth: effectiveLeadingWidth,
      titleSpacing: leading != null ? 0 : null,
      leading: leading,
      automaticallyImplyLeading: showBackButton,
      bottom: PreferredSize(
        preferredSize: Size.fromHeight(skin.borderWidth),
        child: Container(
          height: skin.borderWidth,
          decoration: BoxDecoration(
            color: colors.divider,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.04),
                offset: const Offset(0, 1),
                blurRadius: 0,
              ),
            ],
          ),
        ),
      ),
      title: Padding(
        padding: EdgeInsets.only(left: leading != null ? 0 : titleLeftPadding),
        child: Text(
          title,
          style: TextStyle(
            fontWeight: FontWeight.w800,
            fontSize: 24,
            color: colors.headerContentColor,
            letterSpacing: 0.8,
          ),
        ),
      ),
      centerTitle: centerTitle,
      actions: actions,
    );
  }
}

/// MoeAppBar 的简化版本，用于详情页（较小标题）
class MoeDetailAppBar extends StatelessWidget implements PreferredSizeWidget {
  final String title;
  final List<Widget>? actions;

  const MoeDetailAppBar({
    super.key,
    required this.title,
    this.actions,
  });

  @override
  Size get preferredSize => Size.fromHeight(kToolbarHeight + borderWidth);

  @override
  Widget build(BuildContext context) {
    final skin = context.skin;
    final colors = context.moeColors;
    final decoration = skin.appBarDecoration(colors);
    
    // 状态栏样式：颜色与 AppBar 同步
    final appBarColor = decoration.color ?? colors.headerColor;
    final systemOverlayStyle = SystemUiOverlayStyle(
      statusBarColor: appBarColor,
      statusBarIconBrightness: Brightness.light,
      statusBarBrightness: Brightness.dark,
    );

    return AppBar(
      systemOverlayStyle: systemOverlayStyle,
      backgroundColor: appBarColor,
      foregroundColor: colors.headerContentColor,
      elevation: 0,
      bottom: PreferredSize(
        preferredSize: Size.fromHeight(skin.borderWidth),
        child: Container(
          height: skin.borderWidth,
          decoration: BoxDecoration(
            color: colors.divider,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.04),
                offset: const Offset(0, 1),
                blurRadius: 0,
              ),
            ],
          ),
        ),
      ),
      titleTextStyle: TextStyle(
        fontSize: 22,
        fontWeight: FontWeight.w800,
        color: colors.headerContentColor,
        letterSpacing: 0.8,
      ),
      title: Text(title),
      centerTitle: false,
      actions: actions,
    );
  }
}
