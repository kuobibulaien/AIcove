/// MVU 变量执行器（ADR0071）：纯函数，无 IO。
///
/// `initialize` 由世界书 `[InitVar]` 条目与开场白 `<initvar>` 生成冻结基线；
/// `apply` 在前态上执行一条原始回复里的更新命令，逐条跳过非法命令，不回滚其他命令。
library;

import 'mvu_literal.dart';
import 'mvu_markup.dart';
import 'state_path.dart';

/// 结果状态，存进 `message_states.status`。
enum StateStepStatus {
  applied('applied'),
  partial('partial'),
  noOps('no_ops'),
  parseError('parse_error');

  const StateStepStatus(this.wire);
  final String wire;

  static StateStepStatus fromWire(String value) =>
      values.firstWhere((s) => s.wire == value, orElse: () => noOps);
}

class MvuState {
  MvuState({
    required this.statData,
    this.strictSet = false,
    this.unsupportedFeatures = const <String>{},
  });

  factory MvuState.empty() => MvuState(statData: <String, Object?>{});

  factory MvuState.fromJson(Map<String, Object?> json) {
    final config = json['config'];
    return MvuState(
      statData:
          (cloneJson(json['stat_data']) as Map<String, Object?>?) ??
          <String, Object?>{},
      strictSet: config is Map && config['strictSet'] == true,
      unsupportedFeatures: {
        for (final item in (json['unsupported'] as List? ?? const []))
          item.toString(),
      },
    );
  }

  final Map<String, Object?> statData;
  final bool strictSet;

  /// 检测到但本期不支持的特性（template、constraints），用于诊断。
  final Set<String> unsupportedFeatures;

  MvuState copy() => MvuState(
    statData: cloneJson(statData) as Map<String, Object?>,
    strictSet: strictSet,
    unsupportedFeatures: unsupportedFeatures,
  );

  Map<String, Object?> toJson() => {
    'stat_data': statData,
    'config': {'strictSet': strictSet},
    if (unsupportedFeatures.isNotEmpty)
      'unsupported': (unsupportedFeatures.toList()..sort()),
  };
}

class MvuStepResult {
  const MvuStepResult(this.state, this.status, this.diagnostics);
  final MvuState state;
  final StateStepStatus status;
  final List<String> diagnostics;
}

/// 一个 `[InitVar]` 来源：世界书条目名与内容。
class MvuInitSource {
  const MvuInitSource({required this.name, required this.content});
  final String name;
  final String content;
}

class MvuInitResult {
  const MvuInitResult.ready(this.state, this.diagnostics) : failure = null;
  const MvuInitResult.failed(this.failure, this.diagnostics) : state = null;

  final MvuState? state;
  final String? failure;
  final List<String> diagnostics;
  bool get ok => state != null;
}

class MvuEngine {
  const MvuEngine();

  /// 执行器版本；语义变化时递增，旧缓存自动失效。
  static const int version = 1;

  static const String extensibleMarker = r'$__META_EXTENSIBLE__$';

  /// [expandMacros] 只做已支持的宏展开（如 `{{char}}`），不执行脚本。
  MvuInitResult initialize({
    required List<MvuInitSource> sources,
    String? greetingRaw,
    String Function(String text)? expandMacros,
  }) {
    final expand = expandMacros ?? (String text) => text;
    final diagnostics = <String>[];
    final merged = <String, Object?>{};
    for (final source in sources) {
      if (_hasEjs(source.content)) {
        return MvuInitResult.failed(
          '初始化条目「${source.name}」含 EJS 模板（<% %>），本期不支持，MVU 未启用',
          diagnostics,
        );
      }
      final wrapped = _initvarBlock.allMatches(source.content).toList();
      final bodies = wrapped.isEmpty
          ? [source.content]
          : [for (final m in wrapped) m[1]!];
      for (final body in bodies) {
        final Object? parsed;
        try {
          parsed = parseMvuDataBlock(expand(body));
        } on FormatException catch (error) {
          return MvuInitResult.failed(
            '初始化条目「${source.name}」无法解析：${error.message}',
            diagnostics,
          );
        }
        if (parsed is! Map<String, Object?>) {
          return MvuInitResult.failed('初始化条目「${source.name}」不是对象', diagnostics);
        }
        _mergeReplacingArrays(merged, parsed);
      }
    }

    final greeting = greetingRaw ?? '';
    final overrides = _initvarBlock.allMatches(greeting).toList();
    if (overrides.isNotEmpty) {
      final replaced = <String, Object?>{};
      var applied = false;
      for (final match in overrides) {
        final body = match[1]!;
        if (_hasEjs(body)) {
          return MvuInitResult.failed(
            '开场白里的 <initvar> 含 EJS 模板，本期不支持，MVU 未启用',
            diagnostics,
          );
        }
        try {
          final parsed = parseMvuDataBlock(expand(body));
          if (parsed is Map<String, Object?>) {
            _mergeReplacingArrays(replaced, parsed);
            applied = true;
          }
        } on FormatException catch (error) {
          diagnostics.add('开场白里的 <initvar> 块无法解析，已忽略：${error.message}');
        }
      }
      if (applied) {
        merged
          ..clear()
          ..addAll(replaced);
        diagnostics.add('开场白 <initvar> 已替换世界书初始化变量');
      }
    }

    final meta = merged[r'$meta'];
    final strictSet = meta is Map && meta['strictSet'] == true;
    final features = <String>{};
    _detectFeatures(merged, features);
    _cleanUpMetadata(merged);
    for (final feature in features) {
      diagnostics.add(switch (feature) {
        'template' => '此卡使用 MVU 模板，插入的新条目不会自动补全字段',
        _ => '此卡声明了 MVU 结构约束（可扩展／必填），本期不校验',
      });
    }
    return MvuInitResult.ready(
      MvuState(
        statData: merged,
        strictSet: strictSet,
        unsupportedFeatures: features,
      ),
      diagnostics,
    );
  }

  MvuStepResult apply(MvuState previous, String rawText) {
    final extraction = extractMvuCommands(rawText);
    final diagnostics = <String>[...extraction.brokenBlocks];
    if (!extraction.hasUpdateMarkup && extraction.brokenBlocks.isEmpty) {
      return MvuStepResult(previous, StateStepStatus.noOps, const []);
    }
    final state = previous.copy();
    var succeeded = 0;
    var failed = extraction.brokenBlocks.length;
    for (final command in extraction.commands) {
      final error = _execute(state, command);
      if (error == null) {
        succeeded++;
      } else {
        failed++;
        diagnostics.add('${_label(command)}：$error');
      }
    }
    final StateStepStatus status;
    if (succeeded == 0 && failed == 0) {
      status = StateStepStatus.noOps;
    } else if (succeeded == 0) {
      return MvuStepResult(previous, StateStepStatus.parseError, diagnostics);
    } else {
      status = failed == 0 ? StateStepStatus.applied : StateStepStatus.partial;
    }
    return MvuStepResult(state, status, diagnostics);
  }

  /// 返回 null 表示成功，否则为跳过原因。
  String? _execute(MvuState state, MvuCommand command) {
    try {
      return switch (command.type) {
        MvuCommandType.set => _set(state, command),
        MvuCommandType.insert => _insert(state, command),
        MvuCommandType.delete => _delete(state, command),
        MvuCommandType.add => _add(state, command),
        MvuCommandType.move => '上游执行器未实现 move，已跳过',
      };
    } on MvuUnsupportedExpression catch (error) {
      return '$error，未执行';
    }
  }

  String? _set(MvuState state, MvuCommand command) {
    final path = command.path;
    final root = state.statData;
    if (command.args.isEmpty) return '缺少新值';
    if (path.isNotEmpty && !stateHas(root, path)) return '路径不存在';
    final newValue = parseMvuCommandValue(command.args.last);
    final oldValue = path.isEmpty ? root : stateGet(root, path);
    if (!state.strictSet &&
        oldValue is List<Object?> &&
        oldValue.length == 2 &&
        oldValue[1] is String &&
        oldValue[0] is! List) {
      if (oldValue[0] is num && newValue != null) {
        final number = _toNumber(newValue);
        if (number == null) return '旧值是数字，新值“$newValue”不是数字';
        oldValue[0] = number;
      } else {
        oldValue[0] = cloneJson(newValue);
      }
      return null;
    }
    if (oldValue is num && newValue is String) {
      final number = _toNumber(newValue);
      if (number == null) return '旧值是数字，新值“$newValue”不是数字';
      stateSet(root, path, number);
      return null;
    }
    if (path.isEmpty) {
      if (newValue is! Map) return '根状态只能替换为对象';
      root
        ..clear()
        ..addAll(cloneJson(newValue) as Map<String, Object?>);
      return null;
    }
    return stateSet(root, path, cloneJson(newValue)) ? null : '路径穿过了非容器值';
  }

  String? _insert(MvuState state, MvuCommand command) {
    final path = command.path;
    final root = state.statData;
    if (command.args.isEmpty) return '缺少要插入的值';
    final existing = path.isEmpty ? root : stateGet(root, path);
    final exists = path.isEmpty || stateHas(root, path);
    if (exists && existing != null && existing is! List && existing is! Map) {
      return '目标不是数组或对象';
    }
    if (!exists &&
        path.length > 1 &&
        !stateHas(root, path.sublist(0, path.length - 1))) {
      return '父路径不存在';
    }
    if (command.args.length == 1) {
      final value = cloneJson(parseMvuCommandValue(command.args.first));
      Object? collection = existing;
      if (collection is! List && collection is! Map) {
        collection = value is List ? <Object?>[] : <String, Object?>{};
        stateSet(root, path, collection);
      }
      if (collection is List<Object?>) {
        collection.add(value);
        return null;
      }
      if (value is Map<String, Object?>) {
        deepMergeInto(collection as Map<String, Object?>, value);
        return null;
      }
      return '向对象插入时值必须是对象';
    }
    final key = parseMvuCommandValue(command.args[0]);
    final value = cloneJson(parseMvuCommandValue(command.args[1]));
    if (existing is List<Object?> && (key is num || key == '-')) {
      existing.insert(
        _spliceIndex(
          key == '-' ? existing.length : key as num,
          existing.length,
        ),
        value,
      );
      return null;
    }
    if (existing is Map<String, Object?>) {
      existing[_keyString(key)] = value;
      return null;
    }
    final created = <String, Object?>{_keyString(key): value};
    if (path.isEmpty) return '根状态不能被替换';
    return stateSet(root, path, created) ? null : '路径穿过了非容器值';
  }

  String? _delete(MvuState state, MvuCommand command) {
    final path = command.path;
    final root = state.statData;
    if (path.isEmpty && command.args.isEmpty) return '不能删除根状态';
    if (command.args.isEmpty && path.isNotEmpty && path.last is int) {
      final container = stateGet(root, path.sublist(0, path.length - 1));
      final index = path.last as int;
      if (container is List<Object?> && index < container.length) {
        container.removeAt(index);
        return null;
      }
    }
    if (path.isNotEmpty && !stateHas(root, path)) return '路径不存在';
    if (command.args.isEmpty) {
      return stateUnset(root, path) ? null : '删除失败';
    }
    final target = parseMvuCommandValue(command.args.first);
    final collection = path.isEmpty ? root : stateGet(root, path);
    if (collection is List<Object?>) {
      final index = target is num
          ? target.toInt()
          : collection.indexWhere((item) => jsonDeepEquals(item, target));
      if (index < 0 || index >= collection.length) return '未找到要删除的元素';
      collection.removeAt(index);
      return null;
    }
    if (collection is Map<String, Object?>) {
      if (target is num) {
        final keys = collection.keys.toList();
        final index = target.toInt();
        if (index < 0 || index >= keys.length) return '下标超出键数量';
        collection.remove(keys[index]);
        return null;
      }
      final key = target is String
          ? trimQuotesAndBackslashes(target)
          : _keyString(target);
      if (!collection.containsKey(key)) return '键不存在';
      collection.remove(key);
      return null;
    }
    return '目标不是数组或对象';
  }

  String? _add(MvuState state, MvuCommand command) {
    final path = command.path;
    final root = state.statData;
    if (!stateHas(root, path) || path.isEmpty) return '路径不存在';
    if (command.args.length != 1) return '需要且只需要一个增量';
    final current = stateGet(root, path);
    final isVwd =
        current is List<Object?> &&
        current.length == 2 &&
        current[1] is String &&
        current[0] != null &&
        current[0] is! Map &&
        current[0] is! List;
    final value = isVwd ? current[0] : current;
    final delta = parseMvuCommandValue(command.args.first);
    Object? updated;
    if (value is num) {
      if (delta is! num) return '增量“$delta”不是数字';
      final sum = value + delta;
      updated = sum is int ? sum : double.parse(sum.toStringAsPrecision(12));
    } else if (value is String && _zonedIso.hasMatch(value)) {
      final date = DateTime.tryParse(value);
      if (date == null) return '日期无法解析';
      if (delta is! num) return '日期增量必须是毫秒数';
      updated = date
          .toUtc()
          .add(Duration(milliseconds: delta.round()))
          .toIso8601String();
    } else if (value is String && DateTime.tryParse(value) != null) {
      return '日期没有时区，无法确定偏移基准，已跳过';
    } else {
      return '目标类型（${value.runtimeType}）不支持 add';
    }
    if (isVwd) {
      current[0] = updated;
    } else {
      stateSet(root, path, updated);
    }
    return null;
  }

  static String _label(MvuCommand command) {
    final name = command.fromPatch ? 'JSON Patch' : command.type.name;
    return '$name ${formatStatePath(command.path)}';
  }
}

int _spliceIndex(num raw, int length) {
  final index = raw.toInt();
  if (index < 0) return (length + index).clamp(0, length);
  return index > length ? length : index;
}

String _keyString(Object? key) => key is double && key == key.truncateToDouble()
    ? key.toInt().toString()
    : key.toString();

num? _toNumber(Object? value) {
  if (value is num) return value;
  if (value is String) return num.tryParse(value.trim());
  if (value is bool) return value ? 1 : 0;
  return null;
}

bool _hasEjs(String text) => text.contains('<%') && text.contains('%>');

/// 对齐 MVU `correctlyMerge`：对象递归合并，数组整体替换。
void _mergeReplacingArrays(
  Map<String, Object?> target,
  Map<String, Object?> source,
) {
  for (final entry in source.entries) {
    final existing = target[entry.key];
    final incoming = entry.value;
    if (existing is Map<String, Object?> && incoming is Map<String, Object?>) {
      _mergeReplacingArrays(existing, incoming);
    } else {
      target[entry.key] = cloneJson(incoming);
    }
  }
}

void _detectFeatures(Object? node, Set<String> features) {
  if (node is Map) {
    final meta = node[r'$meta'];
    if (meta is Map) {
      if (meta.containsKey('template') ||
          meta.containsKey('strictTemplate') ||
          meta.containsKey('concatTemplateArray')) {
        features.add('template');
      }
      if (meta.containsKey('extensible') || meta.containsKey('required')) {
        features.add('constraints');
      }
    }
    for (final value in node.values) {
      _detectFeatures(value, features);
    }
  } else if (node is List) {
    for (final item in node) {
      if (item == MvuEngine.extensibleMarker) features.add('constraints');
      _detectFeatures(item, features);
    }
  }
}

/// 对齐 MVU `cleanUpMetadata`。
void _cleanUpMetadata(Object? node) {
  if (node is List<Object?>) {
    for (var i = node.length - 1; i >= 0; i--) {
      final item = node[i];
      if (item == MvuEngine.extensibleMarker) {
        node.removeAt(i);
      } else if (item is Map &&
          item.containsKey(r'$arrayMeta') &&
          item.containsKey(r'$meta') &&
          item[r'$arrayMeta'] == true) {
        node.removeAt(i);
      } else {
        _cleanUpMetadata(item);
      }
    }
  } else if (node is Map<String, Object?>) {
    node.remove(r'$meta');
    for (final value in node.values) {
      _cleanUpMetadata(value);
    }
  }
}

final RegExp _initvarBlock = RegExp(
  r'<initvar>(?:\s*```[^\n]*)?([\s\S]*?)(?:```\s*)?</initvar>',
  caseSensitive: false,
);

final RegExp _zonedIso = RegExp(
  r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?(?:Z|[+-]\d{2}:?\d{2})$',
);
