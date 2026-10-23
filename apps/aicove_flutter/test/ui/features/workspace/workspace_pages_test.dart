import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:aicove_flutter/src/features/workspace/data/workspace_store.dart';
import 'package:aicove_flutter/src/features/workspace/workspace_providers.dart';
import 'package:aicove_flutter/src/ui/features/workspace/pages/workspace_file_page.dart';
import 'package:aicove_flutter/src/ui/features/workspace/pages/workspace_list_page.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/index.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Source-rendered previews: `--dart-define=WRITE_WORKSPACE_PREVIEW=true`.
const _capture = bool.fromEnvironment('WRITE_WORKSPACE_PREVIEW');

void main() {
  late Directory root;
  late WorkspaceStore store;
  late String ws;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('workspace_pages_test');
    store = await WorkspaceStore.open(root);
    await store.ensureDefault();
    ws = (await store.create(name: '读书笔记', description: '整理读过的书和摘抄')).id;
    await store.write(
      ws,
      'AGENTS.md',
      utf8.encode('# 说明\n按书名建文件。'),
      runId: 'run-1',
    );
    await store.write(ws, 'notes/三体.md', utf8.encode('黑暗森林'), runId: 'run-1');
    await store.create(name: '旅行计划');
  });

  tearDown(() async {
    await store.close();
    await root.delete(recursive: true);
  });

  /// The test body runs in the real async zone so filesystem and database
  /// work started by route builds can complete between frames.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pumpAndSettle();
  }

  Future<void> settleUntil(WidgetTester tester, Finder finder) async {
    for (var i = 0; i < 100 && finder.evaluate().isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pumpAndSettle();
  }

  Future<GlobalKey> mount(WidgetTester tester, double width) async {
    if (_capture) {
      await (() async {
        final text = FontLoader('Preview')
          ..addFont(
            File(
              '/System/Library/Fonts/STHeiti Medium.ttc',
            ).readAsBytes().then(ByteData.sublistView),
          );
        await text.load();
        final icons = FontLoader('MaterialIcons')
          ..addFont(
            File(
              '${Platform.environment['HOME']}/dev-sdks/flutter-3.44.6/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
            ).readAsBytes().then(ByteData.sublistView),
          );
        await icons.load();
      })();
    }
    tester.view.physicalSize = Size(width, 820);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final boundary = GlobalKey();
    final navigator = GlobalKey<NavigatorState>();
    final observer = MoeDetailStackObserver();
    addTearDown(observer.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [workspaceStoreProvider.overrideWith((ref) async => store)],
        child: MaterialApp(
          theme: ThemeData(
            fontFamily: _capture ? 'Preview' : null,
            extensions: [MoeColors.light(accentColor: moePrimary)],
          ),
          home: RepaintBoundary(
            key: boundary,
            child: MoeAdaptiveShell(
              primary: const WorkspaceListPage(),
              navigatorKey: navigator,
              observer: observer,
              detail: Navigator(
                key: navigator,
                observers: [observer],
                onGenerateRoute: (_) => MaterialPageRoute(
                  builder: (_) => const MoeWorkspacePlaceholder(),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await settle(tester);
    return boundary;
  }

  Future<void> capture(WidgetTester tester, GlobalKey key, String name) async {
    if (!_capture) return;
    await (() async {
      final layer = tester.binding.renderViews.first.debugLayer! as OffsetLayer;
      final image = await layer.toImage(
        Offset.zero & tester.view.physicalSize,
        pixelRatio: 2,
      );
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final dir = Directory('../../.codex-temp/workspace/previews')
        ..createSync(recursive: true);
      await File(
        '${dir.path}/$name.png',
      ).writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    })();
  }

  for (final width in [360.0, 1040.0]) {
    testWidgets('command changes remain with exact skip copy at $width', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final lease = await store.beginCommand(ws, 'command-preview');
        await File(
          '${store.directoryOf(ws).path}/shell-result.txt',
        ).writeAsString('command result');
        await store.finishCommand(lease);
        final key = await mount(tester, width);
        await tester.tap(find.text('读书笔记'));
        await settle(tester);
        await tester.tap(find.text('撤销').first);
        await settle(tester);
        await tester.tap(
          find.descendant(
            of: find.byType(MoePrimaryButton),
            matching: find.textContaining('撤销'),
            matchRoot: true,
          ),
        );
        await settleUntil(tester, find.text('部分文件没有撤销'));
        expect(
          find.text('命令造成的改动不能撤销：\nshell-result.txt'),
          findsOneWidget,
        );
        expect(find.textContaining('这些文件在这一轮之后又被改过'), findsNothing);
        expect(
          await File(
            '${store.directoryOf(ws).path}/shell-result.txt',
          ).readAsString(),
          'command result',
        );
        await capture(tester, key, 'shell-undo-${width.toInt()}');
        await tester.tap(find.text('知道了'));
        await settle(tester);
        expect(
          (await store.runs(
            ws,
          )).singleWhere((r) => r.runId == 'command-preview').undone,
          isFalse,
        );
        expect(tester.takeException(), isNull);
      });
    });
    testWidgets('html files offer run and web saves get their own label at $width', (
      tester,
    ) async {
      await tester.runAsync(() async {
        await store.write(
          ws,
          'game.html',
          utf8.encode('<!doctype html><p>小游戏</p>'),
          runId: 'run-2',
        );
        await store.write(
          ws,
          'game.save.json',
          utf8.encode('{"format":"aicove.webapp.save.v1","localStorage":{}}'),
          runId: 'webapp-preview',
        );
        final key = await mount(tester, width);
        await tester.tap(find.text('读书笔记'));
        await settle(tester);
        expect(find.textContaining('网页存档'), findsOneWidget);
        await capture(tester, key, 'webapp-detail-${width.toInt()}');
        await tester.tap(
          find.byKey(const ValueKey('workspace-entry-game.html')),
        );
        await settle(tester);
        expect(find.byKey(const ValueKey('workspace-file-run')), findsOneWidget);
        await capture(tester, key, 'webapp-file-${width.toInt()}');
        await tester.pageBack();
        await settle(tester);
        await tester.tap(
          find.byKey(const ValueKey('workspace-entry-AGENTS.md')),
        );
        await settle(tester);
        expect(find.byKey(const ValueKey('workspace-file-run')), findsNothing);
        expect(tester.takeException(), isNull);
      });
    });
    testWidgets('list, browse, read and undo a run at $width', (tester) async {
      await tester.runAsync(() async {
        final key = await mount(tester, width);
        expect(find.byKey(const ValueKey('workspace-aicove')), findsOneWidget);
        expect(find.text('读书笔记'), findsOneWidget);
        expect(find.text('整理读过的书和摘抄'), findsOneWidget);
        expect(find.byTooltip('新建空间'), findsOneWidget);
        expect(find.byTooltip('后台任务'), findsNothing);
        if (width == 360) await capture(tester, key, 'list-360');

        await tester.tap(find.text('读书笔记'));
        await settle(tester);
        expect(find.text('notes'), findsOneWidget);
        expect(find.text('AGENTS.md'), findsOneWidget);
        expect(find.textContaining('2 处修改'), findsOneWidget);
        await capture(tester, key, 'detail-${width.toInt()}');

        await tester.tap(find.text('notes'));
        await settle(tester);
        await tester.tap(find.text('三体.md'));
        await settle(tester);
        expect(find.byType(WorkspaceFilePage), findsOneWidget);
        expect(find.text('黑暗森林'), findsOneWidget);
        if (width == 360) await capture(tester, key, 'file-360');
        await tester.pageBack();
        await settle(tester);
        await tester.pageBack();
        await settle(tester);

        await tester.tap(find.text('撤销').first);
        await settle(tester);
        expect(find.text('撤销这一轮修改？'), findsOneWidget);
        await tester.tap(
          find.descendant(
            of: find.byType(MoePrimaryButton),
            matching: find.textContaining('撤销'),
            matchRoot: true,
          ),
        );
        await settleUntil(tester, find.text('已撤销'));
        expect(find.text('已撤销'), findsOneWidget);
        expect(find.text('notes'), findsNothing);
        expect(await store.stat(ws, 'AGENTS.md'), isNull);
        expect(find.textContaining('已撤销 2 处修改'), findsOneWidget);
        await tester.pump(const Duration(seconds: 3));
        expect(tester.takeException(), isNull);
      });
    });
  }
}
