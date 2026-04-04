import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/features/settings/provider_detail/provider_detail_support.dart';

void main() {
  test('providerMultiKeyItemsFromProvider 优先读取 custom_config 中的多 key 列表', () {
    const provider = ProviderAuth(
      id: 'openai',
      apiBaseUrl: 'https://api.example.com/v1',
      apiKeys: <String>['sk-fallback'],
      customConfig: <String, dynamic>{
        'multi_key_items': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'mk_1',
            'key': 'sk-primary',
            'enabled': true,
            'status': 'normal',
            'updated_at': 1,
          },
          <String, dynamic>{
            'id': 'mk_2',
            'key': '',
            'enabled': true,
            'status': 'normal',
            'updated_at': 2,
          },
        ],
      },
    );

    final items = providerMultiKeyItemsFromProvider(provider);

    expect(items, hasLength(1));
    expect(items.single.id, 'mk_1');
    expect(items.single.key, 'sk-primary');
  });

  test('providerMultiKeyItemsFromProvider 在没有明细时回退到 apiKeys', () {
    const provider = ProviderAuth(
      id: 'openai',
      apiBaseUrl: 'https://api.example.com/v1',
      apiKeys: <String>['sk-one', 'sk-two'],
    );

    final items = providerMultiKeyItemsFromProvider(provider);

    expect(items, hasLength(2));
    expect(items.map((item) => item.key), <String>['sk-one', 'sk-two']);
  });

  test('buildProviderCustomConfigForMultiKey 会保留并更新多 key 相关字段', () {
    const provider = ProviderAuth(
      id: 'openai',
      apiBaseUrl: 'https://api.example.com/v1',
      apiKeys: <String>['sk-old'],
      customConfig: <String, dynamic>{'requestFormat': 'openai'},
    );
    final items = <ProviderMultiKeyItem>[
      const ProviderMultiKeyItem(
        id: 'mk_1',
        key: 'sk-new',
        updatedAt: 10,
      ),
    ];

    final config = buildProviderCustomConfigForMultiKey(
      provider: provider,
      enabled: true,
      strategy: providerMultiKeyStrategyRandom,
      items: items,
      roundRobinIndex: 3,
    );

    expect(config['requestFormat'], 'openai');
    expect(config[providerMultiKeyEnabledField], isTrue);
    expect(
        config[providerMultiKeyStrategyField], providerMultiKeyStrategyRandom);
    expect(config[providerMultiKeyRoundRobinIndexField], 3);
    expect(config[providerMultiKeyItemsField], hasLength(1));
  });

  test('resolveProviderDetailRequestFormat 在缺省时回退到 provider id', () {
    const provider = ProviderAuth(
      id: 'gemini',
      apiBaseUrl: 'https://generativelanguage.googleapis.com/v1beta',
      apiKeys: <String>[],
    );

    final format = resolveProviderDetailRequestFormat(provider);

    expect(format, ProviderDetailRequestFormat.gemini);
  });

  test('旧 vertex 渠道别名仍固定使用 Gemini 请求格式', () {
    const provider = ProviderAuth(
      id: 'vertex',
      apiBaseUrl: 'https://generativelanguage.googleapis.com/v1beta',
      apiKeys: <String>[],
      customConfig: <String, dynamic>{
        'requestFormat': 'gemini',
      },
    );

    final format = resolveProviderDetailRequestFormat(provider);
    final available = ProviderDetailRequestFormat.forProvider(provider);

    expect(format, ProviderDetailRequestFormat.gemini);
    expect(available, <ProviderDetailRequestFormat>[
      ProviderDetailRequestFormat.gemini,
    ]);
  });
}
