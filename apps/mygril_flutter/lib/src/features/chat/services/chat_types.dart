/// 聊天辅助数据类型
/// 
/// 从 chat_actions.dart 提取的内部数据类，改为公开类型以便服务间共享。
/// 
/// 更新记录：
/// - 2025-12-31: 从 chat_actions.dart 提取
library;

import 'dart:async';
import '../domain/message.dart';

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
  final List<Message> messages;
  final String lastMessageText;

  const AssistantMessageBuildResult({
    required this.messages,
    required this.lastMessageText,
  });
}
