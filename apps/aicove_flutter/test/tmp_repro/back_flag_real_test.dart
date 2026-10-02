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
      addTearDown(() {
        debugDefaultTargetPlatformOverride = null;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        );
      });
      addTearDown(() => tester.binding.setSurfaceSize(null));
      rootBundle.clear();
      await tester.binding.setSurfaceSize(Size(width, 850));
      final fixture = (await tester.runAsync(
        () => SegmentedChatFixture.create(historyCount: 4),
      ))!;
      final flags = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'SystemNavigator.setFrameworkHandlesBack')
            flags.add('${call.arguments}');
          return null;
        },
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final key = GlobalKey<NavigatorState>();
      final observer = MoeDetailStackObserver();
      final router = GoRouter(
        routes: [
          ShellRoute(
            navigatorKey: key,
            observers: [observer],
            builder: (_, __, child) => MoeAdaptiveShell(
              primary: const MainPage(),
              detail: child,
              navigatorKey: key,
              observer: observer,
            ),
            routes: [
              GoRoute(
                path: '/',
                builder: (_, __) => const MoeWorkspacePlaceholder(),
              ),
            ],
          ),
        ],
      );
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: fixture.container,
          child: MaterialApp.router(
            routerConfig: router,
            theme: ThemeData(
              extensions: [MoeColors.light(accentColor: moePrimary)],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final nav = find.descendant(
        of: find.byType(CustomBottomNav),
        matching: find.byWidgetPredicate(
          (w) => w is Semantics && w.properties.label == '设置',
        ),
      );
      await tester.tap(nav);
      await tester.pumpAndSettle();
      expect(find.text('通用'), findsOneWidget);
      flags.clear();
      await tester.tap(find.text('通用'));
      await tester.pumpAndSettle();
      expect(observer.routeCount.value, 2);
      expect(key.currentState!.canPop(), isTrue);
      if (width < 900) expect(find.byType(BackButton), findsOneWidget);
      expect(flags, contains('true'), reason: '设置详情必须声明可由应用处理返回');
      flags.clear();
      await tester.pump(const Duration(seconds: 2));
      expect(flags, isNot(contains('false')), reason: '等待后不应丢失详情返回状态');
      expect(await key.currentState!.maybePop(), isTrue);
      await tester.pumpAndSettle();
      expect(find.text('通用'), findsOneWidget);
      expect(observer.routeCount.value, 1);
      expect(key.currentState!.canPop(), isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
      router.dispose();
      await tester.runAsync(fixture.dispose);
      debugDefaultTargetPlatformOverride = null;
      await tester.binding.setSurfaceSize(null);
    });
  }
}
