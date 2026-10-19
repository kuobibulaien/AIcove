import 'package:flutter/material.dart';

import '../../../../features/ui_blocks/domain/ui_block.dart';
import '../../../../features/ui_blocks/domain/ui_expression.dart';
import '../buttons/moe_choice_chip.dart';
import '../form/moe_checkbox.dart';
import 'ui_block_options.dart';
import 'ui_block_primitives.dart' show UiBadge, UiCallout;
import 'ui_block_style.dart';

/// A catalog component (ADR0073 交互组件): props in, interaction inside.
///
/// [saved] is what the user changed last time; [onChanged] receives the new
/// changes (empty when back at the start). Both are null for a component
/// nested in a panel, which keeps plain local state.
class UiCatalogView extends StatelessWidget {
  const UiCatalogView({
    super.key,
    required this.node,
    required this.style,
    required this.saved,
    required this.onChanged,
    this.ask,
  });

  final UiNode node;
  final UiBlockStyle style;
  final Map<String, Object?>? saved;
  final ValueChanged<Map<String, Object?>>? onChanged;

  /// Puts text into the composer; null where nothing can receive it.
  final ValueChanged<String>? ask;

  @override
  Widget build(BuildContext context) {
    final title = node.text('title') ?? '';
    final Widget body = switch (node.component) {
      'checklist' => _Checklist(node: node, style: style, saved: saved, onChanged: onChanged),
      'steps' => _Steps(node: node, style: style, saved: saved, onChanged: onChanged),
      'decision-tree' => _DecisionTree(node: node, style: style, saved: saved, onChanged: onChanged, ask: ask),
      'quiz' => _Quiz(node: node, style: style, saved: saved, onChanged: onChanged),
      'form' => _Form(node: node, style: style, saved: saved, onChanged: onChanged, ask: ask),
      'stat-grid' => _StatGrid(node: node, style: style),
      'data-table' => _DataTable(node: node, style: style),
      _ => Text('（不支持的组件 ${node.component}）', style: style.caption),
    };
    if (title.isEmpty) return body;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(title, style: style.title),
        const SizedBox(height: 10),
        body,
      ],
    );
  }
}

Map<String, Object?>? _asMap(Object? value) =>
    value is Map ? {for (final e in value.entries) '${e.key}': e.value} : null;

/// A field of a list item; a plain string item is its own main text
/// ([primary]) and has no other fields.
String _itemText(Object? item, [String key = 'text', bool primary = true]) =>
    item is Map ? uiStringify(item[key]) : primary ? uiStringify(item) : '';

// ---- checklist ----

class _Checklist extends StatefulWidget {
  const _Checklist({required this.node, required this.style, required this.saved, required this.onChanged});
  final UiNode node;
  final UiBlockStyle style;
  final Map<String, Object?>? saved;
  final ValueChanged<Map<String, Object?>>? onChanged;

  @override
  State<_Checklist> createState() => _ChecklistState();
}

class _ChecklistState extends State<_Checklist> {
  Set<int>? _done;

  Set<int> get done {
    final saved = widget.saved?['done'];
    return _done ??
        {
          if (saved is List)
            for (final i in saved)
              if (i is num) i.toInt(),
        };
  }

  void _toggle(int index) {
    final next = {...done};
    if (!next.remove(index)) next.add(index);
    setState(() => _done = next);
    widget.onChanged?.call(next.isEmpty ? const {} : {'done': (next.toList()..sort())});
  }

  @override
  Widget build(BuildContext context) {
    final style = widget.style;
    final items = widget.node.list('items');
    final checked = done;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < items.length; i++)
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => _toggle(i),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  MoeCheckbox(
                    size: MoeCheckboxSize.sm,
                    value: checked.contains(i),
                    onChanged: (_) => _toggle(i),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _itemText(items[i]),
                          style: style.body.copyWith(
                            color: checked.contains(i) ? style.muted : style.fg,
                            decoration: checked.contains(i) ? TextDecoration.lineThrough : null,
                            decorationColor: style.muted,
                          ),
                        ),
                        if (_itemText(items[i], 'note', false).isNotEmpty)
                          Text(_itemText(items[i], 'note', false), style: style.caption),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        const SizedBox(height: 4),
        Text('已完成 ${checked.where((i) => i < items.length).length} / ${items.length}', style: style.caption),
      ],
    );
  }
}

// ---- steps ----

class _Steps extends StatefulWidget {
  const _Steps({required this.node, required this.style, required this.saved, required this.onChanged});
  final UiNode node;
  final UiBlockStyle style;
  final Map<String, Object?>? saved;
  final ValueChanged<Map<String, Object?>>? onChanged;

  @override
  State<_Steps> createState() => _StepsState();
}

class _StepsState extends State<_Steps> {
  int? _step;

  void _go(int step) {
    setState(() => _step = step);
    widget.onChanged?.call(step == 0 ? const {} : {'step': step});
  }

  @override
  Widget build(BuildContext context) {
    final style = widget.style;
    final items = widget.node.list('items');
    if (items.isEmpty) return const SizedBox.shrink();
    final saved = widget.saved?['step'];
    final current = (_step ?? (saved is num ? saved.toInt() : 0)).clamp(0, items.length - 1);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < items.length; i++)
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => _go(i),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _StepDot(index: i, state: i < current ? 1 : i == current ? 0 : -1, style: style),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _itemText(items[i], 'title'),
                          style: style.body.copyWith(
                            fontWeight: i == current ? FontWeight.w600 : null,
                            color: i > current ? style.muted : style.fg,
                          ),
                        ),
                        if (i == current && _itemText(items[i], 'text', false).isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(_itemText(items[i], 'text', false), style: style.small.copyWith(color: style.muted)),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        const SizedBox(height: 8),
        Row(
          children: [
            Text('第 ${current + 1} / ${items.length} 步', style: style.caption),
            const Spacer(),
            if (current > 0)
              MoeChoiceChip(size: MoeChoiceChipSize.sm, label: '上一步', selected: false, onTap: () => _go(current - 1)),
            if (current < items.length - 1) ...[
              const SizedBox(width: 6),
              MoeChoiceChip(size: MoeChoiceChipSize.sm, label: '下一步', selected: true, onTap: () => _go(current + 1)),
            ],
          ],
        ),
      ],
    );
  }
}

class _StepDot extends StatelessWidget {
  const _StepDot({required this.index, required this.state, required this.style});
  final int index;

  /// 1 done, 0 current, -1 ahead.
  final int state;
  final UiBlockStyle style;

  @override
  Widget build(BuildContext context) {
    final color = state >= 0 ? style.accent : style.line;
    return Container(
      width: 22,
      height: 22,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: state == 1 ? color : Colors.transparent,
        border: Border.all(color: color, width: 1.4),
      ),
      child: state == 1
          ? const Icon(Icons.check_rounded, size: 14, color: Colors.white)
          : Text('${index + 1}', style: style.caption.copyWith(color: state == 0 ? style.accent : style.muted, fontWeight: FontWeight.w600)),
    );
  }
}

// ---- decision tree ----

class _DecisionTree extends StatefulWidget {
  const _DecisionTree({required this.node, required this.style, required this.saved, required this.onChanged, required this.ask});
  final UiNode node;
  final UiBlockStyle style;
  final Map<String, Object?>? saved;
  final ValueChanged<Map<String, Object?>>? onChanged;
  final ValueChanged<String>? ask;

  @override
  State<_DecisionTree> createState() => _DecisionTreeState();
}

class _DecisionTreeState extends State<_DecisionTree> {
  List<String>? _path;

  /// The question whose 「其他」 field is open, if any.
  String? _otherAt;
  final TextEditingController _other = TextEditingController();
  bool _sent = false;

  @override
  void dispose() {
    _other.dispose();
    super.dispose();
  }

  Map<String, Map<String, Object?>> get _nodes => {
        for (final raw in widget.node.list('nodes'))
          if (_asMap(raw) case final node? when uiStringify(node['id']).isNotEmpty) uiStringify(node['id']): node,
      };

  String? get _start {
    final start = widget.node.text('start');
    final nodes = _nodes;
    if (start != null && nodes.containsKey(start)) return start;
    return nodes.keys.firstOrNull;
  }

  List<String> get path {
    if (_path != null) return _path!;
    final nodes = _nodes;
    final saved = widget.saved?['path'];
    final restored = [
      if (saved is List)
        for (final id in saved)
          if (nodes.containsKey(uiStringify(id))) uiStringify(id),
    ];
    final start = _start;
    if (start == null) return const [];
    return restored.isNotEmpty && restored.first == start ? restored : [start];
  }

  void _set(List<String> next) {
    setState(() {
      _path = next;
      _otherAt = null;
      _sent = false;
    });
    widget.onChanged?.call(next.length <= 1 ? const {} : {'path': next});
  }

  /// Puts the answers so far and the user's own words into the composer.
  void _sendOther(Map<String, Map<String, Object?>> nodes, List<String> trail) {
    final text = _other.text.trim();
    final ask = widget.ask;
    if (text.isEmpty || ask == null) return;
    final title = widget.node.text('title') ?? '';
    ask([
      if (title.isNotEmpty) '【$title】',
      for (var i = 0; i < trail.length - 1; i++)
        '${uiStringify(nodes[trail[i]]!['text'])} → ${_chosenLabel(nodes[trail[i]]!, trail[i + 1])}',
      '${uiStringify(nodes[trail.last]!['text'])} → $kUiOtherLabel：$text',
    ].join('\n'));
    setState(() => _sent = true);
  }

  @override
  Widget build(BuildContext context) {
    final style = widget.style;
    final nodes = _nodes;
    final trail = path;
    if (trail.isEmpty) return Text('（决策树没有节点）', style: style.caption);
    final current = nodes[trail.last]!;
    final options = [for (final o in (current['options'] as List?) ?? const []) ?_asMap(o)];
    final detail = uiStringify(current['detail']);
    final isConclusion = options.isEmpty;
    final offersOther = widget.ask != null && uiOffersOther(current['other'], widget.node.props['other']);
    final otherOpen = offersOther && _otherAt == trail.last;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < trail.length - 1; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              '${uiStringify(nodes[trail[i]]!['text'])} → ${_chosenLabel(nodes[trail[i]]!, trail[i + 1])}',
              style: style.caption,
            ),
          ),
        if (isConclusion)
          UiCallout(title: '结论', text: uiStringify(current['text']), tone: 'positive', style: style)
        else
          Text(uiStringify(current['text']), style: style.body.copyWith(fontWeight: FontWeight.w600)),
        if (detail.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(detail, style: style.small.copyWith(color: style.muted)),
        ],
        if (!isConclusion) ...[
          const SizedBox(height: 10),
          UiChoices(
            labels: [
              for (final option in options) uiStringify(option['label']),
              if (offersOther) kUiOtherLabel,
            ],
            selected: {if (otherOpen) options.length},
            onTap: (i) {
              if (i == options.length) {
                setState(() {
                  _otherAt = otherOpen ? null : trail.last;
                  _sent = false;
                });
                return;
              }
              final next = uiStringify(options[i]['next']);
              if (nodes.containsKey(next)) _set([...trail, next]);
            },
            style: style,
          ),
          if (otherOpen) ...[
            const SizedBox(height: 8),
            TextField(
              controller: _other,
              autofocus: true,
              minLines: 1,
              maxLines: 4,
              style: style.small,
              decoration: uiInputDecoration(style, hint: '说说你的情况或想法'),
              onChanged: (_) => setState(() => _sent = false),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(_sent ? '已填进输入框，确认后发送' : '会连同前面的选择一起填进输入框', style: style.caption),
                ),
                MoeChoiceChip(
                  size: MoeChoiceChipSize.sm,
                  label: '填进输入框',
                  icon: Icons.edit_note_rounded,
                  selected: true,
                  onTap: _other.text.trim().isEmpty ? null : () => _sendOther(nodes, trail),
                ),
              ],
            ),
          ],
        ],
        if (trail.length > 1) ...[
          const SizedBox(height: 10),
          Row(
            children: [
              MoeChoiceChip(size: MoeChoiceChipSize.sm, label: '返回', selected: false, onTap: () => _set(trail.sublist(0, trail.length - 1))),
              const SizedBox(width: 6),
              MoeChoiceChip(size: MoeChoiceChipSize.sm, label: '重来', selected: false, onTap: () => _set([trail.first])),
            ],
          ),
        ],
      ],
    );
  }

  String _chosenLabel(Map<String, Object?> node, String next) {
    for (final raw in (node['options'] as List?) ?? const []) {
      final option = _asMap(raw);
      if (option != null && uiStringify(option['next']) == next) return uiStringify(option['label']);
    }
    return next;
  }
}

// ---- quiz ----

class _Quiz extends StatefulWidget {
  const _Quiz({required this.node, required this.style, required this.saved, required this.onChanged});
  final UiNode node;
  final UiBlockStyle style;
  final Map<String, Object?>? saved;
  final ValueChanged<Map<String, Object?>>? onChanged;

  @override
  State<_Quiz> createState() => _QuizState();
}

class _QuizState extends State<_Quiz> {
  Map<int, int>? _answers;

  Map<int, int> get answers {
    if (_answers != null) return _answers!;
    final saved = _asMap(widget.saved?['answers']);
    return {
      if (saved != null)
        for (final e in saved.entries)
          if (int.tryParse(e.key) case final q? when e.value is num) q: (e.value as num).toInt(),
    };
  }

  void _answer(int question, int option) {
    final next = {...answers, question: option};
    setState(() => _answers = next);
    widget.onChanged?.call({
      'answers': {for (final e in next.entries) '${e.key}': e.value},
    });
  }

  @override
  Widget build(BuildContext context) {
    final style = widget.style;
    final questions = [for (final q in widget.node.list('questions')) ?_asMap(q)];
    final picked = answers;
    var scored = 0;
    var correct = 0;
    final children = <Widget>[];
    for (var q = 0; q < questions.length; q++) {
      final question = questions[q];
      final options = (question['options'] as List?) ?? const [];
      final answer = question['answer'] is num ? (question['answer'] as num).toInt() : null;
      final choice = picked[q];
      if (answer != null && choice != null) {
        scored += 1;
        if (choice == answer) correct += 1;
      }
      children.add(Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('${questions.length > 1 ? '${q + 1}. ' : ''}${uiStringify(question['question'])}',
              style: style.body.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          for (var o = 0; o < options.length; o++)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: UiOptionTile(
                text: _itemText(options[o]),
                state: choice == null
                    ? UiOptionState.neutral
                    : answer == null
                        ? (o == choice ? UiOptionState.selected : UiOptionState.neutral)
                        : o == answer
                            ? UiOptionState.right
                            : (o == choice ? UiOptionState.wrong : UiOptionState.neutral),
                onTap: choice == null ? () => _answer(q, o) : null,
                style: style,
              ),
            ),
          if (choice != null && uiStringify(question['explanation']).isNotEmpty)
            Text(uiStringify(question['explanation']), style: style.small.copyWith(color: style.muted)),
        ],
      ));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) const SizedBox(height: 14),
          children[i],
        ],
        if (scored > 0) ...[
          const SizedBox(height: 10),
          Row(
            children: [
              Text('答对 $correct / $scored', style: style.caption),
              const Spacer(),
              MoeChoiceChip(
                size: MoeChoiceChipSize.sm,
                label: '重做',
                selected: false,
                onTap: () {
                  setState(() => _answers = {});
                  widget.onChanged?.call(const {});
                },
              ),
            ],
          ),
        ],
      ],
    );
  }
}

// ---- form ----

/// Labels that ask for a secret; such fields are never shown as inputs,
/// since what the form collects is sent as a chat message.
final _secretField = RegExp(r'api[ _-]?key|密钥|密码|口令|password|passwd|secret', caseSensitive: false);

class _Form extends StatefulWidget {
  const _Form({required this.node, required this.style, required this.saved, required this.onChanged, required this.ask});
  final UiNode node;
  final UiBlockStyle style;
  final Map<String, Object?>? saved;
  final ValueChanged<Map<String, Object?>>? onChanged;
  final ValueChanged<String>? ask;

  @override
  State<_Form> createState() => _FormState();
}

class _FormState extends State<_Form> {
  late final Map<String, Object?> _values = {...?_asMap(widget.saved?['values'])};

  /// Fields where 「其他」 is picked, with what the user wrote there.
  late final Map<String, String> _others = {
    for (final e in (_asMap(widget.saved?['other']) ?? const {}).entries) e.key: uiStringify(e.value),
  };
  final Map<String, TextEditingController> _controllers = {};
  final Set<String> _missing = {};
  bool _sent = false;

  List<Map<String, Object?>> get _fields => [
        for (final raw in widget.node.list('fields').take(8))
          if (_asMap(raw) case final field? when uiStringify(field['key']).isNotEmpty) field,
      ];

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _set(String key, Object? value) => _update(() => _values[key] = value, key);

  /// Picks or drops 「其他」 for [key]; [text] null drops it.
  void _setOther(String key, String? text) => _update(() {
        if (text == null) {
          _others.remove(key);
        } else {
          _others[key] = text;
        }
      }, key);

  void _update(VoidCallback change, String key) {
    setState(() {
      change();
      _missing.remove(key);
      _sent = false;
    });
    final kept = {
      for (final e in _values.entries)
        if (!_isEmpty(e.value)) e.key: e.value,
    };
    widget.onChanged?.call({
      if (kept.isNotEmpty) 'values': kept,
      if (_others.isNotEmpty) 'other': {..._others},
    });
  }

  /// The field's answer: picked or typed values plus the 「其他」 text.
  Object? _answer(String key) {
    final other = _others[key]?.trim() ?? '';
    final value = _values[key];
    if (other.isEmpty) return value;
    if (value is List) return [...value, other];
    return other;
  }

  static bool _isEmpty(Object? value) =>
      value == null || (value is String && value.trim().isEmpty) || (value is List && value.isEmpty);

  void _submit() {
    final ask = widget.ask;
    if (ask == null) return;
    final missing = {
      for (final field in _fields)
        if (uiTruthy(field['required']) && _isEmpty(_answer(uiStringify(field['key'])))) uiStringify(field['key']),
    };
    if (missing.isNotEmpty) {
      setState(() => _missing
        ..clear()
        ..addAll(missing));
      return;
    }
    final title = widget.node.text('title') ?? '';
    final lines = [
      if (title.isNotEmpty) '【$title】',
      for (final field in _fields)
        if (!_isEmpty(_answer(uiStringify(field['key']))) && !_isSecret(field))
          '${uiStringify(field['label'] ?? field['key'])}：${_display(_answer(uiStringify(field['key'])))}',
    ];
    ask(lines.join('\n'));
    setState(() => _sent = true);
  }

  static String _display(Object? value) => value is List ? value.map(uiStringify).join('、') : uiStringify(value);

  static bool _isSecret(Map<String, Object?> field) =>
      _secretField.hasMatch('${field['key']} ${field['label']}');

  @override
  Widget build(BuildContext context) {
    final style = widget.style;
    final fields = _fields;
    final children = <Widget>[];
    for (final field in fields) {
      final key = uiStringify(field['key']);
      final label = uiStringify(field['label'] ?? key);
      final required = uiTruthy(field['required']);
      final type = uiStringify(field['type']);
      Widget input;
      if (_isSecret(field)) {
        input = UiCallout(
          title: '',
          text: '「$label」是机密信息，不要发在聊天里。需要 Key 时请让助手给你一张 Key 输入卡片。',
          tone: 'warning',
          style: style,
        );
      } else if (type == 'select' || type == 'multiselect') {
        final options = uiOptions(field['options']);
        final current = _values[key];
        final multiple = type == 'multiselect';
        final offersOther = uiOffersOther(field['other'], widget.node.props['other']);
        final otherPicked = offersOther && _others.containsKey(key);
        final picked = <int>{
          for (var i = 0; i < options.length; i++)
            if (multiple
                ? (current is List && current.any((v) => uiValuesEqual(v, options[i].value)))
                : !otherPicked && uiValuesEqual(current, options[i].value))
              i,
          if (otherPicked) options.length,
        };
        final choices = UiChoices(
          labels: [for (final o in options) o.label, if (offersOther) kUiOtherLabel],
          selected: picked,
          style: style,
          onTap: (i) {
            if (i == options.length) {
              if (_others.containsKey(key)) {
                _setOther(key, null);
              } else {
                if (!multiple) _values.remove(key);
                _setOther(key, '');
              }
              return;
            }
            if (!multiple) {
              _others.remove(key);
              _set(key, options[i].value);
              return;
            }
            // Read the latest value: taps can land before the next build.
            final now = _values[key];
            final next = <int>{
              for (var j = 0; j < options.length; j++)
                if (now is List && now.any((v) => uiValuesEqual(v, options[j].value))) j,
            };
            if (!next.remove(i)) next.add(i);
            _set(key, [for (final j in next.toList()..sort()) options[j].value]);
          },
        );
        input = !otherPicked
            ? choices
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  choices,
                  const SizedBox(height: 8),
                  TextField(
                    controller: _controllers.putIfAbsent('$key\u0000other', () => TextEditingController(text: _others[key])),
                    minLines: 1,
                    maxLines: 4,
                    style: style.small,
                    decoration: uiInputDecoration(style, hint: '写下你的想法', error: _missing.contains(key)),
                    onChanged: (text) => _setOther(key, text),
                  ),
                ],
              );
      } else {
        final controller = _controllers.putIfAbsent(
          key,
          () => TextEditingController(text: _isEmpty(_values[key]) ? '' : uiStringify(_values[key])),
        );
        final number = type == 'number';
        input = TextField(
          controller: controller,
          minLines: type == 'textarea' ? 3 : 1,
          maxLines: type == 'textarea' ? 8 : 1,
          keyboardType: number ? const TextInputType.numberWithOptions(decimal: true, signed: true) : null,
          style: style.small,
          decoration: uiInputDecoration(style, hint: uiStringify(field['placeholder']), error: _missing.contains(key)),
          onChanged: (text) => _set(key, number ? (num.tryParse(text.trim()) ?? text) : text),
        );
      }
      children.add(Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text.rich(TextSpan(children: [
            TextSpan(text: label, style: style.small),
            if (required) TextSpan(text: ' *', style: style.small.copyWith(color: style.negative)),
          ])),
          const SizedBox(height: 6),
          input,
          if (_missing.contains(key))
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('这一项要填', style: style.caption.copyWith(color: style.negative)),
            ),
        ],
      ));
    }
    final submit = widget.node.text('submit');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) const SizedBox(height: 12),
          children[i],
        ],
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: Text(
                _sent ? '已填进输入框，确认后发送' : '提交后会填进输入框，由你发送',
                style: style.caption,
              ),
            ),
            MoeChoiceChip(
              size: MoeChoiceChipSize.sm,
              label: submit == null || submit.isEmpty ? '填好了' : submit,
              icon: Icons.edit_note_rounded,
              selected: true,
              onTap: widget.ask == null ? null : _submit,
            ),
          ],
        ),
      ],
    );
  }
}

// ---- stat grid ----

class _StatGrid extends StatelessWidget {
  const _StatGrid({required this.node, required this.style});
  final UiNode node;
  final UiBlockStyle style;

  @override
  Widget build(BuildContext context) {
    final items = [for (final item in node.list('items')) ?_asMap(item)];
    return LayoutBuilder(builder: (context, constraints) {
      final columns = ((constraints.maxWidth + 8) / 148).floor().clamp(1, 4);
      final rows = <Widget>[];
      for (var start = 0; start < items.length; start += columns) {
        // Tiles of a line share its tallest height, so the grid stays even.
        rows.add(IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < columns; i++) ...[
                if (i > 0) const SizedBox(width: 8),
                Expanded(
                  child: start + i < items.length
                      ? Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(color: style.faint, borderRadius: BorderRadius.circular(10)),
                          child: _StatTile(item: items[start + i], style: style),
                        )
                      : const SizedBox.shrink(),
                ),
              ],
            ],
          ),
        ));
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0) const SizedBox(height: 8),
            rows[i],
          ],
        ],
      );
    });
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({required this.item, required this.style});
  final Map<String, Object?> item;
  final UiBlockStyle style;

  @override
  Widget build(BuildContext context) {
    final trend = item['trend'];
    final tone = item['tone'] ??
        switch (trend) {
          'up' => 'positive',
          'down' => 'negative',
          _ => null,
        };
    final delta = uiStringify(item['delta']);
    final unit = uiStringify(item['unit']);
    final note = uiStringify(item['note']);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(uiStringify(item['label']), style: style.caption, maxLines: 1, overflow: TextOverflow.ellipsis),
        const SizedBox(height: 2),
        Text.rich(TextSpan(children: [
          TextSpan(
            text: uiStringify(item['value']),
            style: TextStyle(fontSize: style.fontSize + 5, fontWeight: FontWeight.w600, color: style.fg, height: 1.2),
          ),
          if (unit.isNotEmpty) TextSpan(text: ' $unit', style: style.caption),
        ])),
        if (delta.isNotEmpty) ...[
          const SizedBox(height: 2),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (trend == 'up' || trend == 'down')
                Icon(trend == 'up' ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded,
                    size: 13, color: style.tone(tone)),
              Text(delta, style: style.caption.copyWith(color: style.tone(tone))),
            ],
          ),
        ],
        if (note.isNotEmpty) Text(note, style: style.caption),
      ],
    );
  }
}

// ---- data table ----

class _DataTable extends StatefulWidget {
  const _DataTable({required this.node, required this.style});
  final UiNode node;
  final UiBlockStyle style;

  @override
  State<_DataTable> createState() => _DataTableState();
}

class _DataTableState extends State<_DataTable> {
  String? _sortKey;
  bool _ascending = true;
  String _query = '';
  int _page = 0;

  @override
  Widget build(BuildContext context) {
    final style = widget.style;
    final columns = [for (final c in widget.node.list('columns')) ?_asMap(c)];
    var rows = [for (final r in widget.node.list('rows')) ?_asMap(r)];
    if (columns.isEmpty && rows.isNotEmpty) {
      columns.addAll([for (final key in rows.first.keys) {'key': key, 'label': key}]);
    }
    final total = rows.length;
    if (_query.isNotEmpty) {
      final q = _query.toLowerCase();
      rows = [
        for (final row in rows)
          if (row.values.any((v) => uiStringify(v).toLowerCase().contains(q))) row,
      ];
    }
    final sortKey = _sortKey;
    if (sortKey != null) {
      rows = [...rows]..sort((a, b) {
          final x = a[sortKey];
          final y = b[sortKey];
          final order = x is num && y is num ? x.compareTo(y) : uiStringify(x).compareTo(uiStringify(y));
          return _ascending ? order : -order;
        });
    }
    final pageSize = (widget.node.number('pageSize') ?? 10).toInt().clamp(5, 50);
    final pages = (rows.length / pageSize).ceil().clamp(1, 1 << 20);
    final page = _page.clamp(0, pages - 1);
    final visible = rows.skip(page * pageSize).take(pageSize).toList();

    final headerStyle = style.caption.copyWith(fontWeight: FontWeight.w600, color: style.fg);
    final table = Table(
      defaultColumnWidth: const IntrinsicColumnWidth(),
      defaultVerticalAlignment: TableCellVerticalAlignment.middle,
      children: [
        TableRow(
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: style.line, width: 0.8))),
          children: [
            for (final column in columns)
              InkWell(
                onTap: () => setState(() {
                  final key = uiStringify(column['key']);
                  if (_sortKey == key) {
                    _ascending = !_ascending;
                  } else {
                    _sortKey = key;
                    _ascending = true;
                  }
                }),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(4, 6, 14, 6),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(uiStringify(column['label'] ?? column['key']), style: headerStyle),
                      if (_sortKey == uiStringify(column['key']))
                        Icon(_ascending ? Icons.arrow_drop_up_rounded : Icons.arrow_drop_down_rounded,
                            size: 18, color: style.muted),
                    ],
                  ),
                ),
              ),
          ],
        ),
        for (final row in visible)
          TableRow(
            decoration: BoxDecoration(border: Border(bottom: BorderSide(color: style.faint, width: 0.8))),
            children: [
              for (final column in columns)
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 7, 14, 7),
                  child: Text(
                    uiStringify(row[uiStringify(column['key'])]),
                    style: style.small,
                    textAlign: column['type'] == 'number' ? TextAlign.right : TextAlign.left,
                  ),
                ),
            ],
          ),
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (total > pageSize)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: TextField(
              style: style.small,
              decoration: InputDecoration(
                isDense: true,
                prefixIcon: Icon(Icons.search_rounded, size: 18, color: style.muted),
                hintText: '搜索',
                hintStyle: style.small.copyWith(color: style.muted),
                filled: true,
                fillColor: style.faint,
                contentPadding: const EdgeInsets.symmetric(vertical: 8),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
              ),
              onChanged: (text) => setState(() {
                _query = text.trim();
                _page = 0;
              }),
            ),
          ),
        SingleChildScrollView(scrollDirection: Axis.horizontal, child: table),
        if (pages > 1)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(
              children: [
                UiBadge(text: '${rows.length} 行', color: style.muted, style: style),
                const Spacer(),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  iconSize: 18,
                  onPressed: page > 0 ? () => setState(() => _page = page - 1) : null,
                  icon: const Icon(Icons.chevron_left_rounded),
                ),
                Text('${page + 1} / $pages', style: style.caption),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  iconSize: 18,
                  onPressed: page < pages - 1 ? () => setState(() => _page = page + 1) : null,
                  icon: const Icon(Icons.chevron_right_rounded),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
