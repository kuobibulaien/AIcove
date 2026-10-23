/// Line syntax for catalog blocks (ADR0091 交互组件): one item per line, no
/// brackets to balance, so a weak model cannot leave the block unclosed.
/// The result is the same map the JSON form gives, so everything after
/// parsing is shared. Panels and action components stay JSON.
///
///     form rr-config            component, optional id
///     # 要我改哪些               title
///     @submit: 就这样改          any top-level prop
///     接口地址 | 文字 | 例：https://api.deepseek.com | 必填
///     > 补充说明                 note of the line above
///
/// Cells are split on `|`; a cell like `tone=positive` sets that prop of the
/// line. Option lists are split on ` / `. Leading list markers (`- `,
/// `1. `) are ignored, so a model writing Markdown habits still parses.
Map<String, Object?> readUiLines(String text) {
  final lines = [
    for (final raw in text.split('\n').take(kUiLinesMax))
      if (raw.trim().isNotEmpty) raw.trim(),
  ];
  if (lines.isEmpty) throw const FormatException('empty block');
  final head = lines.first.split(RegExp(r'\s+'));
  final component = head.first.replaceAll(RegExp(r'[:：]$'), '').toLowerCase();
  if (!RegExp(r'^[a-z][a-z-]*$').hasMatch(component)) {
    throw FormatException('expected a component name', head.first);
  }
  final result = <String, Object?>{
    'component': component,
    if (head.length > 1) 'id': head[1],
  };
  final body = <String>[];
  for (final line in lines.skip(1)) {
    if (_titleLine.firstMatch(line) case final match?) {
      result['title'] = match.group(1)!.trim();
    } else if (_propLine.firstMatch(line) case final match?) {
      result[match.group(1)!] = _scalar(match.group(2)!.trim());
    } else {
      body.add(line);
    }
  }
  final read = _readers[component];
  if (read != null) result.addAll(read(body));
  return result;
}

/// Lines read from one block; far more than any block shows.
const int kUiLinesMax = 500;

final _titleLine = RegExp(r'^#{1,3}\s*(.+)$');
final _propLine = RegExp(r'^@([A-Za-z][A-Za-z0-9_]*)\s*[:：]\s*(.*)$');
final _attrCell = RegExp(r'^([A-Za-z][A-Za-z0-9_]*)=(\S*)$');
final _listMarker = RegExp(r'^(?:[-*+•]\s+|\d+[.、)）]\s*)');
final _arrow = RegExp(r'\s*(?:->|→|=>)\s*');
final _correctMark = RegExp(r'\s*(?:✓|✔|√|[(（](?:对|正确)[)）])$');

final Map<String, Map<String, Object?> Function(List<String>)> _readers = {
  'checklist': _checklist,
  'steps': _steps,
  'form': _form,
  'quiz': _quiz,
  'decision-tree': _decisionTree,
  'stat-grid': _statGrid,
  'data-table': _dataTable,
};

Object? _scalar(String value) {
  if (value == 'true') return true;
  if (value == 'false') return false;
  return num.tryParse(value) ?? value;
}

/// A body line split into cells, with `name=value` cells taken out.
class _Line {
  _Line(String raw) {
    final text = raw.replaceFirst(_listMarker, '');
    for (final part in text.split('|')) {
      final cell = part.trim();
      final attr = _attrCell.firstMatch(cell);
      if (attr != null) {
        attrs[attr.group(1)!] = _scalar(attr.group(2)!);
      } else {
        cells.add(cell);
      }
    }
    while (cells.length > 1 && cells.last.isEmpty) {
      cells.removeLast();
    }
  }

  final cells = <String>[];
  final attrs = <String, Object?>{};

  String cell(int i) => i < cells.length ? cells[i] : '';
}

bool _isNote(String line) => line.startsWith('>');

String _noteText(String line) => line.substring(1).trim();

/// Appends [text] to [key] of [item], joining several note lines.
void _appendNote(Map<String, Object?> item, String key, String text) {
  final before = item[key];
  item[key] = before is String && before.isNotEmpty ? '$before\n$text' : text;
}

List<String> _options(String cell) {
  var parts = cell.split(RegExp(r'\s+/\s+|／'));
  if (parts.length == 1 && cell.contains('/') && !cell.contains('://')) {
    parts = cell.split('/');
  }
  return [
    for (final part in parts)
      if (part.trim().isNotEmpty) part.trim(),
  ];
}

Map<String, Object?> _checklist(List<String> body) {
  final items = <Map<String, Object?>>[];
  for (final raw in body) {
    if (_isNote(raw)) {
      if (items.isNotEmpty) _appendNote(items.last, 'note', _noteText(raw));
      continue;
    }
    final line = _Line(raw);
    items.add({
      'text': line.cell(0),
      if (line.cell(1).isNotEmpty) 'note': line.cells.skip(1).join(' | '),
      ...line.attrs,
    });
  }
  return {'items': items};
}

Map<String, Object?> _steps(List<String> body) {
  final items = <Map<String, Object?>>[];
  for (final raw in body) {
    if (_isNote(raw)) {
      if (items.isNotEmpty) _appendNote(items.last, 'text', _noteText(raw));
      continue;
    }
    final line = _Line(raw);
    items.add({
      'title': line.cell(0),
      if (line.cell(1).isNotEmpty) 'text': line.cells.skip(1).join(' | '),
      ...line.attrs,
    });
  }
  return {'items': items};
}

const _fieldTypes = {
  '文字': 'text', '文本': 'text', '单行': 'text', 'text': 'text', //
  '长文字': 'textarea', '长文本': 'textarea', '多行': 'textarea', 'textarea': 'textarea',
  '数字': 'number', 'number': 'number',
  '单选': 'select', 'select': 'select',
  '多选': 'multiselect', 'multiselect': 'multiselect',
};

const _requiredFlags = {'必填', 'required'};
const _noOtherFlags = {'无其他', '不要其他'};

Map<String, Object?> _form(List<String> body) {
  final fields = <Map<String, Object?>>[];
  for (final raw in body) {
    if (_isNote(raw)) {
      if (fields.isNotEmpty) _appendNote(fields.last, 'placeholder', _noteText(raw));
      continue;
    }
    final line = _Line(raw);
    final label = line.cell(0);
    if (label.isEmpty) continue;
    final rest = line.cells.skip(1).toList();
    final type = rest.isEmpty ? null : _fieldTypes[rest.first.toLowerCase()];
    if (type != null) rest.removeAt(0);
    final field = <String, Object?>{'key': label, 'label': label, 'type': type ?? 'text'};
    for (final cell in rest) {
      if (_requiredFlags.contains(cell)) {
        field['required'] = true;
      } else if (_noOtherFlags.contains(cell)) {
        field['other'] = false;
      } else if (cell.isNotEmpty && !field.containsKey('options') && !field.containsKey('placeholder')) {
        if (type == 'select' || type == 'multiselect') {
          field['options'] = _options(cell);
        } else {
          field['placeholder'] = cell;
        }
      }
    }
    field.addAll(line.attrs);
    fields.add(field);
  }
  return {'fields': fields};
}

final _questionStart = RegExp(r'^(?:\?|？|问[:：]|Q[:：]|\d+[.、)）]\s*.*[?？]$)');

Map<String, Object?> _quiz(List<String> body) {
  final questions = <Map<String, Object?>>[];
  for (final raw in body) {
    if (_isNote(raw)) {
      if (questions.isNotEmpty) _appendNote(questions.last, 'explanation', _noteText(raw));
      continue;
    }
    if (_questionStart.hasMatch(raw) || questions.isEmpty) {
      final text = raw.replaceFirst(RegExp(r'^(?:\?|？|问[:：]|Q[:：])\s*'), '').replaceFirst(_listMarker, '');
      questions.add({'question': text, 'options': <String>[]});
      continue;
    }
    final question = questions.last;
    final options = question['options']! as List<String>;
    var option = _Line(raw).cell(0);
    if (_correctMark.hasMatch(option)) {
      option = option.replaceFirst(_correctMark, '').trim();
      question['answer'] = options.length;
    }
    options.add(option);
  }
  return {'questions': questions};
}

final _nodeLine = RegExp(r'^\[([^\]]+)\]\s*(.*)$');

Map<String, Object?> _decisionTree(List<String> body) {
  final nodes = <Map<String, Object?>>[];
  for (final raw in body) {
    if (_isNote(raw)) {
      if (nodes.isNotEmpty) _appendNote(nodes.last, 'detail', _noteText(raw));
      continue;
    }
    final node = _nodeLine.firstMatch(raw);
    if (node != null || nodes.isEmpty) {
      final line = _Line(node?.group(2) ?? raw);
      nodes.add({
        'id': node?.group(1)!.trim() ?? 'n${nodes.length + 1}',
        'text': line.cells.join(' | '),
        ...line.attrs,
      });
      continue;
    }
    final line = _Line(raw);
    final parts = line.cells.join(' | ').split(_arrow);
    if (parts.length < 2) continue;
    final options = (nodes.last['options'] as List<Object?>?) ?? <Object?>[];
    nodes.last['options'] = options
      ..add({'label': parts.first.trim(), 'next': parts.last.replaceAll(RegExp(r'[\[\]]'), '').trim()});
  }
  return {'nodes': nodes};
}

Map<String, Object?> _statGrid(List<String> body) {
  const columns = ['label', 'value', 'unit', 'delta', 'note'];
  final items = <Map<String, Object?>>[];
  for (final raw in body) {
    if (_isNote(raw)) {
      if (items.isNotEmpty) _appendNote(items.last, 'note', _noteText(raw));
      continue;
    }
    final line = _Line(raw);
    items.add({
      for (var i = 0; i < columns.length; i++)
        if (line.cell(i).isNotEmpty) columns[i]: line.cell(i),
      ...line.attrs,
    });
  }
  return {'items': items};
}

Map<String, Object?> _dataTable(List<String> body) {
  // A Markdown table habit: drop `|---|---|` rules and outer pipes.
  final lines = [
    for (final raw in body)
      if (!RegExp(r'^\|?[\s:|-]+$').hasMatch(raw)) raw.replaceAll(RegExp(r'^\||\|$'), ''),
  ];
  if (lines.isEmpty) return {'columns': const [], 'rows': const []};
  final header = _Line(lines.first).cells;
  final rows = [for (final raw in lines.skip(1)) _Line(raw).cells];
  final columns = <Map<String, Object?>>[];
  for (var i = 0; i < header.length; i++) {
    final values = [
      for (final row in rows)
        if (i < row.length && row[i].isNotEmpty) row[i],
    ];
    final numeric = values.isNotEmpty && values.every((v) => num.tryParse(v.replaceAll(',', '')) != null);
    columns.add({'key': 'c$i', 'label': header[i], if (numeric) 'type': 'number'});
  }
  return {
    'columns': columns,
    'rows': [
      for (final row in rows)
        {
          for (var i = 0; i < columns.length && i < row.length; i++)
            'c$i': columns[i]['type'] == 'number' ? num.tryParse(row[i].replaceAll(',', '')) ?? row[i] : row[i],
        },
    ],
  };
}
