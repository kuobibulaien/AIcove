import 'dart:io';
import 'dart:ui' as ui;
import 'package:aicove_flutter/src/features/chat/presentation/widgets/composer_more_panel.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/index.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:aicove_flutter/src/ui/theme/moe_interaction_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const capture = bool.fromEnvironment('WRITE_GROUP_QA');
  setUpAll(() async {
    if (!capture) return;
    for (final entry in {
      'GroupCapture': '/System/Library/Fonts/STHeiti Medium.ttc',
      'MaterialIcons':
          '${Platform.environment['FLUTTER_ROOT']}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    }.entries) {
      final loader = FontLoader(entry.key)
        ..addFont(File(entry.value).readAsBytes().then(ByteData.sublistView));
      await loader.load();
    }
  });
  for (final dark in [false, true]) {
    for (final liquid in [false, true]) {
      testWidgets('grouped buttons share outer surface $dark/$liquid', (
        tester,
      ) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(420, 720);
        addTearDown(tester.view.reset);
        MoeLiquidGlassService.setMockState(available: true);
        final boundary = GlobalKey();
        final menuKey = GlobalKey();
        var taps = 0;
        await tester.pumpWidget(
          MaterialApp(
            theme: withMoeInteractionTheme(
              ThemeData(
                brightness: dark ? Brightness.dark : Brightness.light,
                fontFamily: capture ? 'GroupCapture' : null,
                extensions: [dark ? MoeColors.dark() : MoeColors.light()],
              ),
            ),
            home: MoeGlassTheme(
              enabled: true,
              useLiquidGlass: liquid,
              blurSigma: 16,
              child: Scaffold(
                body: RepaintBoundary(
                  key: boundary,
                  child: ColoredBox(
                    color: dark
                        ? const Color(0xFF17232B)
                        : const Color(0xFFE8EDF2),
                    child: Column(
                      children: [
                        const SizedBox(height: 24),
                        MoeChatHeader(
                          title: const Text('聊天'),
                          actions: [
                            IconButton(
                              onPressed: () => taps++,
                              icon: const Icon(Icons.call_outlined),
                            ),
                            IconButton(
                              key: menuKey,
                              onPressed: () => MoePopupMenu.show(
                                menuKey.currentContext!,
                                targetBox:
                                    menuKey.currentContext!.findRenderObject()
                                        as RenderBox,
                                items: [
                                  MoePopupMenuItem(
                                    label: '详情',
                                    onTap: () => taps++,
                                  ),
                                ],
                              ),
                              icon: const Icon(Icons.more_horiz),
                            ),
                          ],
                          showBackButton: true,
                          nativeInset: 0,
                          toolbarHeight: 48,
                        ),
                        const Spacer(),
                        Padding(
                          padding: const EdgeInsets.all(12),
                          child: MoeFloatingSurface(
                            child: Row(
                              children: [
                                IconButton(
                                  onPressed: () => taps++,
                                  icon: const Icon(Icons.add),
                                ),
                                const Expanded(child: Text('输入消息')),
                                IconButton(
                                  onPressed: () => taps++,
                                  icon: const Icon(Icons.send),
                                ),
                              ],
                            ),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.all(12),
                          child: MoeFloatingSurface(
                            child: ComposerMorePanel(onAction: (_) => taps++),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        // Three header capsules, one composer capsule, one panel and five tiles.
        expect(find.byType(MoeFloatingSurface), findsNWidgets(10));
        await tester.tap(find.byIcon(Icons.call_outlined).first);
        await tester.tap(find.text('相册'));
        expect(taps, 2);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.tap(find.byIcon(Icons.more_horiz));
        await tester.pumpAndSettle();
        expect(find.byType(MoeFloatingSurface), findsNWidgets(11));
        await tester.tap(find.text('详情'));
        await tester.pumpAndSettle();
        expect(taps, 3);
        expect(find.byType(MoeFloatingSurface), findsNWidgets(10));
        if (capture && liquid) {
          await tester.runAsync(() async {
            final render =
                boundary.currentContext!.findRenderObject()
                    as RenderRepaintBoundary;
            final image = await render.toImage();
            final data = await image.toByteData(format: ui.ImageByteFormat.png);
            final file = File(
              '../../.codex-temp/shared-button-surface/${dark ? 'dark' : 'light'}.png',
            );
            await file.parent.create(recursive: true);
            await file.writeAsBytes(data!.buffer.asUint8List());
            image.dispose();
          });
        }
      });
    }
  }

  for (final dark in [false, true]) {
    testWidgets(
      'root header and list row icon buttons have no frame or press feedback ($dark)',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(420, 680);
        addTearDown(tester.view.reset);
        MoeLiquidGlassService.setMockState(available: true);
        final boundary = GlobalKey();
        final colors = dark ? MoeColors.dark() : MoeColors.light();
        await tester.pumpWidget(
          MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: withMoeInteractionTheme(
              ThemeData(
                brightness: dark ? Brightness.dark : Brightness.light,
                fontFamily: capture ? 'GroupCapture' : null,
                extensions: [colors],
              ),
            ),
            home: MoeGlassTheme(
              enabled: true,
              useLiquidGlass: false,
              blurSigma: 16,
              child: RepaintBoundary(
                key: boundary,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: dark
                          ? const [
                              Color(0xFF15384B),
                              Color(0xFF1A1528),
                              Color(0xFF1A332A),
                            ]
                          : const [
                              Color(0xFF78B7C4),
                              Color(0xFFF6C0A2),
                              Color(0xFF9AC58E),
                            ],
                    ),
                  ),
                  child: MoeSurfaceGroup(
                    child: Scaffold(
                      backgroundColor: Colors.transparent,
                      appBar: MoeAppBar(
                        title: '角色',
                        centerTitle: true,
                        actions: [
                          MoeIconButton(
                            key: const ValueKey('role-create-btn'),
                            tooltip: '创建角色',
                            icon: Icons.person_add_alt_1_outlined,
                            onTap: () {},
                          ),
                        ],
                      ),
                      body: ListView(
                        padding: const EdgeInsets.fromLTRB(16, 80, 16, 24),
                        children: [
                          MoeSettingsGroup(
                            title: '预设列表',
                            children: [
                              MoeSettingsRow(
                                label: '默认绘图预设',
                                subtitle: 'NovelAI · 832 × 1216 · 1 张',
                                trailingType: MoeSettingsRowTrailing.custom,
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    MoeIconButton(
                                      key: const ValueKey('preset-more-btn'),
                                      icon: Icons.more_vert,
                                      size: 20,
                                      color: colors.muted,
                                      tooltip: '更多操作',
                                      onTap: () {},
                                    ),
                                    Icon(
                                      Icons.chevron_right,
                                      size: 20,
                                      color: colors.muted,
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          MoeSettingsGroup(
                            title: '模型列表（支持拖拽排序）',
                            children: [
                              ReorderableListView(
                                shrinkWrap: true,
                                physics: const NeverScrollableScrollPhysics(),
                                buildDefaultDragHandles: false,
                                onReorder: (_, _) {},
                                children: [
                                  ReorderableDelayedDragStartListener(
                                    key: const ValueKey('model-0'),
                                    index: 0,
                                    child: MoeSettingsRow(
                                      label: 'deepseek-flash',
                                      subtitle: '快速对话模型',
                                      showDivider: false,
                                      trailingType:
                                          MoeSettingsRowTrailing.custom,
                                      trailing: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          MoeIconButton(
                                            key: const ValueKey('model-copy'),
                                            icon: Icons.copy_outlined,
                                            size: 16,
                                            padding: const EdgeInsets.all(6),
                                            minTouchTarget: 32,
                                            color: colors.muted,
                                            onTap: () {},
                                          ),
                                          MoeIconButton(
                                            key: const ValueKey('model-edit'),
                                            icon: Icons.edit_outlined,
                                            size: 18,
                                            padding: const EdgeInsets.all(6),
                                            minTouchTarget: 32,
                                            color: colors.muted,
                                            onTap: () {},
                                          ),
                                          MoeIconButton(
                                            key: const ValueKey('model-del'),
                                            icon: Icons.delete_outline,
                                            size: 18,
                                            padding: const EdgeInsets.all(6),
                                            minTouchTarget: 32,
                                            color: Colors.redAccent,
                                            onTap: () {},
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          Row(
                            children: [
                              Expanded(
                                child: MoeSecondaryButton(
                                  label: '获取模型',
                                  icon: Icons.cloud_download_outlined,
                                  onPressed: () {},
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: MoePrimaryButton(
                                  label: '新建预设',
                                  icon: Icons.add,
                                  onPressed: () {},
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        for (final key in [
          'role-create-btn',
          'preset-more-btn',
          'model-copy',
          'model-edit',
          'model-del',
        ]) {
          expect(
            find.descendant(
              of: find.byKey(ValueKey(key)),
              matching: find.byType(MoeFloatingSurface),
            ),
            findsNothing,
          );
          expect(
            find.descendant(
              of: find.byKey(ValueKey(key)),
              matching: find.byType(MoeButtonSurface),
            ),
            findsNothing,
          );
        }
        if (capture) {
          await tester.runAsync(() async {
            final render =
                boundary.currentContext!.findRenderObject()
                    as RenderRepaintBoundary;
            final image = await render.toImage(pixelRatio: 2.0);
            final data = await image.toByteData(format: ui.ImageByteFormat.png);
            final file = File(
              '../../scratch/button-audit-20261013/preview-${dark ? 'dark' : 'light'}.png',
            );
            await file.parent.create(recursive: true);
            await file.writeAsBytes(data!.buffer.asUint8List());
            image.dispose();
          });
        }
      },
    );
  }
}
