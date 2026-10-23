import '../../../core/api/tool_media.dart';
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
    messages.fold(0, (sum, m) {
      final content = m['content'];
      final native =
          m.containsKey('parts') ||
          content is Map ||
          (content is List &&
              content.whereType<Map>().any(
                (p) => p['type'] == 'tool_result' || p['type'] == 'tool_use',
              ));
      if (native) return sum + estimateTokenCount(jsonEncode(ToolMedia.log(m)));
      return sum +
          estimateMessageTokens(m) +
          estimateTokenCount(
            jsonEncode(
              Map<String, dynamic>.of(m)
                ..remove('content')
                ..remove('role'),
            ),
          );
    }) +
    estimateTokenCount(jsonEncode(tools ?? []));

/// 后台模型（压缩、记忆整理）请求的输出上限。推理模型的思考也计入输出，
/// 给窗口的 1/4，最多 [kMaxOutputTokens]；服务商嫌大时逐次减半，
/// 不低于 [kSafeOutputTokens]（常见模型都接受）。
const kMaxOutputTokens = 128000;
const kSafeOutputTokens = 8192;

int backgroundOutputTokens(
  int contextTokens, {
  int ceiling = kMaxOutputTokens,
}) => (contextTokens ~/ 4).clamp(2048, ceiling);

/// 服务商拒绝了输出上限（超过模型允许的最大输出）。
bool isOutputLimitRejected(Object error) {
  final text = error.toString().toLowerCase();
  return !isContextOverflow(error) &&
      (text.contains('max_tokens') ||
          text.contains('max_output_tokens') ||
          text.contains('max_completion_tokens') ||
          text.contains('maxoutputtokens'));
}

/// 被拒绝后的下一个上限；已到安全值时返回 null，不再重试。
int? reducedOutputCeiling(int current) =>
    current > kSafeOutputTokens
        ? math.max(kSafeOutputTokens, current ~/ 2)
        : null;

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
