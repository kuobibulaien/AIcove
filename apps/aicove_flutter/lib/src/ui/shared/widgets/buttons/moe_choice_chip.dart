import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../theme/moe_input_theme.dart';
import '../../../theme/tokens.dart';
import 'moe_button_surface.dart';

/// 选择标签尺寸。
enum MoeChoiceChipSize {
  sm(height: 32, paddingH: 10, fontSize: 12, iconSize: 14, gap: 4),
  md(height: 38, paddingH: 12, fontSize: 13, iconSize: 16, gap: 6);

  const MoeChoiceChipSize({
    required this.height,
    required this.paddingH,
    required this.fontSize,
    required this.iconSize,
    required this.gap,
  });

  final double height;
  final double paddingH;
  final double fontSize;
  final double iconSize;
  final double gap;
}

/// 选择标签前的状态指示。
enum MoeChoiceIndicator { none, check, radio }

/// 可选中的标签按钮：单选、多选、筛选共用。
///
/// 可读性优先：文字始终用主题文字色，选中态只靠强调色淡染、
/// 强调色描边和加粗区分，不用彩色文字，也不出现实色块。
class MoeChoiceChip extends StatefulWidget {
  const MoeChoiceChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
    this.size = MoeChoiceChipSize.md,
    this.expand = false,
    this.muted = false,
    this.indicator = MoeChoiceIndicator.none,
  });

  final String label;
  final bool selected;

  /// 为 null 时显示禁用态。
  final VoidCallback? onTap;
  final IconData? icon;
  final MoeChoiceChipSize size;

  /// 撑满父级宽度并居中文字，用于网格选项。
  final bool expand;

  /// 未选中时文字弱化，用于「未设置」之类的占位选项。
  final bool muted;

  /// 多选用 [MoeChoiceIndicator.check]，单选用 [MoeChoiceIndicator.radio]。
  final MoeChoiceIndicator indicator;

  @override
  State<MoeChoiceChip> createState() => _MoeChoiceChipState();
}

class _MoeChoiceChipState extends State<MoeChoiceChip> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed != value) setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final size = widget.size;
    final selected = widget.selected;
    final enabled = widget.onTap != null;
    final tint = selected
        ? colors.primary
        : (_pressed ? colors.text.withValues(alpha: 0.08) : null);
    final textColor = !selected && widget.muted ? colors.muted : colors.text;
    final iconColor = selected
        ? context.moeAccentInk
        : colors.textSecondary;

    final content = Row(
      mainAxisSize: widget.expand ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (widget.indicator != MoeChoiceIndicator.none) ...[
          _Indicator(
            kind: widget.indicator,
            selected: selected,
            size: size.iconSize,
          ),
          SizedBox(width: size.gap + 2),
        ],
        if (widget.icon != null) ...[
          Icon(widget.icon, size: size.iconSize, color: iconColor),
          SizedBox(width: size.gap),
        ],
        Flexible(
          child: Text(
            widget.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: size.fontSize,
              height: 1.2,
              color: textColor,
              fontWeight: selected
                  ? MoeFontWeights.emphasis
                  : MoeFontWeights.normal,
            ),
          ),
        ),
      ],
    );

    return Semantics(
      button: true,
      selected: selected,
      enabled: enabled,
      child: Opacity(
        opacity: enabled ? 1 : 0.45,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: enabled ? (_) => _setPressed(true) : null,
          onTapUp: enabled ? (_) => _setPressed(false) : null,
          onTapCancel: enabled ? () => _setPressed(false) : null,
          onTap: enabled
              ? () {
                  HapticFeedback.selectionClick();
                  widget.onTap!();
                }
              : null,
          child: MoeButtonSurface(
            shareParentSurface: false,
            radius: moeInputRadius,
            width: widget.expand ? double.infinity : null,
            padding: EdgeInsets.symmetric(horizontal: size.paddingH),
            tintColor: tint,
            border: Border.all(
              color: selected ? colors.primary : colors.border,
              width: selected ? 1.5 : 1,
            ),
            child: SizedBox(
              height: size.height,
              child: Center(
                widthFactor: widget.expand ? null : 1,
                child: content,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Indicator extends StatelessWidget {
  const _Indicator({
    required this.kind,
    required this.selected,
    required this.size,
  });

  final MoeChoiceIndicator kind;
  final bool selected;
  final double size;

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final active = colors.primary;
    return AnimatedContainer(
      duration: kAnimFast,
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: selected ? active : Colors.transparent,
        border: Border.all(
          color: selected ? active : colors.textSecondary,
          width: 1.5,
        ),
      ),
      child: !selected
          ? null
          : kind == MoeChoiceIndicator.check
          ? Icon(Icons.check, size: size - 6, color: Colors.white)
          : Center(
              child: Container(
                width: size * 0.36,
                height: size * 0.36,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white,
                ),
              ),
            ),
    );
  }
}
