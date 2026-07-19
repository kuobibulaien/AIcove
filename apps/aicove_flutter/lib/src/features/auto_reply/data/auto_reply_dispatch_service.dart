import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/app_logger.dart';
import '../../chat/conversation_providers.dart';
import '../../chat/domain/conversation.dart';
import '../../chat/domain/message.dart';
import '../../chat/services/chat_history_store.dart';
import '../../chat/services/chat_send_service.dart';
import '../../chat/services/chat_tts_handler.dart';
import '../../settings/app_settings.dart';
import 'auto_reply_agent_helpers.dart';
import 'auto_reply_trigger.dart';
import 'auto_reply_trigger_storage.dart';

final autoReplyDispatchServiceProvider =
    Provider<AutoReplyDispatchService>((ref) {
  return AutoReplyDispatchService(ref);
});

class AutoReplyDispatchResult {
  const AutoReplyDispatchResult._({
    required this.success,
    required this.retryable,
    required this.reason,
  });

  final bool success;
  final bool retryable;
  final String reason;

  const AutoReplyDispatchResult.success()
      : this._(success: true, retryable: false, reason: 'sent');

  const AutoReplyDispatchResult.skipped(String reason)
      : this._(success: false, retryable: false, reason: reason);

  const AutoReplyDispatchResult.failed(
    String reason, {
    bool retryable = true,
  }) : this._(success: false, retryable: retryable, reason: reason);
}

class AutoReplyDispatchService {
  static const String _triggerPluginId = 'trigger';

  AutoReplyDispatchService(this._ref);

  final Ref _ref;
  final AutoReplyTriggerStorage _historyStorage = AutoReplyTriggerStorage();

  ChatSendService get _chatSendService => _ref.read(chatSendServiceProvider);
  ChatTtsHandler get _chatTtsHandler => _ref.read(chatTtsHandlerProvider);
  ChatHistoryStore get _chatHistoryStore => _ref.read(chatHistoryStoreProvider);

  Future<void> _appendHistoryLog({
    required String event,
    required String message,
    required AutoReplyTrigger trigger,
    bool? success,
    AutoReplyTriggerLogCategory category = AutoReplyTriggerLogCategory.delivery,
    AutoReplyTriggerLogLevel level = AutoReplyTriggerLogLevel.info,
    Map<String, dynamic> metadata = const <String, dynamic>{},
  }) async {
    await _historyStorage.appendLog(
      AutoReplyTriggerLog(
        id: 'dispatch_${DateTime.now().microsecondsSinceEpoch}',
        category: category,
        event: event,
        message: message,
        occurredAt: DateTime.now(),
        triggerId: trigger.id,
        title: trigger.title,
        conversationId: trigger.conversationId,
        source: trigger.source,
        success: success,
        level: level,
        metadata: metadata,
      ),
    );
  }

  Future<AutoReplyDispatchResult> dispatchTrigger(
    AutoReplyTrigger trigger,
  ) async {
    final targetConversationId = trigger.conversationId.isNotEmpty
        ? trigger.conversationId
        : _ref.read(activeConversationIdProvider) ?? '';
    if (targetConversationId.isEmpty) {
      AppLogger.warning(
        'AutoReplyDispatchService',
        'Skip proactive send: target conversation missing',
        metadata: {'triggerId': trigger.id},
      );
      await _appendHistoryLog(
        event: 'dispatch_skipped_missing_conversation_id',
        message: '跳过主动回复发送：缺少目标会话 ID',
        trigger: trigger,
        success: false,
        level: AutoReplyTriggerLogLevel.warning,
      );
      return const AutoReplyDispatchResult.skipped(
        'target_conversation_missing',
      );
    }

    final conversation = _resolveConversation(targetConversationId);
    if (conversation == null) {
      AppLogger.warning(
        'AutoReplyDispatchService',
        'Skip proactive send: target conversation not found',
        metadata: {
          'triggerId': trigger.id,
          'conversationId': targetConversationId,
        },
      );
      await _appendHistoryLog(
        event: 'dispatch_skipped_conversation_not_found',
        message: '跳过主动回复发送：找不到目标会话',
        trigger: trigger,
        success: false,
        level: AutoReplyTriggerLogLevel.warning,
        metadata: {
          'targetConversationId': targetConversationId,
        },
      );
      return const AutoReplyDispatchResult.skipped(
        'target_conversation_not_found',
      );
    }

    final settings = await _ref.read(appSettingsProvider.future);
    if (!settings.autoReplySettings.enabled) {
      await _appendHistoryLog(
        event: 'dispatch_skipped_auto_reply_disabled',
        message: '跳过主动回复发送：总开关已关闭',
        trigger: trigger,
        success: false,
        level: AutoReplyTriggerLogLevel.warning,
      );
      return const AutoReplyDispatchResult.skipped('auto_reply_disabled');
    }
    if (trigger.source == TriggerSource.aiScheduler &&
        conversation.blocksPlugin(_triggerPluginId)) {
      await _appendHistoryLog(
        event: 'dispatch_skipped_trigger_plugin_disabled',
        message: '跳过主动回复发送：当前联系人已关闭主动关怀插件',
        trigger: trigger,
        success: false,
        level: AutoReplyTriggerLogLevel.warning,
        metadata: {
          'targetConversationId': targetConversationId,
        },
      );
      return const AutoReplyDispatchResult.skipped(
        'trigger_plugin_disabled_for_conversation',
      );
    }

    try {
      await _appendHistoryLog(
        event: 'dispatch_started',
        message: '开始执行主动回复发送链路',
        trigger: trigger,
        metadata: {
          'targetConversationId': targetConversationId,
          'hasCachedContent': trigger.hasCachedContent,
        },
      );
      final replyText = await _resolveReplyText(
        conversation: conversation,
        trigger: trigger,
        settings: settings,
      );
      final normalizedReply = replyText.trim();
      if (normalizedReply.isEmpty) {
        await _appendHistoryLog(
          event: 'dispatch_empty_reply',
          message: '主动回复发送失败：生成结果为空',
          trigger: trigger,
          success: false,
          level: AutoReplyTriggerLogLevel.warning,
        );
        return const AutoReplyDispatchResult.failed(
          'empty_reply',
          retryable: true,
        );
      }

      final apiResult = await _chatSendService.processAssistantReplyWithPlugins(
        conv: conversation,
        rawReplyText: normalizedReply,
      );
      final buildResult = _chatSendService.buildAssistantMessages(
        apiResult: apiResult,
        settings: settings,
      );
      await _chatTtsHandler.deliverSegmentedMessages(
        convId: targetConversationId,
        userMsgId: '',
        buildResult: buildResult,
        replyText: apiResult.rawReplyText,
        pluginEvents: apiResult.pluginEvents,
        ttsEnabled: settings.ttsEnabled,
      );
      AppLogger.info(
        'AutoReplyDispatchService',
        'Auto-reply delivered by background agent runtime',
        metadata: {
          'triggerId': trigger.id,
          'conversationId': targetConversationId,
          'usedCachedContent': trigger.hasCachedContent,
        },
      );
      await _appendHistoryLog(
        event: 'dispatch_delivered',
        message: '主动回复已写入聊天并完成交付',
        trigger: trigger,
        success: true,
        metadata: {
          'targetConversationId': targetConversationId,
          'usedCachedContent': trigger.hasCachedContent,
          'replyLength': normalizedReply.length,
          'pluginEvents': apiResult.pluginEvents.length,
        },
      );
      return const AutoReplyDispatchResult.success();
    } catch (e) {
      AppLogger.error(
        'AutoReplyDispatchService',
        'Failed to dispatch proactive trigger',
        metadata: {
          'triggerId': trigger.id,
          'conversationId': targetConversationId,
          'error': e.toString(),
        },
      );
      await _appendHistoryLog(
        event: 'dispatch_failed',
        message: '主动回复发送链路执行失败',
        trigger: trigger,
        success: false,
        level: AutoReplyTriggerLogLevel.error,
        metadata: {
          'error': e.toString(),
        },
      );
      return AutoReplyDispatchResult.failed(e.toString());
    }
  }

  Conversation? _resolveConversation(String conversationId) {
    final conversations =
        _ref.read(conversationsProvider).valueOrNull ?? const [];
    for (final conversation in conversations) {
      if (conversation.id == conversationId) {
        return conversation;
      }
    }
    return null;
  }

  Future<String> _resolveReplyText({
    required Conversation conversation,
    required AutoReplyTrigger trigger,
    required AppSettings settings,
  }) async {
    final cachedContent = trigger.cachedContent?.trim();
    final hasCache = cachedContent != null && cachedContent.isNotEmpty;
    final now = DateTime.now();
    final cacheFresh = hasCache &&
        isCachedAutoReplyContentFresh(
          preparedAt: trigger.preparedAt,
          now: now,
        );
    if (cacheFresh) {
      await _appendHistoryLog(
        event: 'dispatch_used_cached_content',
        message: '命中新鲜 cachedContent，直接使用预生成文案发送',
        trigger: trigger,
        category: AutoReplyTriggerLogCategory.agent,
        success: true,
        metadata: {
          'cachedLength': cachedContent.length,
          'cacheAgeMinutes': trigger.preparedAt == null
              ? null
              : now.difference(trigger.preparedAt!).inMinutes,
        },
      );
      return cachedContent;
    }

    if (hasCache) {
      await _appendHistoryLog(
        event: 'dispatch_cache_stale_live_generation',
        message: '预生成缓存已过期，优先即时生成，缓存降级为兜底文案',
        trigger: trigger,
        category: AutoReplyTriggerLogCategory.agent,
        metadata: {
          'cacheAgeMinutes': trigger.preparedAt == null
              ? null
              : now.difference(trigger.preparedAt!).inMinutes,
        },
      );
    }

    try {
      final liveReply = await _generateLiveReplyText(
        conversation: conversation,
        trigger: trigger,
        settings: settings,
      );
      if (liveReply.trim().isNotEmpty) {
        return liveReply;
      }
      if (hasCache) {
        await _logCachedContentFallback(trigger, reason: 'empty_live_reply');
        return cachedContent;
      }
      return liveReply;
    } catch (e) {
      if (hasCache) {
        await _logCachedContentFallback(trigger, reason: e.toString());
        return cachedContent;
      }
      rethrow;
    }
  }

  Future<void> _logCachedContentFallback(
    AutoReplyTrigger trigger, {
    required String reason,
  }) async {
    await _appendHistoryLog(
      event: 'dispatch_fallback_cached_content',
      message: '即时生成失败，回退使用预生成兜底文案',
      trigger: trigger,
      category: AutoReplyTriggerLogCategory.agent,
      success: true,
      level: AutoReplyTriggerLogLevel.warning,
      metadata: {
        'reason': reason,
      },
    );
  }

  Future<String> _generateLiveReplyText({
    required Conversation conversation,
    required AutoReplyTrigger trigger,
    required AppSettings settings,
  }) async {
    final contextMessages = await _resolveContextMessages(conversation.id);
    if (contextMessages.isEmpty) {
      throw StateError('proactive_context_empty');
    }

    final modelRef = resolveAutoReplyAgentModelRef(settings);
    await _appendHistoryLog(
      event: 'runtime_generation_started',
      message: '开始通过聊天主链路即时生成主动回复',
      trigger: trigger,
      category: AutoReplyTriggerLogCategory.agent,
      metadata: {
        'contextMessageCount': contextMessages.length,
        'reminderAsLastUser': (trigger.prompt?.trim().isNotEmpty ?? false),
        'modelRef': modelRef,
      },
    );

    final baseConfig = await _chatSendService.prepareApiConfig(
      conv: conversation,
      history: contextMessages,
      userText: trigger.prompt,
      overrideModel: modelRef,
      conversationId: conversation.id,
    );
    final config = disableNativeToolCallsForAutoReplyGeneration(
      appendAutoReplyReminderAsLastUser(baseConfig, trigger.prompt),
    );
    final result = await _chatSendService.executeApiCall(
      config: config,
      sessionId: conversation.id,
      userText: trigger.prompt,
      turnId: 'auto_reply_dispatch_${trigger.id}',
      maxRounds: 1,
    );
    final replyText = selectCacheableAutoReplyText(result);
    await _appendHistoryLog(
      event: 'runtime_generation_finished',
      message: '聊天主链路已完成即时主动回复生成',
      trigger: trigger,
      category: AutoReplyTriggerLogCategory.agent,
      success: true,
      metadata: {
        'replyLength': replyText.length,
        'pluginEvents': result.pluginEvents.length,
      },
    );
    return replyText;
  }

  Future<List<Message>> _resolveContextMessages(String conversationId) {
    return _chatHistoryStore.loadCanonicalContextMessages(
      conversationId,
      limit: 10,
    );
  }
}
