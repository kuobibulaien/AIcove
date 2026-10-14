import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/app_logger.dart';
import '../../../core/database/database_provider.dart';
import '../../chat/conversation_providers.dart';
import '../../chat/domain/conversation.dart';
import '../../chat/services/chat_send_service.dart';
import '../../chat/services/chat_tts_handler.dart';
import '../../settings/app_settings.dart';
import 'auto_reply_agent_helpers.dart';
import 'auto_reply_claim_store.dart';
import 'auto_reply_trigger.dart';
import 'auto_reply_trigger_storage.dart';
import 'incoming_call.dart';
import 'proactive_call.dart';
import 'proactive_call_ledger.dart';
import 'proactive_planner.dart';
import 'proactive_reply_generator.dart';

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

  /// A proactive call is ringing; how it ends is recorded by the ringer.
  const AutoReplyDispatchResult.rang()
      : this._(success: true, retryable: false, reason: 'rang');

  const AutoReplyDispatchResult.skipped(String reason)
      : this._(success: false, retryable: false, reason: reason);

  const AutoReplyDispatchResult.failed(
    String reason, {
    bool retryable = true,
  }) : this._(success: false, retryable: retryable, reason: reason);

  /// The claim lease was taken over during generation; the other party
  /// delivers, so nothing was written here.
  const AutoReplyDispatchResult.superseded()
      : this._(success: false, retryable: false, reason: supersededReason);

  static const supersededReason = 'claim_superseded';
}

class AutoReplyDispatchService {
  static const String _triggerPluginId = 'trigger';

  AutoReplyDispatchService(this._ref);

  final Ref _ref;
  final AutoReplyTriggerStorage _historyStorage = AutoReplyTriggerStorage();

  ChatSendService get _chatSendService => _ref.read(chatSendServiceProvider);
  ChatTtsHandler get _chatTtsHandler => _ref.read(chatTtsHandlerProvider);

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

  /// Sends a persisted trigger fired under [claimToken] (from the fired
  /// event). Nothing is written without a token that still holds the claim.
  Future<AutoReplyDispatchResult> dispatchTrigger(
    AutoReplyTrigger trigger, {
    required String? claimToken,
  }) {
    if (claimToken == null) {
      return Future.value(
        const AutoReplyDispatchResult.failed('missing_claim', retryable: false),
      );
    }
    return _dispatch(trigger, claimToken: claimToken);
  }

  /// One-off test send from the trigger form: the trigger is not stored and
  /// no other side can fire it, so it runs without a claim.
  Future<AutoReplyDispatchResult> dispatchTestTrigger(
    AutoReplyTrigger trigger,
  ) =>
      _dispatch(trigger, claimToken: null);

  Future<AutoReplyDispatchResult> _dispatch(
    AutoReplyTrigger trigger, {
    required String? claimToken,
  }) async {
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

    // Null once the delivery is already claimed (a call that fell back to a
    // message after claiming it).
    var deliveryToken = claimToken;
    if (trigger.action == ProactiveAction.callUser) {
      final ring = await _tryRing(
        conversation: conversation,
        trigger: trigger,
        settings: settings,
        claimToken: claimToken,
      );
      if (ring.result case final result?) return result;
      if (ring.claimed) deliveryToken = null;
    }

    var deliveryStarted = false;
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
      // 仍持有认领才写消息；写入开始后不再重试（至多一次，宁缺不重）。
      if (deliveryToken != null &&
          !await AutoReplyClaimStore(_ref.read(databaseProvider))
              .beginDelivery(
                trigger.id,
                deliveryToken,
                messageId: buildResult.rawMessage?.id,
              )) {
        await _appendHistoryLog(
          event: 'dispatch_superseded',
          message: '主动回复已放弃：生成期间执行权被另一方接管',
          trigger: trigger,
          success: false,
          level: AutoReplyTriggerLogLevel.warning,
        );
        return const AutoReplyDispatchResult.superseded();
      }
      deliveryStarted = true;
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
      // 已开始写消息时失败：可能写了一部分，不再重试，免得重复。
      return AutoReplyDispatchResult.failed(
        e.toString(),
        retryable: !deliveryStarted,
      );
    }
  }

  /// Rings the call written ahead. A null `result` means the trigger is sent
  /// as a message instead (the opening line when it is still fresh, otherwise
  /// a reply written now, plan 12 §4.8); `claimed` tells whether the delivery
  /// is already claimed for it.
  Future<({AutoReplyDispatchResult? result, bool claimed})> _tryRing({
    required Conversation conversation,
    required AutoReplyTrigger trigger,
    required AppSettings settings,
    required String? claimToken,
  }) async {
    final now = DateTime.now();
    final openingLine = trigger.cachedContent?.trim() ?? '';
    final quiet = settings.autoReplySettings;
    final String? blocked;
    if (openingLine.isEmpty ||
        !isCachedAutoReplyContentFresh(preparedAt: trigger.preparedAt, now: now)) {
      blocked = '开场白已过期';
    } else if (!trigger.allowNight &&
        QuietHours.parse(
          enabled: quiet.quietHoursEnabled,
          start: quiet.quietHoursStart,
          end: quiet.quietHoursEnd,
        ).contains(now)) {
      blocked = '免打扰时段';
    } else if (_ref.read(incomingCallProvider.notifier).busy) {
      blocked = '正在通话';
    } else {
      blocked = await _callBlocker(conversation);
    }
    if (blocked != null) {
      await _logCallAsMessage(trigger, blocked);
      return (result: null, claimed: false);
    }
    // Reserve the one ringing slot, claim the delivery, confirm, then show
    // the call: nothing shows or answers a call whose delivery was not
    // claimed, and a busy line always falls back to a message (plan 12, §13).
    final ledger = _ref.read(proactiveCallLedgerProvider);
    final notifier = _ref.read(incomingCallProvider.notifier);
    final until = now.add(_ref.read(incomingCallRingTimeoutProvider));
    final call = IncomingCall(
      conversation: conversation,
      openingLine: openingLine,
      triggerId: trigger.id,
    );
    if (!await ledger.reserve(
      ProactiveCall(
        triggerId: trigger.id,
        conversationId: conversation.id,
        openingLine: openingLine,
        rangAt: now,
        answerUntil: until,
      ),
    )) {
      await _logCallAsMessage(trigger, '另一通来电还在响');
      return (result: null, claimed: false);
    }
    final bool claimed;
    try {
      claimed =
          claimToken == null ||
          await AutoReplyClaimStore(
            _ref.read(databaseProvider),
          ).beginDelivery(trigger.id, claimToken);
    } catch (e) {
      await ledger.release(trigger.id);
      await _logCallAsMessage(trigger, '确认送达失败：$e');
      return (result: null, claimed: false);
    }
    if (!claimed) {
      await ledger.release(trigger.id);
      return (
        result: const AutoReplyDispatchResult.superseded(),
        claimed: false,
      );
    }
    await ledger.confirm(trigger.id);
    if (!notifier.show(call, until: until)) {
      // A voice call started while claiming: send the line as a message
      // under the delivery already claimed.
      await ledger.release(trigger.id);
      await _logCallAsMessage(trigger, '正在通话');
      return (result: null, claimed: true);
    }
    await _appendHistoryLog(
      event: 'call_ringing',
      message: '角色来电，正在响铃',
      trigger: trigger,
      success: true,
    );
    return (result: const AutoReplyDispatchResult.rang(), claimed: true);
  }

  Future<void> _logCallAsMessage(AutoReplyTrigger trigger, String reason) =>
      _appendHistoryLog(
        event: 'call_sent_as_message',
        message: '这次不打电话，改发消息：$reason',
        trigger: trigger,
        metadata: {'reason': reason},
      );

  Future<String?> _callBlocker(Conversation conversation) async {
    try {
      return await _ref.read(proactiveCallGateProvider)(conversation);
    } catch (e) {
      return '来电条件检查失败：$e';
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
    final modelRef = resolveAutoReplyAgentModelRef(settings);
    await _appendHistoryLog(
      event: 'runtime_generation_started',
      message: '开始通过聊天主链路即时生成主动回复',
      trigger: trigger,
      category: AutoReplyTriggerLogCategory.agent,
      metadata: {
        'contextWindow': ProactiveReplyGenerator.contextWindow,
        'reminderAsLastUser': (trigger.prompt?.trim().isNotEmpty ?? false),
        'modelRef': modelRef,
      },
    );

    final replyText = await _ref
        .read(proactiveReplyGeneratorProvider)
        .generate(
          conversation: conversation,
          reminder: trigger.prompt,
          turnId: 'auto_reply_dispatch_${trigger.id}',
        );
    await _appendHistoryLog(
      event: 'runtime_generation_finished',
      message: '聊天主链路已完成即时主动回复生成',
      trigger: trigger,
      category: AutoReplyTriggerLogCategory.agent,
      success: true,
      metadata: {'replyLength': replyText.length},
    );
    return replyText;
  }
}
