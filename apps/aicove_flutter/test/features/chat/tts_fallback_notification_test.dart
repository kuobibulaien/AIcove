import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:aicove_flutter/src/features/chat/services/tts_fallback_notification.dart';
import '../../helpers/release_source_preview.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('missing overlay cannot turn a fallback notice into an error', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const TtsFallbackNotificationListener(child: SizedBox()),
      ),
    );
    container.read(ttsFallbackNotificationServiceProvider).notify('error');
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  for (final width in [390.0, 1000.0]) {
    testWidgets(
      'fallback notice is shown inside the route overlay width=$width',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(width, 420);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await loadReleasePreviewFonts(tester);
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final router = GoRouter(
          routes: [
            ShellRoute(
              builder: (context, state, child) =>
                  TtsFallbackNotificationListener(child: child),
              routes: [
                GoRoute(
                  path: '/',
                  builder: (context, state) => const Scaffold(
                    body: Align(
                      alignment: Alignment.topLeft,
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text('聊天正文仍然保留'),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        );
        addTearDown(router.dispose);
        final boundaryKey = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: boundaryKey,
            child: UncontrolledProviderScope(
              container: container,
              child: MaterialApp.router(
                debugShowCheckedModeBanner: false,
                theme: ThemeData(
                  fontFamily: captureReleaseSourcePreview
                      ? 'ReleasePreview'
                      : null,
                ),
                routerConfig: router,
              ),
            ),
          ),
        );
        container.read(ttsFallbackNotificationServiceProvider).notify('error');
        await tester.pumpAndSettle();
        expect(find.text('语音生成失败，已显示文本'), findsOneWidget);
        expect(find.text('聊天正文仍然保留'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await saveReleaseSourcePreview(
          tester,
          boundaryKey,
          'tts-fallback-$width',
        );
        await tester.tap(find.text('不再提醒'));
        await tester.pumpAndSettle();
        container
            .read(ttsFallbackNotificationServiceProvider)
            .notify('timeout');
        await tester.pumpAndSettle();
        expect(find.text('语音生成超时，已显示文本'), findsNothing);
        await tester.pump(const Duration(seconds: 5));
      },
    );
  }
}
