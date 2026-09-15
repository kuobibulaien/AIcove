/// 模型思考档位（reasoning effort / thinking budget）的统一领域模型。
///
/// 持久层与 UI 只使用 [ThinkingLevel] 的 canonical 值；上游字段名与数值
/// 由各 ProviderAdapter 按 [ThinkingScheme] 翻译。
library;

/// 统一档位。序号即强弱顺序，`auto` 表示不发任何 thinking 参数。
enum ThinkingLevel {
  auto,
  off,
  minimal,
  low,
  medium,
  high,
  xhigh,
  max;

  String get storageValue => name;

  static ThinkingLevel? tryParse(Object? raw) {
    if (raw is ThinkingLevel) return raw;
    final text = raw?.toString().trim().toLowerCase();
    if (text == null || text.isEmpty) return null;
    for (final level in values) {
      if (level.name == text) return level;
    }
    return switch (text) {
      'none' || 'disabled' || 'disable' => ThinkingLevel.off,
      'auto' || 'default' => ThinkingLevel.auto,
      _ => null,
    };
  }

  bool get isAuto => this == ThinkingLevel.auto;
  bool get isOff => this == ThinkingLevel.off;
}

/// 上游参数方案。
enum ThinkingScheme {
  /// OpenAI 兼容 `reasoning_effort` 原生枚举。
  openaiEffort,

  /// Claude 4.6+ `output_config.effort`。
  claudeEffort,

  /// Claude 4.5 及更早 `thinking.budget_tokens`。
  claudeBudget,

  /// Gemini 3.x `thinkingConfig.thinkingLevel`。
  geminiLevel,

  /// Gemini 2.5 `thinkingConfig.thinkingBudget`。
  geminiBudget,

  /// 未识别的 OpenAI 兼容模型：四档，翻译为 `reasoning_effort`。
  generic,
}

/// 某个模型可用的档位集合。
class ThinkingLevelOptions {
  final ThinkingScheme scheme;

  /// 始终以 [ThinkingLevel.auto] 开头，其余按序号升序。
  final List<ThinkingLevel> levels;

  /// true 表示直接展示上游原生档位；false 表示自研四档。
  final bool isNative;

  const ThinkingLevelOptions({
    required this.scheme,
    required this.levels,
    required this.isNative,
  });

  bool supports(ThinkingLevel level) => levels.contains(level);

  /// 软件默认档位：能关就关，不能关取最低档；generic 方案无法确认上游
  /// 是否接受 `none`，因此保持 auto。
  ThinkingLevel get softwareDefault {
    if (scheme == ThinkingScheme.generic) return ThinkingLevel.auto;
    if (supports(ThinkingLevel.off)) return ThinkingLevel.off;
    for (final level in levels) {
      if (!level.isAuto) return level;
    }
    return ThinkingLevel.auto;
  }

  /// 把请求的档位收敛到本集合内：同名直接用；`off` 不可用取最低档；
  /// 其余取序号距离最近者，同距离取更高档。
  ThinkingLevel coerce(ThinkingLevel requested) {
    if (requested.isAuto || supports(requested)) return requested;
    final candidates = levels.where((l) => !l.isAuto).toList();
    if (candidates.isEmpty) return ThinkingLevel.auto;
    if (requested.isOff) return candidates.first;
    ThinkingLevel best = candidates.first;
    var bestDistance = (best.index - requested.index).abs();
    for (final candidate in candidates.skip(1)) {
      final distance = (candidate.index - requested.index).abs();
      if (distance < bestDistance ||
          (distance == bestDistance && candidate.index > best.index)) {
        best = candidate;
        bestDistance = distance;
      }
    }
    return best;
  }
}
