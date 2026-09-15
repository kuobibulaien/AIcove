import 'package:aicove_flutter/src/ui/shared/widgets/sheets/moe_bottom_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('sheet title stays on the sheet center with unequal actions', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 390,
              child: MoeBottomSheet(
                title: '选择模型',
                showCloseButton: true,
                titleTrailing: TextButton(
                  onPressed: () {},
                  child: const Text('全部取消'),
                ),
                child: const SizedBox(height: 100),
              ),
            ),
          ),
        ),
      ),
    );
    final sheet = tester.getRect(find.byType(MoeBottomSheet));
    expect(tester.getCenter(find.text('选择模型')).dx, closeTo(sheet.center.dx, 1));
  });
  for (final width in [360.0, 420.0, 1000.0, 1280.0]) {
    for (final scale in [1.0, 1.8]) {
      for (final keyboard in [0.0, 220.0]) {
        testWidgets(
          'sheet scroll and footer width=$width scale=$scale keyboard=$keyboard',
          (tester) async {
            tester.view.devicePixelRatio = 1;
            tester.view.physicalSize = Size(width, 520);
            addTearDown(tester.view.reset);
            await tester.pumpWidget(
              MaterialApp(
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    textScaler: TextScaler.linear(scale),
                    padding: EdgeInsets.only(bottom: keyboard == 0 ? 34 : 0),
                    viewInsets: EdgeInsets.only(bottom: keyboard),
                  ),
                  child: child!,
                ),
                home: Scaffold(
                  resizeToAvoidBottomInset: false,
                  body: Align(
                    alignment: Alignment.bottomCenter,
                    child: MoeBottomSheet(
                      title: '一个很长的选择器标题需要保持可用',
                      showCloseButton: true,
                      titleTrailing: TextButton(
                        onPressed: () {},
                        child: const Text('全选'),
                      ),
                      footer: SizedBox(
                        height: 52,
                        child: FilledButton(
                          onPressed: () {},
                          child: const Text('确认'),
                        ),
                      ),
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: 60,
                        itemBuilder: (context, index) =>
                            ListTile(title: Text('选项 $index')),
                      ),
                    ),
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            expect(
              tester.getCenter(find.text('一个很长的选择器标题需要保持可用')).dx,
              closeTo(tester.getRect(find.byType(MoeBottomSheet)).center.dx, 1),
            );
            final footer = tester.getRect(find.byType(FilledButton));
            expect(
              footer.bottom,
              lessThanOrEqualTo(520 - keyboard - (keyboard == 0 ? 34 : 0)),
            );
            final original = footer;
            await tester.drag(find.byType(ListView), const Offset(0, -500));
            await tester.pumpAndSettle();
            expect(tester.getRect(find.byType(FilledButton)), original);
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }
}
