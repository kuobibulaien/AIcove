import 'package:aicove_flutter/src/features/chat/presentation/widgets/custom_bottom_nav.dart';
import 'package:aicove_flutter/src/ui/features/home/pages/main_page.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/index.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import '../../tool/chat_segmented_fixture.dart';

void main() {
  for (final width in [400.0, 1000.0]) {
  testWidgets('real back flag $width', (tester) async {
    rootBundle.clear();
    await tester.binding.setSurfaceSize(Size(width, 850));
    final fixture = (await tester.runAsync(() => SegmentedChatFixture.create(historyCount: 4)))!;
    final flags = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform, (call) async {
        if (call.method == 'SystemNavigator.setFrameworkHandlesBack') flags.add('${call.arguments}');
        return null;
      });
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final key = GlobalKey<NavigatorState>();
    final observer = MoeDetailStackObserver();
    final router = GoRouter(routes: [
      ShellRoute(
        navigatorKey: key, observers: [observer],
        builder: (_, __, child) => MoeAdaptiveShell(primary: const MainPage(), detail: child, navigatorKey: key, observer: observer),
        routes: [GoRoute(path: '/', builder: (_, __) => const MoeWorkspacePlaceholder())],
      ),
    ]);
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await tester.pumpWidget(UncontrolledProviderScope(container: fixture.container,
      child: MaterialApp.router(routerConfig: router, theme: ThemeData(extensions: [MoeColors.light(accentColor: moePrimary)]))));
    await tester.pumpAndSettle();
    final nav = find.descendant(of: find.byType(CustomBottomNav), matching: find.byWidgetPredicate((w) => w is Semantics && w.properties.label == '设置'));
    await tester.tap(nav); await tester.pumpAndSettle();
    print('settings tab $flags'); flags.clear();
    print(tester.widgetList<Text>(find.byType(Text)).map((t)=>t.data).toList());
    await tester.tap(find.text('界面')); await tester.pumpAndSettle();
    print('second $flags canPop=${router.canPop()}'); flags.clear();
    await tester.pump(const Duration(seconds: 2));
    print('later $flags'); flags.clear();
    debugDefaultTargetPlatformOverride = null;
    await tester.binding.setSurfaceSize(null);
  });
  }
}
