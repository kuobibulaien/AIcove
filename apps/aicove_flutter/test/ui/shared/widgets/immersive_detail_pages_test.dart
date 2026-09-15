import 'dart:ui' as ui;

import 'package:aicove_flutter/src/ui/features/debug/pages/debug_center_page.dart';
import 'package:aicove_flutter/src/ui/features/backup/pages/data_management_page.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/moe_adaptive_shell.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/moe_page_scaffold.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/moe_app_bar.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

void main() {
  for (final dark in [false, true]) {
    testWidgets('整窗像素连续、浅深色与宽窄草稿保持 dark=$dark', (tester) async {
      final navigator = GlobalKey<NavigatorState>();
      final capture = GlobalKey();
      final observer = MoeDetailStackObserver();
      final draft = TextEditingController(text: '保留编辑草稿');
      final backgroundColor =
          dark ? const Color(0xff132a42) : const Color(0xffecf2f8);
      final router = GoRouter(routes: [
        ShellRoute(
          navigatorKey: navigator,
          observers: [observer],
          builder: (_, __, child) => MoeAdaptiveShell(
              primary: const Scaffold(body: Text('一级页')),
              detail: child,
              navigatorKey: navigator,
              observer: observer),
          routes: [
            GoRoute(
                path: '/', builder: (_, __) => const MoeWorkspacePlaceholder())
          ],
        )
      ]);
      await tester.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(MaterialApp.router(
          routerConfig: router,
          theme: ThemeData(
              brightness: dark ? Brightness.dark : Brightness.light,
              extensions: [dark ? MoeColors.dark() : MoeColors.light()]),
          builder: (_, child) => RepaintBoundary(key: capture, child: child!)));
      await tester.pumpAndSettle();
      MoeWorkspace.open(
          tester.element(find.text('一级页')),
          MoePageScaffold(
              backgroundColor: backgroundColor,
              appBar: const MoeAppBar(title: '详情编辑', showBackButton: true),
              body: ListView(padding: const EdgeInsets.all(24), children: [
                TextField(
                    key: const ValueKey('detail-draft'), controller: draft),
              ])));
      await tester.pumpAndSettle();
      final state = tester.state(find.byKey(const ValueKey('detail-draft')));
      final boundary =
          capture.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = (await tester.runAsync(() => boundary.toImage()))!;
      final bytes = (await tester.runAsync(
          () => image.toByteData(format: ui.ImageByteFormat.rawRgba)))!;
      for (final point in [
        const Offset(2, 2),
        const Offset(600, 2),
        const Offset(600, 790)
      ]) {
        final offset = (point.dy.toInt() * image.width + point.dx.toInt()) * 4;
        expect(
            Color.fromARGB(bytes.getUint8(offset + 3), bytes.getUint8(offset),
                bytes.getUint8(offset + 1), bytes.getUint8(offset + 2)),
            backgroundColor,
            reason: '卡片四周、详情标题后方和页底必须是同一背景');
      }
      image.dispose();
      for (final width in [360.0, 420.0, 899.0, 900.0, 901.0, 1000.0, 1280.0]) {
        await tester.binding.setSurfaceSize(Size(width, 600));
        await tester.pumpAndSettle();
        expect(tester.state(find.byKey(const ValueKey('detail-draft'))),
            same(state));
        expect(draft.text, '保留编辑草稿');
        final page = tester.getRect(find.byType(MoePageScaffold));
        expect(page.left, width >= 900 ? 384 : 0);
        expect(tester.takeException(), isNull);
      }
      for (final delta in [-1000.0, 1000.0]) {
        await tester.drag(find.byKey(const ValueKey('workspace-resize-handle')),
            Offset(delta, 0));
        await tester.pumpAndSettle();
        expect(
            tester
                .getSize(find.byKey(const ValueKey('workspace-primary')))
                .width,
            delta < 0 ? 320 : 440);
        expect(tester.state(find.byKey(const ValueKey('detail-draft'))),
            same(state));
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      router.dispose();
      observer.dispose();
      draft.dispose();
    });
  }

  testWidgets('普通详情及下级页背景贯通整个工作区并在退出后恢复', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final navigator = GlobalKey<NavigatorState>();
    final observer = MoeDetailStackObserver();
    final router = GoRouter(routes: [
      ShellRoute(
        navigatorKey: navigator,
        observers: [observer],
        builder: (_, __, child) => MoeAdaptiveShell(
            primary: const Scaffold(body: Text('手机一级页')),
            detail: child,
            navigatorKey: navigator,
            observer: observer),
        routes: [
          GoRoute(
              path: '/', builder: (_, __) => const MoeWorkspacePlaceholder())
        ],
      )
    ]);
    await tester.pumpWidget(MaterialApp.router(
        routerConfig: router,
        theme: ThemeData(extensions: [MoeColors.light()])));
    await tester.pumpAndSettle();
    MoeWorkspace.open(
        tester.element(find.text('手机一级页')), const DebugCenterPage());
    await tester.pumpAndSettle();
    expect(observer.background.value, isNotNull,
        reason: '调试中心必须像聊天一样注册整窗背景，不能回落到另一块底色');
    final background = find.descendant(
        of: find.byKey(const ValueKey('workspace-background')),
        matching: find.byType(ColoredBox));
    expect(tester.getRect(background), const Rect.fromLTWH(0, 0, 1000, 800));
    await tester.ensureVisible(find.text('数据管理'));
    await tester.tap(find.text('数据管理'));
    await tester.pumpAndSettle();
    expect(find.byType(DataManagementPage), findsOneWidget);
    expect(observer.background.value, isNotNull);
    expect(
        ModalRoute.of(tester.element(find.byType(DataManagementPage)))!
            .barrierColor,
        isNull,
        reason: '下级页不能给透明详情加单侧暗色遮罩');
    final childBackground = observer.background.value;
    await navigator.currentState!.maybePop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    expect(observer.background.value, same(childBackground));
    await tester.pumpAndSettle();
    expect(observer.background.value, isNotNull);
    expect(find.byType(DebugCenterPage), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    router.dispose();
    observer.dispose();
  });
}
