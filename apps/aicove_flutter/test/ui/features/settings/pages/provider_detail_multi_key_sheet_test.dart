import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:aicove_flutter/src/ui/features/settings/pages/provider_detail_page.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/index.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'aicove.ui_models.v1': jsonEncode(_mockStore),
    });
  });

  testWidgets('添加 Key 使用 MoeBottomSheet 并响应键盘 inset', (tester) async {
    await tester.pumpWidget(_buildApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('添加'));
    await tester.pumpAndSettle();

    expect(find.byType(MoeBottomSheet), findsOneWidget);
    expect(find.byType(MoeTextField), findsOneWidget);

    final padding = tester.widget<AnimatedPadding>(
      find.descendant(
        of: find.byType(MoeBottomSheet),
        matching: find.byType(AnimatedPadding),
      ),
    );
    expect(padding.padding, const EdgeInsets.only(bottom: 240));
  });

  testWidgets('添加 Key 表单在小屏键盘场景不溢出', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 568));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(_buildApp(
      size: const Size(320, 568),
      viewInsets: const EdgeInsets.only(bottom: 340),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('添加'));
    await tester.pumpAndSettle();

    expect(find.byType(MoeBottomSheet), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('添加 Key 表单在宽屏场景不溢出', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1024, 768));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(_buildApp(
      size: const Size(1024, 768),
      viewInsets: EdgeInsets.zero,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('添加'));
    await tester.pumpAndSettle();

    expect(find.byType(MoeBottomSheet), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('负载均衡策略支持用尽选项', (tester) async {
    await tester.pumpWidget(_buildApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('负载均衡策略'));
    await tester.pumpAndSettle();

    expect(find.text('用尽'), findsOneWidget);
    expect(find.text('当前 Key 报错后再切换'), findsOneWidget);
  });

  testWidgets('编辑 Key 使用公共表单组件', (tester) async {
    await tester.pumpWidget(_buildApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('编辑').first);
    await tester.pumpAndSettle();

    expect(find.byType(MoeBottomSheet), findsOneWidget);
    expect(find.byType(MoeTextField), findsNWidgets(2));
    expect(find.text('保存'), findsOneWidget);
  });
}

Widget _buildApp({
  Size size = const Size(390, 844),
  EdgeInsets viewInsets = const EdgeInsets.only(bottom: 240),
}) {
  return ProviderScope(
    child: MediaQuery(
      data: MediaQueryData(
        size: size,
        viewInsets: viewInsets,
      ),
      child: const MaterialApp(
        home: MultiKeyManagerPage(providerId: 'openai'),
      ),
    ),
  );
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
