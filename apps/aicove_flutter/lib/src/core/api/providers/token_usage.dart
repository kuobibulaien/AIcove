import 'dart:convert';
import 'dart:math' as math;

import '../../utils/token_estimator.dart';
import 'provider_adapter.dart' show ToolCall;

/// Normalized request usage. Input includes cache reads/writes; output includes
/// reasoning. Cache and reasoning counters are subsets, never extra charges.
class TokenUsage {
  final int inputTokens;
  final int outputTokens;
  final int cachedInputTokens;
  final int cacheWriteTokens;
  final int reasoningTokens;
  final bool isEstimated;
  final double? reportedCostUsd;

  const TokenUsage({
    required this.inputTokens,
    required this.outputTokens,
    this.cachedInputTokens = 0,
    this.cacheWriteTokens = 0,
    this.reasoningTokens = 0,
    this.isEstimated = false,
    this.reportedCostUsd,
  });

  int get uncachedInputTokens =>
      (inputTokens - cachedInputTokens - cacheWriteTokens).clamp(
        0,
        inputTokens,
      );
  int get totalTokens => inputTokens + outputTokens;
  bool get isZero => inputTokens <= 0 && outputTokens <= 0;

  TokenUsage operator +(TokenUsage other) => TokenUsage(
    inputTokens: inputTokens + other.inputTokens,
    outputTokens: outputTokens + other.outputTokens,
    cachedInputTokens: cachedInputTokens + other.cachedInputTokens,
    cacheWriteTokens: cacheWriteTokens + other.cacheWriteTokens,
    reasoningTokens: reasoningTokens + other.reasoningTokens,
    isEstimated: isEstimated || other.isEstimated,
    reportedCostUsd: reportedCostUsd != null && other.reportedCostUsd != null
        ? reportedCostUsd! + other.reportedCostUsd!
        : null,
  );

  Map<String, dynamic> toJson() => {
    'inputTokens': inputTokens,
    'outputTokens': outputTokens,
    'cachedInputTokens': cachedInputTokens,
    'cacheWriteTokens': cacheWriteTokens,
    'reasoningTokens': reasoningTokens,
    'isEstimated': isEstimated,
    if (reportedCostUsd != null) 'reportedCostUsd': reportedCostUsd,
  };

  factory TokenUsage.fromJson(Map<String, dynamic> json) => TokenUsage(
    inputTokens: _int(json['inputTokens']) ?? 0,
    outputTokens: _int(json['outputTokens']) ?? 0,
    cachedInputTokens: _int(json['cachedInputTokens']) ?? 0,
    cacheWriteTokens: _int(json['cacheWriteTokens']) ?? 0,
    reasoningTokens: _int(json['reasoningTokens']) ?? 0,
    isEstimated: json['isEstimated'] == true,
    reportedCostUsd: _parseCost(json['reportedCostUsd']),
  );

  static double? _parseCost(Object? value, {double max = double.infinity}) {
    final cost = double.tryParse('$value');
    return cost != null && cost.isFinite && cost >= 0 && cost <= max
        ? cost
        : null;
  }

  static int? _int(Object? value) {
    final number = value is num ? value : num.tryParse('$value');
    return number != null && number.isFinite
        ? math.max(0, number.toInt())
        : null;
  }

  static TokenUsage? fromOpenAiUsage(Map<String, dynamic>? usage) {
    if (usage == null) return null;
    final cost = _parseCost(usage['cost'], max: 1000);
    var prompt = _int(usage['prompt_tokens'] ?? usage['input_tokens']);
    final completion = _int(
      usage['completion_tokens'] ?? usage['output_tokens'],
    );
    final hit = _int(usage['prompt_cache_hit_tokens']);
    final miss = _int(usage['prompt_cache_miss_tokens']);
    if (prompt == null && hit != null && miss != null) prompt = hit + miss;
    if (prompt == null &&
        completion == null &&
        _int(usage['total_tokens']) == null) {
      return null;
    }
    final promptDetails =
        usage['prompt_tokens_details'] ?? usage['input_tokens_details'];
    final completionDetails =
        usage['completion_tokens_details'] ?? usage['output_tokens_details'];
    final cached =
        _int(
          (promptDetails is Map ? promptDetails['cached_tokens'] : null) ??
              usage['prompt_cache_hit_tokens'],
        ) ??
        0;
    final reasoning =
        _int(
          completionDetails is Map
              ? completionDetails['reasoning_tokens']
              : null,
        ) ??
        0;
    return TokenUsage(
      inputTokens: math.max(prompt ?? 0, cached),
      outputTokens: math.max(completion ?? 0, reasoning),
      cachedInputTokens: cached,
      reasoningTokens: reasoning,
      reportedCostUsd: cost,
    );
  }

  static TokenUsage? fromClaudeUsage(Map<String, dynamic>? usage) {
    if (usage == null) return null;
    final uncached = _int(usage['input_tokens']);
    final read = _int(usage['cache_read_input_tokens']) ?? 0;
    final write = _int(usage['cache_creation_input_tokens']) ?? 0;
    final output = _int(usage['output_tokens']);
    if (uncached == null && output == null && read == 0 && write == 0) {
      return null;
    }
    return TokenUsage(
      inputTokens: (uncached ?? 0) + read + write,
      outputTokens: output ?? 0,
      cachedInputTokens: read,
      cacheWriteTokens: write,
    );
  }

  static TokenUsage? fromGeminiUsageMetadata(Map<String, dynamic>? meta) {
    if (meta == null) return null;
    final prompt = _int(meta['promptTokenCount']);
    final tool = _int(meta['toolUsePromptTokenCount']) ?? 0;
    final cached = _int(meta['cachedContentTokenCount']) ?? 0;
    final candidates = _int(meta['candidatesTokenCount']);
    final thoughts = _int(meta['thoughtsTokenCount']) ?? 0;
    final total = _int(meta['totalTokenCount']);
    if (prompt == null && candidates == null && total == null) return null;
    var output = candidates ?? 0;
    if (thoughts > 0) {
      if ((total != null &&
              total >= (prompt ?? 0) + tool + output + thoughts) ||
          candidates == null ||
          output < thoughts) {
        output += thoughts;
      } else if (total != null && (prompt ?? 0) + output == total) {
        output = math.max(output, thoughts);
      } else {
        output += thoughts;
      }
    }
    return TokenUsage(
      inputTokens: math.max((prompt ?? 0) + tool, cached),
      outputTokens: output,
      cachedInputTokens: cached,
      reasoningTokens: thoughts,
    );
  }

  static TokenUsage estimate({
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    String outputText = '',
    String reasoningText = '',
    List<ToolCall> toolCalls = const [],
  }) {
    final input =
        messages.fold<int>(
          0,
          (sum, message) => sum + estimateMessageTokens(message),
        ) +
        (tools == null || tools.isEmpty
            ? 0
            : estimateTokenCount(jsonEncode(tools)));
    final reasoning = estimateTokenCount(reasoningText);
    final output =
        estimateTokenCount(outputText) +
        reasoning +
        toolCalls.fold<int>(
          0,
          (sum, call) =>
              sum +
              estimateTokenCount(call.name) +
              estimateTokenCount(jsonEncode(call.arguments)),
        );
    return TokenUsage(
      inputTokens: input,
      outputTokens: output,
      reasoningTokens: reasoning,
      isEstimated: true,
    );
  }
}
