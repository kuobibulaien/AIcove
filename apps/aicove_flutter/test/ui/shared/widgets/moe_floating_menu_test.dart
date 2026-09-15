import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/menus/moe_popup_menu.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:aicove_flutter/src/ui/theme/moe_interaction_theme.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final width in [320.0, 1000.0]) {
    for (final dark in [false, true]) {
      testWidgets('悬浮菜单边缘定位、长列表和Escape关闭 $width dark=$dark', (tester) async {
        await tester.binding.setSurfaceSize(Size(width, 360));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        var selected = -1;
        final anchor = GlobalKey();
        final boundary = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            theme: withMoeInteractionTheme(
              ThemeData(
                brightness: dark ? Brightness.dark : Brightness.light,
                extensions: [dark ? MoeColors.dark() : MoeColors.light()],
              ),
            ),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(1.8)),
              child: RepaintBoundary(key: boundary, child: child!),
            ),
            home: Scaffold(
              body: Builder(
                builder: (context) => Align(
                  alignment: Alignment.bottomRight,
                  child: IconButton(
                    key: anchor,
                    icon: const Icon(Icons.more_horiz),
                    onPressed: () => MoePopupMenu.show(
                      context,
                      targetBox:
                          anchor.currentContext!.findRenderObject()
                              as RenderBox,
                      vertical: true,
                      alignToEnd: true,
                      items: List.generate(
                        12,
                        (i) => MoePopupMenuItem(
                          icon: i.isEven ? null : Icons.settings_outlined,
                          label: '操作 $i',
                          onTap: () => selected = i,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.byIcon(Icons.more_horiz));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byIcon(Icons.settings_outlined), findsNothing);
        expect(
          find.byWidgetPredicate(
            (widget) => widget is Icon && widget.icon == null,
          ),
          findsNothing,
        );
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: const Offset(1, 1));
        await tester.pumpAndSettle();
        Future<Uint8List> pixels({bool save = false}) async =>
            (await tester.runAsync(() async {
              final image =
                  await (boundary.currentContext!.findRenderObject()!
                          as RenderRepaintBoundary)
                      .toImage();
              if (save) {
                final png = await image.toByteData(
                  format: ui.ImageByteFormat.png,
                );
                final file = File(
                  '../../.codex-temp/menu-hover/menu-$width-$dark.png',
                );
                await file.parent.create(recursive: true);
                await file.writeAsBytes(png!.buffer.asUint8List());
              }
              final data = await image.toByteData(
                format: ui.ImageByteFormat.rawRgba,
              );
              image.dispose();
              return Uint8List.fromList(data!.buffer.asUint8List());
            }))!;
        final before = await pixels();
        await mouse.moveTo(tester.getCenter(find.text('操作 1')));
        await tester.pumpAndSettle();
        expect(await pixels(save: true), orderedEquals(before));
        for (final button in tester.widgetList<TextButton>(
          find.byType(TextButton),
        )) {
          for (final state in [WidgetState.hovered, WidgetState.focused]) {
            expect(
              button.style!.overlayColor!.resolve({state}),
              Colors.transparent,
            );
          }
        }
        await mouse.removePointer();
        await tester.ensureVisible(find.text('操作 11'));
        await tester.tap(find.text('操作 11'));
        await tester.pumpAndSettle();
        expect(selected, 11);
        expect(find.text('操作 11'), findsNothing);
        await tester.tap(find.byIcon(Icons.more_horiz));
        await tester.pumpAndSettle();
        bool hasFocusBorder(Widget widget) =>
            widget is AnimatedContainer &&
            widget.decoration is BoxDecoration &&
            (widget.decoration! as BoxDecoration).border != null;
        // 打开菜单不预选任何项，不出现焦点强调边框
        expect(find.byWidgetPredicate(hasFocusBorder), findsNothing);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
        // 方向键导航到第一项后才显示焦点边框
        expect(find.byWidgetPredicate(hasFocusBorder), findsOneWidget);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(selected, 0);
        await tester.tap(find.byIcon(Icons.more_horiz));
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.text('操作 0'), findsNothing);
        expect(selected, 0);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
