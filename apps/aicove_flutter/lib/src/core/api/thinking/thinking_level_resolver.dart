import 'thinking_level.dart';
import 'thinking_level_catalog.dart';
import 'thinking_level_labels.dart';

/// 生效档位及其来源。
class EffectiveThinkingLevel {
  final ThinkingLevel level;
  final ThinkingLevelSource source;
  final ThinkingLevelOptions options;

  const EffectiveThinkingLevel({
    required this.level,
    required this.source,
    required this.options,
  });
}

/// 优先级：会话覆盖 > 模型默认 > 预设 > 软件默认（prd R1.3 / R1.5）。
/// 显式来源的档位会先按模型可用集合收敛（R2.4）。
EffectiveThinkingLevel resolveEffectiveThinkingLevel({
  required String providerType,
  required String modelId,
  ThinkingLevel? sessionLevel,
  ThinkingLevel? modelDefaultLevel,
  String? presetReasoningEffort,
}) {
  final options = resolveThinkingOptions(
    providerType: providerType,
    modelId: modelId,
  );
  if (sessionLevel != null) {
    return EffectiveThinkingLevel(
      level: options.coerce(sessionLevel),
      source: ThinkingLevelSource.session,
      options: options,
    );
  }
  if (modelDefaultLevel != null) {
    return EffectiveThinkingLevel(
      level: options.coerce(modelDefaultLevel),
      source: ThinkingLevelSource.model,
      options: options,
    );
  }
  final preset = ThinkingLevel.tryParse(presetReasoningEffort);
  if (preset != null && !preset.isAuto) {
    return EffectiveThinkingLevel(
      level: options.coerce(preset),
      source: ThinkingLevelSource.preset,
      options: options,
    );
  }
  return EffectiveThinkingLevel(
    level: options.softwareDefault,
    source: ThinkingLevelSource.softwareDefault,
    options: options,
  );
}
