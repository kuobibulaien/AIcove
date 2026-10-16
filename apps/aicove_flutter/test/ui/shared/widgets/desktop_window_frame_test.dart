import 'package:aicove_flutter/src/ui/shared/widgets/desktop_window_frame.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('window_manager'),
            (call) async => call.method == 'isMaximized' ? false : null);
  });

  Future<List<IconData>> hoverIcons(WidgetTester tester, bool closeFirst) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(child: MacWindowButtons(closeFirst: closeFirst)),
      ),
    ));
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    await gesture.moveTo(tester.getCenter(find.byType(MacWindowButtons)));
    await tester.pump();
    final icons = tester.widgetList<Icon>(find.byType(Icon)).toList()
      ..sort((a, b) => tester
          .getCenter(find.byWidget(a))
          .dx
          .compareTo(tester.getCenter(find.byWidget(b)).dx));
    return icons.map((icon) => icon.icon!).toList();
  }

  testWidgets('left side uses macOS order: close, minimize, maximize',
      (tester) async {
    expect(await hoverIcons(tester, true),
        [Icons.close, Icons.remove, Icons.fullscreen]);
  });

  testWidgets('right side keeps Windows order: minimize, maximize, close',
      (tester) async {
    expect(await hoverIcons(tester, false),
        [Icons.remove, Icons.fullscreen, Icons.close]);
  });
}
