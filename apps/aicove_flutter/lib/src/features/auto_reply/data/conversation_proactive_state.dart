enum ConversationProactiveMode {
  active,
  silent,
  dormant,
}

class ConversationProactiveState {
  static const Duration firstSilentDuration = Duration(hours: 8);
  static const Duration secondSilentDuration = Duration(hours: 24);

  final String conversationId;
  final ConversationProactiveMode mode;
  final int unrepliedCount;
  final String? lastUserMessageId;
  final DateTime? lastUserAt;
  final DateTime? lastProactiveAt;
  final DateTime? silenceUntil;
  final String? pendingAutoTriggerId;

  const ConversationProactiveState({
    required this.conversationId,
    this.mode = ConversationProactiveMode.active,
    this.unrepliedCount = 0,
    this.lastUserMessageId,
    this.lastUserAt,
    this.lastProactiveAt,
    this.silenceUntil,
    this.pendingAutoTriggerId,
  });

  bool get hasPendingAutoTrigger =>
      pendingAutoTriggerId != null && pendingAutoTriggerId!.trim().isNotEmpty;

  bool get isSilentWakeDue =>
      mode == ConversationProactiveMode.silent &&
      silenceUntil != null &&
      !silenceUntil!.isAfter(DateTime.now());

  ConversationProactiveState markUserMessage({
    required String? messageId,
    required DateTime occurredAt,
  }) {
    return copyWith(
      mode: ConversationProactiveMode.active,
      unrepliedCount: 0,
      lastUserMessageId: messageId?.trim().isEmpty == true ? null : messageId,
      lastUserAt: occurredAt,
      silenceUntil: null,
      pendingAutoTriggerId: null,
    );
  }

  ConversationProactiveState withPendingAutoTrigger(String? triggerId) {
    final normalizedTriggerId = triggerId?.trim();
    return copyWith(
      pendingAutoTriggerId:
          normalizedTriggerId == null || normalizedTriggerId.isEmpty
              ? null
              : normalizedTriggerId,
    );
  }

  ConversationProactiveState clearPendingAutoTrigger({String? triggerId}) {
    final normalizedTriggerId = triggerId?.trim();
    if (normalizedTriggerId != null &&
        normalizedTriggerId.isNotEmpty &&
        pendingAutoTriggerId != normalizedTriggerId) {
      return this;
    }
    return copyWith(pendingAutoTriggerId: null);
  }

  ConversationProactiveState applySessionPatch({
    ConversationProactiveMode? mode,
    Duration? silenceDuration,
    DateTime? now,
  }) {
    final effectiveNow = now ?? DateTime.now();
    final nextMode = mode ?? this.mode;
    DateTime? nextSilenceUntil;
    if (nextMode == ConversationProactiveMode.silent) {
      nextSilenceUntil = silenceDuration == null
          ? silenceUntil
          : effectiveNow.add(silenceDuration);
    }
    if (nextMode != ConversationProactiveMode.silent) {
      nextSilenceUntil = null;
    }

    return copyWith(
      mode: nextMode,
      silenceUntil: nextSilenceUntil,
    );
  }

  ConversationProactiveState afterSuccessfulAutoTriggerSend({
    required DateTime occurredAt,
  }) {
    final nextCount = (unrepliedCount + 1).clamp(0, 3);
    if (nextCount >= 3) {
      return copyWith(
        mode: ConversationProactiveMode.dormant,
        unrepliedCount: nextCount,
        lastProactiveAt: occurredAt,
        silenceUntil: null,
        pendingAutoTriggerId: null,
      );
    }

    final silenceDuration =
        nextCount == 1 ? firstSilentDuration : secondSilentDuration;
    return copyWith(
      mode: ConversationProactiveMode.silent,
      unrepliedCount: nextCount,
      lastProactiveAt: occurredAt,
      silenceUntil: occurredAt.add(silenceDuration),
      pendingAutoTriggerId: null,
    );
  }

  ConversationProactiveState copyWith({
    String? conversationId,
    ConversationProactiveMode? mode,
    int? unrepliedCount,
    Object? lastUserMessageId = _unset,
    Object? lastUserAt = _unset,
    Object? lastProactiveAt = _unset,
    Object? silenceUntil = _unset,
    Object? pendingAutoTriggerId = _unset,
  }) {
    return ConversationProactiveState(
      conversationId: conversationId ?? this.conversationId,
      mode: mode ?? this.mode,
      unrepliedCount: unrepliedCount ?? this.unrepliedCount,
      lastUserMessageId: identical(lastUserMessageId, _unset)
          ? this.lastUserMessageId
          : lastUserMessageId as String?,
      lastUserAt: identical(lastUserAt, _unset)
          ? this.lastUserAt
          : lastUserAt as DateTime?,
      lastProactiveAt: identical(lastProactiveAt, _unset)
          ? this.lastProactiveAt
          : lastProactiveAt as DateTime?,
      silenceUntil: identical(silenceUntil, _unset)
          ? this.silenceUntil
          : silenceUntil as DateTime?,
      pendingAutoTriggerId: identical(pendingAutoTriggerId, _unset)
          ? this.pendingAutoTriggerId
          : pendingAutoTriggerId as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'conversation_id': conversationId,
      'mode': mode.name,
      'unreplied_count': unrepliedCount,
      'last_user_message_id': lastUserMessageId,
      'last_user_at': lastUserAt?.toIso8601String(),
      'last_proactive_at': lastProactiveAt?.toIso8601String(),
      'silence_until': silenceUntil?.toIso8601String(),
      'pending_auto_trigger_id': pendingAutoTriggerId,
    };
  }

  factory ConversationProactiveState.fromJson(Map<String, dynamic> json) {
    DateTime? parseNullable(String? value) =>
        value == null ? null : DateTime.tryParse(value)?.toLocal();
    int clampCount(dynamic rawValue) {
      if (rawValue is! num) {
        return 0;
      }
      final count = rawValue.toInt();
      if (count < 0) {
        return 0;
      }
      if (count > 3) {
        return 3;
      }
      return count;
    }

    return ConversationProactiveState(
      conversationId: (json['conversation_id'] as String?)?.trim() ?? '',
      mode: _parseMode(json['mode'] as String?),
      unrepliedCount: clampCount(json['unreplied_count']),
      lastUserMessageId: json['last_user_message_id'] as String?,
      lastUserAt: parseNullable(json['last_user_at'] as String?),
      lastProactiveAt: parseNullable(json['last_proactive_at'] as String?),
      silenceUntil: parseNullable(json['silence_until'] as String?),
      pendingAutoTriggerId: json['pending_auto_trigger_id'] as String?,
    );
  }

  static ConversationProactiveMode _parseMode(String? value) {
    switch (value) {
      case 'silent':
        return ConversationProactiveMode.silent;
      case 'dormant':
        return ConversationProactiveMode.dormant;
      default:
        return ConversationProactiveMode.active;
    }
  }
}

const Object _unset = Object();
