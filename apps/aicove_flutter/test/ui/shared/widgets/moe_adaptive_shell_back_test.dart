import 'package:aicove_flutter/src/ui/shared/widgets/moe_adaptive_shell.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

void main() {
  for (final width in [400.0, 1200.0]) {
    testWidgets(
      '安卓预测性返回：详情栈非空时框架必须接管返回 $width',
      (tester) async {
        await tester.binding.setSurfaceSize(Size(width, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final handlesBack = <bool>[];
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'SystemNavigator.setFrameworkHandlesBack') {
              handlesBack.add(call.arguments as bool);
            }
            return null;
          },
        );
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        final key = GlobalKey<NavigatorState>();
        final observer = MoeDetailStackObserver();
        final router = GoRouter(
          routes: [
            ShellRoute(
              navigatorKey: key,
              observers: [observer],
              builder: (context, state, child) => MoeAdaptiveShell(
                primary: Builder(
                  builder: (context) => Scaffold(
                    body: Column(
                      children: [
                        TextButton(
                          onPressed: () => MoeWorkspace.open(
                            context,
                            Builder(
                              builder: (context) => Scaffold(
                                body: Column(
                                  children: [
                                    const Text('二级'),
                                    TextButton(
                                      onPressed: () => showDialog<void>(
                                        context: context,
                                        builder: (_) => const AlertDialog(
                                          content: Text('弹窗'),
                                        ),
                                      ),
                                      child: const Text('二级弹窗'),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          child: const Text('打开二级'),
                        ),
                        TextButton(
                          onPressed: () => showDialog<void>(
                            context: context,
                            builder: (_) =>
                                const AlertDialog(content: Text('弹窗')),
                          ),
                          child: const Text('一级弹窗'),
                        ),
                      ],
                    ),
                  ),
                ),
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
        await tester.pumpWidget(
          MaterialApp.router(
            routerConfig: router,
            onNavigationNotification: moeNavigationNotification(router),
            theme: ThemeData(extensions: [MoeColors.light()]),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('打开二级'));
        await tester.pumpAndSettle();
        expect(find.text('二级'), findsOneWidget);
        expect(handlesBack.last, isTrue, reason: '推入二级后');

        await tester.tap(find.text('二级弹窗'));
        await tester.pumpAndSettle();
        await tester.tapAt(const Offset(5, 5));
        await tester.pumpAndSettle();
        expect(handlesBack.last, isTrue, reason: '二级内弹窗关闭后');

        key.currentState!.pop();
        await tester.pumpAndSettle();
        expect(handlesBack.last, isFalse, reason: '退回一级后应交还系统返回');

        await tester.tap(find.text('一级弹窗'));
        await tester.pumpAndSettle();
        await tester.tapAt(const Offset(5, 5));
        await tester.pumpAndSettle();
        expect(handlesBack.last, isFalse);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );
  }
}
