import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../../theme/tokens.dart';
import 'moe_floating_surface.dart';

/// Shared capsule search with a continuous centered-to-leading focus transition.
class MoeSearchField extends StatefulWidget {
  const MoeSearchField({
    super.key,
    this.onChanged,
    this.hintText = '搜索',
    this.controller,
    this.initialValue = '',
    this.autofocus = false,
    this.padding = defaultPadding,
  });

  static const defaultPadding = EdgeInsets.fromLTRB(12, 4, 12, 10);

  /// Laid-out height including [padding], so a bar can reserve the field.
  static double heightFor(
    BuildContext context, {
    EdgeInsetsGeometry padding = defaultPadding,
  }) {
    final painter = TextPainter(
      text: TextSpan(text: ' ', style: _textStyle(context)),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final lineHeight = painter.preferredLineHeight;
    painter.dispose();
    return lineHeight + _verticalContentPadding * 2 + padding.vertical;
  }

  static const double _verticalContentPadding = 10;

  static TextStyle _textStyle(BuildContext context) =>
      Theme.of(context).textTheme.bodyMedium!.copyWith(
        fontSize: 15,
        color: context.moeColors.muted,
        fontWeight: FontWeight.normal,
      );

  final ValueChanged<String>? onChanged;
  final String hintText;
  final TextEditingController? controller;
  final String initialValue;
  final bool autofocus;
  final EdgeInsetsGeometry padding;

  @override
  State<MoeSearchField> createState() => _MoeSearchFieldState();
}

class _MoeSearchFieldState extends State<MoeSearchField> {
  late final _ownedController = TextEditingController(
    text: widget.initialValue,
  );
  final _focusNode = FocusNode();
  TextEditingController get _controller =>
      widget.controller ?? _ownedController;

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_onFocusChanged);
  }

  void _onFocusChanged() => setState(() {});

  @override
  void dispose() {
    _ownedController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final hintStyle = MoeSearchField._textStyle(context);
    return Padding(
      padding: widget.padding,
      child: ValueListenableBuilder<TextEditingValue>(
        valueListenable: _controller,
        builder: (context, value, _) {
          final expanded = value.text.isNotEmpty || _focusNode.hasFocus;
          return LayoutBuilder(
            builder: (context, constraints) {
              final painter = TextPainter(
                text: TextSpan(text: widget.hintText, style: hintStyle),
                textDirection: Directionality.of(context),
                textScaler: MediaQuery.textScalerOf(context),
                maxLines: 1,
              )..layout();
              final groupWidth = math.min(
                painter.width + 30,
                math.max(0.0, constraints.maxWidth - 60),
              );
              painter.dispose();
              // The material owns the shape and border; the input only lays
              // out text so the two renderers cannot draw separate outlines.
              const border = InputBorder.none;
              final field = TweenAnimationBuilder<double>(
                tween: Tween<double>(
                  end: expanded ? 14 : (constraints.maxWidth - groupWidth) / 2,
                ),
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeInOutCubic,
                builder: (context, leading, _) => Stack(
                  alignment: Alignment.centerLeft,
                  children: [
                    TextField(
                      controller: _controller,
                      focusNode: _focusNode,
                      autofocus: widget.autofocus,
                      onChanged: widget.onChanged,
                      onTapOutside: (_) => _focusNode.unfocus(),
                      textInputAction: TextInputAction.search,
                      textAlignVertical: TextAlignVertical.center,
                      style: hintStyle.copyWith(color: colors.text),
                      decoration: InputDecoration(
                        // Hint, caret and input share the native text layout.
                        hintText: widget.hintText,
                        hintStyle: hintStyle,
                        isDense: true,
                        filled: true,
                        fillColor: Colors.transparent,
                        contentPadding: EdgeInsets.fromLTRB(
                          leading + 30,
                          MoeSearchField._verticalContentPadding,
                          44,
                          MoeSearchField._verticalContentPadding,
                        ),
                        border: border,
                        enabledBorder: border,
                        focusedBorder: border,
                      ),
                    ),
                    Positioned(
                      left: leading,
                      top: 0,
                      bottom: 0,
                      child: IgnorePointer(
                        child: ExcludeSemantics(
                          child: Icon(
                            Icons.search_rounded,
                            color: colors.muted,
                            size: 22,
                          ),
                        ),
                      ),
                    ),
                    if (expanded)
                      Positioned(
                        right: 2,
                        top: 0,
                        bottom: 0,
                        child: IconButton(
                          tooltip: value.text.isEmpty ? '取消搜索' : '清除搜索',
                          icon: Icon(
                            Icons.cancel,
                            size: 18,
                            color: colors.muted,
                          ),
                          onPressed: () {
                            if (value.text.isEmpty) {
                              _focusNode.unfocus();
                            } else {
                              _controller.clear();
                              widget.onChanged?.call('');
                              _focusNode.requestFocus();
                            }
                          },
                        ),
                      ),
                  ],
                ),
              );
              return MoeFloatingSurface(
                baseline: MoeMaterialBaseline.text,
                radius: 100,
                solidColor: colors.surface,
                shadows: const [],
                child: field,
              );
            },
          );
        },
      ),
    );
  }
}
