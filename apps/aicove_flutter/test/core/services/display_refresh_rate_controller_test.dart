import 'package:aicove_flutter/src/core/services/display_refresh_rate_controller.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const channel = MethodChannel('test/display_rate');
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return null;
        });
  });

  Iterable<bool> enabledCalls() => calls.map((call) {
    expect(call.method, 'setHighRefreshRate');
    return (call.arguments as Map)['enabled'] as bool;
  });

  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'waits for touches, scrolling and route activity before release',
    (tester) async {
      final controller = DisplayRefreshRateController(
        channel: channel,
        isAndroid: true,
      )..install();
      addTearDown(controller.uninstall);
      controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
      final router = GestureBinding.instance.pointerRouter;
      router.route(const PointerDownEvent(pointer: 1));
      router.route(const PointerDownEvent(pointer: 2));
      router.route(const PointerUpEvent(pointer: 1));
      await tester.pump(const Duration(seconds: 2));
      expect(enabledCalls(), [true]);

      await tester.pumpWidget(const SizedBox());
      final context = tester.element(find.byType(SizedBox));
      final metrics = FixedScrollMetrics(
        minScrollExtent: 0,
        maxScrollExtent: 100,
        pixels: 20,
        viewportDimension: 100,
        axisDirection: AxisDirection.down,
        devicePixelRatio: 1,
      );
      controller.onScrollNotification(
        ScrollUpdateNotification(
          metrics: metrics,
          context: context,
          scrollDelta: 5,
        ),
      );
      router.route(const PointerCancelEvent(pointer: 2));
      await tester.pump(const Duration(seconds: 2));
      expect(enabledCalls(), [true]);
      controller.onScrollNotification(
        ScrollEndNotification(metrics: metrics, context: context),
      );
      await tester.pump(const Duration(milliseconds: 900));
      controller.notifyRouteTransition();
      await tester.pump(const Duration(milliseconds: 1599));
      expect(enabledCalls(), [true]);
      await tester.pump(const Duration(milliseconds: 1));
      expect(enabledCalls(), [true, false]);
    },
  );

  testWidgets('background resets boost; other platforms never request it', (
    tester,
  ) async {
    final unsupported = DisplayRefreshRateController(
      channel: channel,
      isAndroid: false,
    )..install();
    unsupported.notifyRouteTransition();
    expect(enabledCalls(), isEmpty);

    final controller = DisplayRefreshRateController(
      channel: channel,
      isAndroid: true,
    )..install();
    addTearDown(controller.uninstall);
    controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
    controller.notifyRouteTransition();
    controller.didChangeAppLifecycleState(AppLifecycleState.inactive);
    controller.notifyRouteTransition();
    await tester.pump(const Duration(seconds: 2));
    expect(enabledCalls(), [true, false]);
  });
}
