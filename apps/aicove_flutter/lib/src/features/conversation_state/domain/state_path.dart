/// JSON 状态树上的路径工具，口径对齐 lodash `_.toPath` / `_.get` / `_.set`
/// 与 MVU 的 `pathFix`（ADR0071）。
///
/// 段为 [int]（数组下标，来自裸数字 `[0]` 或点分段里的纯数字）或 [String]（键）。
library;

/// 解析 MVU 命令里的路径参数。空串表示根。
List<Object> parseStatePath(String raw) {
  final path = _trimQuotesAndBackslashes(raw.trim());
  if (path.isEmpty) return const [];
  final segments = <Object>[];
  final buffer = StringBuffer();
  var i = 0;
  void flush({bool allowIndex = true}) {
    if (buffer.isEmpty) return;
    final text = buffer.toString();
    buffer.clear();
    segments.add(allowIndex && _digits.hasMatch(text) ? int.parse(text) : text);
  }

  while (i < path.length) {
    final char = path[i];
    if (char == '.') {
      flush();
      i++;
      continue;
    }
    if (char == '[') {
      flush();
      final close = _findBracketClose(path, i);
      if (close < 0) {
        buffer.write(path.substring(i));
        break;
      }
      var inner = path.substring(i + 1, close).trim();
      var quoted = false;
      if (inner.length >= 2 &&
          (inner[0] == '"' || inner[0] == "'") &&
          inner[inner.length - 1] == inner[0]) {
        quoted = true;
        inner = inner.substring(1, inner.length - 1).replaceAll('\\"', '"');
      }
      if (inner.isNotEmpty) {
        segments.add(
          !quoted && _digits.hasMatch(inner) ? int.parse(inner) : inner,
        );
      }
      i = close + 1;
      continue;
    }
    if ((char == '"' || char == "'") && buffer.isEmpty) {
      final end = path.indexOf(char, i + 1);
      if (end > i) {
        buffer.write(path.substring(i + 1, end));
        i = end + 1;
        flush(allowIndex: false);
        continue;
      }
    }
    buffer.write(char);
    i++;
  }
  flush();
  return segments;
}

/// JSON Pointer（RFC 6901）转路径段；`-` 保留为字符串由调用方解释。
List<Object> parseJsonPointer(String pointer) {
  if (pointer.isEmpty || pointer == '/') {
    return pointer.isEmpty ? const [] : const [''];
  }
  final body = pointer.startsWith('/') ? pointer.substring(1) : pointer;
  return [
    for (final part in body.split('/'))
      _digits.hasMatch(part)
          ? int.parse(part)
          : part.replaceAll('~1', '/').replaceAll('~0', '~'),
  ];
}

String formatStatePath(List<Object> path) => path.isEmpty
    ? '(根)'
    : path.map((s) => s is int ? '[$s]' : s.toString()).join('.');

/// 判断路径是否存在（对象键存在、数组下标在范围内）。
bool stateHas(Object? root, List<Object> path) {
  if (path.isEmpty) return true;
  Object? current = root;
  for (final segment in path) {
    final next = _child(current, segment);
    if (!next.found) return false;
    current = next.value;
  }
  return true;
}

Object? stateGet(Object? root, List<Object> path) {
  Object? current = root;
  for (final segment in path) {
    final next = _child(current, segment);
    if (!next.found) return null;
    current = next.value;
  }
  return current;
}

/// 原地写入；中间缺失的容器按 lodash 规则补建（下一段为数字时建数组）。
/// 返回 false 表示路径穿过了标量，无法写入。
bool stateSet(Map<String, Object?> root, List<Object> path, Object? value) {
  if (path.isEmpty) return false;
  Object? current = root;
  for (var i = 0; i < path.length; i++) {
    final segment = path[i];
    final last = i == path.length - 1;
    if (current is Map<String, Object?>) {
      final key = segment.toString();
      if (last) {
        current[key] = value;
        return true;
      }
      var next = current[key];
      if (next is! Map && next is! List) {
        next = path[i + 1] is int ? <Object?>[] : <String, Object?>{};
        current[key] = next;
      }
      current = next;
    } else if (current is List<Object?>) {
      final index = _index(segment);
      if (index == null || index < 0) return false;
      while (current.length <= index) {
        current.add(null);
      }
      if (last) {
        current[index] = value;
        return true;
      }
      var next = current[index];
      if (next is! Map && next is! List) {
        next = path[i + 1] is int ? <Object?>[] : <String, Object?>{};
        current[index] = next;
      }
      current = next;
    } else {
      return false;
    }
  }
  return false;
}

/// 删除路径末段；数组元素被移除并收缩，不留空洞。返回是否删除。
bool stateUnset(Object? root, List<Object> path) {
  if (path.isEmpty) return false;
  final parent = stateGet(root, path.sublist(0, path.length - 1));
  final last = path.last;
  if (parent is Map<String, Object?>) {
    final key = last.toString();
    if (!parent.containsKey(key)) return false;
    parent.remove(key);
    return true;
  }
  if (parent is List<Object?>) {
    final index = _index(last);
    if (index == null || index < 0 || index >= parent.length) return false;
    parent.removeAt(index);
    return true;
  }
  return false;
}

/// 深拷贝 JSON 值，统一成可变的 `Map<String, Object?>` / `List<Object?>`。
Object? cloneJson(Object? value) {
  if (value is Map) {
    return <String, Object?>{
      for (final entry in value.entries)
        entry.key.toString(): cloneJson(entry.value),
    };
  }
  if (value is List) {
    return <Object?>[for (final item in value) cloneJson(item)];
  }
  return value;
}

/// lodash `_.isEqual` 对 JSON 值的等价判断。
bool jsonDeepEquals(Object? a, Object? b) {
  if (a is num && b is num) return a == b;
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final key in a.keys) {
      if (!b.containsKey(key) || !jsonDeepEquals(a[key], b[key])) return false;
    }
    return true;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!jsonDeepEquals(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}

/// lodash `_.merge` 的 JSON 子集：对象递归合并，数组按下标合并，其余覆盖。
void deepMergeInto(Map<String, Object?> target, Map<String, Object?> source) {
  for (final entry in source.entries) {
    final existing = target[entry.key];
    final incoming = entry.value;
    if (existing is Map<String, Object?> && incoming is Map) {
      deepMergeInto(existing, cloneJson(incoming) as Map<String, Object?>);
    } else if (existing is List<Object?> && incoming is List) {
      _mergeList(existing, incoming);
    } else {
      target[entry.key] = cloneJson(incoming);
    }
  }
}

void _mergeList(List<Object?> target, List<Object?> source) {
  for (var i = 0; i < source.length; i++) {
    final incoming = source[i];
    if (i >= target.length) {
      target.add(cloneJson(incoming));
      continue;
    }
    final existing = target[i];
    if (existing is Map<String, Object?> && incoming is Map) {
      deepMergeInto(existing, cloneJson(incoming) as Map<String, Object?>);
    } else if (existing is List<Object?> && incoming is List) {
      _mergeList(existing, incoming);
    } else {
      target[i] = cloneJson(incoming);
    }
  }
}

({bool found, Object? value}) _child(Object? container, Object segment) {
  if (container is Map) {
    final key = segment.toString();
    return container.containsKey(key)
        ? (found: true, value: container[key])
        : (found: false, value: null);
  }
  if (container is List) {
    final index = _index(segment);
    if (index != null && index >= 0 && index < container.length) {
      return (found: true, value: container[index]);
    }
  }
  return (found: false, value: null);
}

int? _index(Object segment) =>
    segment is int ? segment : int.tryParse(segment.toString());

int _findBracketClose(String path, int open) {
  String? quote;
  for (var i = open + 1; i < path.length; i++) {
    final char = path[i];
    if (quote != null) {
      if (char == '\\') {
        i++;
      } else if (char == quote) {
        quote = null;
      }
      continue;
    }
    if (char == '"' || char == "'") {
      quote = char;
    } else if (char == ']') {
      return i;
    }
  }
  return -1;
}

final RegExp _digits = RegExp(r'^\d+$');

/// MVU `trimQuotesAndBackslashes`：去掉首尾的引号、反引号、反斜杠与空格。
String _trimQuotesAndBackslashes(String value) => value.replaceFirstMapped(
  RegExp(
    r'^[\\"'
    "'"
    r'` ]*([\s\S]*?)[\\"'
    "'"
    r'` ]*$',
  ),
  (m) => m[1]!,
);

String trimQuotesAndBackslashes(String value) =>
    _trimQuotesAndBackslashes(value);
