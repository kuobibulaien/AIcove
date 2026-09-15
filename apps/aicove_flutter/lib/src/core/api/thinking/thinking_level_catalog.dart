import 'thinking_level.dart';

/// 按「供应商类型 + 模型 id」静态决定档位方案（design.md §1）。
///
/// 未命中一律退到该供应商的兜底方案，宁可保守也不报错。
ThinkingLevelOptions resolveThinkingOptions({
  required String providerType,
  required String modelId,
}) {
  final provider = providerType.trim().toLowerCase();
  final model = modelId.trim().toLowerCase();
  return switch (provider) {
    'claude' || 'anthropic' => _resolveClaude(model),
    'gemini' || 'google' => _resolveGemini(model),
    _ => _resolveOpenAiCompatible(model),
  };
}

const _auto = ThinkingLevel.auto;
const _off = ThinkingLevel.off;
const _minimal = ThinkingLevel.minimal;
const _low = ThinkingLevel.low;
const _medium = ThinkingLevel.medium;
const _high = ThinkingLevel.high;
const _xhigh = ThinkingLevel.xhigh;
const _max = ThinkingLevel.max;

final _gpt5Xhigh = RegExp(r'gpt-5\.([2-9]|\d{2,})|gpt-5\.1-codex-max|gpt-5\.\d+-codex');
final _gpt51 = RegExp(r'gpt-5\.1(?!-codex)');
final _gpt5Base = RegExp(r'gpt-5(?![\.\d])');
final _oSeries = RegExp(r'(^|[^a-z0-9])o[134](-|$)');

ThinkingLevelOptions _resolveOpenAiCompatible(String model) {
  if (_gpt5Xhigh.hasMatch(model)) {
    return const ThinkingLevelOptions(
      scheme: ThinkingScheme.openaiEffort,
      levels: [_auto, _off, _low, _medium, _high, _xhigh],
      isNative: true,
    );
  }
  if (_gpt51.hasMatch(model)) {
    return const ThinkingLevelOptions(
      scheme: ThinkingScheme.openaiEffort,
      levels: [_auto, _off, _low, _medium, _high],
      isNative: true,
    );
  }
  if (_gpt5Base.hasMatch(model)) {
    return const ThinkingLevelOptions(
      scheme: ThinkingScheme.openaiEffort,
      levels: [_auto, _minimal, _low, _medium, _high],
      isNative: true,
    );
  }
  if (_oSeries.hasMatch(model)) {
    return const ThinkingLevelOptions(
      scheme: ThinkingScheme.openaiEffort,
      levels: [_auto, _low, _medium, _high],
      isNative: true,
    );
  }
  return const ThinkingLevelOptions(
    scheme: ThinkingScheme.generic,
    levels: [_auto, _off, _low, _medium, _high],
    isNative: false,
  );
}

final _claudeAlwaysOn = RegExp(r'fable-5|mythos');
final _claudeEffortFull = RegExp(r'opus-5|opus-4-[78]|sonnet-5');
final _claudeEffort46 = RegExp(r'opus-4-6|sonnet-4-6');

ThinkingLevelOptions _resolveClaude(String model) {
  if (_claudeAlwaysOn.hasMatch(model)) {
    return const ThinkingLevelOptions(
      scheme: ThinkingScheme.claudeEffort,
      levels: [_auto, _low, _medium, _high, _xhigh, _max],
      isNative: true,
    );
  }
  if (_claudeEffortFull.hasMatch(model)) {
    return const ThinkingLevelOptions(
      scheme: ThinkingScheme.claudeEffort,
      levels: [_auto, _off, _low, _medium, _high, _xhigh, _max],
      isNative: true,
    );
  }
  if (_claudeEffort46.hasMatch(model)) {
    return const ThinkingLevelOptions(
      scheme: ThinkingScheme.claudeEffort,
      levels: [_auto, _off, _low, _medium, _high, _max],
      isNative: true,
    );
  }
  return const ThinkingLevelOptions(
    scheme: ThinkingScheme.claudeBudget,
    levels: [_auto, _off, _low, _medium, _high],
    isNative: false,
  );
}

final _gemini3Pro = RegExp(r'gemini-3(\.\d+)?-pro');
final _gemini3 = RegExp(r'gemini-3');

ThinkingLevelOptions _resolveGemini(String model) {
  if (_gemini3Pro.hasMatch(model)) {
    return const ThinkingLevelOptions(
      scheme: ThinkingScheme.geminiLevel,
      levels: [_auto, _low, _medium, _high],
      isNative: true,
    );
  }
  if (_gemini3.hasMatch(model)) {
    return const ThinkingLevelOptions(
      scheme: ThinkingScheme.geminiLevel,
      levels: [_auto, _minimal, _low, _medium, _high],
      isNative: true,
    );
  }
  return const ThinkingLevelOptions(
    scheme: ThinkingScheme.geminiBudget,
    levels: [_auto, _off, _low, _medium, _high],
    isNative: false,
  );
}
