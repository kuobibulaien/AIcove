import 'package:aicove_flutter/src/ui/features/debug/pages/ui_gallery_page.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final width in [360.0, 1000.0]) {
    testWidgets('组件库三种转场可进入、叠加与返回 ${width}px', (tester) async {
      tester.view.physicalSize = Size(width, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(const MaterialApp(home: UiGalleryPage()));
      expect(tester.takeException(), isNull);
      for (final label in ['横向切页', '自定义横向转场', '底部堆叠']) {
        await tester.tap(find.text(label));
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        expect(find.text('$label · 第 1 层'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('再打开一层'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 120));
        if (label == '底部堆叠') {
          expect(find.byType(CupertinoSheetTransition), findsWidgets);
        } else {
          expect(find.byType(CupertinoPageTransition), findsWidgets);
          // 中间帧确实在横向移动，而非仅完成页面替换。
          expect(tester.getTopLeft(find.text('$label · 第 2 层')).dx,
              greaterThan(80));
        }
        expect(tester.takeException(), isNull);
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        expect(find.text('$label · 第 2 层'), findsOneWidget);
        await tester.tap(find.text('返回上一层').last);
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        expect(find.text('$label · 第 1 层'), findsOneWidget);
        await tester.tap(find.text('返回上一层'));
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        expect(find.text('组件库 (UI Kit)'), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
    });
  }
}
