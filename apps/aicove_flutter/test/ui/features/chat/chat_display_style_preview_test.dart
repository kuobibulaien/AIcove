import 'dart:io';
import 'dart:ui' as ui;

import 'package:aicove_flutter/src/features/chat/domain/chat_display_policy.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/index.dart';
import 'package:aicove_flutter/src/ui/theme/skin_provider.dart';
import 'package:aicove_flutter/src/ui/theme/skins/moetalk_skin.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 源码渲染预览（ADR0047 批 B）：设置页「新会话默认样式」行与聊天菜单「聊天样式」选项单，
/// 用与页面相同的组件组合渲染。--dart-define=WRITE_CHAT_STYLE_PREVIEW=true 时写到
/// scratch/chat-style/。
void main() {
  const capture = bool.fromEnvironment('WRITE_CHAT_STYLE_PREVIEW');
  for (final dark in [false, true]) {
    testWidgets('chat display style preview dark=$dark', (tester) async {
      if (!capture) return;
      tester.view.physicalSize = const Size(360 * 2, 900 * 2);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.runAsync(() async {
        final loader = FontLoader('Preview')
          ..addFont(File('/System/Library/Fonts/STHeiti Medium.ttc')
              .readAsBytes()
              .then(ByteData.sublistView));
        await loader.load();
        final icons = FontLoader('MaterialIcons')
          ..addFont(File(
            '${Platform.environment['HOME']}/dev-sdks/flutter-3.44.6/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
          ).readAsBytes().then(ByteData.sublistView));
        await icons.load();
      });
      final key = GlobalKey();
      final colors = dark ? MoeColors.dark() : MoeColors.light();
      await tester.pumpWidget(
        SkinScope(
          skin: const MoeTalkSkin(),
          child: MaterialApp(
            theme: ThemeData(
              brightness: dark ? Brightness.dark : Brightness.light,
              fontFamily: 'Preview',
              extensions: [colors],
            ),
            home: RepaintBoundary(
              key: key,
              child: Scaffold(
                backgroundColor: colors.bgMain,
                body: ListView(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  children: [
                    MoeSettingsGroup(
                      title: '聊天样式与分段',
                      children: [
                        MoeSettingsRow(
                          label: '新会话默认样式',
                          subtitle: '文档样式不分段，长文和代码块完整显示；聊天菜单里可为单个会话另设',
                          trailingType: MoeSettingsRowTrailing.custom,
                          trailing: MoeToggleBar<ChatDisplayStyle>(
                            expanded: false,
                            value: ChatDisplayStyle.bubble,
                            items: const [
                              MoeToggleItem(
                                  value: ChatDisplayStyle.bubble, label: '气泡'),
                              MoeToggleItem(
                                  value: ChatDisplayStyle.document,
                                  label: '文档'),
                            ],
                            onChanged: (_) {},
                          ),
                        ),
                        MoeSettingsRow(
                          label: '启用消息分段',
                          subtitle: '气泡样式下按标点符号自动分段显示 AI 回复',
                          trailingType: MoeSettingsRowTrailing.switchControl,
                          switchValue: true,
                          onSwitchChanged: (_) {},
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    MoeActionSheet(
                      title: '聊天样式',
                      description: '只对当前会话生效',
                      enableHaptics: false,
                      actions: [
                        MoeSheetAction(
                            label: '跟随默认（气泡）', onTap: () {}),
                        MoeSheetAction(
                          label: '气泡',
                          subtitle: '按句分段，像聊天软件一样一条条冒出来',
                          onTap: () {},
                        ),
                        MoeSheetAction(
                          label: '文档（当前）',
                          subtitle: '不分段，长文和代码块完整显示',
                          onTap: () {},
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final dir = Directory('../../scratch/chat-style')
          ..createSync(recursive: true);
        await File('${dir.path}/chat-style-360-${dark ? 'dark' : 'light'}.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    });
  }
}
