import 'dart:async';

import 'package:aicove_agent_kernel/aicove_agent_kernel.dart'
    show KernelCancellation;

import '../../../core/api/providers/provider_adapter.dart'
    show ProviderChatRequestOptions;
import '../../agent_plugins/tool_policy.dart' show redactorForCredentials;
import '../../background_agent/background_agent_service.dart';
import '../../chat/services/api_runner.dart';
import '../../chat/services/chat_types.dart';
import '../../settings/app_settings.dart';

/// One model call requested by a workspace web page (ADR0109).
class WebAppAiRequest {
  const WebAppAiRequest({
    required this.messages,
    this.temperature,
    this.maxTokens,
  });

  static const maxBodyBytes = 1 << 20;
  static const maxMessages = 200;
  static const _roles = {'system', 'user', 'assistant'};

  final List<Map<String, String>> messages;
  final double? temperature;
  final int? maxTokens;

  /// Validates the decoded request body; throws [WebAppAiException].
  factory WebAppAiRequest.fromJson(Object? body) {
    const invalid = WebAppAiException('bad_request', '请求格式不对');
    if (body is! Map) throw invalid;
    final raw = body['messages'];
    if (raw is! List || raw.isEmpty || raw.length > maxMessages) {
      throw const WebAppAiException(
        'bad_request',
        'messages 必须是 1～$maxMessages 条消息',
      );
    }
    final messages = <Map<String, String>>[];
    for (final item in raw) {
      if (item is! Map ||
          !_roles.contains(item['role']) ||
          item['content'] is! String) {
        throw const WebAppAiException(
          'bad_request',
          '每条消息须有 role（system／user／assistant）和字符串 content',
        );
      }
      messages.add({
        'role': item['role'] as String,
        'content': item['content'] as String,
      });
    }
    if (messages.every((message) => message['role'] == 'system')) {
      throw const WebAppAiException('bad_request', '至少要有一条 user 或 assistant 消息');
    }
    final temperature = body['temperature'];
    if (temperature != null &&
        (temperature is! num || temperature < 0 || temperature > 2)) {
      throw const WebAppAiException('bad_request', 'temperature 须在 0～2 之间');
    }
    final maxTokens = body['max_tokens'];
    if (maxTokens != null && (maxTokens is! int || maxTokens < 1)) {
      throw const WebAppAiException('bad_request', 'max_tokens 须是正整数');
    }
    return WebAppAiRequest(
      messages: messages,
      temperature: (temperature as num?)?.toDouble(),
      maxTokens: maxTokens as int?,
    );
  }

  /// OpenAI chat-completions body, for third-party pages that only speak that
  /// format. `model` is ignored; `developer` is treated as `system`; content
  /// may be text parts but nothing else.
  factory WebAppAiRequest.fromOpenAi(Object? body) {
    if (body is! Map) throw const WebAppAiException('bad_request', '请求格式不对');
    final raw = body['messages'];
    return WebAppAiRequest.fromJson({
      'messages': raw is! List
          ? raw
          : [
              for (final item in raw)
                if (item is! Map)
                  item
                else
                  {
                    'role': item['role'] == 'developer'
                        ? 'system'
                        : item['role'],
                    'content': _openAiText(item['content']),
                  },
            ],
      'temperature': body['temperature'],
      'max_tokens': body['max_completion_tokens'] ?? body['max_tokens'],
    });
  }

  static Object? _openAiText(Object? content) {
    if (content is! List) return content;
    final text = StringBuffer();
    for (final part in content) {
      if (part is! Map || part['type'] != 'text' || part['text'] is! String) {
        throw const WebAppAiException('bad_request', '只支持文字消息');
      }
      text.write(part['text']);
    }
    return text.toString();
  }
}

class WebAppAiException implements Exception {
  const WebAppAiException(this.code, this.message);
  final String code;
  final String message;
  @override
  String toString() => message;
}

typedef WebAppAiChat = Future<String> Function(WebAppAiRequest request);
typedef WebAppAiExecutor =
    Future<ApiCallResult> Function({required ApiConfig config});

/// Calls the user's default chat model with the stored channel key. Every
/// message returned to the page passes the credential redactor.
WebAppAiChat createWebAppAiChat({
  required Future<AppSettings> Function() loadSettings,
  WebAppAiExecutor? executor,
  ResolveBackgroundAgentRequestConfig? requestConfig,
}) {
  final execute = executor ?? _defaultExecutor;
  final resolve = requestConfig ?? BackgroundAgentService.resolveRequestConfig;
  return (request) async {
    final settings = await loadSettings();
    final redactor = redactorForCredentials(settings: settings);
    final model = settings.defaultChatModels.isNotEmpty
        ? settings.defaultChatModels.first
        : settings.defaultModelName;
    if (model.trim().isEmpty ||
        settings.getModelProviderId(model.trim()) == null) {
      throw const WebAppAiException('no_model', 'AIcove 还没有配置默认聊天模型');
    }
    final resolved = await resolve(settings: settings, modelRef: model);
    final cancellation = KernelCancellation();
    final config = ApiConfig(
      settings: settings,
      modelFullId: resolved.modelFullId,
      providerApiBase: resolved.providerApiBase,
      providerApiKey: resolved.providerApiKey,
      customConfig: resolved.customConfig,
      messages: [
        for (final message in request.messages)
          Map<String, dynamic>.of(message),
      ],
      modelTemperature: request.temperature ?? resolved.modelTemperature,
      modelTopP: resolved.modelTopP,
      providerRequestOptions: request.maxTokens == null
          ? null
          : ProviderChatRequestOptions(maxOutputTokens: request.maxTokens),
      cancellation: cancellation,
    );
    final timeout = Duration(
      seconds: settings.callFlowSettings.modelTimeoutSeconds,
    );
    ApiCallResult result;
    try {
      result = await execute(config: config).timeout(timeout);
    } on TimeoutException {
      cancellation.cancel();
      throw WebAppAiException(
        'model_failed',
        '模型超过 ${timeout.inSeconds} 秒没有回复',
      );
    } on WebAppAiException {
      rethrow;
    } catch (error) {
      throw WebAppAiException('model_failed', redactor.redact('$error'));
    }
    if (result.status == ApiRunStatus.failed ||
        result.status == ApiRunStatus.cancelled) {
      throw WebAppAiException(
        'model_failed',
        redactor.redact(result.stopReason ?? '模型调用失败'),
      );
    }
    final text = result.processedText.trim().isNotEmpty
        ? result.processedText
        : result.replyText;
    if (text.trim().isEmpty) {
      throw const WebAppAiException('model_failed', '模型没有返回正文');
    }
    return redactor.redact(text);
  };
}

Future<ApiCallResult> _defaultExecutor({required ApiConfig config}) =>
    createApiRunner().executeApiCall(
      config: config,
      sessionId: 'webapp_ai_${DateTime.now().millisecondsSinceEpoch}',
      userText: null,
      responseProcessors: const [],
      availableTools: const [],
    );
