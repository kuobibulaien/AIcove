import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/api/providers/token_usage.dart';
import '../../../core/app_logger.dart';
import '../../../core/api_client.dart';
import '../../../core/database/database.dart' hide Provider;
import '../../../core/media/media_store.dart';
import '../../../core/sync/cloud_local_write.dart';
import '../../../core/sync/cloud_setting_policy.dart';
import '../../settings/app_settings.dart';
import '../../sync/data/device_names.dart';
import '../model_request_ledger.dart';
import 'model_pricing_catalog.dart';
import 'token_usage_models.dart';

export 'model_pricing_catalog.dart' show OfficialPricingSyncResult;
export 'token_usage_models.dart';

const tokenUsageRollupPrefix = 'aicove.plugins.observability.usage_rollups.';

/// Per model execution. Nested executions collect their own HTTP responses.
class TokenUsageCaptureScope {
  TokenUsageCaptureScope({
    this.settings,
    this.providerId,
    this.modelFullId,
    this.scope,
    String? purpose,
    String? conversationId,
    String? turnId,
  }) : purpose = purpose ?? scope?.purpose,
       conversationId = conversationId ?? scope?.conversationId,
       turnId = turnId ?? scope?.turnId;
  final AppSettings? settings;
  final String? providerId, modelFullId, purpose, conversationId, turnId;
  final ModelRunScope? scope;
  TokenUsage usage = const TokenUsage(inputTokens: 0, outputTokens: 0);
  final Set<String> _requests = {};
  bool get hasUsage => _requests.isNotEmpty;
  static final Object _key = Object();
  static TokenUsageCaptureScope? get current =>
      Zone.current[_key] as TokenUsageCaptureScope?;
  Future<T> run<T>(Future<T> Function() action) =>
      runZoned(action, zoneValues: {_key: this});
  Future<T> runAsync<T>(Future<T> Function() action) => run(action);
  void _capture(String requestId, TokenUsage value) {
    if (_requests.add(requestId)) {
      usage = _requests.length == 1 ? value : usage + value;
    }
  }
}

class TokenUsageLedger with WidgetsBindingObserver {
  TokenUsageLedger({AppDatabase? database, this.isBackgroundIsolate = false})
    : _db = database;
  static final instance = TokenUsageLedger();
  AppDatabase? _db;
  bool isBackgroundIsolate;
  Future<void>? _restoring;
  Future<void> _publication = Future.value();
  Timer? _snapshotTimer;
  final _changes = StreamController<void>.broadcast();
  Stream<void> get changes => _changes.stream;

  DateTime? get lastOfficialPricingSyncAt =>
      ModelPricingCatalog.lastOfficialPricingSyncAt;

  Future<DateTime?> getLastOfficialPricingSyncTime() async {
    await ModelPricingCatalog.loadLocalCaches();
    return lastOfficialPricingSyncAt;
  }

  Future<OfficialPricingSyncResult> syncOfficialPricingCatalog({
    ApiClient? apiClient,
  }) async {
    final result = await ModelPricingCatalog.syncOfficialPricingCatalog(
      apiClient: apiClient,
    );
    _changes.add(null);
    return result;
  }

  void bindDatabase(AppDatabase database, {bool isBackgroundIsolate = false}) {
    final ledger = this;
    if (identical(ledger._db, database)) return;
    if (ledger._db != null && !ledger.isBackgroundIsolate) {
      WidgetsBinding.instance.removeObserver(ledger);
    }
    _cancelScheduledSnapshot();
    ledger._db = database;
    ledger.isBackgroundIsolate = isBackgroundIsolate;
    ledger._restoring = null;
    unawaited(ModelPricingCatalog.loadLocalCaches().catchError(ledger._warn));
    if (!isBackgroundIsolate) {
      WidgetsBinding.instance.addObserver(ledger);
      unawaited(ledger.publishLocalSnapshot().catchError(ledger._warn));
    }
  }

  void unbindDatabase(AppDatabase database) {
    if (!identical(_db, database)) return;
    if (!isBackgroundIsolate) WidgetsBinding.instance.removeObserver(this);
    _cancelScheduledSnapshot();
    _db = null;
    _restoring = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !isBackgroundIsolate) {
      unawaited(publishLocalSnapshot().catchError(_warn));
    }
  }

  void _warn(Object error) => AppLogger.warning(
    'TokenUsageLedger',
    '保存用量记录失败',
    metadata: {'error': '$error'},
  );

  Future<AppSettings> _settings(SharedPreferences prefs) async =>
      mapUiModelsToAppSettings(
        Map<String, dynamic>.from(
          jsonDecode(prefs.getString(cloudUiModelsKey) ?? '{}') as Map,
        ),
      );

  ModelConfig? _modelConfig(
    AppSettings settings,
    String providerId,
    String model,
  ) =>
      settings.modelConfigs['$providerId:$model'] ??
      settings.modelConfigs[model];

  String _rawModelId(String providerId, String model) =>
      model.startsWith('$providerId:')
      ? model.substring(providerId.length + 1)
      : model;

  ModelPricing? _pricing(
    AppSettings settings,
    String providerId,
    String model,
  ) {
    final raw = _rawModelId(providerId, model);
    return resolveEffectiveModelPricing(
      providerId: providerId,
      rawModelId: raw,
      modelConfig: _modelConfig(settings, providerId, raw),
      providerCustomConfig: settings.getProvider(providerId)?.customConfig,
    );
  }

  bool _isOpenRouter(String providerId, ProviderAuth? provider) {
    if (providerId.trim().toLowerCase() == 'openrouter') return true;
    final host = Uri.tryParse(
      provider?.apiBaseUrl.trim() ?? '',
    )?.host.toLowerCase();
    return host == 'openrouter.ai' ||
        (host?.endsWith('.openrouter.ai') ?? false);
  }

  Future<void> recordHttpRound({
    required String requestId,
    required String providerId,
    required String model,
    required TokenUsage usage,
    DateTime? occurredAt,
    String? purpose,
    String? conversationId,
    String? turnId,
    int? durationMs,
    int? roundIndex,
  }) async {
    final capture = TokenUsageCaptureScope.current;
    capture?._capture(requestId, usage);
    final db = _db;
    if (db == null) return;
    try {
      await ModelPricingCatalog.loadLocalCaches();
      final prefs = await SharedPreferences.getInstance();
      await _restore(db, prefs);
      final settings = capture?.settings ?? await _settings(prefs);
      final effectiveProvider = capture?.providerId ?? providerId;
      final effectiveModel = _rawModelId(
        effectiveProvider,
        capture?.modelFullId ?? model,
      );
      final config = _modelConfig(settings, effectiveProvider, effectiveModel);
      final provider = settings.getProvider(effectiveProvider);
      final reportedCost = usage.reportedCostUsd;
      final useReportedCost =
          reportedCost != null &&
          !hasManualModelPricing(config) &&
          _isOpenRouter(effectiveProvider, provider);
      final pricing = useReportedCost
          ? null
          : resolveEffectiveModelPricing(
              providerId: effectiveProvider,
              rawModelId: effectiveModel,
              modelConfig: config,
              providerCustomConfig: provider?.customConfig,
            );
      final run = capture?.scope ?? ModelRunScope.current;
      final row = TokenUsageEntry(
        requestId: requestId,
        deviceId: await MediaStore.localDeviceId,
        deviceName: await ownDeviceName(prefs),
        occurredAtMs: (occurredAt ?? DateTime.now()).millisecondsSinceEpoch,
        providerId: effectiveProvider,
        model: effectiveModel,
        purpose: purpose ?? capture?.purpose ?? run?.purpose ?? 'other',
        conversationId:
            conversationId ?? capture?.conversationId ?? run?.conversationId,
        turnId: turnId ?? capture?.turnId ?? run?.turnId,
        durationMs: durationMs,
        roundIndex: roundIndex,
        usage: usage,
        priced: useReportedCost || pricing != null,
        costMicros: useReportedCost
            ? (reportedCost *
                      1000000 *
                      effectivePricingMultiplier(
                        config,
                        provider?.customConfig,
                      ))
                  .round()
            : pricing == null
            ? null
            : calculateCostMicros(usage, pricing),
        currency: useReportedCost ? 'USD' : pricing?.currency,
      );
      await db.tokenUsageTransaction(() async {
        await db.customStatement(_entryInsertSql, _entryValues(row));
      });
      _changes.add(null);
      schedulePublishLocalSnapshot();
    } catch (error) {
      _warn(error);
    }
  }

  static const _entryInsertSql =
      'INSERT OR IGNORE INTO token_usage_entries '
      '(id,device_id,device_name,conversation_id,turn_id,round_index,purpose,provider_id,model,'
      'input_tokens,output_tokens,cached_input_tokens,cache_write_tokens,reasoning_tokens,'
      'is_estimated,priced,currency,cost_micros,duration_ms,created_at) '
      'VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)';
  List<Object?> _entryValues(TokenUsageEntry e) => [
    e.requestId,
    e.deviceId,
    e.deviceName,
    e.conversationId,
    e.turnId,
    e.roundIndex,
    e.purpose,
    e.providerId,
    e.model,
    e.inputTokens,
    e.outputTokens,
    e.cachedInputTokens,
    e.usage.cacheWriteTokens,
    e.usage.reasoningTokens,
    e.usage.isEstimated ? 1 : 0,
    e.priced ? 1 : 0,
    e.currency ?? 'USD',
    e.costMicros ?? 0,
    e.durationMs,
    e.occurredAtMs,
  ];
  static const _archiveInsertSql =
      'INSERT OR IGNORE INTO token_usage_archives '
      '(bucket_key,device_id,device_name,period,period_start_ms,provider_id,model,purpose,'
      'conversation_id,request_count,input_tokens,output_tokens,cached_input_tokens,'
      'cache_write_tokens,reasoning_tokens,estimated_count,priced_usd_micros,priced_cny_micros,'
      'unpriced_input_tokens,unpriced_output_tokens,unpriced_cached_tokens,unpriced_cache_write_tokens,'
      'price_currency,is_priced,period_end_ms,components) '
      'VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)';
  List<Object?> _archiveValues(TokenUsageEntry e) {
    Iterable<TokenUsageEntry> leaves(TokenUsageEntry row) sync* {
      if (row.children.isEmpty) {
        yield row;
      } else {
        for (final child in row.children) {
          yield* leaves(child);
        }
      }
    }

    final parts = leaves(e).toList();
    final costs = TokenUsageSummary(parts).costMicrosByCurrency;
    final unpriced = parts
        .where((p) => !p.priced)
        .fold(
          const TokenUsage(inputTokens: 0, outputTokens: 0),
          (sum, p) => sum + p.usage,
        );
    return [
      e.requestId,
      e.deviceId,
      e.deviceName,
      DateTime.fromMillisecondsSinceEpoch(
        e.occurredAtMs,
      ).toIso8601String().substring(
        0,
        e.periodEndMs != null &&
                e.periodEndMs! - e.occurredAtMs >
                    const Duration(days: 27).inMilliseconds
            ? 7
            : 10,
      ),
      e.occurredAtMs,
      e.providerId,
      e.model,
      e.purpose,
      e.conversationId ?? '',
      e.requestCount,
      e.inputTokens,
      e.outputTokens,
      e.cachedInputTokens,
      e.usage.cacheWriteTokens,
      e.usage.reasoningTokens,
      e.effectiveEstimatedCount,
      costs['USD'] ?? 0,
      costs['CNY'] ?? 0,
      unpriced.inputTokens,
      unpriced.outputTokens,
      unpriced.cachedInputTokens,
      unpriced.cacheWriteTokens,
      e.currency,
      e.priced ? 1 : 0,
      e.periodEndMs,
      e.children.isEmpty
          ? null
          : jsonEncode(e.children.map((c) => c.toJson()).toList()),
    ];
  }

  Future<List<TokenUsageEntry>> _local(
    AppDatabase db, {
    bool includeEntries = true,
    bool includeArchives = true,
    int? entriesBeforeMs,
    int? entriesLimit,
  }) async {
    final result = <TokenUsageEntry>[];
    for (final archive in [false, true]) {
      if ((archive && !includeArchives) || (!archive && !includeEntries)) {
        continue;
      }
      final table = archive ? 'token_usage_archives' : 'token_usage_entries';
      final variables = <Variable>[];
      var sql = 'SELECT * FROM $table';
      if (!archive && entriesBeforeMs != null) {
        sql += ' WHERE created_at < ?';
        variables.add(Variable.withInt(entriesBeforeMs));
      }
      if (!archive && entriesLimit != null) {
        sql += ' ORDER BY created_at DESC LIMIT ?';
        variables.add(Variable.withInt(entriesLimit));
      }
      for (final row
          in await db.customSelect(sql, variables: variables).get()) {
        final d = row.data;
        final priced = d[archive ? 'is_priced' : 'priced'] == 1;
        final currency = d[archive ? 'price_currency' : 'currency'] as String?;
        result.add(
          TokenUsageEntry(
            requestId: d[archive ? 'bucket_key' : 'id'] as String,
            deviceId: d['device_id'] as String,
            deviceName: d['device_name'] as String,
            occurredAtMs: d[archive ? 'period_start_ms' : 'created_at'] as int,
            providerId: d['provider_id'] as String,
            model: d['model'] as String,
            purpose: d['purpose'] as String,
            conversationId: (d['conversation_id'] as String?)?.isEmpty == true
                ? null
                : d['conversation_id'] as String?,
            turnId: archive ? null : d['turn_id'] as String?,
            durationMs: archive ? null : d['duration_ms'] as int?,
            roundIndex: archive ? null : d['round_index'] as int?,
            requestCount: archive ? d['request_count'] as int : 1,
            estimatedCount: archive ? d['estimated_count'] as int : null,
            usage: TokenUsage(
              inputTokens: d['input_tokens'] as int,
              outputTokens: d['output_tokens'] as int,
              cachedInputTokens: d['cached_input_tokens'] as int,
              cacheWriteTokens: d['cache_write_tokens'] as int,
              reasoningTokens: d['reasoning_tokens'] as int,
              isEstimated: archive
                  ? (d['estimated_count'] as int) > 0
                  : d['is_estimated'] == 1,
            ),
            priced: priced,
            currency: currency,
            costMicros: priced
                ? d[archive
                          ? (currency == 'CNY'
                                ? 'priced_cny_micros'
                                : 'priced_usd_micros')
                          : 'cost_micros']
                      as int
                : null,
            isArchive: archive,
            periodEndMs: archive ? d['period_end_ms'] as int? : null,
            children: archive && d['components'] != null
                ? (jsonDecode(d['components'] as String) as List)
                      .map(
                        (c) => TokenUsageEntry.fromJson(
                          Map<String, dynamic>.from(c as Map),
                        ),
                      )
                      .toList()
                : const [],
          ),
        );
      }
    }
    return result;
  }

  static const _bucketColumns = [
    'at',
    'end',
    'provider',
    'model',
    'purpose',
    'conversation',
    'count',
    'input',
    'output',
    'cached',
    'write',
    'reasoning',
    'estimated_count',
    'priced',
    'currency',
    'micros',
    'children',
  ];
  List<Object?> _pack(TokenUsageEntry e) => [
    e.occurredAtMs,
    e.periodEndMs,
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
    e.effectiveEstimatedCount,
    e.priced ? 1 : 0,
    e.currency,
    e.costMicros,
    e.children.isEmpty ? null : e.children.map(_pack).toList(),
  ];
  TokenUsageEntry _unpack(
    List<dynamic> row,
    String device,
    String name,
    String id,
  ) => TokenUsageEntry(
    requestId: id,
    deviceId: device,
    deviceName: name,
    occurredAtMs: row[0] as int,
    periodEndMs: row[1] as int?,
    providerId: row[2] as String,
    model: row[3] as String,
    purpose: row[4] as String,
    conversationId: row[5] as String?,
    requestCount: row[6] as int,
    usage: TokenUsage(
      inputTokens: row[7] as int,
      outputTokens: row[8] as int,
      cachedInputTokens: row[9] as int,
      cacheWriteTokens: row[10] as int,
      reasoningTokens: row[11] as int,
      isEstimated: (row[12] as int) > 0,
    ),
    estimatedCount: row[12] as int,
    priced: row[13] == 1,
    currency: row[14] as String?,
    costMicros: row[15] as int?,
    isArchive: true,
    children: row[16] == null
        ? const []
        : (row[16] as List).indexed
              .map((e) => _unpack(e.$2 as List, device, name, '$id:${e.$1}'))
              .toList(),
  );

  List<TokenUsageEntry> _parse(String? raw) {
    if (raw == null) return [];
    try {
      final snapshot = (jsonDecode(raw) as Map)['snapshot'] as Map;
      final rows = snapshot['buckets'] as List;
      return rows.indexed
          .map(
            (item) => item.$2 is Map
                ? TokenUsageEntry.fromJson(
                    Map<String, dynamic>.from(item.$2 as Map),
                  )
                : _unpack(
                    item.$2 as List,
                    snapshot['device_id'] as String,
                    snapshot['device_name'] as String? ?? '',
                    'rollup:${item.$1}',
                  ),
          )
          .toList();
    } on FormatException {
      return [];
    } on TypeError {
      return [];
    } on RangeError {
      return [];
    }
  }

  /// Import a restored local snapshot once into SQLite before any new writes.
  /// The marker lives in SQLite, so process restart and repeated publication
  /// cannot import the same snapshot twice.
  Future<void> _restore(
    AppDatabase db,
    SharedPreferences prefs,
  ) => _restoring ??=
      () async {
        await prefs.reload();
        final id = await MediaStore.localDeviceId;
        final restored = _parse(
          prefs.getString('$tokenUsageRollupPrefix$id.v1'),
        );
        await db.tokenUsageTransaction(() async {
          await db.customStatement(
            'CREATE TABLE IF NOT EXISTS token_usage_meta (id TEXT PRIMARY KEY NOT NULL, value INTEGER NOT NULL)',
          );
          if ((await db
                  .customSelect(
                    "SELECT value FROM token_usage_meta WHERE id = 'restored'",
                  )
                  .get())
              .isNotEmpty) {
            return;
          }
          final existing = await _local(db);
          final earliest = existing.isEmpty
              ? null
              : existing
                    .map((e) => e.occurredAtMs)
                    .reduce((a, b) => a < b ? a : b);
          for (final row in restored) {
            if (row.deviceId != id ||
                (earliest != null && row.occurredAtMs >= earliest)) {
              continue;
            }
            final archive = row.copyWith(
              requestId: 'restored:${row.requestId}',
              isArchive: true,
            );
            await db.customStatement(
              _archiveInsertSql,
              _archiveValues(archive),
            );
          }
          await db.customStatement(
            "INSERT INTO token_usage_meta(id,value) VALUES ('restored',1)",
          );
        });
      }().catchError((Object error, StackTrace stack) {
        _restoring = null;
        Error.throwWithStackTrace(error, stack);
      });

  String _key(TokenUsageEntry e, int start, String? conversation) =>
      jsonEncode([
        start,
        e.deviceId,
        e.providerId,
        e.model,
        e.purpose,
        conversation,
        e.currency,
        e.priced,
      ]);

  List<TokenUsageEntry> _aggregate(
    Iterable<TokenUsageEntry> rows,
    DateTime now, {
    bool monthly = false,
    bool conversations = true,
    bool preserveConversation = false,
  }) {
    final groups = <String, TokenUsageEntry>{};
    for (final e in rows) {
      final at = DateTime.fromMillisecondsSinceEpoch(e.occurredAtMs);
      final age = now.millisecondsSinceEpoch - e.occurredAtMs;
      final month =
          monthly ||
          age > const Duration(days: 90).inMilliseconds ||
          (e.periodEndMs != null &&
              e.periodEndMs! - e.occurredAtMs >
                  const Duration(days: 27).inMilliseconds);
      final start =
          (month
                  ? DateTime(at.year, at.month)
                  : DateTime(at.year, at.month, at.day))
              .millisecondsSinceEpoch;
      final end =
          (month
                  ? DateTime(at.year, at.month + 1)
                  : DateTime(at.year, at.month, at.day + 1))
              .millisecondsSinceEpoch -
          1;
      final conversation =
          preserveConversation ||
              (conversations &&
                  !month &&
                  age <= const Duration(days: 30).inMilliseconds)
          ? e.conversationId
          : null;
      final key = _key(e, start, conversation);
      final old = groups[key];
      groups[key] = e.copyWith(
        requestId: key,
        occurredAtMs: start,
        periodEndMs: end,
        conversationId: conversation,
        removeConversation: conversation == null,
        isArchive: true,
        usage: old == null ? e.usage : old.usage + e.usage,
        requestCount: (old?.requestCount ?? 0) + e.requestCount,
        estimatedCount:
            (old?.effectiveEstimatedCount ?? 0) + e.effectiveEstimatedCount,
        costMicros: e.priced
            ? (old?.costMicros ?? 0) + (e.costMicros ?? 0)
            : null,
        children: [...?old?.children, ...e.children],
      );
    }
    return groups.values.toList()
      ..sort((a, b) => b.occurredAtMs.compareTo(a.occurredAtMs));
  }

  Future<void> _archive(AppDatabase db, DateTime now) async {
    final cutoff = now
        .subtract(const Duration(days: 180))
        .millisecondsSinceEpoch;
    await db.tokenUsageTransaction(() async {
      final expiredEntries = await _local(
        db,
        includeArchives: false,
        entriesBeforeMs: cutoff,
      );
      if (expiredEntries.isEmpty) return;
      final archives = await _local(db, includeEntries: false);
      final all = [...archives, ...expiredEntries];
      final expired = all.where((e) => e.occurredAtMs < cutoff).toList();
      final buckets = [
        ...all.where((e) => e.isArchive && e.occurredAtMs >= cutoff),
        ..._aggregate(expired, now, monthly: true, preserveConversation: true),
      ];
      await db.customStatement('DELETE FROM token_usage_archives');
      for (final e in buckets) {
        await db.customStatement(_archiveInsertSql, _archiveValues(e));
      }
      await db.customStatement(
        'DELETE FROM token_usage_entries WHERE created_at < ?',
        [cutoff],
      );
    });
  }

  List<TokenUsageEntry> _bounded(List<TokenUsageEntry> rows, DateTime now) {
    var buckets = _aggregate(rows, now);
    final conversationBuckets = buckets
        .where((e) => e.conversationId != null)
        .toList();
    if (conversationBuckets.length > 500) {
      final keep = conversationBuckets.take(500).toSet();
      buckets = _aggregate([
        ...buckets.where((e) => e.conversationId == null || keep.contains(e)),
        ..._aggregate(conversationBuckets.skip(500), now, conversations: false),
      ], now);
    }
    // Fold oldest daily periods first; keep recent conversation buckets while
    // their detail still fits the shared snapshot budget.
    while (buckets.length > 600) {
      final daily = buckets
          .where(
            (e) =>
                e.periodEndMs != null &&
                e.periodEndMs! - e.occurredAtMs <=
                    const Duration(days: 27).inMilliseconds,
          )
          .toList();
      if (daily.isEmpty) break;
      final oldest = daily.last.occurredAtMs;
      final fold = daily.where((e) => e.occurredAtMs == oldest).toSet();
      buckets = _aggregate([
        ...buckets.where((e) => !fold.contains(e)),
        ..._aggregate(fold, now, monthly: true, conversations: false),
      ], now);
    }
    while (buckets.length > 600) {
      final last = buckets.removeLast();
      final before = buckets.removeLast();
      // Exceptional high-cardinality history retains components for later pricing.
      final children = [
        for (final e in [before, last])
          ...e.children.isEmpty ? [e] : e.children,
      ];
      buckets.add(
        before.copyWith(
          requestId: 'mixed:${last.occurredAtMs}',
          model: '*',
          purpose: 'mixed',
          occurredAtMs: last.occurredAtMs,
          periodEndMs: before.periodEndMs,
          removeConversation: true,
          usage: before.usage + last.usage,
          requestCount: before.requestCount + last.requestCount,
          estimatedCount:
              before.effectiveEstimatedCount + last.effectiveEstimatedCount,
          priced: false,
          children: children,
        ),
      );
    }
    return buckets;
  }

  void schedulePublishLocalSnapshot() {
    if (isBackgroundIsolate || _db == null) return;
    _cancelScheduledSnapshot();
    _snapshotTimer = Timer(const Duration(seconds: 3), () {
      unawaited(flushPendingSnapshot());
    });
  }

  void _cancelScheduledSnapshot() {
    _snapshotTimer?.cancel();
    _snapshotTimer = null;
  }

  Future<void> flushPendingSnapshot() async {
    if (_snapshotTimer == null) return;
    _cancelScheduledSnapshot();
    await publishLocalSnapshot().catchError(_warn);
  }

  Future<void> publishLocalSnapshot({DateTime? now}) {
    if (isBackgroundIsolate || _db == null) return Future.value();
    _cancelScheduledSnapshot();
    final db = _db!;
    final task = _publication.catchError(_warn).then((_) async {
      final prefs = await SharedPreferences.getInstance();
      await _restore(db, prefs);
      final time = now ?? DateTime.now();
      await _archive(db, time);
      final buckets = _bounded(await _local(db), time);
      final id = await MediaStore.localDeviceId;
      final key = '$tokenUsageRollupPrefix$id.v1';
      await cloudLocalWrite(() async {
        final value = canonicalSettingJson({
          'snapshot': {
            'version': 1,
            'device_id': id,
            'device_name': await ownDeviceName(prefs),
            'updated_at_ms': time.millisecondsSinceEpoch,
            'columns': _bucketColumns,
            'buckets': buckets.map(_pack).toList(),
          },
        });
        if (!await saveCloudPreference(prefs, key, value)) {
          throw StateError('Could not save usage rollup');
        }
        final journal = preferenceTimeJournal(prefs);
        final clock = Map<String, dynamic>.from(journal[key] as Map);
        clock.remove('value');
        journal[key] = {'snapshot': clock['snapshot']};
        await prefs.setString(cloudPreferenceTimesKey, jsonEncode(journal));
      });
      _changes.add(null);
    });
    _publication = task;
    return task;
  }

  TokenUsageEntry _resolve(TokenUsageEntry e, AppSettings settings) {
    if (e.children.isNotEmpty) {
      return e.copyWith(
        children: e.children.map((c) => _resolve(c, settings)).toList(),
      );
    }
    if (e.priced) return e;
    final p = _pricing(settings, e.providerId, e.model);
    return p == null
        ? e
        : e.copyWith(
            priced: true,
            currency: p.currency,
            costMicros: calculateCostMicros(e.usage, p),
          );
  }

  Future<TokenUsageReport> query({
    TokenUsageQuery filter = const TokenUsageQuery(),
    DateTime? now,
    AppSettings? settings,
  }) async {
    await ModelPricingCatalog.loadLocalCaches();
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final id = await MediaStore.localDeviceId;
    final db = _db;
    if (db != null) await _restore(db, prefs);
    final current = settings ?? await _settings(prefs);
    final rows = <TokenUsageEntry>[
      if (db != null)
        ...await _local(db)
      else
        ..._parse(prefs.getString('$tokenUsageRollupPrefix$id.v1')),
      for (final key in prefs.getKeys())
        if (key.startsWith(tokenUsageRollupPrefix) &&
            key.endsWith('.v1') &&
            key != '$tokenUsageRollupPrefix$id.v1')
          ..._parse(prefs.getString(key)).where(
            (e) =>
                e.deviceId != id &&
                key == '$tokenUsageRollupPrefix${e.deviceId}.v1',
          ),
    ];
    Iterable<TokenUsageEntry> leaves(TokenUsageEntry row) sync* {
      if (row.children.isEmpty) {
        yield row;
      } else {
        for (final child in row.children) {
          yield* leaves(child);
        }
      }
    }

    final entries =
        rows
            .expand(leaves)
            .where((e) => filter.matches(e, now ?? DateTime.now()))
            .map((e) => _resolve(e, current))
            .toList()
          ..sort((a, b) => b.occurredAtMs.compareTo(a.occurredAtMs));
    return TokenUsageReport(entries);
  }

  Future<Map<String, String>> _conversationTitles(AppDatabase? db) async {
    final titles = <String, String>{};
    if (db == null) return titles;
    for (final row
        in await db
            .customSelect('SELECT id, title, display_name FROM conversations')
            .get()) {
      final displayName = row.read<String>('display_name').trim();
      final title = row.read<String>('title').trim();
      final name = displayName.isNotEmpty ? displayName : title;
      if (name.isNotEmpty) titles[row.read<String>('id')] = name;
    }
    return titles;
  }

  String _conversationTitle(TokenUsageEntry e, Map<String, String> titles) =>
      titles[e.conversationId] ??
      (e.conversationId?.trim().isNotEmpty == true
          ? '已删除会话'
          : usagePurposeTitle(e.purpose));

  Future<UsageOverview> overview({
    UsageTimeRange range = UsageTimeRange.all,
    UsageGroupBy groupBy = UsageGroupBy.model,
    String? deviceId,
    DateTime? now,
    AppSettings? settings,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final current = settings ?? await _settings(prefs);
    final local = await MediaStore.localDeviceId;
    final allReport = await query(settings: current, now: now);
    final filtered = allReport.entries
        .where(
          (e) => usageQuery(range, deviceId).matches(e, now ?? DateTime.now()),
        )
        .toList();
    final report = TokenUsageReport(filtered);
    final by = TokenUsageGroupBy.values[groupBy.index];
    final grouped = report.groupBy(by);
    final groups = <UsageGroupItem>[];
    final conversationTitles = groupBy == UsageGroupBy.conversation
        ? await _conversationTitles(_db)
        : const <String, String>{};
    for (final item in grouped.entries) {
      final key = item.key;
      final members = filtered
          .where(
            (e) => switch (groupBy) {
              UsageGroupBy.model => '${e.providerId}:${e.rawModelId}' == key,
              UsageGroupBy.conversation => (e.conversationId ?? '') == key,
              UsageGroupBy.purpose => e.purpose == key,
              UsageGroupBy.device => e.deviceId == key,
            },
          )
          .toList();
      final e = members.first;
      final value = item.value;
      final raw = e.model.startsWith('${e.providerId}:')
          ? e.model.substring(e.providerId.length + 1)
          : e.model;
      groups.add(
        UsageGroupItem(
          key: key,
          title: switch (groupBy) {
            UsageGroupBy.model =>
              current.getCustomModelDisplayName(
                    raw,
                    providerId: e.providerId,
                  ) ??
                  raw,
            UsageGroupBy.conversation => _conversationTitle(
              e,
              conversationTitles,
            ),
            UsageGroupBy.purpose => usagePurposeTitle(e.purpose),
            UsageGroupBy.device =>
              e.deviceName.trim().isNotEmpty
                  ? e.deviceName
                  : (e.deviceId == local ? '本机' : '其他设备'),
          },
          subtitle: groupBy == UsageGroupBy.model
              ? current.getProviderDisplayName(e.providerId)
              : null,
          providerId: groupBy == UsageGroupBy.model ? e.providerId : null,
          rawModelId: groupBy == UsageGroupBy.model ? raw : null,
          isUnpricedModel:
              groupBy == UsageGroupBy.model && value.unpricedRequestCount > 0,
          requestCount: value.requestCount,
          inputTokens: value.inputTokens,
          outputTokens: value.outputTokens,
          cachedInputTokens: value.cachedInputTokens,
          usdCostMicros: value.costMicrosByCurrency['USD'] ?? 0,
          cnyCostMicros: value.costMicrosByCurrency['CNY'] ?? 0,
          shareRatio: report.summary.totalTokens == 0
              ? 0
              : value.totalTokens / report.summary.totalTokens,
        ),
      );
    }
    groups.sort(
      (a, b) => (b.inputTokens + b.outputTokens).compareTo(
        a.inputTokens + a.outputTokens,
      ),
    );
    final devices = <String, UsageDevice>{
      local: UsageDevice(
        deviceId: local,
        deviceName: await ownDeviceName(prefs),
        isLocal: true,
      ),
    };
    for (final key in prefs.getKeys()) {
      if (!key.startsWith(tokenUsageRollupPrefix) || !key.endsWith('.v1')) {
        continue;
      }
      try {
        final snapshot =
            (jsonDecode(prefs.getString(key)!) as Map)['snapshot'] as Map;
        final device = snapshot['device_id'] as String;
        if (key != '$tokenUsageRollupPrefix$device.v1') continue;
        devices[device] = UsageDevice(
          deviceId: device,
          deviceName: snapshot['device_name'] as String? ?? device,
          isLocal: device == local,
        );
      } on FormatException {
        continue;
      } on TypeError {
        continue;
      }
    }
    for (final e in allReport.entries) {
      devices[e.deviceId] = UsageDevice(
        deviceId: e.deviceId,
        deviceName: e.deviceName,
        isLocal: e.deviceId == local,
      );
    }
    final sum = report.summary;
    return UsageOverview(
      requestCount: sum.requestCount,
      inputTokens: sum.inputTokens,
      outputTokens: sum.outputTokens,
      cachedInputTokens: sum.cachedInputTokens,
      cacheWriteTokens: sum.usage.cacheWriteTokens,
      reasoningTokens: sum.usage.reasoningTokens,
      estimatedCount: filtered.fold(0, (n, e) => n + e.effectiveEstimatedCount),
      usdCostMicros: sum.costMicrosByCurrency['USD'] ?? 0,
      cnyCostMicros: sum.costMicrosByCurrency['CNY'] ?? 0,
      unpricedRequestCount: sum.unpricedRequestCount,
      groups: groups,
      availableDevices: devices.values.toList(),
    );
  }

  Future<List<UsageEntryView>> entries({
    UsageTimeRange range = UsageTimeRange.all,
    String? deviceId,
    int limit = 200,
    DateTime? now,
    AppSettings? settings,
  }) async {
    await ModelPricingCatalog.loadLocalCaches();
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final local = await MediaStore.localDeviceId;
    final current = settings ?? await _settings(prefs);
    final db = _db;
    if (db != null) await _restore(db, prefs);
    final rows = <TokenUsageEntry>[
      if (db != null) ...await _local(db, includeArchives: false),
      for (final run in await ModelRequestLedger.instance.all())
        if (run.deviceId != local &&
            run.status != 'running' &&
            run.usage != null)
          TokenUsageEntry(
            requestId: run.runId,
            deviceId: run.deviceId,
            deviceName: run.deviceName,
            occurredAtMs: run.endedAtMs ?? run.startedAtMs,
            providerId: run.providerId,
            model: run.model,
            purpose: run.purpose,
            usage: run.usage!,
            conversationId: run.conversationId,
            turnId: run.turnId,
            durationMs: run.durationMs,
          ),
    ];
    final filter = usageQuery(range, deviceId);
    final seen = <String>{};
    final matched =
        rows
            .where(
              (e) =>
                  filter.matches(e, now ?? DateTime.now()) &&
                  seen.add('${e.deviceId}:${e.requestId}'),
            )
            .toList()
          ..sort((a, b) => b.occurredAtMs.compareTo(a.occurredAtMs));
    final conversationTitles = await _conversationTitles(db);
    return matched
        .take(limit < 0 ? 0 : limit)
        .map(
          (e) => UsageEntryView(
            entry: _resolve(e, current),
            isRemote: e.deviceId != local,
            conversationTitle: _conversationTitle(e, conversationTitles),
            modelDisplayName:
                current.getCustomModelDisplayName(
                  e.rawModelId,
                  providerId: e.providerId,
                ) ??
                e.rawModelId,
            providerDisplayName: current.getProviderDisplayName(e.providerId),
          ),
        )
        .toList();
  }

  Future<List<TokenUsageEntry>> all() async => (await query()).entries;
  Future<String> exportCsv({
    TokenUsageQuery filter = const TokenUsageQuery(),
  }) async => (await query(filter: filter)).toCsv();
  Future<void> clearLocalUsage() => clearLocal();
  Future<void> clearLocal() async {
    final db = _db;
    if (db == null) return;
    final prefs = await SharedPreferences.getInstance();
    await _restore(db, prefs);
    await db.tokenUsageTransaction(() async {
      await db.customStatement('DELETE FROM token_usage_entries');
      await db.customStatement('DELETE FROM token_usage_archives');
    });
    if (!isBackgroundIsolate) await publishLocalSnapshot();
    _changes.add(null);
  }
}

// databaseProvider owns binding; reading usage alone must not open disk storage.
final tokenUsageLedgerProvider = Provider<TokenUsageLedger>(
  (ref) => TokenUsageLedger.instance,
);
final tokenUsageReportProvider =
    StreamProvider.family<TokenUsageReport, TokenUsageQuery>((
      ref,
      query,
    ) async* {
      final ledger = ref.watch(tokenUsageLedgerProvider);
      final settings = ref.watch(appSettingsProvider).valueOrNull;
      final signal = StreamController<void>();
      final local = ledger.changes.listen((_) => signal.add(null));
      final remote = externalSyncChanges.listen((key) {
        if (key == null || key.startsWith(tokenUsageRollupPrefix)) {
          signal.add(null);
        }
      });
      try {
        yield await ledger.query(filter: query, settings: settings);
        await for (final _ in signal.stream) {
          yield await ledger.query(filter: query, settings: settings);
        }
      } finally {
        await local.cancel();
        await remote.cancel();
        await signal.close();
      }
    });

/// A single change source covers local writes and incoming usage/run snapshots.
final usageLedgerTickProvider = StreamProvider<int>((ref) async* {
  final signal = StreamController<void>();
  final local = ref
      .watch(tokenUsageLedgerProvider)
      .changes
      .listen((_) => signal.add(null));
  final remote = externalSyncChanges.listen((key) {
    if (key == null ||
        key.startsWith(tokenUsageRollupPrefix) ||
        key.startsWith('aicove.plugins.observability.model_runs.')) {
      signal.add(null);
    }
  });
  var tick = 0;
  try {
    yield tick++;
    await for (final _ in signal.stream) {
      yield tick++;
    }
  } finally {
    await local.cancel();
    await remote.cancel();
    await signal.close();
  }
});
typedef UsageOverviewParams = ({
  UsageTimeRange range,
  UsageGroupBy groupBy,
  String? deviceId,
});
typedef UsageEntriesParams = ({
  UsageTimeRange range,
  String? deviceId,
  int limit,
});
final usageOverviewProvider =
    FutureProvider.family<UsageOverview, UsageOverviewParams>((ref, args) {
      ref.watch(usageLedgerTickProvider);
      final settings = ref.watch(appSettingsProvider).valueOrNull;
      return ref
          .watch(tokenUsageLedgerProvider)
          .overview(
            range: args.range,
            groupBy: args.groupBy,
            deviceId: args.deviceId,
            settings: settings,
          );
    });
final usageEntriesProvider =
    FutureProvider.family<List<UsageEntryView>, UsageEntriesParams>((
      ref,
      args,
    ) {
      ref.watch(usageLedgerTickProvider);
      final settings = ref.watch(appSettingsProvider).valueOrNull;
      return ref
          .watch(tokenUsageLedgerProvider)
          .entries(
            range: args.range,
            deviceId: args.deviceId,
            limit: args.limit,
            settings: settings,
          );
    });
final officialPricingSyncTimeProvider = FutureProvider<DateTime?>((ref) {
  ref.watch(usageLedgerTickProvider);
  return ref.watch(tokenUsageLedgerProvider).getLastOfficialPricingSyncTime();
});

final tokenUsageChangeTickProvider = usageLedgerTickProvider;
final tokenUsageOverviewProvider = usageOverviewProvider;
final tokenUsageEntriesProvider = usageEntriesProvider;

String buildUsageCsvExport(
  List<UsageEntryView> entries, {
  Map<String, String> conversationTitles = const {},
  AppSettings? settings,
}) {
  String cell(Object? value) {
    var text = value?.toString() ?? '';
    if (RegExp(r'^[=+@\-\t\r]').hasMatch(text)) text = "'$text";
    return '"${text.replaceAll('"', '""')}"';
  }

  final rows = <List<Object?>>[
    [
      '时间',
      '设备',
      '来源',
      '渠道',
      '模型',
      '用途',
      '角色',
      '输入Token',
      '输出Token',
      '缓存读取Token',
      '缓存写入Token',
      '思考Token',
      '估算',
      '币种',
      '花费',
      '已设单价',
    ],
    for (final view in entries)
      [
        view.createdAtDateTime.toIso8601String(),
        view.deviceName,
        view.isRemote ? '其他设备' : '本机',
        view.providerId,
        settings?.modelDisplayNames['${view.providerId}:${view.rawModelId}'] ??
            settings?.modelDisplayNames[view.rawModelId] ??
            view.rawModelId,
        view.purposeTitle,
        conversationTitles[view.conversationId] ?? view.conversationId,
        view.inputTokens,
        view.outputTokens,
        view.cachedInputTokens,
        view.usage.cacheWriteTokens,
        view.usage.reasoningTokens,
        view.isEstimated ? '是' : '否',
        view.currency,
        view.costMicros == null
            ? null
            : (view.costMicros! / 1000000).toStringAsFixed(6),
        view.priced ? '是' : '否',
      ],
  ];
  return '\uFEFF${rows.map((r) => r.map(cell).join(',')).join('\r\n')}';
}
