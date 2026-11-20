import 'dart:convert';

import 'package:aicove_flutter/src/core/api_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/features/settings/data/support/ui_models_store_support.dart';
import 'package:aicove_flutter/src/features/settings/provider_detail/provider_detail_actions.dart';
import 'package:aicove_flutter/src/features/settings/provider_detail/provider_detail_support.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/core/api/providers/token_usage.dart';
import 'package:aicove_flutter/src/core/api/providers/provider_adapter_factory.dart';
import 'package:aicove_flutter/src/features/observability/usage/model_pricing_catalog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    resetModelPricingCachesForTesting();
  });
  tearDown(resetModelPricingCachesForTesting);

  test('channel aliases select the specified offline rates and tiers', () {
    final cases = <String, (String, double, double, double, String, double?)>{
      '假流式-gemini-3.8-flash': (
        'gemini-3.8-flash',
        .75,
        3.75,
        .075,
        'USD',
        null,
      ),
      'vtx-抗截断-gemini-4-carbon-low': (
        'gemini-4-carbon',
        2,
        10,
        .1,
        'USD',
        null,
      ),
      'gate/anthropic/claude-opus-5-5': (
        'claude-opus-5-5',
        4,
        20,
        .2,
        'USD',
        5,
      ),
      'wind/opus-4.6': ('claude-opus-4-6', 5, 25, .5, 'USD', 6.25),
      'wind/fable-5-1-low': ('claude-fable-5-1', 10, 50, .25, 'USD', 12.5),
      'wind/k3-low': ('kimi-k3', 20, 100, 2, 'CNY', null),
      'k3.1-pro:floor': ('kimi-k3.1-pro', 14, 70, 1.4, 'CNY', null),
      'wind/glm-5-3-low': ('glm-5.3', 8, 28, 2, 'CNY', null),
      'co/DeepSeek V4.1 Flash 1017': (
        'deepseek-v4.1-flash',
        .5,
        2,
        .1,
        'CNY',
        null,
      ),
      'deepseek-v4-flash': ('deepseek-v4-flash', .5, 2, .1, 'CNY', null),
      'accounts/fireworks/models/glm-5p1': ('glm-5.1', 6, 24, 1.3, 'CNY', null),
      'accounts/fireworks/models/kimi-k2p6': (
        'kimi-k2.6',
        6.8,
        28,
        1.1,
        'CNY',
        null,
      ),
      'qwen3.8-max-0902': ('qwen3.8-max', 14, 42, 2.8, 'CNY', null),
      'glm-4.7-flash': ('glm-4.7-flash', 0, 0, 0, 'CNY', null),
      'glm-4.7-flashx': ('glm-4.7-flashx', .8, 2.8, .2, 'CNY', null),
      'gemini-2.0-flash-lite': (
        'gemini-2.0-flash-lite',
        .075,
        .3,
        .01875,
        'USD',
        null,
      ),
      'mimo-v2.6-pro-ultraspeed': (
        'mimo-v2.6-pro-ultraspeed',
        30,
        60,
        .25,
        'CNY',
        null,
      ),
      'gpt-6.2-astra-260731-high': ('gpt-6.2-astra', 8, 40, .4, 'USD', 10),
      'minimax-m3.1-flash': ('minimax-m3.1-flash', 1, 4, .1, 'CNY', null),
    };
    for (final item in cases.entries) {
      final (id, input, output, read, currency, write) = item.value;
      expect(normalizeModelIdForPricing(item.key), id, reason: item.key);
      final price = lookupBuiltinModelPricing(item.key)!;
      expect(
        (
          price.inputPricePerMillion,
          price.outputPricePerMillion,
          price.cachedInputPricePerMillion,
          price.currency,
          price.cacheWritePricePerMillion,
        ),
        (input, output, read, currency, write),
        reason: item.key,
      );
    }

    for (final unknown in [
      'echo',
      'openai__2:echo',
      'atria-dawn',
      'stealth/union-alpha',
      'gpt-50',
      'deepseek-v4-lite',
      'gemini-2.5-flash-nano',
      'glm-4.7-flash-lite',
    ]) {
      expect(lookupBuiltinModelPricing(unknown), isNull, reason: unknown);
    }
    expect(normalizeModelIdForPricing('gpt-4'), 'gpt-4');
    expect(
      normalizeModelIdForPricing('co:gpt-5.4:extended'),
      'gpt-5.4:extended',
    );
    expect(normalizeModelIdForPricing('gpt-5.4:low-cost'), 'gpt-5.4:low-cost');
  });

  test(
    'official sync validates prices, aliases, and first-party priority',
    () async {
      final client = MockClient((request) async {
        expect(request.url.toString(), 'https://models.dev/api.json');
        return http.Response(
          jsonEncode({
            'amd': {
              'models': {
                'gpt-4o-mini': {
                  'cost': {'input': 0, 'output': 0},
                },
                'trial-only': {
                  'cost': {'input': 0, 'output': 0},
                },
                'trial-free': {
                  'cost': {'input': 0, 'output': 0},
                },
              },
            },
            'relay': {
              'models': {
                'openai/gpt-4o-mini': {
                  'cost': {'input': 50, 'output': 60},
                },
                'muse-spark-1.3-contributor': {
                  'cost': {'input': .12, 'output': .24},
                },
                'official-free': {
                  'cost': {'input': 4, 'output': 5},
                },
                'invalid-cost': {
                  'cost': {'input': -1, 'output': 1},
                },
              },
            },
            'openai': {
              'models': {
                'GPT-4o-Mini': {
                  'cost': {
                    'input': 1,
                    'output': 2,
                    'cache_read': .1,
                    'cache_write': 0,
                  },
                },
                'official-free': {
                  'cost': {'input': 0, 'output': 0},
                },
              },
            },
            'anthropic': {
              'models': {
                'claude-opus-5.5-preview': {
                  'cost': {'input': 3, 'output': 4, 'cache_write': 4},
                },
              },
            },
          }),
          200,
        );
      });
      addTearDown(client.close);
      final result = await ModelPricingCatalog.syncOfficialPricingCatalog(
        apiClient: ApiClient(client: client),
      );
      expect(result.modelCount, 5);
      expect(
        lookupBuiltinModelPricing('vendor/trial-free')!.inputPricePerMillion,
        0,
      );
      expect(lookupBuiltinModelPricing('trial-only'), isNull);
      expect(lookupBuiltinModelPricing('invalid-cost'), isNull);
      expect(
        lookupBuiltinModelPricing('official-free')!.inputPricePerMillion,
        0,
      );
      expect(
        lookupBuiltinModelPricing(
          'muse-spark-1.3-contributor',
        )!.inputPricePerMillion,
        .12,
      );
      expect(
        lookupBuiltinModelPricing('gate/opus-5.5')!.cacheWritePricePerMillion,
        4,
      );
      final paid = lookupBuiltinModelPricing('openai/gpt-4o-mini')!;
      expect(paid.inputPricePerMillion, 1);
      expect(paid.outputPricePerMillion, 2);
      expect(paid.cachedInputPricePerMillion, .1);
      expect(paid.cacheWritePricePerMillion, isNull);

      for (final id in [
        'google/gemma-4-31b-it:free',
        'nex-agi/nex-n2.5-pro:free',
        'router:openai/gpt-4o-mini:FREE',
      ]) {
        final free = lookupBuiltinModelPricing(id)!;
        expect(free.inputPricePerMillion, 0);
        expect(free.outputPricePerMillion, 0);
        expect(free.cachedInputPricePerMillion, 0);
        expect(free.currency, 'USD');
        expect(free.isBuiltinReference, isTrue);
      }

      await ModelPricingCatalog.cacheProviderPricing('my-channel', {
        'openai/gpt-4o-mini': {'prompt': '0.000007', 'completion': '0.000009'},
      });
      final channel = resolveEffectiveModelPricing(
        providerId: 'my-channel',
        rawModelId: 'gpt-4o-mini:exacto',
        modelConfig: const ModelConfig(priceMultiplier: 2),
        providerCustomConfig: {'priceMultiplier': 3},
      )!;
      expect(channel.inputPricePerMillion, 7);
      expect(channel.multiplier, 6);
      expect(
        lookupBuiltinModelPricing(
          'gpt-4o-mini',
          providerId: 'other',
        )!.inputPricePerMillion,
        1,
      );
      expect(
        lookupBuiltinModelPricing(
          'gpt-4o-mini:free',
          providerId: 'my-channel',
        )!.inputPricePerMillion,
        0,
      );
      final manual = resolveEffectiveModelPricing(
        providerId: 'my-channel',
        rawModelId: 'gpt-4o-mini',
        modelConfig: const ModelConfig(inputPricePerMillion: 8),
      )!;
      expect(manual.inputPricePerMillion, 8);
      expect(manual.outputPricePerMillion, 0);
      expect(manual.isBuiltinReference, isFalse);
    },
  );

  test(
    'channel multiplier helper removes default and rejects invalid values',
    () {
      const provider = ProviderAuth(
        id: 'relay',
        apiKeys: [],
        apiBaseUrl: '',
        customConfig: {'priceMultiplier': 2, 'requestFormat': 'openai'},
      );
      for (final value in [null, 1.0, 1 + 5e-10]) {
        expect(
          buildProviderCustomConfigForPriceMultiplier(
            provider: provider,
            multiplier: value,
          ),
          {'requestFormat': 'openai'},
        );
      }
      expect(
        buildProviderCustomConfigForPriceMultiplier(
          provider: provider,
          multiplier: 1.5,
        ),
        {'priceMultiplier': 1.5, 'requestFormat': 'openai'},
      );
      for (final value in [0.0, -1.0, double.nan, double.infinity]) {
        expect(
          () => buildProviderCustomConfigForPriceMultiplier(
            provider: provider,
            multiplier: value,
          ),
          throwsArgumentError,
        );
      }
      expect(provider.customConfig['priceMultiplier'], 2);
    },
  );

  test(
    'savePriceMultiplier persists removal and preserves other channel options',
    () async {
      SharedPreferences.setMockInitialValues({
        kUiModelsStoreKey: jsonEncode({
          'providers': [
            {
              'id': 'relay',
              'enabled': true,
              'models': ['gpt-4o'],
              'custom_config': {
                'requestFormat': 'openai',
                'priceMultiplier': 2,
              },
            },
          ],
        }),
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container.read(appSettingsProvider.future);
      final notifier = container.read(appSettingsProvider.notifier);
      final actions = container.read(providerDetailActionsProvider);
      for (final value in [null, 1.0, 1 + 5e-10, 1.5]) {
        final before = (await notifier.readStored()).getProvider('relay')!;
        await actions.savePriceMultiplier(before, value);
        final saved = (await notifier.readStored()).getProvider('relay')!;
        expect(saved.customConfig['requestFormat'], 'openai');
        expect(
          saved.customConfig['priceMultiplier'],
          value == 1.5 ? 1.5 : null,
        );
      }
    },
  );

  test(
    'notifier persists pricing fields and clears only requested settings',
    () async {
      SharedPreferences.setMockInitialValues({
        kUiModelsStoreKey: jsonEncode({
          'providers': [
            {
              'id': 'relay',
              'enabled': true,
              'models': ['custom'],
              'visible_models': ['custom'],
            },
          ],
        }),
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container.read(appSettingsProvider.future);
      final notifier = container.read(appSettingsProvider.notifier);
      await notifier.updateModelConfig(
        modelId: 'relay:custom',
        temperature: .4,
        inputPricePerMillion: 2,
        outputPricePerMillion: 8,
        cachedInputPricePerMillion: .5,
        priceCurrency: 'CNY',
        priceMultiplier: 3,
      );
      final first = (await notifier.readStored()).getModelConfig(
        'relay:custom',
      );
      expect(first.inputPricePerMillion, 2);
      expect(first.outputPricePerMillion, 8);
      expect(first.cachedInputPricePerMillion, .5);
      expect(first.priceCurrency, 'CNY');
      expect(first.priceMultiplier, 3);
      await notifier.updateModelConfig(
        modelId: 'relay:custom',
        clearInputPricePerMillion: true,
        clearOutputPricePerMillion: true,
        clearCachedInputPricePerMillion: true,
        clearPriceCurrency: true,
        clearPriceMultiplier: true,
      );
      final cleared = (await notifier.readStored()).getModelConfig(
        'relay:custom',
      );
      expect(cleared.temperature, .4);
      expect(cleared.inputPricePerMillion, isNull);
      expect(cleared.outputPricePerMillion, isNull);
      expect(cleared.cachedInputPricePerMillion, isNull);
      expect(cleared.priceCurrency, isNull);
      expect(cleared.priceMultiplier, isNull);
    },
  );

  test('catalog strips provider and relay prefixes without truncating IDs', () {
    for (final id in ['gpt-4o-mini', 'relay:openai/gpt-4o-mini-2024-07-18']) {
      expect(lookupBuiltinModelPricing(id)?.inputPricePerMillion, .15);
    }
    expect(
      lookupBuiltinModelPricing(
        'vtx-us-east5-claude-opus-4-6',
      )?.inputPricePerMillion,
      5,
    );
    expect(
      lookupBuiltinModelPricing(
        'deepseek/deepseek-v4.1-flash-1017',
      )?.inputPricePerMillion,
      .5,
    );
    expect(
      lookupBuiltinModelPricing(
        'google/gemini-3.1-flash-lite-preview',
      )?.inputPricePerMillion,
      .1,
    );
    expect(
      lookupBuiltinModelPricing('minimax/MiniMax-M2.5')?.inputPricePerMillion,
      1,
    );
    expect(lookupBuiltinModelPricing('qwen/qwen3-235b')?.currency, 'CNY');
    expect(lookupBuiltinModelPricing('unknown'), isNull);
    expect(lookupBuiltinModelPricing('gpt-50'), isNull);
  });

  test('custom relay prefixes do not replace an existing model family', () {
    const aliases = {
      '假流-gemini-3.8-flash': ('gemini-3.8-flash', .75),
      '渠道a-claude-opus-5': ('claude-opus-5', 5.0),
      'vip1-deepseek-v4-pro': ('deepseek-v4-pro', 4.8),
    };
    for (final entry in aliases.entries) {
      final (modelId, inputPrice) = entry.value;
      expect(normalizeModelIdForPricing(entry.key), modelId, reason: entry.key);
      expect(
        lookupBuiltinModelPricing(entry.key)?.inputPricePerMillion,
        inputPrice,
        reason: entry.key,
      );
    }

    const distill = 'deepseek-r1-distill-qwen-1.5b';
    expect(normalizeModelIdForPricing(distill), distill);
    expect(
      normalizeModelIdForPricing('opus-4p6-gemini-3.8-flash'),
      'claude-opus-4-6-gemini-3.8-flash',
    );
    expect(normalizeModelIdForPricing('k3-qwen3-max'), 'kimi-k3-qwen3-max');
  });

  test('specific model rules take precedence over family rules', () {
    expect(
      lookupBuiltinModelPricing(
        'claude-opus-4-5-20251101',
      )?.inputPricePerMillion,
      5,
    );
    expect(
      lookupBuiltinModelPricing('glm-4.5-flash')?.inputPricePerMillion,
      .1,
    );
    expect(lookupBuiltinModelPricing('gpt-4.1-nano')?.inputPricePerMillion, .1);
    expect(
      lookupBuiltinModelPricing('gemini-2.5-flash-lite')?.outputPricePerMillion,
      .4,
    );
  });

  test(
    'unknown stays unpriced, explicit zero and one-sided override are priced',
    () {
      expect(
        resolveEffectiveModelPricing(
          providerId: 'relay',
          rawModelId: 'unknown',
        ),
        isNull,
      );
      final price = resolveEffectiveModelPricing(
        providerId: 'relay',
        rawModelId: 'unknown',
        modelConfig: const ModelConfig(
          inputPricePerMillion: 0,
          priceCurrency: 'CNY',
          priceMultiplier: 2,
        ),
      )!;
      expect(price.inputPricePerMillion, 0);
      expect(price.outputPricePerMillion, 0);
      expect(price.currency, 'CNY');
      expect(price.isBuiltinReference, isFalse);
      final overridden = resolveEffectiveModelPricing(
        providerId: 'relay',
        rawModelId: 'gpt-4o',
        modelConfig: const ModelConfig(inputPricePerMillion: 3),
      )!;
      expect(overridden.outputPricePerMillion, 0);
      expect(overridden.cachedInputPricePerMillion, 3);
      final builtin = resolveEffectiveModelPricing(
        providerId: 'relay',
        rawModelId: 'gpt-4o',
        modelConfig: const ModelConfig(cachedInputPricePerMillion: 99),
      )!;
      expect(builtin.cachedInputPricePerMillion, 1.25);
      expect(builtin.isBuiltinReference, isTrue);
    },
  );

  test(
    'cost separates cached reads/writes and does not double count reasoning',
    () {
      const usage = TokenUsage(
        inputTokens: 1000,
        cachedInputTokens: 200,
        cacheWriteTokens: 100,
        outputTokens: 500,
        reasoningTokens: 300,
      );
      const price = ModelPricing(
        inputPricePerMillion: 2,
        outputPricePerMillion: 8,
        cachedInputPricePerMillion: .5,
        multiplier: 2,
      );
      expect(calculateCostMicros(usage, price), 11500);
      final claude = lookupBuiltinModelPricing('claude-opus-4-6')!;
      expect(claude.cacheWritePricePerMillion, 6.25);
    },
  );

  test(
    'currency accepts only exact USD/CNY through every settings entry point',
    () {
      const valid = ModelConfig(priceCurrency: 'USD');
      const invalid = ModelConfig(priceCurrency: 'EUR');
      expect(valid.priceCurrency, 'USD');
      expect(invalid.priceCurrency, isNull);
      expect(invalid.isDefault, isTrue);
      expect(invalid.toJson().containsKey('price_currency'), isFalse);
      for (final raw in ['usd', ' CNY ', 'EUR', 12, null]) {
        final restored = ModelConfig.fromJson({'price_currency': raw});
        expect(restored.priceCurrency, isNull);
        expect(restored.toJson().containsKey('price_currency'), isFalse);
      }
      expect(valid.copyWith(priceCurrency: 'CNY').priceCurrency, 'CNY');
      expect(valid.copyWith(priceCurrency: 'usd').priceCurrency, isNull);
      expect(valid.copyWith(clearPriceCurrency: true).isDefault, isTrue);
    },
  );

  test('price config round trips and each clear flag restores defaults', () {
    const config = ModelConfig(
      inputPricePerMillion: 0,
      outputPricePerMillion: 4,
      cachedInputPricePerMillion: .2,
      priceCurrency: 'CNY',
      priceMultiplier: 2,
    );
    expect(config.isDefault, isFalse);
    expect(ModelConfig.fromJson(config.toJson()).toJson(), config.toJson());
    expect(config.copyWith(temperature: .5).inputPricePerMillion, 0);
    expect(
      config
          .copyWith(
            clearInputPricePerMillion: true,
            clearOutputPricePerMillion: true,
            clearCachedInputPricePerMillion: true,
            clearPriceCurrency: true,
            clearPriceMultiplier: true,
          )
          .isDefault,
      isTrue,
    );
    expect(const ModelConfig().isDefault, isTrue);
  });

  test(
    'channel multiplier is applied locally and never forwarded upstream',
    () {
      final price = resolveEffectiveModelPricing(
        providerId: 'relay',
        rawModelId: 'gpt-4o-mini',
        modelConfig: const ModelConfig(
          priceMultiplier: 3,
          priceCurrency: 'CNY',
        ),
        providerCustomConfig: {'priceMultiplier': .5},
      )!;
      expect(price.multiplier, 1.5);
      expect(price.currency, 'USD');
      final invalidMultiplier = resolveEffectiveModelPricing(
        providerId: 'relay',
        rawModelId: 'gpt-4o-mini',
        modelConfig: const ModelConfig(priceMultiplier: 0),
        providerCustomConfig: {'priceMultiplier': -2},
      )!;
      expect(invalidMultiplier.multiplier, 1);
      expect(
        ProviderAdapterFactory.sanitizeRequestCustomConfig({
          'priceMultiplier': .5,
          'temperature': .8,
        }),
        {'temperature': .8},
      );
    },
  );
}
