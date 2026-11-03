import '../../../core/services/system_reminder_service.dart';
import '../../chat/domain/message.dart';
import '../../chat/services/chat_send_service.dart';
import '../../chat/application/conversation_model.dart';
import '../../chat/domain/conversation.dart';
import '../../settings/app_settings.dart';

const SystemReminderService _systemReminderService = SystemReminderService();

/// cachedContent 视为「新鲜」的最大年龄。
/// 决策（2026-06-13）：短延迟触发器直接发预生成缓存；超过该年龄的缓存
/// 降级为兜底文案，到点优先即时生成，避免长延迟后发送过时语境。
/// 2026-10-13 起 AI 调度的触发器把 preparedAt 记为计划发送时间（文案按那一刻
/// 写成），所以按时发送都算新鲜，只有实际发送比计划晚超过该时长才重写。
const Duration autoReplyCachedContentMaxAge = Duration(minutes: 60);

/// 判断预生成缓存在 [now] 时刻是否仍然新鲜（可直接发送）。
bool isCachedAutoReplyContentFresh({
  required DateTime? preparedAt,
  required DateTime now,
  Duration maxAge = autoReplyCachedContentMaxAge,
}) {
  if (preparedAt == null) return false;
  final age = now.difference(preparedAt);
  if (age.isNegative) return true;
  return age <= maxAge;
}

/// 主动回复用目标会话自己的聊天模型（会话选过的 > 默认队列首位）。
String resolveAutoReplyAgentModelRef(
  AppSettings settings,
  Conversation conversation,
) =>
    conversationPrimaryModel(settings, conversation);

List<Message> buildAutoReplyAgentContextMessages({
  required List<Message> messages,
  required String? systemReminder,
}) {
  final normalized = <Message>[
    for (final message in messages) message,
  ];
  final trimmedReminder = systemReminder?.trim() ?? '';
  if (trimmedReminder.isEmpty) {
    return normalized;
  }

  final reminderMessage = Message.text(
    id: 'system_reminder_${DateTime.now().millisecondsSinceEpoch}',
    role: 'user',
    content: _systemReminderService.wrapReminderContent(trimmedReminder),
    createdAt: _resolveReminderMessageTime(normalized),
  );

  normalized.add(reminderMessage);
  return normalized;
}

DateTime _resolveReminderMessageTime(List<Message> messages) {
  final now = DateTime.now();
  if (messages.isEmpty) return now;
  final lastCreatedAt = messages.last.createdAt;
  if (now.isAfter(lastCreatedAt)) return now;
  return lastCreatedAt.add(const Duration(milliseconds: 1));
}

/// Proactive generation keeps raw text; response plugins belong to delivery.
ApiConfig disableNativeToolCallsForAutoReplyGeneration(
  ApiConfig config, {
  double defaultTemperature = 0.7,
}) {
  return config.copyWith(
    clearTools: true,
    responseProcessors: const [],
    modelTemperature: config.modelTemperature ?? defaultTemperature,
  );
}

// ApiCallResult already defaults omitted raw text for legacy callers. An
// explicitly empty raw reply must not resurrect display-only text or tags.
String selectCacheableAutoReplyText(ApiCallResult result) =>
    result.rawReplyText.trim();

ApiConfig appendAutoReplyReminderAsLastUser(
  ApiConfig config,
  String? reminderContent,
) {
  final trimmedReminder = reminderContent?.trim() ?? '';
  if (trimmedReminder.isEmpty) {
    return config;
  }
  final messagesWithReminder = _systemReminderService.appendReminderAsLastUser(
    messages: config.messages,
    reminderContent: trimmedReminder,
  );
  final normalizedMessages =
      _systemReminderService.ensureReminderSemanticsPrompt(
    messages: messagesWithReminder,
  );
  return config.copyWith(messages: normalizedMessages);
}
