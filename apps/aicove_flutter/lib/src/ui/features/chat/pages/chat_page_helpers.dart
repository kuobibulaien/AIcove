part of 'chat_page.dart';

@visibleForTesting
Future<int> resolveChatPageLoadMoreVisibleCount({
  required ConversationTimelineCache store,
  required String conversationId,
  required int currentVisibleCount,
  int pageSize = kConversationVisiblePageSize,
}) async {
  final localMessageCount = await store.loadCachedMessageCount(conversationId);
  if (localMessageCount > currentVisibleCount) {
    return localMessageCount;
  }

  final addedCount = await store.loadOlderMessages(
    conversationId: conversationId,
    pageSize: pageSize,
  );
  if (addedCount <= 0) {
    return currentVisibleCount;
  }
  return currentVisibleCount + addedCount;
}

@visibleForTesting
List<Message> resolveChatPageLoadingFallbackMessages({
  required String? conversationId,
  required String? cachedConversationId,
  required List<Message> cachedMessages,
  required bool isGenerating,
  List<Message>? inMemoryTimelineMessages,
}) {
  final normalizedConversationId = conversationId?.trim();
  if (normalizedConversationId == null || normalizedConversationId.isEmpty) {
    return const <Message>[];
  }

  final fallbackMessages = cachedConversationId == normalizedConversationId
      ? cachedMessages
      : (inMemoryTimelineMessages ?? const <Message>[]);
  if (isGenerating) {
    return fallbackMessages;
  }

  return <Message>[
    for (final message in fallbackMessages)
      if (!(message.role == 'assistant' && message.status == 'sending'))
        message,
  ];
}

@visibleForTesting
String resolveChatPageAppBarTitle({
  required String displayName,
  required String? conversationId,
  required ChatStatus chatStatus,
  required List<TraceEvent> traceEvents,
}) {
  final normalizedDisplayName = displayName.trim().isEmpty
      ? '聊天'
      : displayName.trim();
  final statusLabel = switch (chatStatus) {
    ChatStatus.generatingImage ||
    ChatStatus.generatingVoice ||
    ChatStatus.toolCalling => chatStatus.label.trim(),
    _ => '',
  };
  if (statusLabel.isNotEmpty) {
    return statusLabel;
  }
  final normalizedConversationId = conversationId?.trim() ?? '';
  if (normalizedConversationId.isEmpty || traceEvents.isEmpty) {
    return normalizedDisplayName;
  }

  final conversationEvents = traceEvents
      .where((event) => event.sessionId == normalizedConversationId)
      .toList(growable: false);
  if (conversationEvents.isEmpty) {
    return normalizedDisplayName;
  }

  TraceTurnSummary? activeTurn;
  for (final turn in TraceQueryService.aggregateTurns(conversationEvents)) {
    if (turn.status == TraceEventStatus.running.value) {
      activeTurn = turn;
      break;
    }
  }
  if (activeTurn == null) {
    return normalizedDisplayName;
  }

  final timeline = TraceQueryService.sortEvents(
    conversationEvents
        .where((event) => event.traceId == activeTurn!.traceId)
        .toList(growable: false),
  );
  if (timeline.isEmpty) {
    return normalizedDisplayName;
  }

  final stageLabel = stageToZh(timeline.last.stage).trim();
  if (stageLabel.isEmpty || stageLabel == timeline.last.stage) {
    return normalizedDisplayName;
  }
  return stageLabel;
}
