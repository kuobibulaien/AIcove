import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:aicove_flutter/src/ui/features/settings/pages/provider_detail_page.dart';

void main() {
  for (final width in [320.0, 1000.0]) {
    for (final keys in [true, false]) {
      for (final scale in [1.2, 1.8]) {
        testWidgets(
            '${keys ? "multi-key" : "model-test"} width=$width scale=$scale 1000 entries',
            (tester) async {
          await tester.binding.setSurfaceSize(Size(width, 700));
          addTearDown(() => tester.binding.setSurfaceSize(null));
          final store =
              jsonDecode(jsonEncode(_mockStore)) as Map<String, dynamic>;
          final provider =
              (store['providers'] as List).first as Map<String, dynamic>;
          provider['models'] = List.generate(1000, (i) => 'model-$i');
          provider['visible_models'] = provider['models'];
          provider['custom_config']['multi_key_items'] = List.generate(
              1000,
              (i) => {
                    'id': 'mk_$i',
                    'key': 'sk-synthetic-$i',
                    'alias': 'Synthetic key $i',
                    'enabled': true,
                    'status': 'normal',
                    'updated_at': 1,
                  });
          SharedPreferences.setMockInitialValues(
              {'aicove.ui_models.v1': jsonEncode(store)});
          await tester.pumpWidget(ProviderScope(
              child: MaterialApp(
                  builder: (context, child) => MediaQuery(
                      data: MediaQuery.of(context)
                          .copyWith(textScaler: TextScaler.linear(scale)),
                      child: child!),
                  home: keys
                      ? const MultiKeyManagerPage(providerId: 'openai')
                      : const ProviderDetailPage(providerId: 'openai'))));
          await tester.pumpAndSettle();
          if (!keys) {
            await tester.tap(find.byTooltip('测试模型'));
            await tester.pumpAndSettle();
          }
          expect(tester.takeException(), isNull);
          if (keys) {
            final last = find.textContaining('Synthetic key 999 ·');
            await tester.ensureVisible(last);
            await tester.pumpAndSettle();
            expect(last.hitTestable(), findsOneWidget);
            expect(tester.takeException(), isNull);
          }
        });
      }
    }
  }
}

const _mockStore = <String, dynamic>{
  'providers': [
    {
      'id': 'openai',
      'displayName': 'OpenAI',
      'apiKeys': <String>['sk-test-1'],
      'apiBaseUrl': 'https://api.example.com/v1',
      'enabled': true,
      'models': <String>['gpt-4o-mini'],
      'visible_models': <String>['gpt-4o-mini'],
      'hidden_models': <String>[],
      'capabilities': <String>['chat'],
      'custom_config': <String, dynamic>{
        'requestFormat': 'openai',
        'multi_key_enabled': true,
        'multi_key_strategy': 'round_robin',
        'multi_key_items': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'mk_1',
            'key': 'sk-test-1',
            'alias': '主 Key',
            'enabled': true,
            'status': 'normal',
            'updated_at': 1,
          },
        ],
        'multi_key_rr_index': 0,
      },
    },
  ],
  'visible_models': <String>['gpt-4o-mini'],
  'default_model': 'openai:gpt-4o-mini',
  'default_chat_models': <String>['openai:gpt-4o-mini'],
  'model_display_names': <String, String>{
    'openai:gpt-4o-mini': 'GPT-4o mini',
  },
};
