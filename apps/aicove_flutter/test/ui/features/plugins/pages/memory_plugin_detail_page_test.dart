import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:aicove_flutter/src/features/plugins/memory/memory_config.dart';
import 'package:aicove_flutter/src/ui/features/plugins/pages/memory_plugin_detail_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('mixed provider should be usable as embedding source', (
    tester,
  ) async {
    final store = <String, dynamic>{
      'providers': [
        {
          'id': 'siliconflow',
          'displayName': '硅基流动',
          'apiKeys': <String>['dummy-key'],
          'apiBaseUrl': 'https://api.siliconflow.cn/v1',
          'enabled': true,
          'models': <String>['Qwen/Qwen3-32B', 'BAAI/bge-large-zh-v1.5'],
          'visible_models': <String>['Qwen/Qwen3-32B'],
          'hidden_models': <String>['BAAI/bge-large-zh-v1.5'],
          'capabilities': <String>['chat'],
        },
      ],
      'model_types': <String, String>{
        'siliconflow:BAAI/bge-large-zh-v1.5': 'embedding',
      },
      'default_model': 'siliconflow:Qwen/Qwen3-32B',
      'default_chat_models': <String>['siliconflow:Qwen/Qwen3-32B'],
      'visible_models': <String>['siliconflow:Qwen/Qwen3-32B'],
    };

    SharedPreferences.setMockInitialValues(<String, Object>{
      'aicove.ui_models.v1': jsonEncode(store),
      'aicove.plugins.memory.config': jsonEncode(<String, dynamic>{
        'enabled': true,
      }),
    });

    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: MemoryPluginDetailPage())),
    );

    await tester.pumpAndSettle();

    expect(find.text('请先导入 embedding 模型渠道'), findsNothing);
    expect(find.text('Embedding 模型'), findsOneWidget);
  });

  const fixture = MemoryConfig(
    summarizeProviderId: 'p1',
    summarizeModelName: 'sum-model',
    summarizePrompt: '非空提示词',
    embeddingProviderId: 'p2',
    embeddingModelName: 'embed-model',
    fallbackEmbeddingEnabled: true,
    fallbackEmbeddingProviderId: 'p3',
    fallbackEmbeddingModelName: 'fb-model',
    roundSplitThreshold: 42,
  );

  test('copyWith() keeps toJson identical', () {
    expect(fixture.copyWith().toJson(), equals(fixture.toJson()));
  });

  test('copyWith clears only embedding fields with explicit null', () {
    final cleared = fixture.copyWith(
      embeddingProviderId: null,
      embeddingModelName: null,
    );
    final expected = Map<String, dynamic>.from(fixture.toJson())
      ..['embeddingProviderId'] = null
      ..['embeddingModelName'] = null;
    expect(cleared.toJson(), equals(expected));
    final restored = MemoryConfig.fromJson(cleared.toJson());
    expect(restored.embeddingProviderId, isNull);
    expect(restored.embeddingModelName, isNull);
  });
}
