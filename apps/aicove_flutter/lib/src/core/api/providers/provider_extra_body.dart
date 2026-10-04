/// 渠道级额外请求参数（extra body）
///
/// 用户在渠道里填写一段 JSON 对象，聊天请求组装完成后浅合并到请求体顶层，
/// 用于供应商要求的非标准字段（例如 Echo 的 `persona`）。
library;

import 'dart:convert';

const kProviderExtraBodyField = 'extraBody';

/// 读取渠道配置里的额外请求参数；不存在或格式不对时返回空表。
Map<String, dynamic> providerExtraBody(Map<String, dynamic>? customConfig) {
  final raw = customConfig?[kProviderExtraBodyField];
  if (raw is! Map) return const <String, dynamic>{};
  return Map<String, dynamic>.from(raw);
}

/// 把额外参数合并到已组装好的请求体顶层，同名字段以用户填写为准。
void applyProviderExtraBody(
  Map<String, dynamic> body,
  Map<String, dynamic>? customConfig,
) {
  final extra = providerExtraBody(customConfig);
  if (extra.isEmpty) return;
  body.addAll(extra);
}

/// 解析用户输入；空白视为清空。非 JSON 对象时抛出 [FormatException]。
Map<String, dynamic> parseProviderExtraBody(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return const <String, dynamic>{};
  final Object? decoded;
  try {
    decoded = jsonDecode(trimmed);
  } on FormatException {
    throw const FormatException('不是有效的 JSON');
  }
  if (decoded is! Map) {
    throw const FormatException('需要填写 JSON 对象，例如 {"persona": "鲁迅"}');
  }
  return Map<String, dynamic>.from(decoded);
}

String formatProviderExtraBody(Map<String, dynamic>? customConfig) {
  final extra = providerExtraBody(customConfig);
  if (extra.isEmpty) return '';
  return const JsonEncoder.withIndent('  ').convert(extra);
}

Map<String, dynamic> copyCustomConfigWithProviderExtraBody(
  Map<String, dynamic> customConfig,
  Map<String, dynamic> extraBody,
) {
  final next = Map<String, dynamic>.from(customConfig);
  if (extraBody.isEmpty) {
    next.remove(kProviderExtraBodyField);
  } else {
    next[kProviderExtraBodyField] = extraBody;
  }
  return next;
}
