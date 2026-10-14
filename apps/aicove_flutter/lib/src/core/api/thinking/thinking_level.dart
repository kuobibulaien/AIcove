/// 模型思考档位（reasoning effort / thinking budget）的统一领域模型。
///
/// 持久层与 UI 只使用 [ThinkingLevel] 的 canonical 值；上游字段名与数值
/// 由各 ProviderAdapter 按 [ThinkingScheme] 翻译。
library;

/// 统一档位。序号即强弱顺序，`auto` 表示不发任何 thinking 参数。
///
/// `lowest` 不对应固定的上游值：请求时按 [ThinkingLevelOptions.lowestCandidates]
/// 依次尝试（关 → minimal → low），上游拒绝就换下一档，成功的档位按
/// 「渠道 + 模型」记住（见 `thinking_fallback_memory.dart`）。
enum ThinkingLevel {
  auto,
  lowest,
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
  bool get isLowest => this == ThinkingLevel.lowest;
  bool get isOff => this == ThinkingLevel.off;

  /// 是否会让 adapter 写出具体的上游参数。`lowest` 需先展开成候选档。
  bool get isConcrete => !isAuto && !isLowest;
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

  /// OpenAI 兼容接口上用 `thinking.type` 开关思考的模型（DeepSeek、GLM、
  /// Kimi、豆包、混元等）；思考强度仍走 `reasoning_effort`。
  thinkingToggle,

  /// 通义千问：`enable_thinking` 布尔开关。
  qwenToggle,

  /// 未识别的 OpenAI 兼容模型：四档，翻译为 `reasoning_effort`。
  generic,
}

/// 某个模型可用的档位集合。
class ThinkingLevelOptions {
  final ThinkingScheme scheme;

  /// 上游真实可用的档位：始终以 [ThinkingLevel.auto] 开头，其余按序号升序，
  /// 不含 [ThinkingLevel.lowest]。
  final List<ThinkingLevel> levels;

  /// true 表示直接展示上游原生档位；false 表示自研四档。
  final bool isNative;

  const ThinkingLevelOptions({
    required this.scheme,
    required this.levels,
    required this.isNative,
  });

  bool supports(ThinkingLevel level) =>
      level.isLowest || levels.contains(level);

  /// 界面可选项：跟随上游、最低，然后是上游档位。
  List<ThinkingLevel> get choices => [
        ThinkingLevel.auto,
        ThinkingLevel.lowest,
        for (final level in levels)
          if (!level.isAuto) level,
      ];

  /// 「最低」档依次尝试的上游档位：能关就关，关不了取 minimal，再不行取 low。
  /// 三档都不在表里时取最低的可用档。调用方在末尾再补一次「不发参数」兜底。
  List<ThinkingLevel> get lowestCandidates {
    final candidates = [
      for (final level in levels)
        if (level.index <= ThinkingLevel.low.index && level.isConcrete) level,
    ];
    if (candidates.isNotEmpty) return candidates;
    final concrete = levels.where((l) => l.isConcrete);
    return concrete.isEmpty ? const [] : [concrete.first];
  }

  /// 软件默认档位：最低档（角色扮演聊天基本不需要思考，2026-10-13 用户裁决）。
  ThinkingLevel get softwareDefault => ThinkingLevel.lowest;

  /// 把请求的档位收敛到本集合内：同名直接用；`off` 不可用取最低档；
  /// 其余取序号距离最近者，同距离取更高档。
  ThinkingLevel coerce(ThinkingLevel requested) {
    if (!requested.isConcrete || supports(requested)) return requested;
    final candidates = levels.where((l) => l.isConcrete).toList();
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
