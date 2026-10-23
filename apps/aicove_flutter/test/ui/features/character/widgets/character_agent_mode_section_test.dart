import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/features/chat/domain/role_agent_mode.dart';
import 'package:aicove_flutter/src/ui/features/character/widgets/character_agent_mode_section.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';

/// 设为 true 时把三种状态渲染成 PNG（源码渲染预览，ADR 无关，供汇报用）。
const _writePreview = bool.fromEnvironment('WRITE_AGENT_MODE_PREVIEW');

void main() {
  setUpAll(() async {
    if (!_writePreview) return;
    final loader = FontLoader('Preview')
      ..addFont(
        File(
          '/System/Library/Fonts/STHeiti Medium.ttc',
        ).readAsBytes().then(ByteData.sublistView),
      );
    await loader.load();
  });

  Widget app({
    required RoleAgentMode mode,
    required bool locked,
    required ValueChanged<RoleAgentMode> onChanged,
    Key? captureKey,
  }) {
    return MaterialApp(
      theme: ThemeData(fontFamily: 'Preview', extensions: [MoeColors.light()]),
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: RepaintBoundary(
            key: captureKey,
            child: ColoredBox(
              color: Colors.white,
              child: CharacterAgentModeSection(
                mode: mode,
                locked: locked,
                onChanged: onChanged,
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('点选另一档时回调新模式', (tester) async {
    RoleAgentMode? picked;
    await tester.pumpWidget(
      app(
        mode: RoleAgentMode.chat,
        locked: false,
        onChanged: (mode) => picked = mode,
      ),
    );

    await tester.tap(find.text('工具'));
    await tester.pumpAndSettle();

    expect(picked, RoleAgentMode.tool);
  });

  testWidgets('锁定时不能切换', (tester) async {
    RoleAgentMode? picked;
    await tester.pumpWidget(
      app(
        mode: RoleAgentMode.tool,
        locked: true,
        onChanged: (mode) => picked = mode,
      ),
    );

    await tester.tap(find.text('聊天'));
    await tester.pumpAndSettle();

    expect(picked, isNull);
  });

  if (_writePreview) {
    for (final (name, mode, locked) in [
      ('chat', RoleAgentMode.chat, false),
      ('tool', RoleAgentMode.tool, false),
      ('locked', RoleAgentMode.tool, true),
    ]) {
      testWidgets('渲染预览：$name', (tester) async {
        final key = GlobalKey();
        tester.view.physicalSize = const Size(390, 260);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          app(mode: mode, locked: locked, onChanged: (_) {}, captureKey: key),
        );
        await tester.pumpAndSettle();

        await tester.runAsync(() async {
          final boundary =
              key.currentContext!.findRenderObject() as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: 2);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File('../../scratch/role-agent-mode-20261021/$name.png');
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
        });
      });
    }
  }
}
