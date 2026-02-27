/// MoeTextField - 统一输入框组件
/// 
/// 用于文本输入（单行、多行、密码、搜索等）。
/// 
/// 设计特点：
/// - 统一的视觉风格（边框、圆角、焦点状态）
/// - 支持前缀/后缀图标
/// - 支持错误/帮助文本
/// - 完整的样式接口（背景、边框、圆角皆可覆盖）
/// 
/// 使用示例：
/// ```dart
/// MoeTextField(
///   controller: _controller,
///   label: '用户名',
///   hint: '请输入用户名',
/// )
/// ```
/// 
/// 更新记录：
/// - 2025-12-31: 创建统一输入框组件
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../theme/tokens.dart';
import '../../effects/smooth_clip.dart';

/// 输入框尺寸枚举
enum MoeTextFieldSize { sm, md, lg }

/// 统一输入框组件
class MoeTextField extends StatefulWidget {
  const MoeTextField({
    super.key,
    this.controller,
    this.focusNode,
    this.label,
    this.hint,
    this.errorText,
    this.helperText,
    this.prefixIcon,
    this.suffixIcon,
    this.suffix,
    this.obscureText = false,
    this.maxLines = 1,
    this.minLines,
    this.maxLength,
    this.keyboardType,
    this.textInputAction,
    this.inputFormatters,
    this.onChanged,
    this.onSubmitted,
    this.onTap,
    this.enabled = true,
    this.readOnly = false,
    this.autofocus = false,
    this.size = MoeTextFieldSize.md,
    // === 样式接口 ===
    this.fillColor,
    this.focusFillColor,
    this.errorFillColor,
    this.borderColor,
    this.focusBorderColor,
    this.errorBorderColor,
    this.textColor,
    this.hintColor,
    this.labelColor,
    this.borderRadius,
    this.borderWidth,
    this.contentPadding,
  });

  /// 文本控制器
  final TextEditingController? controller;

  /// 焦点节点
  final FocusNode? focusNode;

  /// 标签文本（浮动标签）
  final String? label;

  /// 占位提示文本
  final String? hint;

  /// 错误文本
  final String? errorText;

  /// 帮助文本
  final String? helperText;

  /// 前缀图标
  final IconData? prefixIcon;

  /// 后缀图标
  final IconData? suffixIcon;

  /// 后缀 Widget（优先于 suffixIcon）
  final Widget? suffix;

  /// 是否隐藏文本（密码输入）
  final bool obscureText;

  /// 最大行数（1 = 单行）
  final int maxLines;

  /// 最小行数
  final int? minLines;

  /// 最大字符数
  final int? maxLength;

  /// 键盘类型
  final TextInputType? keyboardType;

  /// 键盘操作按钮
  final TextInputAction? textInputAction;

  /// 输入格式化器
  final List<TextInputFormatter>? inputFormatters;

  /// 内容变化回调
  final ValueChanged<String>? onChanged;

  /// 提交回调
  final ValueChanged<String>? onSubmitted;

  /// 点击回调
  final VoidCallback? onTap;

  /// 是否启用
  final bool enabled;

  /// 是否只读
  final bool readOnly;

  /// 是否自动聚焦
  final bool autofocus;

  /// 输入框尺寸
  final MoeTextFieldSize size;

  // === 样式接口 ===
  
  /// 背景填充色
  final Color? fillColor;

  /// 聚焦时的填充色
  final Color? focusFillColor;

  /// 错误时的填充色
  final Color? errorFillColor;

  /// 边框颜色
  final Color? borderColor;

  /// 聚焦时的边框颜色
  final Color? focusBorderColor;

  /// 错误时的边框颜色
  final Color? errorBorderColor;

  /// 文本颜色
  final Color? textColor;

  /// 占位文本颜色
  final Color? hintColor;

  /// 标签颜色
  final Color? labelColor;

  /// 圆角
  final BorderRadius? borderRadius;

  /// 边框宽度
  final double? borderWidth;

  /// 内容内边距
  final EdgeInsets? contentPadding;

  @override
  State<MoeTextField> createState() => _MoeTextFieldState();
}

class _MoeTextFieldState extends State<MoeTextField> {
  late FocusNode _focusNode;
  bool _hasFocus = false;

  @override
  void initState() {
    super.initState();
    _focusNode = widget.focusNode ?? FocusNode();
    _focusNode.addListener(_handleFocusChange);
  }

  @override
  void dispose() {
    if (widget.focusNode == null) {
      _focusNode.dispose();
    } else {
      _focusNode.removeListener(_handleFocusChange);
    }
    super.dispose();
  }

  void _handleFocusChange() {
    setState(() => _hasFocus = _focusNode.hasFocus);
  }

  double get _fontSize {
    switch (widget.size) {
      case MoeTextFieldSize.sm:
        return 14;
      case MoeTextFieldSize.md:
        return 16;
      case MoeTextFieldSize.lg:
        return 18;
    }
  }

  EdgeInsets get _defaultPadding {
    switch (widget.size) {
      case MoeTextFieldSize.sm:
        return const EdgeInsets.symmetric(horizontal: 12, vertical: 10);
      case MoeTextFieldSize.md:
        return const EdgeInsets.symmetric(horizontal: 14, vertical: 14);
      case MoeTextFieldSize.lg:
        return const EdgeInsets.symmetric(horizontal: 16, vertical: 16);
    }
  }

  bool get _hasError => widget.errorText != null && widget.errorText!.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    
    // 解析样式
    final fillColor = widget.fillColor ?? colors.surface;
    final focusFillColor = widget.focusFillColor ?? fillColor;
    final errorFillColor = widget.errorFillColor ?? fillColor;
    
    final borderColor = widget.borderColor ?? colors.borderLight;
    final focusBorderColor = widget.focusBorderColor ?? colors.focus;
    final errorBorderColor = widget.errorBorderColor ?? const Color(0xFFE53935);
    
    final textColor = widget.textColor ?? colors.text;
    final hintColor = widget.hintColor ?? colors.muted;
    final labelColor = widget.labelColor ?? colors.textSecondary;
    
    final radius = widget.borderRadius ?? MoeRadii.borderSm;
    final g2Radius = radius.topLeft.x;
    final borderWidth = widget.borderWidth ?? 1.0;
    final padding = widget.contentPadding ?? _defaultPadding;

    // 计算当前状态的样式
    Color currentFill;
    Color currentBorder;
    
    if (_hasError) {
      currentFill = errorFillColor;
      currentBorder = errorBorderColor;
    } else if (_hasFocus) {
      currentFill = focusFillColor;
      currentBorder = focusBorderColor;
    } else {
      currentFill = fillColor;
      currentBorder = borderColor;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // 标签（如果有）
        if (widget.label != null) ...[
          Text(
            widget.label!,
            style: TextStyle(
              fontSize: 12,
              fontWeight: MoeFontWeights.emphasis,
              color: _hasError ? errorBorderColor : labelColor,
            ),
          ),
          const SizedBox(height: 6),
        ],
        
        // 输入框
        AnimatedContainer(
          duration: kAnimFast,
          decoration: MoeG2Decoration(
            radius: g2Radius,
            color: currentFill,
            border: Border.all(
              color: currentBorder,
              width: _hasFocus ? borderWidth * 1.5 : borderWidth,
            ),
          ),
          child: TextField(
            controller: widget.controller,
            focusNode: _focusNode,
            enabled: widget.enabled,
            readOnly: widget.readOnly,
            autofocus: widget.autofocus,
            obscureText: widget.obscureText,
            maxLines: widget.maxLines,
            minLines: widget.minLines,
            maxLength: widget.maxLength,
            keyboardType: widget.keyboardType,
            textInputAction: widget.textInputAction,
            inputFormatters: widget.inputFormatters,
            onChanged: widget.onChanged,
            onSubmitted: widget.onSubmitted,
            onTap: widget.onTap,
            style: TextStyle(
              fontSize: _fontSize,
              color: widget.enabled ? textColor : colors.muted,
            ),
            decoration: InputDecoration(
              hintText: widget.hint,
              hintStyle: TextStyle(
                fontSize: _fontSize,
                color: hintColor,
              ),
              border: InputBorder.none,
              contentPadding: padding,
              isDense: true,
              prefixIcon: widget.prefixIcon != null
                  ? Icon(widget.prefixIcon, size: _fontSize + 4, color: hintColor)
                  : null,
              suffixIcon: widget.suffix ?? (widget.suffixIcon != null
                  ? Icon(widget.suffixIcon, size: _fontSize + 4, color: hintColor)
                  : null),
              counterText: '', // 隐藏字符计数
            ),
          ),
        ),
        
        // 错误/帮助文本
        if (_hasError || widget.helperText != null) ...[
          const SizedBox(height: 4),
          Text(
            _hasError ? widget.errorText! : widget.helperText!,
            style: TextStyle(
              fontSize: 12,
              color: _hasError ? errorBorderColor : colors.muted,
            ),
          ),
        ],
      ],
    );
  }
}
