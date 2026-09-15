import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:aicove_flutter/src/ui/features/plugins/pages/time_awareness_plugin_detail_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('时间感知详情页无全局开关，注入项可直接配置', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});

    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: TimeAwarenessPluginDetailPage()),
      ),
    );

    await tester.pumpAndSettle();

    // 全局开关已移除：没有「启用时间感知」，注入项直接可见
    expect(find.text('启用时间感知'), findsNothing);
    expect(find.text('历史消息时间戳'), findsOneWidget);
    expect(find.text('当前时间注入'), findsOneWidget);

    final switchesBefore = tester
        .widgetList<Switch>(find.byType(Switch))
        .toList();
    expect(switchesBefore, hasLength(2));
    expect(switchesBefore.every((s) => s.value), isTrue);

    await tester.tap(find.text('历史消息时间戳'));
    await tester.pumpAndSettle();

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('aicove.plugins.time_awareness.config');
    expect(raw, isNotNull);

    final saved = jsonDecode(raw!) as Map<String, dynamic>;
    expect(saved['includeMessageTimestamp'], isFalse);
    expect(saved['enabled'], isTrue);
    expect(find.text('当前时间注入'), findsOneWidget);
  });
}
