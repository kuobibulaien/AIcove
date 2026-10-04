import 'dart:io';
import 'dart:ui' as ui;

import 'package:aicove_flutter/src/ui/features/debug/pages/debug_center_page.dart';
import 'package:aicove_flutter/src/ui/features/debug/pages/debug_other_tools_page.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 调试中心与「其他」页。--dart-define=WRITE_DEBUG_CENTER_PREVIEW=true 时
/// 额外把源码渲染预览写到 scratch/debug-center/。
void main() {
  const capture = bool.fromEnvironment('WRITE_DEBUG_CENTER_PREVIEW');
  const viewSize = Size(390, 844);
  const lowFrequency = ['诊断导出与电脑读取', 'UI 组件库', '流式监控', '网络诊断'];

  Future<void> loadPreviewFonts(WidgetTester tester) async {
    await tester.runAsync(() async {
      final loader = FontLoader('Preview')
        ..addFont(
          File(
            '/System/Library/Fonts/STHeiti Medium.ttc',
          ).readAsBytes().then(ByteData.sublistView),
        );
      await loader.load();
      final icons = FontLoader('MaterialIcons')
        ..addFont(
          File(
            '${Platform.environment['HOME']}/dev-sdks/flutter-3.44.6/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
          ).readAsBytes().then(ByteData.sublistView),
        );
      await icons.load();
    });
  }

  Future<GlobalKey> pumpCenter(WidgetTester tester) async {
    tester.view.physicalSize = viewSize * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    if (capture) await loadPreviewFonts(tester);
    final key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          theme: ThemeData(
            fontFamily: capture ? 'Preview' : null,
            extensions: [MoeColors.light()],
          ),
          home: const DebugCenterPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return key;
  }

  Future<void> shot(WidgetTester tester, GlobalKey key, String name) async {
    if (!capture) return;
    await tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final dir = Directory('../../scratch/debug-center')
        ..createSync(recursive: true);
      await File(
        '${dir.path}/$name.png',
      ).writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  testWidgets('低频工具收进列表底部的「其他」', (tester) async {
    final key = await pumpCenter(tester);

    for (final label in lowFrequency) {
      expect(find.text(label), findsNothing);
    }
    final other = find.text(DebugOtherToolsPage.title);
    expect(other, findsOneWidget);
    expect(
      tester.getTopLeft(other).dy,
      greaterThan(tester.getTopLeft(find.text('同步与备份')).dy),
      reason: '「其他」应在列表最底部',
    );
    await shot(tester, key, 'debug-center');

    await tester.tap(other);
    await tester.pumpAndSettle();
    expect(find.byType(DebugOtherToolsPage), findsOneWidget);
    for (final label in lowFrequency) {
      expect(find.text(label), findsOneWidget);
    }
    expect(tester.takeException(), isNull);
    await shot(tester, key, 'debug-other-tools');
  });
}
