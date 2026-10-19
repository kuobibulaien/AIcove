import 'package:flutter/material.dart';

import '../buttons/moe_choice_chip.dart';
import '../form/moe_segmented_control.dart';
import 'ui_block_style.dart';

/// Labels up to this many characters fit a chip; longer ones get full rows.
const int _chipMaxRunes = 12;

/// A set of options picked by tapping (ADR0091). The layout follows the
/// labels: a segmented control for a few short single choices, chips for
/// short labels, and full-width rows whose text wraps once any label is long,
/// so nothing is cut to an ellipsis.
class UiChoices extends StatelessWidget {
  const UiChoices({
    super.key,
    required this.labels,
    required this.selected,
    required this.onTap,
    required this.style,
    this.segmented = false,
  });

  final List<String> labels;
  final Set<int> selected;

  /// Null disables every option.
  final ValueChanged<int>? onTap;
  final UiBlockStyle style;

  /// Prefer a segmented control when the options are few and short.
  final bool segmented;

  @override
  Widget build(BuildContext context) {
    if (labels.isEmpty) return const SizedBox.shrink();
    final longest = labels.map((l) => l.runes.length).reduce((a, b) => a > b ? a : b);
    if (segmented && selected.length <= 1 && labels.length <= 4 && longest <= 8) {
      return MoeSegmentedControl<int>(
        value: selected.isEmpty ? 0 : selected.first,
        height: 32,
        segments: [for (var i = 0; i < labels.length; i++) MoeSegment(value: i, label: labels[i])],
        onChanged: (i) => onTap?.call(i),
      );
    }
    if (longest <= _chipMaxRunes) {
      return Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (var i = 0; i < labels.length; i++)
            MoeChoiceChip(
              size: MoeChoiceChipSize.sm,
              label: labels[i],
              selected: selected.contains(i),
              onTap: onTap == null ? null : () => onTap!(i),
            ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < labels.length; i++)
          Padding(
            padding: EdgeInsets.only(top: i == 0 ? 0 : 6),
            child: UiOptionTile(
              text: labels[i],
              state: selected.contains(i) ? UiOptionState.selected : UiOptionState.neutral,
              onTap: onTap == null ? null : () => onTap!(i),
              style: style,
            ),
          ),
      ],
    );
  }
}

enum UiOptionState { neutral, selected, right, wrong }

/// One full-width option whose text wraps.
class UiOptionTile extends StatelessWidget {
  const UiOptionTile({super.key, required this.text, required this.state, required this.onTap, required this.style});

  final String text;
  final UiOptionState state;
  final VoidCallback? onTap;
  final UiBlockStyle style;

  @override
  Widget build(BuildContext context) {
    final color = switch (state) {
      UiOptionState.neutral => style.line,
      UiOptionState.selected => style.accent,
      UiOptionState.right => style.positive,
      UiOptionState.wrong => style.negative,
    };
    final icon = switch (state) {
      UiOptionState.neutral => null,
      UiOptionState.selected || UiOptionState.right => Icons.check_rounded,
      UiOptionState.wrong => Icons.close_rounded,
    };
    final active = state != UiOptionState.neutral;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Ink(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            color: active ? color.withValues(alpha: 0.1) : null,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: color, width: 0.8),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: Text(text, style: style.small)),
              if (icon != null)
                Padding(
                  padding: const EdgeInsets.only(left: 8, top: 2),
                  child: Icon(icon, size: 16, color: color),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Label of the free-text option added to choices (ADR0091): the user can
/// always answer in their own words instead of the listed options.
const String kUiOtherLabel = '其他';

/// Whether a choice set offers [kUiOtherLabel]; on unless the block or the
/// item says `"other": false`.
bool uiOffersOther(Object? itemFlag, Object? blockFlag) => itemFlag != false && blockFlag != false;

/// The text field style shared by inputs in blocks.
InputDecoration uiInputDecoration(UiBlockStyle style, {String? hint, bool error = false}) {
  OutlineInputBorder border(Color? color) => OutlineInputBorder(
    borderRadius: BorderRadius.circular(10),
    borderSide: color == null ? BorderSide.none : BorderSide(color: color),
  );
  return InputDecoration(
    isDense: true,
    hintText: hint,
    hintStyle: style.small.copyWith(color: style.muted),
    filled: true,
    fillColor: style.faint,
    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    border: border(null),
    enabledBorder: border(error ? style.negative : null),
  );
}
