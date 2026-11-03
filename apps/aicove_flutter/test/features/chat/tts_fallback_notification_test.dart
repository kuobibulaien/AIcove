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

  test('image notification deduplicates by conversation and turn', () async {
    final service = TtsFallbackNotificationService();
    addTearDown(service.dispose);
    final events = <TtsFallbackEvent>[];
    final subscription = service.stream.listen(events.add);
    addTearDown(subscription.cancel);
    service.notifyImageFailure(conversationId: 'a', turnId: 'one');
    service.notifyImageFailure(conversationId: 'a', turnId: 'two');
    service.notifyImageFailure(conversationId: 'a', turnId: 'one');
    service.notifyImageFailure(conversationId: 'b', turnId: 'one');
    service.notify('error');
    await Future<void>.delayed(Duration.zero);
    expect(events, hasLength(4));
    expect(events.take(3).every((event) => event.isImageFailure), isTrue);
    expect(events.last.message, '语音生成失败，已显示文本');
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
        container
            .read(ttsFallbackNotificationServiceProvider)
            .notifyImageFailure(conversationId: 'conversation', turnId: 'turn');
        await tester.pumpAndSettle();
        expect(find.text('图片生成失败，可稍后重试或检查绘图渠道'), findsOneWidget);
        expect(find.text('不再提醒'), findsNothing);
        await saveReleaseSourcePreview(
          tester,
          boundaryKey,
          'image-failure-$width',
        );
        await tester.pump(const Duration(seconds: 5));
      },
    );
  }
}
