/// 聊天辅助数据类型
///
/// 从 chat_actions.dart 提取的内部数据类，改为公开类型以便服务间共享
///
/// 更新记录：
/// - 2025-12-31: 从 chat_actions.dart 提取
library;

import 'dart:async';
import '../domain/conversation.dart';
import '../domain/message.dart';
import '../../plugins/domain/plugin.dart';
import '../../plugins/domain/plugin_content.dart';
import '../../settings/app_settings.dart';
import '../../../core/api/providers/provider_adapter.dart'
    show ToolCall, ToolResult;
import '../../observability/trace_models.dart' show TraceContext;

const String _kProviderRefreshDependencyChangedMessage =
    'Cannot use ref functions after the dependency of a provider changed';
const String _kProviderRefreshRebuiltMessage = 'before the provider rebuilt';
const String _kProviderRefreshDidChangeDependencyToken =
    '!_didChangeDependency';

/// 是否命中了 Riverpod 依赖切换窗口的瞬时错误。
///
/// 当前 Riverpod 没有暴露稳定的专用异常类型，这里统一收敛为：
/// 1) 标准 ref/dependency changed 文案
/// 2) `!_didChangeDependency` 断言变体
///
/// 这样至少可以把运行时的字符串识别集中到一处，避免多份判断漂移。
bool isProviderRefreshTimingError(Object error) {
  final normalized = error.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
  if (normalized.isEmpty) {
    return false;
  }
  if (normalized.contains(_kProviderRefreshDependencyChangedMessage) &&
      normalized.contains(_kProviderRefreshRebuiltMessage)) {
    return true;
  }
  return normalized.contains(_kProviderRefreshDidChangeDependencyToken);
}

/// 发送请求参数数据类
class SendRequest {
  final Conversation conversation;
  final String? text;
  final String? imagePath;
  final Message userMessage;

  const SendRequest({
    required this.conversation,
    this.text,
    this.imagePath,
    required this.userMessage,
  });

  String get convId => conversation.id;
  String get displayText => text ?? (imagePath != null ? '[图片]' : '');
}

/// 工具音频结果
class ToolAudioResult {
  final String audioUrl;
  final String text;

  const ToolAudioResult({required this.audioUrl, required this.text});
}

/// API 调用结果
class ApiCallResult {
  final String rawReplyText;
  final String replyText;
  final String processedText;
  final List<Map<String, dynamic>> hiddenThoughtParts;
  final List<PluginEvent> pluginEvents;
  final List<PluginContent> pluginContents;
  final List<Map<String, dynamic>> toolResults;
  final List<ToolAudioResult> toolAudioResults;
  final List<ToolCall> toolCalls;
  final List<ToolResult> rawToolResults;

  const ApiCallResult({
    String? rawReplyText,
    required this.replyText,
    required this.processedText,
    this.hiddenThoughtParts = const [],
    required this.pluginEvents,
    this.pluginContents = const [],
    required this.toolResults,
    this.toolAudioResults = const [],
    this.toolCalls = const [],
    this.rawToolResults = const [],
  }) : rawReplyText = rawReplyText ?? replyText;

  bool get hasToolAudio => toolAudioResults.isNotEmpty;
}

/// API 配置参数
class ApiConfig {
  final AppSettings settings;
  final String modelFullId;
  final String providerApiBase;
  final String? providerApiKey;
  final Map<String, dynamic> customConfig;
  final Map<String, dynamic> toolPrefs;
  final List<Map<String, dynamic>> messages;
  final List<Map<String, dynamic>>? tools;
  final Set<String>? enabledPluginIds;
  final double? modelTemperature;
  final double? modelTopP;
  final int? modelContextMessageLimit;
  final TraceContext? traceContext;
  final String? boundImageToolPresetName;
  final String? boundImageArtistPresetName;

  const ApiConfig({
    required this.settings,
    required this.modelFullId,
    required this.providerApiBase,
    this.providerApiKey,
    required this.customConfig,
    required this.toolPrefs,
    required this.messages,
    this.tools,
    this.enabledPluginIds,
    this.modelTemperature,
    this.modelTopP,
    this.modelContextMessageLimit,
    this.traceContext,
    this.boundImageToolPresetName,
    this.boundImageArtistPresetName,
  });

  double? get effectiveTemperature => modelTemperature ?? settings.temperature;
}

/// 待处理的 TTS 音频信息
class PendingTtsAudio {
  final String convId;
  final String placeholderId;
  final String? originalText;
  final Completer<TtsAudioResult> completer;

  PendingTtsAudio({
    required this.convId,
    required this.placeholderId,
    this.originalText,
    required this.completer,
  });
}

/// TTS 音频处理结果
class TtsAudioResult {
  final Message? message;
  final bool success;
  final String? error;

  const TtsAudioResult.success(this.message)
      : success = true,
        error = null;

  const TtsAudioResult.failure([this.error])
      : success = false,
        message = null;
}

/// 助手消息交付结果
class AssistantDeliveryResult {
  final List<Message> messages;
  final String lastMessagePreview;
  final String? placeholderId;

  const AssistantDeliveryResult({
    required this.messages,
    required this.lastMessagePreview,
    this.placeholderId,
  });
}

/// 助手消息构建结果
class AssistantMessageBuildResult {
  final Message? rawMessage;
  final List<Message> messages;
  final String lastMessageText;

  const AssistantMessageBuildResult({
    this.rawMessage,
    required this.messages,
    required this.lastMessageText,
  });
}
