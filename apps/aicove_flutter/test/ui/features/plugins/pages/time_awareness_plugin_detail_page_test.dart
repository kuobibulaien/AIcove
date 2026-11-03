import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:aicove_flutter/src/ui/shared/widgets/index.dart';
import 'package:aicove_flutter/src/ui/features/plugins/pages/time_awareness_plugin_detail_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('时间感知全局页只留共用提示词，开关都在角色上', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});

    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: TimeAwarenessPluginDetailPage()),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.byType(MoeSwitch), findsNothing);
    expect(find.text('提示词（所有角色共用）'), findsOneWidget);
    expect(find.text('历史消息时间戳'), findsNothing);
    expect(find.text('当前时间注入'), findsNothing);
  });
}
