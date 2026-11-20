import '../../../core/api/providers/token_usage.dart';

/// A billable HTTP response, or an aggregate with the same accounting units.
class TokenUsageEntry {
  const TokenUsageEntry({
    required this.requestId,
    required this.deviceId,
    required this.deviceName,
    required this.occurredAtMs,
    required this.providerId,
    required this.model,
    required this.purpose,
    required this.usage,
    this.conversationId,
    this.turnId,
    this.durationMs,
    this.roundIndex,
    this.requestCount = 1,
    this.priced = false,
    this.costMicros,
    this.currency,
    this.isArchive = false,
    this.periodEndMs,
    this.children = const [],
    this.estimatedCount,
  });
  final String requestId, deviceId, deviceName, providerId, model, purpose;
  final String? conversationId, turnId, currency;
  final int occurredAtMs, requestCount;
  final int? estimatedCount;
  int get effectiveEstimatedCount =>
      estimatedCount ?? (usage.isEstimated ? requestCount : 0);
  final int? costMicros, durationMs, roundIndex, periodEndMs;
  final bool priced, isArchive;
  final TokenUsage usage;
  final List<TokenUsageEntry> children;
  String get rawModelId => model.startsWith('$providerId:')
      ? model.substring(providerId.length + 1)
      : model;
  int get inputTokens => usage.inputTokens;
  int get outputTokens => usage.outputTokens;
  int get cachedInputTokens => usage.cachedInputTokens;
  int get totalTokens => usage.totalTokens;
  double? get cost => costMicros == null ? null : costMicros! / 1000000;

  TokenUsageEntry copyWith({
    String? requestId,
    String? conversationId,
    String? model,
    String? purpose,
    int? occurredAtMs,
    int? periodEndMs,
    TokenUsage? usage,
    int? requestCount,
    bool? priced,
    int? costMicros,
    String? currency,
    bool? isArchive,
    bool removeConversation = false,
    List<TokenUsageEntry>? children,
    int? estimatedCount,
  }) => TokenUsageEntry(
    requestId: requestId ?? this.requestId,
    deviceId: deviceId,
    deviceName: deviceName,
    providerId: providerId,
    model: model ?? this.model,
    purpose: purpose ?? this.purpose,
    usage: usage ?? this.usage,
    occurredAtMs: occurredAtMs ?? this.occurredAtMs,
    periodEndMs: periodEndMs ?? this.periodEndMs,
    conversationId: removeConversation
        ? null
        : conversationId ?? this.conversationId,
    turnId: turnId,
    durationMs: durationMs,
    roundIndex: roundIndex,
    requestCount: requestCount ?? this.requestCount,
    priced: priced ?? this.priced,
    costMicros: costMicros ?? this.costMicros,
    currency: currency ?? this.currency,
    isArchive: isArchive ?? this.isArchive,
    children: children ?? this.children,
    estimatedCount: estimatedCount ?? this.estimatedCount,
  );

  Map<String, dynamic> toJson() => {
    'id': requestId,
    'device': deviceId,
    'name': deviceName,
    'at': occurredAtMs,
    'provider': providerId,
    'model': model,
    'purpose': purpose,
    'conversation': conversationId,
    'turn': turnId,
    'duration': durationMs,
    'round': roundIndex,
    'count': requestCount,
    'usage': usage.toJson(),
    'priced': priced,
    'micros': costMicros,
    'currency': currency,
    'archive': isArchive,
    'end': periodEndMs,
    'estimated_count': effectiveEstimatedCount,
    if (children.isNotEmpty)
      'children': children.map((c) => c.toJson()).toList(),
  };
  factory TokenUsageEntry.fromJson(Map<String, dynamic> j) => TokenUsageEntry(
    requestId: j['id'] as String,
    deviceId: j['device'] as String,
    deviceName: j['name'] as String? ?? '',
    occurredAtMs: j['at'] as int,
    providerId: j['provider'] as String,
    model: j['model'] as String,
    purpose: j['purpose'] as String,
    conversationId: j['conversation'] as String?,
    turnId: j['turn'] as String?,
    durationMs: j['duration'] as int?,
    roundIndex: j['round'] as int?,
    requestCount: j['count'] as int? ?? 1,
    usage: TokenUsage.fromJson(Map<String, dynamic>.from(j['usage'] as Map)),
    priced: j['priced'] == true,
    costMicros: j['micros'] as int?,
    currency: j['currency'] as String?,
    isArchive: j['archive'] == true,
    periodEndMs: j['end'] as int?,
    estimatedCount: j['estimated_count'] as int?,
    children: (j['children'] as List? ?? [])
        .map(
          (c) => TokenUsageEntry.fromJson(Map<String, dynamic>.from(c as Map)),
        )
        .toList(),
  );
}

enum TokenUsagePeriod { today, last7Days, last30Days, all }

enum TokenUsageGroupBy { model, conversation, purpose, device }

class TokenUsageQuery {
  const TokenUsageQuery({
    this.period = TokenUsagePeriod.all,
    this.deviceId,
    this.since,
    this.until,
  });
  final TokenUsagePeriod period;
  final String? deviceId;
  final DateTime? since, until;
  bool matches(TokenUsageEntry row, DateTime now) {
    final day = DateTime(now.year, now.month, now.day);
    final start =
        since ??
        switch (period) {
          TokenUsagePeriod.today => day,
          TokenUsagePeriod.last7Days => day.subtract(const Duration(days: 6)),
          TokenUsagePeriod.last30Days => day.subtract(const Duration(days: 29)),
          TokenUsagePeriod.all => null,
        };
    return (deviceId == null || row.deviceId == deviceId) &&
        (start == null ||
            (row.periodEndMs ?? row.occurredAtMs) >=
                start.millisecondsSinceEpoch) &&
        (until == null || row.occurredAtMs < until!.millisecondsSinceEpoch);
  }
}

class TokenUsageSummary {
  TokenUsageSummary(Iterable<TokenUsageEntry> rows) {
    for (final row in rows) {
      usage = usage + row.usage;
      requestCount += row.requestCount;
      if (row.priced && row.costMicros != null && row.currency != null) {
        costMicrosByCurrency.update(
          row.currency!,
          (v) => v + row.costMicros!,
          ifAbsent: () => row.costMicros!,
        );
      } else {
        unpricedRequestCount += row.requestCount;
      }
    }
  }
  TokenUsage usage = const TokenUsage(inputTokens: 0, outputTokens: 0);
  int requestCount = 0, unpricedRequestCount = 0;
  final Map<String, int> costMicrosByCurrency = {};
  int get totalTokens => usage.totalTokens;
  int get inputTokens => usage.inputTokens;
  int get outputTokens => usage.outputTokens;
  int get cachedInputTokens => usage.cachedInputTokens;
}

class TokenUsageReport {
  TokenUsageReport(this.entries) : summary = TokenUsageSummary(entries);
  final List<TokenUsageEntry> entries;
  final TokenUsageSummary summary;
  Map<String, TokenUsageSummary> groupBy(TokenUsageGroupBy by) {
    final groups = <String, List<TokenUsageEntry>>{};
    for (final e in entries) {
      final key = switch (by) {
        TokenUsageGroupBy.model => '${e.providerId}:${e.rawModelId}',
        TokenUsageGroupBy.conversation => e.conversationId ?? '',
        TokenUsageGroupBy.purpose => e.purpose,
        TokenUsageGroupBy.device => e.deviceId,
      };
      (groups[key] ??= []).add(e);
    }
    return groups.map((k, v) => MapEntry(k, TokenUsageSummary(v)));
  }

  String toCsv() {
    String cell(Object? value) {
      var text = value?.toString() ?? '';
      // Keep spreadsheets from treating model/device labels as formulas.
      if (RegExp(r'^[=+@\-\t\r]').hasMatch(text)) text = "'$text";
      return '"${text.replaceAll('"', '""')}"';
    }

    final rows = <List<Object?>>[
      [
        'time',
        'device',
        'provider',
        'model',
        'purpose',
        'conversation',
        'requests',
        'input_tokens',
        'output_tokens',
        'cached_input_tokens',
        'cache_write_tokens',
        'reasoning_tokens',
        'estimated',
        'priced',
        'currency',
        'cost_micros',
        'archive',
      ],
      for (final e in entries)
        [
          DateTime.fromMillisecondsSinceEpoch(e.occurredAtMs).toIso8601String(),
          e.deviceName,
          e.providerId,
          e.model,
          e.purpose,
          e.conversationId,
          e.requestCount,
          e.inputTokens,
          e.outputTokens,
          e.cachedInputTokens,
          e.usage.cacheWriteTokens,
          e.usage.reasoningTokens,
          e.usage.isEstimated,
          e.priced,
          e.currency,
          e.costMicros,
          e.isArchive,
        ],
    ];
    return rows.map((r) => r.map(cell).join(',')).join('\r\n');
  }
}

enum UsageTimeRange { today, days7, days30, all }

enum UsageGroupBy { model, conversation, purpose, device }

const usagePurposeTitles = <String, String>{
  'chat': '日常聊天',
  'compaction': '自动压缩上下文',
  'memory': '整理长期记忆',
  'memory_consolidate': '整理长期记忆',
  'proactive_plan': '角色主动发消息',
  'proactive_reply': '角色主动发消息',
  'task_agent': '后台杂活助手',
  'voice_brief': '语音通话总结',
  'voice_summary': '语音通话总结',
  'webapp': '空间小网页',
  'probe': '连接测试',
};
String usagePurposeLabel(String purpose) =>
    usagePurposeTitles[purpose] ?? '后台任务';
String usagePurposeTitle(String purpose) => usagePurposeLabel(purpose);
TokenUsageQuery usageQuery(UsageTimeRange range, String? deviceId) =>
    TokenUsageQuery(
      period: switch (range) {
        UsageTimeRange.today => TokenUsagePeriod.today,
        UsageTimeRange.days7 => TokenUsagePeriod.last7Days,
        UsageTimeRange.days30 => TokenUsagePeriod.last30Days,
        UsageTimeRange.all => TokenUsagePeriod.all,
      },
      deviceId: deviceId,
    );

class UsageDevice {
  const UsageDevice({
    required this.deviceId,
    required this.deviceName,
    required this.isLocal,
  });
  final String deviceId, deviceName;
  final bool isLocal;
  String get id => deviceId;
  String get name => deviceName;
}

class UsageGroupItem {
  const UsageGroupItem({
    required this.key,
    required this.title,
    this.subtitle,
    this.providerId,
    this.rawModelId,
    this.isUnpricedModel = false,
    required this.requestCount,
    required this.inputTokens,
    required this.outputTokens,
    required this.cachedInputTokens,
    required this.usdCostMicros,
    required this.cnyCostMicros,
    required this.shareRatio,
  });
  final String key, title;
  final String? subtitle, providerId, rawModelId;
  final bool isUnpricedModel;
  final int requestCount,
      inputTokens,
      outputTokens,
      cachedInputTokens,
      usdCostMicros,
      cnyCostMicros;
  final double shareRatio;
}

class UsageOverview {
  const UsageOverview({
    required this.requestCount,
    required this.inputTokens,
    required this.outputTokens,
    required this.cachedInputTokens,
    required this.cacheWriteTokens,
    required this.reasoningTokens,
    required this.estimatedCount,
    required this.usdCostMicros,
    required this.cnyCostMicros,
    required this.unpricedRequestCount,
    required this.groups,
    required this.availableDevices,
  });
  final int requestCount,
      inputTokens,
      outputTokens,
      cachedInputTokens,
      cacheWriteTokens,
      reasoningTokens,
      estimatedCount,
      usdCostMicros,
      cnyCostMicros,
      unpricedRequestCount;
  final List<UsageGroupItem> groups;
  final List<UsageDevice> availableDevices;
  int get totalTokens => inputTokens + outputTokens;
}

class UsageEntryView {
  const UsageEntryView({
    required this.entry,
    required this.isRemote,
    this.conversationTitle,
    this.modelDisplayName,
    this.providerDisplayName,
  });
  final TokenUsageEntry entry;
  final bool isRemote;
  final String? conversationTitle, modelDisplayName, providerDisplayName;
  String get id => entry.requestId;
  String get deviceId => entry.deviceId;
  String get deviceName => entry.deviceName;
  String get providerId => entry.providerId;
  String get model => entry.model;
  String get rawModelId => model.startsWith('$providerId:')
      ? model.substring(providerId.length + 1)
      : model;
  String get purpose => entry.purpose;
  String get purposeTitle => usagePurposeTitle(purpose);
  String? get conversationId => entry.conversationId;
  int get createdAt => entry.occurredAtMs;
  DateTime get createdAtDateTime =>
      DateTime.fromMillisecondsSinceEpoch(createdAt);
  TokenUsage get usage => entry.usage;
  bool get isEstimated => usage.isEstimated;
  bool get priced => entry.priced;
  String? get currency => entry.currency;
  int? get costMicros => entry.costMicros;
  int get inputTokens => usage.inputTokens;
  int get outputTokens => usage.outputTokens;
  int get totalTokens => usage.totalTokens;
  int get cachedInputTokens => usage.cachedInputTokens;
}

typedef UsageDeviceOption = UsageDevice;
