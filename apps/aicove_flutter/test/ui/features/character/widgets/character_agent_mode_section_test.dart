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
    double textScale = 1,
  }) {
    return MaterialApp(
      theme: ThemeData(fontFamily: 'Preview', extensions: [MoeColors.light()]),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
        ),
        child: child!,
      ),
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

    await tester.tap(find.text('智能体'));
    await tester.pumpAndSettle();
    expect(picked, RoleAgentMode.agent);
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

    await tester.tap(find.text('纯聊天'));
    await tester.pumpAndSettle();

    expect(picked, isNull);
  });

  testWidgets('窄屏大字号时只显示当前档位，不溢出', (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      app(mode: RoleAgentMode.agent, locked: false, onChanged: (_) {}, textScale: 1.8),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('智能体'), findsOneWidget);
    expect(find.text('纯聊天'), findsNothing);
  });

  testWidgets('窄屏大字号时点开底部菜单切换', (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    RoleAgentMode? picked;
    await tester.pumpWidget(
      app(
        mode: RoleAgentMode.agent,
        locked: false,
        onChanged: (mode) => picked = mode,
        textScale: 1.8,
      ),
    );
    await tester.tap(find.text('角色模式'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('纯聊天'));
    await tester.pumpAndSettle();

    expect(picked, RoleAgentMode.chat);
    expect(tester.takeException(), isNull);
  });

  if (_writePreview) {
    for (final (name, mode, locked, width, scale) in [
      ('chat', RoleAgentMode.chat, false, 390.0, 1.0),
      ('tool', RoleAgentMode.tool, false, 390.0, 1.0),
      ('agent', RoleAgentMode.agent, false, 390.0, 1.0),
      ('locked', RoleAgentMode.tool, true, 390.0, 1.0),
      ('narrow-large-text', RoleAgentMode.agent, false, 320.0, 1.8),
    ]) {
      testWidgets('渲染预览：$name', (tester) async {
        final key = GlobalKey();
        tester.view.physicalSize = Size(width, 260);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          app(
            mode: mode,
            locked: locked,
            onChanged: (_) {},
            captureKey: key,
            textScale: scale,
          ),
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
