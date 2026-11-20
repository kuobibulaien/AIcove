import 'dart:async';
import 'dart:convert';

import 'package:aicove_flutter/src/core/api/providers/token_usage.dart';
import 'package:aicove_flutter/src/core/api_client.dart';
import 'package:aicove_flutter/src/core/database/database.dart';
import 'package:aicove_flutter/src/core/sync/cloud_setting_policy.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_types.dart';
import 'package:aicove_flutter/src/features/chat/services/provider_key_failure.dart';
import 'package:aicove_flutter/src/features/observability/model_request_ledger.dart';
import 'package:aicove_flutter/src/features/observability/token_usage_ledger.dart';
import 'package:aicove_flutter/src/features/observability/usage/model_pricing_catalog.dart'
    show resetModelPricingCachesForTesting;
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    show AsyncValueX, ProviderContainer;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const usage = TokenUsage(
  inputTokens: 100,
  outputTokens: 20,
  cachedInputTokens: 30,
  cacheWriteTokens: 10,
  reasoningTokens: 5,
);
const key = '${tokenUsageRollupPrefix}local.v1';

List<dynamic> buckets(String value) =>
    ((jsonDecode(value) as Map)['snapshot'] as Map)['buckets'] as List;

class _UsageSettings extends AppSettingsNotifier {
  @override
  Future<AppSettings> build() async => mapUiModelsToAppSettings({});
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  late TokenUsageLedger ledger;
  setUp(() {
    resetModelPricingCachesForTesting();
    SharedPreferences.setMockInitialValues({'aicove.cloud.device_id': 'local'});
    db = AppDatabase.forTesting(NativeDatabase.memory());
    ledger = TokenUsageLedger(database: db, isBackgroundIsolate: true);
  });
  tearDown(() async {
    TokenUsageLedger.instance.unbindDatabase(db);
    await db.close();
    resetModelPricingCachesForTesting();
  });
  Future<void> write(
    String id, {
    DateTime? at,
    String model = 'unknown',
    String? conversation,
  }) => ledger.recordHttpRound(
    requestId: id,
    providerId: 'p',
    model: model,
    usage: usage,
    occurredAt: at,
    conversationId: conversation,
    purpose: 'chat',
  );

  test(
    'official sync refreshes historical pricing and restores it locally',
    () async {
      await write('before', model: 'vendor/pricing-sync-demo');
      await write('fixed', model: 'gpt-4o-mini');
      final prior = {for (final row in await ledger.all()) row.requestId: row};
      expect(prior['before']!.priced, isFalse);
      expect(prior['fixed']!.priced, isTrue);
      expect(await ledger.getLastOfficialPricingSyncTime(), isNull);

      final container = ProviderContainer(
        overrides: [tokenUsageLedgerProvider.overrideWithValue(ledger)],
      );
      addTearDown(container.dispose);
      final updatedTime = Completer<DateTime>();
      final listener = container.listen(officialPricingSyncTimeProvider, (
        _,
        value,
      ) {
        final timestamp = value.valueOrNull;
        if (timestamp != null && !updatedTime.isCompleted) {
          updatedTime.complete(timestamp);
        }
      }, fireImmediately: true);
      addTearDown(listener.close);
      expect(
        await container.read(officialPricingSyncTimeProvider.future),
        isNull,
      );

      final client = MockClient(
        (_) async => http.Response(
          jsonEncode({
            'openai': {
              'models': {
                'pricing-sync-demo': {
                  'cost': {'input': 2, 'output': 4, 'cache_read': 1},
                },
                'gpt-4o-mini': {
                  'cost': {'input': 200, 'output': 300},
                },
              },
            },
          }),
          200,
        ),
      );
      addTearDown(client.close);
      final change = ledger.changes.first;
      final OfficialPricingSyncResult result = await ledger
          .syncOfficialPricingCatalog(apiClient: ApiClient(client: client));
      await change;
      expect(await updatedTime.future, result.syncedAt);
      expect(result.modelCount, 2);
      expect(ledger.lastOfficialPricingSyncAt, result.syncedAt);
      final fresh = {for (final row in await ledger.all()) row.requestId: row};
      expect(fresh['before']!.priced, isTrue);
      expect(fresh['before']!.currency, 'USD');
      expect(fresh['before']!.costMicros, 255);
      expect(fresh['fixed']!.costMicros, prior['fixed']!.costMicros);

      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString('aicove.observability.official_pricing_cache.v1'),
        isNotNull,
      );
      resetModelPricingCachesForTesting();
      final restarted = TokenUsageLedger(
        database: db,
        isBackgroundIsolate: true,
      );
      expect(restarted.lastOfficialPricingSyncAt, isNull);
      expect(
        (await restarted.query()).entries
            .firstWhere((e) => e.requestId == 'before')
            .costMicros,
        255,
      );
      expect(await restarted.getLastOfficialPricingSyncTime(), result.syncedAt);
    },
  );

  test('reported cost is OpenRouter-only and manual rates still win', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      cloudUiModelsKey,
      jsonEncode({
        'providers': [
          {
            'id': 'router-alias',
            'apiBaseUrl': 'https://api.openrouter.ai/api/v1',
            'custom_config': {'priceMultiplier': 2},
          },
          {
            'id': 'newapi',
            'apiBaseUrl': 'https://openrouter.ai.relay.example/v1',
          },
        ],
        'model_configs': {
          'router-alias:unknown': {'price_multiplier': 3},
          'router-alias:gpt-4o-mini': {
            'input_price_per_million': 4,
            'price_currency': 'CNY',
          },
        },
      }),
    );
    Future<void> record(
      String id,
      String provider,
      String model,
      double value,
    ) => ledger.recordHttpRound(
      requestId: id,
      providerId: provider,
      model: model,
      usage: TokenUsage.fromOpenAiUsage({
        'prompt_tokens': 100,
        'completion_tokens': 20,
        'cost': value,
      })!,
    );
    await record('alias', 'router-alias', 'unknown', .0025);
    await record('provider-id', 'openrouter', 'unknown', 0);
    await record('manual', 'router-alias', 'gpt-4o-mini', .25);
    await record('custom', 'newapi', 'unknown', 900);
    await record('offline', 'newapi', 'gpt-4o-mini', 900);
    final rows = {for (final row in await ledger.all()) row.requestId: row};
    expect(rows['alias']!.costMicros, 15000);
    expect(rows['alias']!.currency, 'USD');
    expect(rows['alias']!.priced, isTrue);
    expect(rows['provider-id']!.costMicros, 0);
    expect(rows['provider-id']!.priced, isTrue);
    expect(rows['manual']!.costMicros, 800);
    expect(rows['manual']!.currency, 'CNY');
    expect(rows['custom']!.priced, isFalse);
    expect(rows['custom']!.costMicros, isNull);
    expect(rows['offline']!.costMicros, 27);
  });

  test(
    'overview resolves display names and never uses conversation IDs',
    () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        cloudUiModelsKey,
        jsonEncode({
          'providers': [
            {'id': 'p', 'name': 'P', 'displayName': ' 我的渠道 '},
          ],
          'model_display_names': {'p:unknown': '模型备注'},
        }),
      );
      for (final (id, title, name) in [
        ('conv_named', '原始标题', ' 角色名 '),
        ('conv_title', ' 会话标题 ', ' '),
        ('conv_blank', ' ', ' '),
      ]) {
        await db
            .into(db.conversations)
            .insert(
              ConversationsCompanion.insert(
                id: id,
                title: title,
                displayName: name,
                createdAt: 1,
                updatedAt: 1,
              ),
            );
        await write(id, conversation: id);
      }
      await write('deleted', conversation: 'conv_deleted');
      await write('background');
      await write('empty', conversation: '');
      final model = (await ledger.overview()).groups.single;
      expect(model.title, '模型备注');
      expect(model.subtitle, '我的渠道');
      final groups = (await ledger.overview(
        groupBy: UsageGroupBy.conversation,
      )).groups;
      final titles = {for (final group in groups) group.key: group.title};
      expect(titles['conv_named'], '角色名');
      expect(titles['conv_title'], '会话标题');
      expect(titles['conv_blank'], '已删除会话');
      expect(titles['conv_deleted'], '已删除会话');
      expect(titles[''], usagePurposeTitle('chat'));
      final entries = await ledger.entries();
      final byId = {for (final view in entries) view.id: view};
      expect(byId['conv_named']!.conversationTitle, '角色名');
      expect(byId['conv_title']!.conversationTitle, '会话标题');
      expect(byId['conv_blank']!.conversationTitle, '已删除会话');
      expect(byId['deleted']!.conversationTitle, '已删除会话');
      expect(byId['background']!.conversationTitle, usagePurposeTitle('chat'));
      expect(byId['empty']!.conversationTitle, usagePurposeTitle('chat'));
      expect(entries.every((e) => e.modelDisplayName == '模型备注'), isTrue);
      expect(entries.every((e) => e.providerDisplayName == '我的渠道'), isTrue);
    },
  );

  test('usage provider reads without opening a database', () async {
    final container = ProviderContainer(
      overrides: [appSettingsProvider.overrideWith(_UsageSettings.new)],
    );
    addTearDown(container.dispose);
    await container.read(appSettingsProvider.future);
    await container.read(usageLedgerTickProvider.future);
    final overview = await container.read(
      tokenUsageOverviewProvider((
        range: UsageTimeRange.all,
        groupBy: UsageGroupBy.model,
        deviceId: null,
      )).future,
    );
    expect(overview.requestCount, 0);
  });

  test(
    'missing display names fall back without exposing conversation IDs',
    () async {
      await write('fallback', conversation: 'conv_missing');
      final overview = await ledger.overview();
      expect(overview.groups.single.title, 'unknown');
      expect(overview.groups.single.subtitle, 'p');
      final view = (await ledger.entries()).single;
      expect(view.modelDisplayName, 'unknown');
      expect(view.providerDisplayName, 'p');
      expect(view.conversationTitle, '已删除会话');
      await db.customStatement(
        "UPDATE token_usage_entries SET device_name = ' '",
      );
      expect(
        (await ledger.overview(
          groupBy: UsageGroupBy.device,
        )).groups.single.title,
        '本机',
      );
      await db.customStatement(
        "UPDATE token_usage_entries SET device_id = 'remote'",
      );
      expect(
        (await ledger.overview(
          groupBy: UsageGroupBy.device,
        )).groups.single.title,
        '其他设备',
      );
    },
  );

  test(
    'canonical SQL columns, idempotency and background never publishes',
    () async {
      await Future.wait([write('one'), write('one'), write('two')]);
      final rows = await db
          .customSelect(
            'SELECT id,device_id,device_name,purpose,provider_id,model,input_tokens,output_tokens,cached_input_tokens,cache_write_tokens,reasoning_tokens,is_estimated,priced,currency,cost_micros,created_at FROM token_usage_entries',
          )
          .get();
      expect(rows, hasLength(2));
      expect(rows.first.read<int>('input_tokens'), 100);
      expect(rows.first.read<int>('cached_input_tokens'), 30);
      expect(rows.first.read<int>('priced'), 0);
      expect((await SharedPreferences.getInstance()).getString(key), isNull);
      expect((await ledger.overview()).requestCount, 2);
    },
  );

  test(
    'capture works without database, deduplicates and isolates nested requests',
    () async {
      final unbound = TokenUsageLedger();
      final outer = TokenUsageCaptureScope();
      final inner = TokenUsageCaptureScope();
      await outer.run(() async {
        await unbound.recordHttpRound(
          requestId: 'a',
          providerId: 'p',
          model: 'm',
          usage: usage,
        );
        await unbound.recordHttpRound(
          requestId: 'a',
          providerId: 'p',
          model: 'm',
          usage: usage,
        );
        await inner.run(
          () => unbound.recordHttpRound(
            requestId: 'b',
            providerId: 'p',
            model: 'm',
            usage: usage,
          ),
        );
      });
      expect(outer.usage.totalTokens, 120);
      expect(inner.usage.totalTokens, 120);
    },
  );

  test(
    'current persisted settings price old unknown rows, priced rows stay fixed',
    () async {
      await write('unknown');
      final prefs = await SharedPreferences.getInstance();
      Future<void> setPrice(int input, int output) => prefs.setString(
        cloudUiModelsKey,
        jsonEncode({
          'model_configs': {
            'p:unknown': {
              'input_price_per_million': input,
              'output_price_per_million': output,
              'cached_input_price_per_million': 1,
              'price_currency': 'CNY',
            },
          },
          'providers': [
            {
              'id': 'p',
              'name': 'P',
              'custom_config': {'priceMultiplier': 2},
            },
          ],
        }),
      );
      expect((await ledger.all()).single.priced, isFalse);
      await setPrice(2, 4);
      final dynamicCost = (await ledger.all()).single.costMicros;
      expect(dynamicCost, 510); // (60*2 + 30*1 + 10*2.5 + 20*4)*2
      await write('fixed');
      await setPrice(10, 20);
      final rows = await ledger.all();
      expect(
        rows.firstWhere((r) => r.requestId == 'fixed').costMicros,
        dynamicCost,
      );
      expect(
        rows.firstWhere((r) => r.requestId == 'unknown').costMicros,
        greaterThan(dynamicCost!),
      );
      expect((await ledger.overview()).cnyCostMicros, greaterThan(dynamicCost));
    },
  );

  test(
    'writes notify immediately and pending snapshot publishes together',
    () async {
      ledger.isBackgroundIsolate = false;
      var notifications = 0;
      final subscription = ledger.changes.listen((_) => notifications++);
      addTearDown(subscription.cancel);
      addTearDown(ledger.flushPendingSnapshot);
      await write('first');
      await write('second');
      await Future<void>.delayed(Duration.zero);
      expect(notifications, 2);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(key), isNull);
      await ledger.flushPendingSnapshot();
      final snapshot = prefs.getString(key);
      expect(buckets(snapshot!), isNotEmpty);
      expect((await ledger.overview()).requestCount, 2);
      await ledger.flushPendingSnapshot();
      expect(prefs.getString(key), snapshot);
    },
  );

  test(
    '180 day archive is atomic, preserves dimensions and single snapshot clock',
    () async {
      final now = DateTime.now();
      await write(
        'old',
        at: now.subtract(const Duration(days: 200)),
        conversation: 'role',
      );
      await write('recent', at: now, conversation: 'role');
      ledger.isBackgroundIsolate = false;
      await ledger.publishLocalSnapshot(now: now);
      expect(
        await db.customSelect('SELECT id FROM token_usage_entries').get(),
        hasLength(1),
      );
      final archived = await db
          .customSelect(
            'SELECT bucket_key,device_id,period,model,purpose,conversation_id,request_count,input_tokens,unpriced_input_tokens FROM token_usage_archives',
          )
          .get();
      expect(archived, hasLength(1));
      expect(archived.single.read<String>('conversation_id'), 'role');
      expect(archived.single.read<int>('unpriced_input_tokens'), 100);
      expect((await ledger.overview()).requestCount, 2);
      final prefs = await SharedPreferences.getInstance();
      expect((jsonDecode(prefs.getString(key)!) as Map).keys, ['snapshot']);
      expect((preferenceTimeJournal(prefs)[key] as Map).keys, ['snapshot']);
      await ledger.publishLocalSnapshot(now: now);
      expect((preferenceTimeJournal(prefs)[key] as Map).length, 1);
    },
  );

  test(
    'restored local snapshot survives empty SQLite, remote partition never doubles',
    () async {
      final now = DateTime.now();
      await write('old', at: now.subtract(const Duration(days: 40)));
      ledger.isBackgroundIsolate = false;
      await ledger.publishLocalSnapshot(now: now);
      final prefs = await SharedPreferences.getInstance();
      final fresh = AppDatabase.forTesting(NativeDatabase.memory());
      final replacement = TokenUsageLedger(database: fresh);
      try {
        await replacement.publishLocalSnapshot(now: now);
        expect((await replacement.overview()).requestCount, 1);
        expect(buckets(prefs.getString(key)!), isNotEmpty);
        final json = TokenUsageEntry(
          requestId: 'remote',
          deviceId: 'other',
          deviceName: 'Other',
          occurredAtMs: now.millisecondsSinceEpoch,
          providerId: 'p',
          model: 'unknown',
          purpose: 'chat',
          usage: usage,
        ).toJson();
        await prefs.setString(
          '${tokenUsageRollupPrefix}other.v1',
          jsonEncode({
            'snapshot': {
              'buckets': [json],
            },
          }),
        );
        expect((await replacement.overview()).requestCount, 2);
        expect((await replacement.overview(deviceId: 'local')).requestCount, 1);
        await replacement.clearLocal();
        expect((await replacement.overview()).requestCount, 1);
        expect(buckets(prefs.getString(key)!), isEmpty);
      } finally {
        await fresh.close();
      }
    },
  );

  test(
    '600 buckets/120 KB ceiling, no token loss, undeclared remote keys ignored',
    () async {
      for (var i = 0; i < 620; i++) {
        await write('$i', model: 'unknown-$i', conversation: 'role-$i');
      }
      ledger.isBackgroundIsolate = false;
      await ledger.publishLocalSnapshot();
      final prefs = await SharedPreferences.getInstance();
      expect(buckets(prefs.getString(key)!).length, lessThanOrEqualTo(600));
      expect((await ledger.overview()).unpricedRequestCount, 620);
      final fresh = AppDatabase.forTesting(NativeDatabase.memory());
      try {
        final restored = TokenUsageLedger(
          database: fresh,
          isBackgroundIsolate: true,
        );
        expect((await restored.overview()).requestCount, 620);
        await prefs.setString(
          cloudUiModelsKey,
          jsonEncode({
            'model_configs': {
              for (var i = 0; i < 620; i++)
                'p:unknown-$i': {
                  'input_price_per_million': 2,
                  'output_price_per_million': 4,
                },
            },
          }),
        );
        expect((await restored.overview()).unpricedRequestCount, 0);
        expect((await restored.overview()).usdCostMicros, greaterThan(0));
      } finally {
        await fresh.close();
      }
      expect(utf8.encode(prefs.getString(key)!).length, lessThan(120 * 1024));
      expect((await ledger.overview()).requestCount, 620);
      expect((await ledger.overview()).inputTokens, 62000);
      expect((await ledger.overview()).unpricedRequestCount, 0);
    },
  );

  test(
    'terminal model run aggregates each HTTP round and CSV escapes formulas',
    () async {
      final captureLedger = TokenUsageLedger();
      await const ModelRunScope(purpose: 'chat', conversationId: 'role').run(
        () => executeWithProviderKeyFailureRecording(
          config: ApiConfig(
            settings: mapUiModelsToAppSettings({}),
            modelFullId: 'p:unknown',
            providerId: 'p',
            providerApiBase: '',
            customConfig: const {},
            messages: const [],
          ),
          execute: () async {
            await captureLedger.recordHttpRound(
              requestId: 'r1',
              providerId: 'p',
              model: 'unknown',
              usage: usage,
            );
            await captureLedger.recordHttpRound(
              requestId: 'r2',
              providerId: 'p',
              model: 'unknown',
              usage: usage,
            );
            return 1;
          },
        ),
      );
      final run = (await ModelRequestLedger.instance.all()).single;
      expect(run.status, 'succeeded');
      expect(run.usage!.inputTokens, 200);
      expect(run.usage!.outputTokens, 40);
      await write('csv', model: '=formula', conversation: 'role');
      final csv = buildUsageCsvExport(
        await ledger.entries(),
        conversationTitles: {'role': 'a,"b\nc'},
      );
      expect(csv, contains("'=formula"));
      expect(csv, contains('a,""b\nc'));
      expect(csv, startsWith('\uFEFF'));
    },
  );

  test(
    'empty snapshots list devices and flat run fields preserve older records',
    () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        '${tokenUsageRollupPrefix}empty.v1',
        jsonEncode({
          'snapshot': {
            'device_id': 'empty',
            'device_name': 'Empty device',
            'buckets': [],
          },
        }),
      );
      final overview = await ledger.overview();
      expect(
        overview.availableDevices.map((d) => d.deviceId),
        containsAll(['local', 'empty']),
      );
      const run = ModelRunRecord(
        runId: 'r',
        deviceId: 'remote',
        deviceName: 'Remote',
        purpose: 'chat',
        providerId: 'p',
        model: 'p:unknown',
        attempt: 1,
        status: 'succeeded',
        stageSeq: 1000,
        startedAtMs: 1,
        updatedAtMs: 2,
        leaseUntilMs: 3,
        inputTokens: 100,
        outputTokens: 20,
        cachedInputTokens: 30,
        reasoningTokens: 5,
        usageEstimated: true,
      );
      final restored = ModelRunRecord.fromJson(run.toJson());
      expect(restored.inputTokens, 100);
      expect(restored.usageEstimated, true);
      expect(restored.advance('failed', 4).cachedInputTokens, 30);
      final legacyJson = run.toJson()
        ..remove('usage')
        ..remove('input_tokens')
        ..remove('output_tokens')
        ..remove('cached_input_tokens')
        ..remove('reasoning_tokens')
        ..remove('usage_estimated');
      expect(ModelRunRecord.fromJson(legacyJson).inputTokens, isNull);
    },
  );

  test(
    'capture resolves real provider settings rather than adapter name',
    () async {
      final capture = TokenUsageCaptureScope(
        providerId: 'real',
        modelFullId: 'real:custom',
        settings: mapUiModelsToAppSettings({
          'model_configs': {
            'real:custom': {
              'input_price_per_million': 2,
              'output_price_per_million': 4,
            },
          },
        }),
      );
      await capture.run(
        () => ledger.recordHttpRound(
          requestId: 'provider',
          providerId: 'openai',
          model: 'custom',
          usage: usage,
        ),
      );
      final row = (await ledger.all()).single;
      expect(row.providerId, 'real');
      expect(row.model, 'custom');
      expect(row.priced, true);
    },
  );

  test('storage errors do not replace a successful HTTP response', () async {
    await db.close();
    await expectLater(write('closed'), completes);
  });
}
