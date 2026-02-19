/// 触发器类型
enum AutoReplyTriggerType { delay, fixed }

/// 触发器状态（8个状态）
/// 状态机：created → preparing → prepared → fired/expired
///         created → pending → fired/expired
///         任意活跃状态 → paused → pending
///         任意状态 → deleted
enum AutoReplyTriggerStatus {
  /// 刚创建，准备开始预生成
  created,

  /// 正在预生成内容中
  preparing,

  /// 已预生成内容，等待触发
  prepared,

  /// 等待触发（无需预生成，或预生成失败但仍可触发）
  pending,

  /// 已触发发送
  fired,

  /// 已过期/作废
  expired,

  /// 已暂停（用户手动暂停）
  paused,

  /// 已删除
  deleted,
}

/// 触发器优先级
enum AutoReplyTriggerPriority {
  /// 高优先级：用户明确设置的提醒，无论如何都会触发
  high,

  /// 中优先级：AI 管家自动创建的普通关怀，用户发新消息后作废
  medium,

  /// 低优先级：情感性消息，用户发新消息或正在聊天界面就作废
  low,
}

/// 触发器创建来源
enum TriggerSource {
  /// 用户通过 UI 手动创建
  userManual,

  /// 用户通过对话要求 AI 创建（如"明天叫我起床"）
  userRequest,

  /// AI 管家自动分析创建
  aiScheduler,

  /// 系统预设（如每日问候）
  systemPreset,
}

/// 自动回复触发器
class AutoReplyTrigger {
  final String id;
  final String title;
  final AutoReplyTriggerType type;
  final AutoReplyTriggerStatus status;
  final DateTime createdAt;
  final DateTime nextFireAt;
  final bool allowNight;
  final bool requireExact;
  final int delayMinutes;
  final bool manual;
  final DateTime? lastFiredAt;
  final String? contactId; // 指定联系人ID（兼容旧数据）
  final String? prompt; // 唤醒提示词
  final AutoReplyTriggerPriority priority;
  final String? cachedContent; // 预生成的消息内容

  // ===== 新增字段 =====

  /// 上下文快照：创建时的对话历史（JSON 字符串）
  /// 用于预生成内容时提供上下文
  final String? contextSnapshot;

  /// 创建时"最后一条用户消息"的 ID
  /// 用于作废判断：只关心 user role 的消息
  final String? contextLastUserMessageId;

  /// 创建时"最后一条用户消息"的时间
  /// 用于作废判断的退化方案
  final DateTime? contextLastUserMessageAt;

  /// 预生成时间
  /// 用于判断预生成内容是否过时
  final DateTime? preparedAt;

  /// 创建来源
  final TriggerSource source;

  /// 关联的会话 ID（必填）
  final String conversationId;

  /// 过期原因（如果状态是 expired）
  final String? expireReason;

  const AutoReplyTrigger({
    required this.id,
    required this.title,
    required this.type,
    required this.status,
    required this.createdAt,
    required this.nextFireAt,
    required this.allowNight,
    required this.requireExact,
    required this.delayMinutes,
    required this.manual,
    required this.conversationId,
    this.lastFiredAt,
    this.contactId,
    this.prompt,
    this.priority = AutoReplyTriggerPriority.medium,
    this.cachedContent,
    this.contextSnapshot,
    this.contextLastUserMessageId,
    this.contextLastUserMessageAt,
    this.preparedAt,
    this.source = TriggerSource.userManual,
    this.expireReason,
  });

  /// 是否处于活跃状态（可能触发）
  bool get isActive =>
      status == AutoReplyTriggerStatus.created ||
      status == AutoReplyTriggerStatus.preparing ||
      status == AutoReplyTriggerStatus.prepared ||
      status == AutoReplyTriggerStatus.pending;

  /// 是否已预生成内容
  bool get hasCachedContent =>
      cachedContent != null && cachedContent!.isNotEmpty;

  /// 是否应该触发
  bool shouldFire(DateTime now, {bool allowNightOverride = false}) {
    if (!isActive) return false;

    // 夜间检查
    if (!allowNightOverride && !allowNight) {
      final hour = now.hour;
      if (hour >= 23 || hour < 7) return false;
    }

    return !nextFireAt.isAfter(now);
  }

  /// 检查是否应该作废
  /// [currentLastUserMessageId]/[currentLastUserMessageAt] 当前对话里"最后一条用户消息"的标记
  /// [isChatActive] 用户是否正在聊天界面
  bool shouldExpire({
    required String? currentLastUserMessageId,
    required DateTime? currentLastUserMessageAt,
    required bool isChatActive,
  }) {
    if (manual) {
      return false;
    }

    final hasNewUserMessage = _checkHasNewUserMessage(
      currentLastUserMessageId: currentLastUserMessageId,
      currentLastUserMessageAt: currentLastUserMessageAt,
    );

    switch (priority) {
      case AutoReplyTriggerPriority.high:
        // 高优先级：不作废
        return false;

      case AutoReplyTriggerPriority.medium:
        // 中优先级：用户发了新消息就作废
        return hasNewUserMessage;

      case AutoReplyTriggerPriority.low:
        // 低优先级：用户发消息 或 正在聊天 就作废
        if (hasNewUserMessage) return true;
        if (isChatActive) return true;
        return false;
    }
  }

  /// 检查用户是否发了新消息
  bool _checkHasNewUserMessage({
    required String? currentLastUserMessageId,
    required DateTime? currentLastUserMessageAt,
  }) {
    // 1) 创建时没有用户消息，但现在有了 → 说明用户发过新消息
    final hadNoUserMessageAtCreate =
        contextLastUserMessageId == null && contextLastUserMessageAt == null;
    final hasUserMessageNow =
        currentLastUserMessageId != null || currentLastUserMessageAt != null;
    if (hadNoUserMessageAtCreate && hasUserMessageNow) return true;

    // 2) 优先用 ID 判断（最稳）
    if (contextLastUserMessageId != null && currentLastUserMessageId != null) {
      return currentLastUserMessageId != contextLastUserMessageId;
    }

    // 3) 退化用时间判断（兼容：某些场景拿不到稳定 ID）
    if (contextLastUserMessageAt != null && currentLastUserMessageAt != null) {
      return currentLastUserMessageAt.isAfter(contextLastUserMessageAt!);
    }

    return false;
  }

  /// 获取作废原因描述
  String getExpireReason({
    required String? currentLastUserMessageId,
    required DateTime? currentLastUserMessageAt,
    required bool isChatActive,
  }) {
    final hasNewUserMessage = _checkHasNewUserMessage(
      currentLastUserMessageId: currentLastUserMessageId,
      currentLastUserMessageAt: currentLastUserMessageAt,
    );

    if (hasNewUserMessage) return '用户在触发前发了新消息';
    if (isChatActive) return '用户正在聊天界面';
    return '未知原因';
  }

  AutoReplyTrigger copyWith({
    String? id,
    String? title,
    AutoReplyTriggerType? type,
    AutoReplyTriggerStatus? status,
    DateTime? createdAt,
    DateTime? nextFireAt,
    bool? allowNight,
    bool? requireExact,
    int? delayMinutes,
    bool? manual,
    DateTime? lastFiredAt,
    String? contactId,
    String? prompt,
    AutoReplyTriggerPriority? priority,
    String? cachedContent,
    String? contextSnapshot,
    String? contextLastUserMessageId,
    DateTime? contextLastUserMessageAt,
    DateTime? preparedAt,
    TriggerSource? source,
    String? conversationId,
    String? expireReason,
  }) {
    return AutoReplyTrigger(
      id: id ?? this.id,
      title: title ?? this.title,
      type: type ?? this.type,
      status: status ?? this.status,
      createdAt: createdAt ?? this.createdAt,
      nextFireAt: nextFireAt ?? this.nextFireAt,
      allowNight: allowNight ?? this.allowNight,
      requireExact: requireExact ?? this.requireExact,
      delayMinutes: delayMinutes ?? this.delayMinutes,
      manual: manual ?? this.manual,
      lastFiredAt: lastFiredAt ?? this.lastFiredAt,
      contactId: contactId ?? this.contactId,
      prompt: prompt ?? this.prompt,
      priority: priority ?? this.priority,
      cachedContent: cachedContent ?? this.cachedContent,
      contextSnapshot: contextSnapshot ?? this.contextSnapshot,
      contextLastUserMessageId:
          contextLastUserMessageId ?? this.contextLastUserMessageId,
      contextLastUserMessageAt:
          contextLastUserMessageAt ?? this.contextLastUserMessageAt,
      preparedAt: preparedAt ?? this.preparedAt,
      source: source ?? this.source,
      conversationId: conversationId ?? this.conversationId,
      expireReason: expireReason ?? this.expireReason,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'type': type.name,
      'status': status.name,
      'created_at': createdAt.toIso8601String(),
      'next_fire_at': nextFireAt.toIso8601String(),
      'allow_night': allowNight,
      'require_exact': requireExact,
      'delay_minutes': delayMinutes,
      'manual': manual,
      'last_fired_at': lastFiredAt?.toIso8601String(),
      'contact_id': contactId,
      'prompt': prompt,
      'priority': priority.name,
      'cached_content': cachedContent,
      'context_snapshot': contextSnapshot,
      'context_last_user_message_id': contextLastUserMessageId,
      'context_last_user_message_at': contextLastUserMessageAt?.toIso8601String(),
      'prepared_at': preparedAt?.toIso8601String(),
      'source': source.name,
      'conversation_id': conversationId,
      'expire_reason': expireReason,
    };
  }

  factory AutoReplyTrigger.fromJson(Map<String, dynamic> json) {
    DateTime? parseNullable(String? value) =>
        value != null ? DateTime.tryParse(value)?.toLocal() : null;
    DateTime parse(String? value) =>
        value != null ? (DateTime.tryParse(value)?.toLocal() ?? DateTime.now()) : DateTime.now();

    // 旧数据迁移：conversationId 优先用新字段，否则用 contactId，最后兜底空字符串
    final conversationId = (json['conversation_id'] as String?) ??
        (json['contact_id'] as String?) ??
        '';

    return AutoReplyTrigger(
      id: (json['id'] as String?) ?? '',
      title: (json['title'] as String?) ?? '自定义触发',
      type: _parseType(json['type'] as String?),
      status: _parseStatus(json['status'] as String?),
      createdAt: parse(json['created_at'] as String?),
      nextFireAt: parse(json['next_fire_at'] as String?),
      allowNight: json['allow_night'] != false,
      requireExact: json['require_exact'] == true,
      delayMinutes: (json['delay_minutes'] as num?)?.toInt() ?? 30,
      manual: json['manual'] != false,
      lastFiredAt: parseNullable(json['last_fired_at'] as String?),
      contactId: json['contact_id'] as String?,
      prompt: json['prompt'] as String?,
      priority: _parsePriority(json['priority'] as String?),
      cachedContent: json['cached_content'] as String?,
      contextSnapshot: json['context_snapshot'] as String?,
      contextLastUserMessageId: json['context_last_user_message_id'] as String?,
      contextLastUserMessageAt: parseNullable(json['context_last_user_message_at'] as String?),
      preparedAt: parseNullable(json['prepared_at'] as String?),
      source: _parseSource(json['source'] as String?),
      conversationId: conversationId,
      expireReason: json['expire_reason'] as String?,
    );
  }

  static AutoReplyTriggerType _parseType(String? value) {
    switch (value) {
      case 'fixed':
        return AutoReplyTriggerType.fixed;
      default:
        return AutoReplyTriggerType.delay;
    }
  }

  static AutoReplyTriggerStatus _parseStatus(String? value) {
    switch (value) {
      case 'created':
        return AutoReplyTriggerStatus.created;
      case 'preparing':
        return AutoReplyTriggerStatus.preparing;
      case 'prepared':
        return AutoReplyTriggerStatus.prepared;
      case 'pending':
        return AutoReplyTriggerStatus.pending;
      case 'fired':
        return AutoReplyTriggerStatus.fired;
      case 'expired':
        return AutoReplyTriggerStatus.expired;
      case 'paused':
        return AutoReplyTriggerStatus.paused;
      case 'deleted':
        return AutoReplyTriggerStatus.deleted;
      // 旧数据兼容映射
      case 'scheduled':
        return AutoReplyTriggerStatus.pending;
      case 'completed':
        return AutoReplyTriggerStatus.fired;
      default:
        return AutoReplyTriggerStatus.pending;
    }
  }

  static AutoReplyTriggerPriority _parsePriority(String? value) {
    switch (value) {
      case 'high':
        return AutoReplyTriggerPriority.high;
      case 'low':
        return AutoReplyTriggerPriority.low;
      default:
        return AutoReplyTriggerPriority.medium;
    }
  }

  static TriggerSource _parseSource(String? value) {
    switch (value) {
      case 'userRequest':
        return TriggerSource.userRequest;
      case 'aiScheduler':
        return TriggerSource.aiScheduler;
      case 'systemPreset':
        return TriggerSource.systemPreset;
      default:
        return TriggerSource.userManual;
    }
  }
}

enum AutoReplyTriggerEventType { created, fired, deleted, paused, resumed, expired }

class AutoReplyTriggerEvent {
  final AutoReplyTriggerEventType type;
  final String triggerId;
  final String title;
  final DateTime timestamp;
  final String? reason; // 用于 expired 事件

  const AutoReplyTriggerEvent({
    required this.type,
    required this.triggerId,
    required this.title,
    required this.timestamp,
    this.reason,
  });
}

class AutoReplyTriggerLog {
  final String id;
  final String triggerId;
  final String title;
  final DateTime firedAt;
  final bool success;

  const AutoReplyTriggerLog({
    required this.id,
    required this.triggerId,
    required this.title,
    required this.firedAt,
    required this.success,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'trigger_id': triggerId,
        'title': title,
        'fired_at': firedAt.toIso8601String(),
        'success': success,
      };

  factory AutoReplyTriggerLog.fromJson(Map<String, dynamic> json) {
    return AutoReplyTriggerLog(
      id: (json['id'] as String?) ?? '',
      triggerId: (json['trigger_id'] as String?) ?? '',
      title: (json['title'] as String?) ?? '',
      firedAt: DateTime.tryParse((json['fired_at'] as String?) ?? '')?.toLocal() ?? DateTime.now(),
      success: json['success'] != false,
    );
  }
}
