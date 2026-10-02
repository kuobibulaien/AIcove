import 'package:aicove_flutter/src/ui/shared/widgets/moe_adaptive_shell.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

void main() {
  for (final width in [400.0, 1000.0]) {
  testWidgets('back flag $width', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final flags = <bool>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform, (call) async {
        if (call.method == 'SystemNavigator.setFrameworkHandlesBack') flags.add(call.arguments as bool);
        return null;
      });
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.binding.setSurfaceSize(Size(width, 800));
    final key = GlobalKey<NavigatorState>();
    final observer = MoeDetailStackObserver();
    final router = GoRouter(routes: [
      ShellRoute(
        navigatorKey: key,
        observers: [observer],
        builder: (context, state, child) => MoeAdaptiveShell(
          primary: Builder(builder: (context) => Scaffold(body: TextButton(
            onPressed: () => MoeWorkspace.open(context, Scaffold(body: Builder(builder: (c) => TextButton(
              onPressed: () => MoeWorkspace.open(c, const PopScope(canPop: true, child: Scaffold(body: Text('third')))),
              child: const Text('second'))))),
            child: const Text('open')))),
          detail: child, navigatorKey: key, observer: observer),
        routes: [GoRoute(path: '/', builder: (_, __) => const MoeWorkspacePlaceholder())],
      ),
    ]);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    print('init $flags'); flags.clear();
    await tester.tap(find.text('open')); await tester.pumpAndSettle();
    print('after second $flags'); flags.clear();
    await tester.tap(find.text('second')); await tester.pumpAndSettle();
    print('after third $flags');
    debugDefaultTargetPlatformOverride = null;
    await tester.binding.setSurfaceSize(null);
  });
  }
}
