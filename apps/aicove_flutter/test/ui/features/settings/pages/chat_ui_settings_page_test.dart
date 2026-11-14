import 'dart:io';
import 'dart:ui' as ui;

import 'package:aicove_flutter/src/features/chat/presentation/widgets/message_bubble.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/ui/features/settings/pages/chat_ui_settings_page.dart';
import 'package:aicove_flutter/src/ui/features/settings/pages/ui_settings_page.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 通用设置顶部「聊天界面」二级页：上方示例对话，下方「大小／样式／其他」面板。
/// `--dart-define=WRITE_UI_SETTINGS_QA=true` 时输出源码渲染预览到
/// .codex-temp/chat-ui-settings/。
void main() {
  const capture = bool.fromEnvironment('WRITE_UI_SETTINGS_QA');
  setUpAll(() async {
    if (!capture) return;
    final font = FontLoader('UiSettingsPreview')
      ..addFont(
        File(
          '/System/Library/Fonts/STHeiti Medium.ttc',
        ).readAsBytes().then(ByteData.sublistView),
      );
    await font.load();
  });

  Future<void> settle(WidgetTester tester) async {
    // 设置写入与示例图片解码都要真实事件循环，先让它们跑完。
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 30));
      for (final element in find.byType(Image).evaluate().toList()) {
        await precacheImage((element.widget as Image).image, element);
      }
    });
    var frames = 0;
    while (tester.binding.hasScheduledFrame && frames < 600) {
      await tester.pump(const Duration(milliseconds: 16));
      frames++;
    }
    expect(frames, lessThan(600), reason: 'frames keep being scheduled');
  }

  Future<void> snapshot(WidgetTester tester, GlobalKey key, String name) async {
    if (!capture) return;
    await settle(tester);
    await tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 1.5);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('../../.codex-temp/chat-ui-settings/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  testWidgets('通用设置顶部进入聊天界面：预览与三页面板', (tester) async {
    addTearDown(tester.view.reset);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 860);
    SharedPreferences.setMockInitialValues({});
    final key = GlobalKey();
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: ThemeData(
            fontFamily: capture ? 'UiSettingsPreview' : null,
            scaffoldBackgroundColor: moeSurface,
            extensions: [MoeColors.light()],
          ),
          builder: (context, child) => RepaintBoundary(key: key, child: child),
          home: const UiSettingsPage(),
        ),
      ),
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(UiSettingsPage)),
    );
    await tester.runAsync(() => container.read(appSettingsProvider.future));
    await settle(tester);
    AppSettings settings() => container.read(appSettingsProvider).value!;

    final entry = find.byKey(const ValueKey('chat_ui_settings_entry'));
    expect(entry, findsOneWidget);
    expect(
      tester.getTopLeft(entry).dy,
      lessThan(tester.getTopLeft(find.text('外观')).dy),
      reason: '聊天界面入口在通用设置最上方',
    );
    expect(find.text('字体大小'), findsNothing);
    expect(find.text('新会话默认'), findsNothing);
    await snapshot(tester, key, 'general');

    await tester.tap(entry);
    await settle(tester);
    expect(find.byType(ChatUiSettingsPage), findsOneWidget);
    final preview = find.byKey(const ValueKey('chat_ui_settings_preview'));
    expect(
      find.descendant(of: preview, matching: find.byType(MessageBubble)),
      findsWidgets,
    );
    expect(
      find.descendant(of: preview, matching: find.byType(Image)),
      findsWidgets,
      reason: '示例对话里有一张图片',
    );

    final panel = find.byKey(const ValueKey('chat_ui_settings_panel'));
    final panelHeight = tester.getSize(panel).height;
    void expectSamePanelHeight() =>
        expect(tester.getSize(panel).height, panelHeight, reason: '三页面板高度一致');

    // 大小
    for (final k in [
      'chat_ui_text_scale',
      'chat_ui_ui_scale',
      'chat_ui_image_scale',
    ]) {
      expect(find.byKey(ValueKey(k)), findsOneWidget, reason: k);
    }
    await snapshot(tester, key, 'size');

    // 样式：气泡下是消息分段及其子项，文档下是工具调用。
    await tester.tap(find.text('样式'));
    await settle(tester);
    for (final k in [
      'default_chunking_switch',
      'chunk_punctuation_set_row',
      'filter_punctuation_switch',
    ]) {
      expect(find.byKey(ValueKey(k)), findsOneWidget, reason: k);
    }
    expect(
      find.byKey(const ValueKey('default_document_show_tool_calls_switch')),
      findsNothing,
    );
    expectSamePanelHeight();
    await snapshot(tester, key, 'style-bubble');

    await tester.tap(find.text('文档'));
    await settle(tester);
    expect(settings().chatDisplayStyle, ChatDisplayStyle.document);
    expect(find.byKey(const ValueKey('default_chunking_switch')), findsNothing);
    final toolCalls = find.byKey(
      const ValueKey('default_document_show_tool_calls_switch'),
    );
    expect(toolCalls, findsOneWidget);
    if (!settings().documentShowToolCalls) {
      await tester.tap(toolCalls);
      await settle(tester);
    }
    expect(settings().documentShowToolCalls, isTrue);
    expectSamePanelHeight();
    await snapshot(tester, key, 'style-document');

    // 其他：思维链一个开关同时管两种样式。
    await tester.tap(find.text('其他'));
    await settle(tester);
    expect(
      find.byKey(const ValueKey('default_expand_audio_switch')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('default_hide_user_avatar_switch')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('single_avatar_per_turn_switch')),
      findsOneWidget,
    );
    expect(find.text('单轮聊天只显示一次头像'), findsOneWidget);
    expect(settings().singleAvatarPerTurn, isFalse);
    expectSamePanelHeight();
    await snapshot(tester, key, 'other-document');
    await tester.tap(
      find.byKey(const ValueKey('default_show_thinking_switch')),
    );
    await settle(tester);
    expect(settings().bubbleShowThinking, isFalse);
    expect(settings().documentShowThinking, isFalse);

    // 恢复思维链并切回气泡样式，验证「单轮聊天只显示一次头像」开关与预览效果。
    await tester.tap(
      find.byKey(const ValueKey('default_show_thinking_switch')),
    );
    await settle(tester);
    await tester.tap(find.text('样式'));
    await settle(tester);
    await tester.tap(find.text('气泡'));
    await settle(tester);
    await tester.tap(find.text('其他'));
    await settle(tester);
    expectSamePanelHeight();

    final previewAvatars = find.descendant(
      of: preview,
      matching: find.byWidgetPredicate(
        (w) => w.runtimeType.toString() == '_Avatar',
      ),
    );
    expect(previewAvatars, findsNWidgets(4));
    await snapshot(tester, key, 'other-bubble-every-avatar');

    await tester.tap(
      find.byKey(const ValueKey('single_avatar_per_turn_switch')),
    );
    await settle(tester);
    expect(settings().singleAvatarPerTurn, isTrue);
    expect(previewAvatars, findsOneWidget);
    await snapshot(tester, key, 'other-bubble-single-avatar');
    expect(tester.takeException(), isNull);
  });
}
