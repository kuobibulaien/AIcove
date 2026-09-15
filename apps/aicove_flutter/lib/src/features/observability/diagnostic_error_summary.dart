import 'dart:async';
import 'package:flutter/services.dart';

/// 错误细节采用允许列表，避免自由文本夹带聊天正文、请求体或设备路径。
/// 完整有界代码栈单独保存；不调用未知异常的 toString（其本身也可能抛错）。
Map<String, Object?> diagnosticErrorSummary(Object error, StackTrace? stack) {
  String summary = 'free_form_message_omitted';
  if (error is TimeoutException) {
    summary = 'timeout';
  } else if (error is StateError &&
      const {
        'No element',
        'Too many elements',
        'Future already completed',
        'Cannot add new events after calling close',
      }.contains(error.message)) {
    summary = error.message;
  } else if (error is RangeError) {
    summary = 'range_error';
  } else if (error is PlatformException &&
      RegExp(r'^[a-zA-Z_][a-zA-Z0-9_]{0,47}$').hasMatch(error.code)) {
    summary = 'platform:${error.code}';
  }
  final locations = stack == null
      ? <String>[]
      : RegExp(r'(?:package:|dart:)[^\s)]+')
          .allMatches(stack.toString())
          .map((m) => m.group(0)!)
          .toList();
  return {
    'errorType': error.runtimeType.toString(),
    'errorSummary': summary,
    'errorMessageOmitted': summary == 'free_form_message_omitted',
    if (error is TimeoutException && error.duration != null)
      'timeoutMs': error.duration!.inMilliseconds,
    if (error is RangeError) ...{
      'rangeStart': error.start,
      'rangeEnd': error.end,
    },
    if (stack != null) ...{
      'codeLocations': locations
          .take(64)
          .map((s) => s.length > 512 ? s.substring(0, 512) : s)
          .toList(),
      'stackTruncated':
          locations.length > 64 || locations.any((s) => s.length > 512),
      'stackNonCodeFramesOmitted': true,
    },
  };
}
