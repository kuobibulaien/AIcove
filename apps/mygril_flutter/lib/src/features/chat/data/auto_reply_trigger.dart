enum AutoReplyTriggerType { delay, fixed }

enum AutoReplyTriggerStatus { scheduled, paused, completed }

enum AutoReplyTriggerPriority { high, medium, low }

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
  final String? contactId; // 指定联系人ID
  final String? prompt; // 唤醒提示词
  final AutoReplyTriggerPriority priority; // 优先级
  final String? cachedContent; // 预生成的消息内容

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
    this.lastFiredAt,
    this.contactId,
    this.prompt,
    this.priority = AutoReplyTriggerPriority.medium,
    this.cachedContent,
  });

  bool get isActive => status == AutoReplyTriggerStatus.scheduled;

  bool shouldFire(DateTime now, {bool allowNightOverride = false}) {
    if (!isActive) return false;
    if (!allowNightOverride && !allowNight) {
      final hour = now.hour;
      if (hour >= 23 || hour < 7) return false;
    }
    return !nextFireAt.isAfter(now);
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
    };
  }

  factory AutoReplyTrigger.fromJson(Map<String, dynamic> json) {
    DateTime _parse(String value) => DateTime.tryParse(value)?.toLocal() ?? DateTime.now();
    return AutoReplyTrigger(
      id: (json['id'] as String?) ?? '',
      title: (json['title'] as String?) ?? '自定义触发',
      type: _safeType(json['type'] as String?),
      status: _safeStatus(json['status'] as String?),
      createdAt: json['created_at'] is String ? _parse(json['created_at'] as String) : DateTime.now(),
      nextFireAt: json['next_fire_at'] is String ? _parse(json['next_fire_at'] as String) : DateTime.now(),
      allowNight: json['allow_night'] != false,
      requireExact: json['require_exact'] == true,
      delayMinutes: (json['delay_minutes'] as num?)?.toInt() ?? 30,
      manual: json['manual'] != false,
      lastFiredAt: json['last_fired_at'] is String ? _parse(json['last_fired_at'] as String) : null,
      contactId: json['contact_id'] as String?,
      prompt: json['prompt'] as String?,
      priority: _safePriority(json['priority'] as String?),
      cachedContent: json['cached_content'] as String?,
    );
  }

  static AutoReplyTriggerType _safeType(String? value) {
    return AutoReplyTriggerType.values.firstWhere(
      (e) => e.name == value,
      orElse: () => AutoReplyTriggerType.delay,
    );
  }

  static AutoReplyTriggerStatus _safeStatus(String? value) {
    return AutoReplyTriggerStatus.values.firstWhere(
      (e) => e.name == value,
      orElse: () => AutoReplyTriggerStatus.scheduled,
    );
  }

  static AutoReplyTriggerPriority _safePriority(String? value) {
    return AutoReplyTriggerPriority.values.firstWhere(
      (e) => e.name == value,
      orElse: () => AutoReplyTriggerPriority.medium,
    );
  }
}

enum AutoReplyTriggerEventType { created, fired, deleted, paused, resumed }

class AutoReplyTriggerEvent {
  final AutoReplyTriggerEventType type;
  final String triggerId;
  final String title;
  final DateTime timestamp;
  const AutoReplyTriggerEvent({
    required this.type,
    required this.triggerId,
    required this.title,
    required this.timestamp,
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
