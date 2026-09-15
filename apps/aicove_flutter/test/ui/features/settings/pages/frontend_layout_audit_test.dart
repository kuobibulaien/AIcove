import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/ui/features/settings/widgets/model_row_tile.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:aicove_flutter/src/ui/features/settings/pages/provider_detail_page.dart';

void main() {
  for (final width in [360.0, 1000.0]) {
    testWidgets('provider model list supports drag reorder width=$width',
        (tester) async {
      String? copiedText;
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          copiedText = (call.arguments as Map)['text'] as String?;
        }
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));
      await tester.binding.setSurfaceSize(Size(width, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final store = jsonDecode(jsonEncode(_mockStore)) as Map<String, dynamic>;
      final provider = (store['providers'] as List).first;
      provider['models'] = List.generate(100, (i) => 'audit-model-$i');
      provider['visible_models'] = provider['models'];
      SharedPreferences.setMockInitialValues(
          {'aicove.ui_models.v1': jsonEncode(store)});
      await tester.pumpWidget(const ProviderScope(
          child: MaterialApp(home: ProviderDetailPage(providerId: 'openai'))));
      await tester.pumpAndSettle();
      await tester.tap(find.text('模型'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      debugPrint(
          'AUDIT mounted model rows: ${find.byType(ModelRowTile).evaluate().length}');
      final first = find.text('audit-model-0');
      final third = find.text('audit-model-2');
      final gesture = await tester.startGesture(tester.getCenter(first));
      await tester.pump(const Duration(milliseconds: 600));
      await gesture.moveTo(tester.getCenter(third) + const Offset(0, 15));
      await tester.pump(const Duration(milliseconds: 200));
      await gesture.up();
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
          tester.element(find.byType(ProviderDetailPage)));
      final models = container
          .read(appSettingsProvider)
          .requireValue
          .getProvider('openai')!
          .visibleModels;
      debugPrint('AUDIT clipboard after drag: $copiedText');
      expect(models.indexOf('audit-model-0'), greaterThan(0));
    });
  }

  for (final width in [320.0, 1000.0]) {
    for (final keys in [true, false]) {
      for (final scale in [1.0, 1.2, 1.8, 2.0]) {
        testWidgets(
            '${keys ? "multi-key" : "model-test"} width=$width scale=$scale long list',
            (tester) async {
          await tester.binding.setSurfaceSize(Size(width, 700));
          addTearDown(() => tester.binding.setSurfaceSize(null));
          final store =
              jsonDecode(jsonEncode(_mockStore)) as Map<String, dynamic>;
          final provider =
              (store['providers'] as List).first as Map<String, dynamic>;
          provider['models'] = List.generate(100, (i) => 'model-$i');
          provider['visible_models'] = provider['models'];
          provider['custom_config']['multi_key_items'] = List.generate(
              100,
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
