import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../chat/domain/conversation.dart';
import '../../chat/domain/message.dart';
import '../../chat/services/chat_send_service.dart';
import '../../settings/app_settings.dart';
import 'auto_reply_agent_helpers.dart';
import 'auto_reply_trigger.dart';
import 'auto_reply_trigger_storage.dart';

final proactiveMessagePregeneratorProvider =
    Provider((ref) => ProactiveMessagePregenerator(ref));

class ProactiveMessagePregenerator {
  ProactiveMessagePregenerator(this._ref);

  final Ref _ref;
  final AutoReplyTriggerStorage _historyStorage = AutoReplyTriggerStorage();

  Future<void> _appendHistoryLog({
    required String event,
    required String message,
    required String conversationId,
    bool? success,
    AutoReplyTriggerLogLevel level = AutoReplyTriggerLogLevel.info,
    Map<String, dynamic> metadata = const <String, dynamic>{},
  }) async {
    await _historyStorage.appendLog(
      AutoReplyTriggerLog(
        id: 'pregenerator_${DateTime.now().microsecondsSinceEpoch}',
        category: AutoReplyTriggerLogCategory.agent,
        event: event,
        message: message,
        occurredAt: DateTime.now(),
        conversationId: conversationId,
        success: success,
        level: level,
        metadata: metadata,
      ),
    );
  }

  Future<String?> generate({
    required Conversation conversation,
    required List<Message> contextMessages,
    required String systemReminder,
  }) async {
    final trimmedReminder = systemReminder.trim();
    if (trimmedReminder.isEmpty || contextMessages.isEmpty) {
      await _appendHistoryLog(
        event: 'pregeneration_skipped',
        message: '跳过主动回复预生成：缺少上下文或 system_reminder',
        conversationId: conversation.id,
        success: false,
        level: AutoReplyTriggerLogLevel.warning,
        metadata: {
          'contextMessageCount': contextMessages.length,
          'hasReminder': trimmedReminder.isNotEmpty,
        },
      );
      return null;
    }

    final settings = await _ref.read(appSettingsProvider.future);
    final modelRef = resolveAutoReplyAgentModelRef(settings);
    final turnId = 'pregenerator_${DateTime.now().microsecondsSinceEpoch}';

    await _appendHistoryLog(
      event: 'pregeneration_started',
      message: '后台 Agent 开始预生成主动回复文案',
      conversationId: conversation.id,
      metadata: {
        'contextMessageCount': contextMessages.length,
        'reminderAsLastUser': true,
        'modelRef': modelRef,
      },
    );

    try {
      final chatSendService = _ref.read(chatSendServiceProvider);
      final baseConfig = await chatSendService.prepareApiConfig(
        conv: conversation,
        history: contextMessages,
        userText: trimmedReminder,
        overrideModel: modelRef,
        conversationId: conversation.id,
      );
      final config = disableNativeToolCallsForAutoReplyGeneration(
        appendAutoReplyReminderAsLastUser(baseConfig, trimmedReminder),
      );
      final result = await chatSendService.executeApiCall(
        config: config,
        sessionId: conversation.id,
        userText: trimmedReminder,
        turnId: turnId,
        maxRounds: 1,
      );

      final text = selectCacheableAutoReplyText(result).trim();
      if (text.isEmpty) {
        await _appendHistoryLog(
          event: 'pregeneration_empty',
          message: '预生成完成，但没有拿到可发送内容',
          conversationId: conversation.id,
          success: false,
          level: AutoReplyTriggerLogLevel.warning,
        );
        return null;
      }
      await _appendHistoryLog(
        event: 'pregeneration_succeeded',
        message: '预生成完成，已缓存主动回复文案',
        conversationId: conversation.id,
        success: true,
        metadata: {
          'contentLength': text.length,
          'pluginEvents': result.pluginEvents.length,
        },
      );
      return text;
    } catch (e) {
      await _appendHistoryLog(
        event: 'pregeneration_failed',
        message: '后台 Agent 预生成主动回复文案失败',
        conversationId: conversation.id,
        success: false,
        level: AutoReplyTriggerLogLevel.error,
        metadata: {
          'error': e.toString(),
        },
      );
      rethrow;
    }
  }
}
