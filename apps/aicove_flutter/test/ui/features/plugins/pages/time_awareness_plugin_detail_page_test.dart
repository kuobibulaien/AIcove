import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:aicove_flutter/src/ui/features/plugins/pages/time_awareness_plugin_detail_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('时间感知详情页默认开启且可关闭', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});

    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: TimeAwarenessPluginDetailPage(),
        ),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('启用时间感知'), findsOneWidget);
    expect(find.text('历史消息时间戳'), findsOneWidget);
    expect(find.text('当前时间注入'), findsOneWidget);

    final switchesBefore =
        tester.widgetList<Switch>(find.byType(Switch)).toList();
    expect(switchesBefore.first.value, isTrue);

    await tester.tap(find.text('启用时间感知'));
    await tester.pumpAndSettle();

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('aicove.plugins.time_awareness.config');
    expect(raw, isNotNull);

    final saved = jsonDecode(raw!) as Map<String, dynamic>;
    expect(saved['enabled'], isFalse);
    expect(find.text('历史消息时间戳'), findsNothing);
    expect(find.text('当前时间注入'), findsNothing);
  });
}
