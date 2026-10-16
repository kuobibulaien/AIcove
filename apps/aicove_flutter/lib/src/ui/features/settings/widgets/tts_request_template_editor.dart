import 'dart:convert';

import 'package:flutter/material.dart';

import '../../../../features/plugins/tts/tts_request_format.dart';
import 'provider_extra_body_editor.dart';

/// 编辑自定义 REST 语音渠道的请求模板；返回 null 表示取消。
Future<Map<String, dynamic>?> showTtsRequestTemplateEditor(
  BuildContext context,
  Map<String, dynamic> customConfig,
) {
  final current = customConfig[TtsRequestFormat.customRestTemplateKey];
  return showJsonObjectEditor(
    context,
    title: '请求模板',
    description:
        '向「基础 URL + path」发送 POST，响应须是音频。可用占位符：'
        '{text} 文本、{voice} 音色 ID、{model} 模型、{speed} 语速、{apiKey} 密钥（仅请求头）。'
        '默认带 Authorization: Bearer 密钥。',
    hintText: '{"path": "/audio/speech", "body": {"input": "{text}"}}',
    initialText: const JsonEncoder.withIndent('  ').convert(
      current is Map ? current : TtsRequestFormat.defaultCustomRestTemplate,
    ),
    parse: TtsRequestFormat.parseCustomRestTemplate,
    fieldKey: const ValueKey('tts-request-template-json'),
  );
}
