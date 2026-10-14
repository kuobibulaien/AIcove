import 'package:flutter/material.dart';

import '../../../theme/tokens.dart';
import 'moe_slider.dart';

/// 紧凑的「标签｜滑块｜数值」一行，用于浮动面板里的调节项。
class MoeLabeledSliderRow extends StatelessWidget {
  const MoeLabeledSliderRow({
    super.key,
    required this.label,
    required this.value,
    required this.display,
    required this.divisions,
    required this.onChanged,
    this.min = 0.0,
    this.max = 1.0,
  });

  final String label;
  final double value;
  final String display;
  final int divisions;
  final double min;
  final double max;

  /// 为 null 时滑块置灰不可调。
  final ValueChanged<double>? onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    return Row(
      children: [
        SizedBox(
          width: 40,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: MoeFontWeights.emphasis,
              color: colors.text,
            ),
          ),
        ),
        Expanded(
          child: MoeSlider(
            value: value,
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 40,
          child: Text(
            display,
            textAlign: TextAlign.end,
            style: TextStyle(fontSize: 12, color: colors.textSecondary),
          ),
        ),
      ],
    );
  }
}
