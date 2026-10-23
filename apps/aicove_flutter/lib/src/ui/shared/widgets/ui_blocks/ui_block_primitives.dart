import 'package:flutter/material.dart';

import '../../../../features/ui_blocks/domain/ui_block.dart';
import '../../../../features/ui_blocks/domain/ui_block_catalog.dart';
import '../../../../features/ui_blocks/domain/ui_expression.dart';
import '../../../../features/ui_blocks/domain/ui_saved_state.dart';
import '../buttons/moe_choice_chip.dart';
import '../form/moe_slider.dart';
import '../form/moe_switch.dart';
import 'ui_block_catalog_views.dart';
import 'ui_block_options.dart';
import 'ui_block_style.dart';

/// What panel nodes can do to their block.
class UiBlockRuntime {
  const UiBlockRuntime({
    required this.style,
    required this.setValues,
    required this.ask,
    required this.copy,
  });

  final UiBlockStyle style;
  final void Function(Map<String, Object?> changes) setValues;

  /// Null where nothing can receive a follow-up (exports, previews).
  final ValueChanged<String>? ask;
  final Future<void> Function(String text) copy;
}

const double _gap = 10;

/// Renders one resolved node of a panel (ADR0073 交互组件).
Widget buildUiNode(
  BuildContext context,
  UiNode node,
  UiBlockRuntime rt, {
  bool top = false,
}) {
  final style = rt.style;
  List<Widget> children() => [
        for (final child in node.children) buildUiNode(context, child, rt),
      ];
  switch (node.component) {
    case 'panel':
    case 'stack':
      final title = node.text('title') ?? '';
      final description = node.text('description') ?? '';
      return _column([
        if (title.isNotEmpty) Text(title, style: style.title),
        if (description.isNotEmpty) Text(description, style: style.caption),
        ...children(),
      ]);
    case 'row':
      return _UiRow(children: children());
    case 'grid':
      return _UiGrid(
        columns: (node.number('columns') ?? 2).toInt().clamp(1, 4),
        children: children(),
      );
    case 'card':
      final title = node.text('title') ?? '';
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: style.faint,
          borderRadius: BorderRadius.circular(10),
        ),
        child: _column([
          if (title.isNotEmpty) Text(title, style: style.title),
          ...children(),
        ]),
      );
    case 'tabs':
      return _UiTabs(
        labels: [for (final item in node.list('items')) uiStringify(item)],
        style: style,
        pages: children(),
      );
    case 'collapse':
      return UiCollapse(
        title: node.text('title') ?? '',
        initiallyOpen: node.flag('open'),
        style: style,
        children: children(),
      );
    case 'divider':
      return Divider(height: 1, thickness: 0.5, color: style.line);
    case 'text':
      final size = node.text('size');
      final base = size == 'sm'
          ? style.small
          : size == 'lg'
              ? style.body.copyWith(fontSize: style.fontSize + 2)
              : style.body;
      return Text(
        node.text('text') ?? '',
        style: base.copyWith(color: style.tone(node.props['tone'])),
      );
    case 'stat':
      return _UiStat(node: node, style: style);
    case 'badge':
      return Align(
        alignment: Alignment.centerLeft,
        child: UiBadge(text: node.text('text') ?? '', color: style.tone(node.props['tone']), style: style),
      );
    case 'progress':
      return _UiProgress(node: node, style: style);
    case 'callout':
      return UiCallout(
        title: node.text('title') ?? '',
        text: node.text('text') ?? '',
        tone: node.props['tone'],
        style: style,
      );
    case 'slider':
      return _UiSlider(node: node, rt: rt);
    case 'select':
    case 'segmented':
      return _UiChoice(node: node, rt: rt);
    case 'switch':
      return _labeled(
        style,
        node.text('label') ?? '',
        trailing: MoeSwitch(
          size: MoeSwitchSize.sm,
          value: uiTruthy(node.props['value']),
          onChanged: node.bind == null ? null : (v) => rt.setValues({node.bind!: v}),
        ),
      );
    case 'input':
      return _UiInput(key: ValueKey('input-${node.path}'), node: node, rt: rt);
    case 'button':
      return _UiButton(node: node, rt: rt);
  }
  if (kUiCatalogNames.contains(node.component)) {
    // Keyed by position so two tabs holding the same kind of component never
    // share its state.
    return KeyedSubtree(
      key: ValueKey('catalog-${node.path}'),
      child: UiCatalogView(node: node, style: style, saved: null, onChanged: null, ask: rt.ask),
    );
  }
  return Text('（不支持的组件 ${node.component}）', style: style.caption);
}

Widget _column(List<Widget> children) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) const SizedBox(height: _gap),
          children[i],
        ],
      ],
    );

Widget _labeled(UiBlockStyle style, String label, {required Widget trailing, String? value}) {
  return Row(
    children: [
      Expanded(child: Text(label, style: style.small)),
      if (value != null) ...[
        Text(value, style: style.small.copyWith(fontWeight: FontWeight.w600)),
        const SizedBox(width: 8),
      ],
      trailing,
    ],
  );
}

/// Side by side when there is room, stacked on a narrow screen.
class _UiRow extends StatelessWidget {
  const _UiRow({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      if (children.length < 2 || constraints.maxWidth < 120.0 * children.length) {
        return _column(children);
      }
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) const SizedBox(width: _gap),
            Expanded(child: children[i]),
          ],
        ],
      );
    });
  }
}

/// Up to [columns] per line, fewer on narrow screens (at least 140 wide).
class _UiGrid extends StatelessWidget {
  const _UiGrid({required this.columns, required this.children});
  final int columns;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final fit = ((constraints.maxWidth + _gap) / (140 + _gap)).floor();
      final count = fit.clamp(1, columns);
      final rows = <Widget>[];
      for (var start = 0; start < children.length; start += count) {
        rows.add(Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < count; i++) ...[
              if (i > 0) const SizedBox(width: _gap),
              Expanded(
                child: start + i < children.length ? children[start + i] : const SizedBox.shrink(),
              ),
            ],
          ],
        ));
      }
      return _column(rows);
    });
  }
}

class _UiTabs extends StatefulWidget {
  const _UiTabs({required this.labels, required this.style, required this.pages});
  final List<String> labels;
  final UiBlockStyle style;
  final List<Widget> pages;

  @override
  State<_UiTabs> createState() => _UiTabsState();
}

class _UiTabsState extends State<_UiTabs> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final count = widget.pages.length;
    if (count == 0) return const SizedBox.shrink();
    final index = _index.clamp(0, count - 1);
    return _column([
      Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (var i = 0; i < count; i++)
            MoeChoiceChip(
              size: MoeChoiceChipSize.sm,
              label: i < widget.labels.length ? widget.labels[i] : '第 ${i + 1} 页',
              selected: i == index,
              onTap: () => setState(() => _index = i),
            ),
        ],
      ),
      KeyedSubtree(key: ValueKey(index), child: widget.pages[index]),
    ]);
  }
}

/// A titled section that unfolds in place.
class UiCollapse extends StatefulWidget {
  const UiCollapse({
    super.key,
    required this.title,
    required this.initiallyOpen,
    required this.style,
    required this.children,
  });
  final String title;
  final bool initiallyOpen;
  final UiBlockStyle style;
  final List<Widget> children;

  @override
  State<UiCollapse> createState() => _UiCollapseState();
}

class _UiCollapseState extends State<UiCollapse> {
  late bool _open = widget.initiallyOpen;

  @override
  Widget build(BuildContext context) {
    final style = widget.style;
    return _column([
      InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: () => setState(() => _open = !_open),
        child: Row(
          children: [
            Expanded(child: Text(widget.title, style: style.small.copyWith(fontWeight: FontWeight.w600))),
            AnimatedRotation(
              turns: _open ? 0.5 : 0,
              duration: const Duration(milliseconds: 160),
              child: Icon(Icons.expand_more_rounded, size: 18, color: style.muted),
            ),
          ],
        ),
      ),
      if (_open) ...widget.children,
    ]);
  }
}

class _UiStat extends StatelessWidget {
  const _UiStat({required this.node, required this.style});
  final UiNode node;
  final UiBlockStyle style;

  @override
  Widget build(BuildContext context) {
    final raw = node.props['value'];
    final precision = node.number('precision')?.toInt().clamp(0, 6);
    final value = raw == null
        ? '—'
        : raw is num
            ? uiFormatNumber(raw, maxDecimals: precision ?? 2)
            : uiStringify(raw);
    final unit = node.text('unit') ?? '';
    final note = node.text('note') ?? '';
    final color = node.flag('highlight') ? style.accent : style.tone(node.props['tone']);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(node.text('label') ?? '', style: style.caption),
        const SizedBox(height: 2),
        Text.rich(
          TextSpan(children: [
            TextSpan(
              text: value,
              style: TextStyle(
                fontSize: style.fontSize + 7,
                fontWeight: FontWeight.w600,
                color: color,
                height: 1.2,
              ),
            ),
            if (unit.isNotEmpty) TextSpan(text: ' $unit', style: style.small.copyWith(color: style.muted)),
          ]),
        ),
        if (note.isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(note, style: style.caption),
        ],
      ],
    );
  }
}

class UiBadge extends StatelessWidget {
  const UiBadge({super.key, required this.text, required this.color, required this.style});
  final String text;
  final Color color;
  final UiBlockStyle style;

  @override
  Widget build(BuildContext context) {
    final tint = color == style.fg ? style.muted : color;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(text, style: style.caption.copyWith(color: tint, fontWeight: FontWeight.w500)),
    );
  }
}

class _UiProgress extends StatelessWidget {
  const _UiProgress({required this.node, required this.style});
  final UiNode node;
  final UiBlockStyle style;

  @override
  Widget build(BuildContext context) {
    final value = node.number('value') ?? 0;
    final max = node.number('max') ?? 100;
    final ratio = max <= 0 ? 0.0 : (value / max).clamp(0.0, 1.0).toDouble();
    final label = node.text('label') ?? '';
    final color = node.props['tone'] == null ? style.accent : style.tone(node.props['tone']);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (label.isNotEmpty) ...[
          Text(label, style: style.caption),
          const SizedBox(height: 6),
        ],
        ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: LinearProgressIndicator(
            value: ratio,
            minHeight: 6,
            color: color,
            backgroundColor: style.line,
          ),
        ),
      ],
    );
  }
}

class UiCallout extends StatelessWidget {
  const UiCallout({
    super.key,
    required this.title,
    required this.text,
    required this.tone,
    required this.style,
  });
  final String title;
  final String text;
  final Object? tone;
  final UiBlockStyle style;

  @override
  Widget build(BuildContext context) {
    final color = tone == null || tone == 'default' ? style.info : style.tone(tone);
    final icon = switch (tone) {
      'positive' || 'success' => Icons.check_circle_outline_rounded,
      'negative' || 'error' => Icons.error_outline_rounded,
      'warning' || 'warn' => Icons.warning_amber_rounded,
      _ => Icons.info_outline_rounded,
    };
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 9, 12, 9),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(icon, size: 16, color: color),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (title.isNotEmpty)
                  Text(title, style: style.small.copyWith(fontWeight: FontWeight.w600)),
                if (text.isNotEmpty) Text(text, style: style.small),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _UiSlider extends StatelessWidget {
  const _UiSlider({required this.node, required this.rt});
  final UiNode node;
  final UiBlockRuntime rt;

  @override
  Widget build(BuildContext context) {
    final style = rt.style;
    final min = (node.number('min') ?? 0).toDouble();
    var max = (node.number('max') ?? 100).toDouble();
    if (max <= min) max = min + 1;
    final step = node.number('step')?.toDouble();
    final steps = step != null && step > 0 ? (max - min) / step : double.nan;
    final divisions = steps.isFinite ? steps.round().clamp(1, 1000) : null;
    final current = (node.number('value') ?? min).toDouble().clamp(min, max);
    final unit = node.text('unit') ?? '';
    final bind = node.bind;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(child: Text(node.text('label') ?? '', style: style.small)),
            Text(
              '${uiFormatNumber(current)}${unit.isEmpty ? '' : ' $unit'}',
              style: style.small.copyWith(fontWeight: FontWeight.w600),
            ),
          ],
        ),
        MoeSlider(
          value: current,
          min: min,
          max: max,
          divisions: divisions,
          onChanged: bind == null
              ? null
              : (v) {
                  final snapped = divisions != null ? ((v - min) / step!).round() * step + min : v;
                  // Drop float noise (0.1 * 3), then clamp last: snapping can
                  // land past max when the range is not a whole number of
                  // steps, and the stored value must stay where the thumb is.
                  final scaled = snapped * 1e10;
                  final clean = scaled.isFinite && scaled.abs() < 1e18 ? scaled.round() / 1e10 : snapped;
                  rt.setValues({bind: clean.clamp(min, max)});
                },
        ),
      ],
    );
  }
}

class _UiChoice extends StatelessWidget {
  const _UiChoice({required this.node, required this.rt});
  final UiNode node;
  final UiBlockRuntime rt;

  @override
  Widget build(BuildContext context) {
    final style = rt.style;
    final options = uiOptions(node.props['options']);
    final current = node.props['value'];
    final bind = node.bind;
    final label = node.text('label') ?? '';
    void pick(Object? value) {
      if (bind != null) rt.setValues({bind: value});
    }

    final selectedIndex = options.indexWhere((o) => uiValuesEqual(o.value, current));
    final control = UiChoices(
      labels: [for (final o in options) o.label],
      selected: {if (selectedIndex >= 0) selectedIndex},
      onTap: bind == null ? null : (i) => pick(options[i].value),
      style: style,
      segmented: node.component == 'segmented',
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (label.isNotEmpty) ...[
          Text(label, style: style.small),
          const SizedBox(height: 6),
        ],
        control,
      ],
    );
  }
}

class _UiInput extends StatefulWidget {
  const _UiInput({super.key, required this.node, required this.rt});
  final UiNode node;
  final UiBlockRuntime rt;

  @override
  State<_UiInput> createState() => _UiInputState();
}

class _UiInputState extends State<_UiInput> {
  late final TextEditingController _controller =
      TextEditingController(text: _text(widget.node.props['value']));

  static String _text(Object? value) => uiEditText(value);

  @override
  void didUpdateWidget(_UiInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Follow the state when something else changed it (a set button, saved
    // values loading late), but leave text that already means this value,
    // such as a number the user is still typing ("1.").
    final value = widget.node.props['value'];
    final typed = _controller.text;
    final same = widget.node.props['type'] == 'number'
        ? uiValuesEqual(num.tryParse(typed.trim()) ?? 0, value)
        : typed == uiStringify(value);
    if (!same) _controller.text = _text(value);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final style = widget.rt.style;
    final number = widget.node.props['type'] == 'number';
    final bind = widget.node.bind;
    final label = widget.node.text('label') ?? '';
    if (uiFieldIsSecret(type: widget.node.text('type'), words: [bind, label, widget.node.text('placeholder')])) {
      return UiCallout(
        title: label,
        text: '这是机密信息，不要填在这里：组件里的值会发给模型。需要 Key 时请让 AIcove酱给你一张 Key 输入卡片。',
        tone: 'warning',
        style: style,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if ((widget.node.text('label') ?? '').isNotEmpty) ...[
          Text(widget.node.text('label')!, style: style.small),
          const SizedBox(height: 6),
        ],
        TextField(
          controller: _controller,
          enabled: bind != null,
          keyboardType: number ? const TextInputType.numberWithOptions(decimal: true, signed: true) : null,
          style: style.small,
          decoration: uiInputDecoration(style, hint: widget.node.text('placeholder')),
          onChanged: (text) {
            if (bind == null) return;
            final parsed = num.tryParse(text.trim());
            widget.rt.setValues({bind: number ? (parsed != null && parsed.isFinite ? parsed : 0) : text});
          },
        ),
      ],
    );
  }
}

class _UiButton extends StatelessWidget {
  const _UiButton({required this.node, required this.rt});
  final UiNode node;
  final UiBlockRuntime rt;

  @override
  Widget build(BuildContext context) {
    final ask = node.text('ask');
    final copy = node.text('copy');
    final set = node.props['set'];
    if (ask != null && ask.isNotEmpty) {
      return _UiAskButton(text: ask, label: node.text('label'), rt: rt);
    }
    final label = node.text('label') ?? (copy != null ? '复制' : '确定');
    final VoidCallback? onTap = copy != null
        ? () => rt.copy(copy)
        : set is Map
            ? () => rt.setValues({for (final e in set.entries) '${e.key}': e.value})
            : null;
    return Align(
      alignment: Alignment.centerLeft,
      child: MoeChoiceChip(
        size: MoeChoiceChipSize.sm,
        label: label,
        icon: copy != null ? Icons.content_copy_rounded : null,
        selected: false,
        onTap: onTap,
      ),
    );
  }
}

/// A suggested follow-up: tapping puts it into the composer, never sends.
class _UiAskButton extends StatelessWidget {
  const _UiAskButton({required this.text, required this.label, required this.rt});
  final String text;
  final String? label;
  final UiBlockRuntime rt;

  @override
  Widget build(BuildContext context) {
    final style = rt.style;
    final ask = rt.ask;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: ask == null ? null : () => ask(text),
        child: Ink(
          padding: const EdgeInsets.fromLTRB(12, 9, 10, 9),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: style.accent.withValues(alpha: 0.35), width: 0.8),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (label != null && label!.isNotEmpty)
                      Text(label!, style: style.caption),
                    Text(text, style: style.small),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(Icons.edit_note_rounded, size: 18, color: ask == null ? style.muted : style.accent),
            ],
          ),
        ),
      ),
    );
  }
}
