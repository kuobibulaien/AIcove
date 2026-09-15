import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:math';

import 'package:crypto/crypto.dart';

import '../../../core/utils/token_estimator.dart';

class TavernWorldEntry {
  final String id;
  final String name;
  final String content;
  final bool enabled;
  final bool constant;
  final List<String> keys;
  final List<String> secondaryKeys;
  final bool selective;
  final int logic;
  final int position;
  final int depth;
  final String role;
  final int order;
  final int scanDepth;
  final bool caseSensitive;
  final bool wholeWords;
  final int probability;
  final bool ignoreBudget;
  final List<String> unsupported;

  TavernWorldEntry(
    Map<String, dynamic> raw,
    String fallbackId,
    int bookDepth,
    Map overrides,
  ) : id = (raw['uid'] ?? raw['id'] ?? fallbackId).toString(),
      name = (raw['comment'] ?? raw['name'] ?? '条目 $fallbackId').toString(),
      content = raw['content'] is String ? raw['content'] as String : '',
      enabled =
          overrides[(raw['uid'] ?? raw['id'] ?? fallbackId).toString()]
              as bool? ??
          (raw['disable'] != true && raw['enabled'] != false),
      constant = raw['constant'] == true,
      keys = _strings(raw['key'] ?? raw['keys']),
      secondaryKeys = _strings(raw['keysecondary'] ?? raw['secondary_keys']),
      selective = raw['selective'] != false,
      logic = _number(_field(raw, 'selectiveLogic', 'selectiveLogic'), 0),
      position = _position(raw),
      depth = _number(_field(raw, 'depth', 'depth'), 4).clamp(0, 1000),
      role = switch (_number(_field(raw, 'role', 'role'), 0)) {
        1 => 'user',
        2 => 'assistant',
        _ => 'system',
      },
      order = _number(raw['order'] ?? raw['insertion_order'], 100),
      scanDepth = _number(
        _field(raw, 'scanDepth', 'scan_depth'),
        bookDepth,
      ).clamp(0, 1000),
      caseSensitive = _field(raw, 'caseSensitive', 'case_sensitive') == true,
      wholeWords = _field(raw, 'matchWholeWords', 'match_whole_words') == true,
      probability = raw['useProbability'] == false
          ? 100
          : _number(
              _field(raw, 'probability', 'probability'),
              100,
            ).clamp(0, 100),
      ignoreBudget = _field(raw, 'ignoreBudget', 'ignore_budget') == true,
      unsupported = _unsupported(raw);

  String get positionLabel => switch (position) {
    0 => '角色定义前',
    1 => '角色定义后',
    4 => '聊天深度 $depth · $role',
    _ => '暂不支持的位置 $position',
  };
}

class TavernWorldBook {
  final String id;
  final String name;
  final bool enabled;
  final int tokenBudget;
  final List<TavernWorldEntry> entries;
  final List<String> warnings;
  final Map<String, dynamic> source;

  const TavernWorldBook({
    required this.id,
    required this.name,
    required this.enabled,
    required this.tokenBudget,
    required this.entries,
    required this.warnings,
    required this.source,
  });

  static TavernWorldBook parse(
    Map<String, dynamic> source,
    String fileName, {
    String? storedId,
    bool enabled = true,
    Map overrides = const {},
  }) {
    final nested = source['data'];
    final characterBook =
        source['character_book'] ??
        (nested is Map ? nested['character_book'] : null);
    final body = characterBook is Map ? characterBook : source;
    final rawEntries = body['entries'];
    if (rawEntries is! Map && rawEntries is! List) {
      throw const FormatException(
        '未找到世界书 entries；支持酒馆世界书或角色卡内的 character_book JSON',
      );
    }
    final items = rawEntries is Map
        ? rawEntries.entries
              .map((e) => MapEntry(e.key.toString(), e.value))
              .toList()
        : (rawEntries as List)
              .asMap()
              .entries
              .map((e) => MapEntry(e.key.toString(), e.value))
              .toList();
    if (items.length > 2000) throw const FormatException('世界书超过 2000 条，已拒绝导入');
    final depth = _number(body['scan_depth'], 2).clamp(0, 1000);
    final entries = <TavernWorldEntry>[];
    final ids = <String>{};
    final warnings = <String>[];
    for (final item in items) {
      if (item.value is! Map) throw FormatException('世界书条目 ${item.key} 不是对象');
      final entry = TavernWorldEntry(
        Map<String, dynamic>.from(item.value as Map),
        item.key,
        depth,
        overrides,
      );
      if (!ids.add(entry.id)) throw FormatException('世界书条目 ID 重复：${entry.id}');
      entries.add(entry);
      if (entry.unsupported.isNotEmpty) {
        warnings.add(
          '${entry.name}：${entry.unsupported.join('、')} 尚不支持，该条目不执行',
        );
      }
    }
    if (body['recursive_scanning'] == true) {
      warnings.add('本版仅扫描聊天，不进行世界书递归触发');
    }
    return TavernWorldBook(
      id:
          storedId ??
          'wi_${sha256.convert(utf8.encode(jsonEncode(source))).toString().substring(0, 24)}',
      name:
          (body['name'] ??
                  fileName.replaceFirst(
                    RegExp(r'\.json$', caseSensitive: false),
                    '',
                  ))
              .toString(),
      enabled: enabled,
      tokenBudget: _number(body['token_budget'], 2048).clamp(0, 65536),
      entries: List.unmodifiable(entries),
      warnings: List.unmodifiable(warnings),
      source: source,
    );
  }
}

class TavernWorldInjection {
  final String id;
  final String content;
  final int position;
  final int depth;
  final String role;
  final int order;
  const TavernWorldInjection({
    required this.id,
    required this.content,
    required this.position,
    required this.depth,
    required this.role,
    required this.order,
  });
  TavernWorldInjection withContent(String text) => TavernWorldInjection(
    id: id,
    content: text,
    position: position,
    depth: depth,
    role: role,
    order: order,
  );
}

class TavernWorldScanResult {
  final List<TavernWorldInjection> injections;
  final List<Map<String, dynamic>> traces;
  final List<String> warnings;
  const TavernWorldScanResult(this.injections, this.traces, this.warnings);
}

abstract interface class TavernWorldScannerPort {
  Future<TavernWorldScanResult> scan({
    required List<TavernWorldBook> books,
    required List<Map<String, dynamic>> messages,
    required int tokenBudget,
    Map<String, String> macroValues = const {},
  });
}

/// 关键词正则在可终止的 isolate 执行，不能卡住聊天 UI。
class TavernWorldScanner implements TavernWorldScannerPort {
  const TavernWorldScanner();
  @override
  Future<TavernWorldScanResult> scan({
    required List<TavernWorldBook> books,
    required List<Map<String, dynamic>> messages,
    required int tokenBudget,
    Map<String, String> macroValues = const {},
  }) async {
    if (!books.any((b) => b.enabled)) {
      return const TavernWorldScanResult([], [], []);
    }
    final maxDepth = books
        .where((b) => b.enabled)
        .expand((b) => b.entries)
        .where((e) => e.enabled && !e.constant && e.unsupported.isEmpty)
        .fold<int>(0, (depth, e) => max(depth, e.scanDepth));
    final texts = messages.reversed
        .where((m) => m['role'] == 'user' || m['role'] == 'assistant')
        .take(maxDepth)
        .map((m) => _text(m['content']))
        .toList()
        .reversed
        .toList();
    if (texts.fold<int>(0, (n, t) => n + t.length) > 2 * 1024 * 1024) {
      return const TavernWorldScanResult([], [], ['世界书扫描输入超过 2 MB，本轮跳过世界书']);
    }
    final port = ReceivePort();
    Isolate? worker;
    try {
      worker = await Isolate.spawn(_scanWorker, [
        port.sendPort,
        books,
        texts,
        tokenBudget,
        macroValues,
      ]);
      final result = await port.first.timeout(
        const Duration(milliseconds: 1500),
      );
      if (result is! TavernWorldScanResult) {
        throw const FormatException('世界书扫描失败');
      }
      return result;
    } on TimeoutException {
      return const TavernWorldScanResult([], [], ['世界书扫描超过 1500ms，已终止，本轮不注入']);
    } finally {
      worker?.kill(priority: Isolate.immediate);
      port.close();
    }
  }
}

void _scanWorker(List<dynamic> args) {
  final port = args[0] as SendPort;
  try {
    port.send(
      _scan(
        args[1] as List<TavernWorldBook>,
        args[2] as List<String>,
        args[3] as int,
        args[4] as Map<String, String>,
      ),
    );
  } catch (_) {
    port.send(const TavernWorldScanResult([], [], ['世界书扫描异常，本轮不注入']));
  }
}

TavernWorldScanResult _scan(
  List<TavernWorldBook> books,
  List<String> texts,
  int budget,
  Map<String, String> macros,
) {
  final candidates =
      <({TavernWorldBook book, TavernWorldEntry entry, int index})>[];
  final traces = <Map<String, dynamic>>[];
  final warnings = <String>[];
  for (final book in books) {
    warnings.addAll(book.warnings);
    for (final entry in book.entries) {
      final id = '${book.id}/${entry.id}';
      if (!book.enabled || !entry.enabled || entry.unsupported.isNotEmpty) {
        traces.add({
          'id': id,
          'status': 'skipped',
          'reason': !book.enabled || !entry.enabled
              ? 'disabled'
              : 'unsupported',
        });
        continue;
      }
      try {
        final buffer = texts
            .skip(max(0, texts.length - entry.scanDepth))
            .join('\n');
        bool match(String key) =>
            _matches(_substitute(key, macros), buffer, entry);
        var active = entry.constant || entry.keys.any(match);
        if (active &&
            !entry.constant &&
            entry.selective &&
            entry.secondaryKeys.isNotEmpty) {
          final matches = entry.secondaryKeys.map(match).toList();
          active = switch (entry.logic) {
            0 => matches.any((m) => m),
            1 => !matches.every((m) => m),
            2 => !matches.any((m) => m),
            3 => matches.every((m) => m),
            _ => false,
          };
        }
        if (!active || Random().nextInt(100) >= entry.probability) {
          traces.add({
            'id': id,
            'status': 'skipped',
            'reason': active ? 'probability' : 'no_match',
          });
          continue;
        }
        candidates.add((book: book, entry: entry, index: candidates.length));
      } on FormatException {
        warnings.add('${entry.name} 的关键词正则无效或含不支持的标志，已跳过');
        traces.add({'id': id, 'status': 'skipped', 'reason': 'invalid_key'});
      }
    }
  }
  // 常驻优先占预算，其次 order 降序；最终呈现按 order 升序。
  candidates.sort((a, b) {
    final constant = (b.entry.constant ? 1 : 0).compareTo(
      a.entry.constant ? 1 : 0,
    );
    if (constant != 0) return constant;
    final order = b.entry.order.compareTo(a.entry.order);
    return order != 0 ? order : a.index.compareTo(b.index);
  });
  final injections = <TavernWorldInjection>[];
  final usedByBook = <String, int>{};
  var used = 0;
  for (final candidate in candidates) {
    final book = candidate.book;
    final entry = candidate.entry;
    final id = '${book.id}/${entry.id}';
    final content = _substitute(entry.content, macros);
    final tokens = estimateTokenCount(content) + 4;
    if (used + tokens > budget ||
        (!entry.ignoreBudget &&
            (usedByBook[book.id] ?? 0) + tokens > book.tokenBudget)) {
      traces.add({'id': id, 'status': 'skipped', 'reason': 'budget'});
      warnings.add('${entry.name} 超过世界书预算，本轮未注入');
      continue;
    }
    used += tokens;
    usedByBook[book.id] = (usedByBook[book.id] ?? 0) + tokens;
    injections.add(
      TavernWorldInjection(
        id: id,
        content: content,
        position: entry.position,
        depth: entry.depth,
        role: entry.role,
        order: entry.order,
      ),
    );
    traces.add({
      'id': id,
      'status': 'activated',
      'position': entry.position,
      'depth': entry.depth,
      'order': entry.order,
      'estimatedTokens': tokens,
    });
  }
  final indices = {
    for (var i = 0; i < injections.length; i++) injections[i].id: i,
  };
  injections.sort((a, b) {
    final order = a.order.compareTo(b.order);
    return order != 0 ? order : indices[a.id]!.compareTo(indices[b.id]!);
  });
  return TavernWorldScanResult(injections, traces, warnings.toSet().toList());
}

bool _matches(String key, String buffer, TavernWorldEntry entry) {
  if (key.isEmpty) return false;
  if (key.length > 32768) throw const FormatException('关键词过长');
  if (key.startsWith('/') && key.lastIndexOf('/') > 0) {
    final slash = key.lastIndexOf('/');
    final flags = key.substring(slash + 1);
    if (flags.split('').any((f) => !'gimsu'.contains(f))) {
      throw const FormatException('不支持的关键词 regex flags');
    }
    return RegExp(
      key.substring(1, slash),
      caseSensitive: !flags.contains('i'),
      multiLine: flags.contains('m'),
      dotAll: flags.contains('s'),
      unicode: flags.contains('u'),
    ).hasMatch(buffer);
  }
  final text = entry.caseSensitive ? buffer : buffer.toLowerCase();
  final needle = entry.caseSensitive ? key : key.toLowerCase();
  if (!entry.wholeWords) return text.contains(needle);
  return RegExp(
    '(?<![\\p{L}\\p{N}_])${RegExp.escape(needle)}(?![\\p{L}\\p{N}_])',
    unicode: true,
  ).hasMatch(text);
}

String _substitute(String value, Map<String, String> macros) =>
    value.replaceAllMapped(
      RegExp(r'\{\{(char|user|description|scenario)\}\}', caseSensitive: false),
      (m) => macros[m[1]!.toLowerCase()] ?? m[0]!,
    );
String _text(dynamic value) => value is String
    ? value
    : value is List
    ? value
          .whereType<Map>()
          .where((m) => m['type'] == 'text')
          .map((m) => m['text'] ?? '')
          .join('\n')
    : '';
List<String> _strings(dynamic value) => value is List
    ? value.whereType<String>().where((s) => s.isNotEmpty).toList()
    : const [];
int _number(dynamic value, int fallback) => value is num && value.isFinite
    ? value.toInt()
    : int.tryParse('$value') ?? fallback;
dynamic _field(Map raw, String key, String extensionKey) =>
    raw[key] ??
    (raw['extensions'] is Map ? raw['extensions'][extensionKey] : null);
int _position(Map raw) {
  final extension = raw['extensions'];
  final p = extension is Map && extension['position'] != null
      ? extension['position']
      : raw['position'];
  if (p == 'before_char') return 0;
  if (p == 'after_char') return 1;
  return _number(p, 0);
}

List<String> _unsupported(Map raw) {
  final result = <String>[];
  if (![0, 1, 4].contains(_position(raw))) result.add('示例／作者注／Outlet 插入位置');
  if (![
    0,
    1,
    2,
    3,
  ].contains(_number(_field(raw, 'selectiveLogic', 'selectiveLogic'), 0))) {
    result.add('次关键词逻辑');
  }
  for (final pair in const [
    ('vectorized', 'vectorized'),
    ('group', 'group'),
    ('sticky', 'sticky'),
    ('cooldown', 'cooldown'),
    ('delay', 'delay'),
    ('delayUntilRecursion', 'delay_until_recursion'),
  ]) {
    final v = _field(raw, pair.$1, pair.$2);
    if (v != null &&
        v != false &&
        v != 0 &&
        v != '' &&
        !(v is Map && v.isEmpty)) {
      result.add(pair.$1);
    }
  }
  final filter = _field(raw, 'characterFilter', 'character_filter');
  if (filter is Map &&
      (_strings(filter['names']).isNotEmpty ||
          _strings(filter['tags']).isNotEmpty)) {
    result.add('characterFilter');
  }
  final triggers = _strings(raw['triggers']);
  if (triggers.isNotEmpty && !triggers.contains('normal')) {
    result.add('非 normal 触发');
  }
  for (final field in const [
    'matchPersonaDescription',
    'matchCharacterDescription',
    'matchCharacterPersonality',
    'matchCharacterDepthPrompt',
    'matchScenario',
    'matchCreatorNotes',
  ]) {
    if (raw[field] == true) result.add(field);
  }
  return result;
}
