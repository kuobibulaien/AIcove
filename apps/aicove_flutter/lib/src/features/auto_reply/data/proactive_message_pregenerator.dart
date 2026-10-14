import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../chat/domain/conversation.dart';
import '../domain/proactive_action.dart';
import 'auto_reply_trigger.dart';
import 'auto_reply_trigger_storage.dart';
import 'proactive_reply_generator.dart';

final proactiveMessagePregeneratorProvider = Provider(
  (ref) => ProactiveMessagePregenerator(ref),
);

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

  /// Writes the reply ahead of [fireAt] through the shared proactive path,
  /// so time-aware plugins describe the fire time, not now. With [allowCall]
  /// the draft may come back as a call (plan 12, §4.8).
  Future<ProactiveDraft?> generate({
    required Conversation conversation,
    required String systemReminder,
    required DateTime fireAt,
    bool allowCall = false,
  }) async {
    final trimmedReminder = systemReminder.trim();
    if (trimmedReminder.isEmpty) {
      await _appendHistoryLog(
        event: 'pregeneration_skipped',
        message: '跳过主动回复预生成：缺少提醒内容',
        conversationId: conversation.id,
        success: false,
        level: AutoReplyTriggerLogLevel.warning,
      );
      return null;
    }

    final turnId = 'pregenerator_${DateTime.now().microsecondsSinceEpoch}';
    await _appendHistoryLog(
      event: 'pregeneration_started',
      message: '开始预生成主动回复文案',
      conversationId: conversation.id,
      metadata: {'fireAt': fireAt.toIso8601String(), 'allowCall': allowCall},
    );

    try {
      final draft = await _ref
          .read(proactiveReplyGeneratorProvider)
          .generateDraft(
            conversation: conversation,
            reminder: trimmedReminder,
            turnId: turnId,
            requestTime: fireAt,
            allowCall: allowCall,
          );
      final text = draft.text.trim();
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
        message: draft.isCall ? '预生成完成：角色想打电话，已记下开场白' : '预生成完成，已缓存主动回复文案',
        conversationId: conversation.id,
        success: true,
        metadata: {'contentLength': text.length, 'action': draft.action.id},
      );
      return ProactiveDraft(text: text, action: draft.action);
    } catch (e) {
      await _appendHistoryLog(
        event: 'pregeneration_failed',
        message: '预生成主动回复文案失败',
        conversationId: conversation.id,
        success: false,
        level: AutoReplyTriggerLogLevel.error,
        metadata: {'error': e.toString()},
      );
      rethrow;
    }
  }
}
