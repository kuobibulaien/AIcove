import 'dart:convert';
import 'dart:math' as math;
import '../../../core/utils/token_estimator.dart';

/// 窗口是容量；提前留出输出、工具结果和估算误差的空间。
class ContextWindowPolicy {
  ContextWindowPolicy({
    required int configured,
    required int modelWindow,
    this.outputReserve = 2048,
  }) : window = math.min(configured, modelWindow);
  final int window, outputReserve;
  int get trigger =>
      math.max(1, math.min((window * .8).floor(), window - outputReserve));
  int get retain => (window * .16).floor();
}

int renderedContextTokens(
  List<Map<String, dynamic>> messages,
  List<Map<String, dynamic>>? tools,
) =>
    messages.fold(
      0,
      (sum, m) =>
          sum +
          estimateMessageTokens(m) +
          estimateTokenCount(
            jsonEncode(
              Map<String, dynamic>.of(m)
                ..remove('content')
                ..remove('role'),
            ),
          ),
    ) +
    estimateTokenCount(jsonEncode(tools ?? []));

bool isContextOverflow(Object error) {
  final text = error.toString().toLowerCase();
  return text.contains('context_length_exceeded') ||
      text.contains('maximum context length') ||
      text.contains('context window exceeded') ||
      text.contains('prompt is too long') ||
      text.contains('input token limit') ||
      text.contains('too many tokens') ||
      text.contains('exceeds the context') ||
      text.contains('上下文超限');
}
