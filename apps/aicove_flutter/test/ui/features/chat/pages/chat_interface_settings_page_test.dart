import 'dart:io';
import 'dart:ui' as ui;

import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/features/chat/presentation/widgets/message_bubble.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/ui/features/chat/pages/chat_interface_settings_page.dart';
import 'package:aicove_flutter/src/ui/features/settings/pages/chat_ui_settings_page.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'chat_interface_test_support.dart';

/// 聊天菜单「聊天界面」页。--dart-define=WRITE_CHAT_INTERFACE_PREVIEW=true 时
/// 额外把源码渲染预览写到 scratch/chat-interface/。
void main() {
  const capture = bool.fromEnvironment('WRITE_CHAT_INTERFACE_PREVIEW');
  const viewSize = Size(390, 844);

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

  Conversation conversation({ChatDisplayStyle? style}) {
    final now = DateTime(2026, 10, 3);
    return Conversation(
      id: 'conv_1',
      title: 'Test',
      displayName: '纳西妲',
      chatDisplayStyle: style,
      chatBackgroundImage: 'assets/characters/images/nahida.jpg',
      characterImage: 'assets/characters/images/nahida.jpg',
      chatBackgroundMaskOpacity: 0.35,
      createdAt: now,
      updatedAt: now,
    );
  }

  Future<GlobalKey> pumpPage(
    WidgetTester tester,
    Conversation conv, {
    FakeChatInterfaceSettingsNotifier? settings,
  }) async {
    tester.view.physicalSize = viewSize * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    if (capture) await loadPreviewFonts(tester);
    final key = GlobalKey();
    await tester.pumpWidget(
      chatInterfaceTestScope(
        conversation: conv,
        settings: settings,
        child: MaterialApp(
          theme: ThemeData(
            fontFamily: capture ? 'Preview' : null,
            extensions: [MoeColors.light()],
          ),
          home: RepaintBoundary(
            key: key,
            child: ChatInterfaceSettingsPage(conversation: conv),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 450));
    await tester.pumpAndSettle();
    if (capture) {
      await tester.runAsync(() async {
        for (final element in find.byType(Image).evaluate()) {
          await precacheImage((element.widget as Image).image, element);
        }
      });
      await tester.pumpAndSettle();
    }
    return key;
  }

  Future<void> shot(WidgetTester tester, GlobalKey key, String name) async {
    if (!capture) return;
    await tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final dir = Directory('../../scratch/chat-interface')
        ..createSync(recursive: true);
      await File(
        '${dir.path}/$name.png',
      ).writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  testWidgets('上方用真实消息气泡预览，下方面板默认停在界面标签', (tester) async {
    final key = await pumpPage(tester, conversation());

    expect(find.byType(MessageBubble), findsNWidgets(4));
    expect(
      tester
          .widgetList<MessageBubble>(find.byType(MessageBubble))
          .every((bubble) => !bubble.documentStyle),
      isTrue,
    );
    final panelTop = tester
        .getTopLeft(find.byKey(const ValueKey('chat_interface_panel')))
        .dy;
    expect(
      panelTop,
      greaterThan(viewSize.height * 0.6),
      reason: '预览区应占据一半以上的高度',
    );
    expect(find.text('界面'), findsOneWidget);
    expect(find.text('消息样式'), findsOneWidget);
    expect(find.text('默认'), findsNothing, reason: '样式只剩气泡和文档');
    // 三项同高，消息样式排第一。
    final rows = [
      find.byKey(const ValueKey('chat_interface_style_toggle')),
      find.byKey(const ValueKey('chat_interface_edit_wallpaper')),
      find.byKey(const ValueKey('chat_interface_more_options')),
    ];
    final heights = [
      for (final row in rows.skip(1)) tester.getSize(row).height,
    ];
    expect(heights.toSet(), hasLength(1));
    final tops = [for (final row in rows) tester.getTopLeft(row).dy];
    expect(tops, orderedEquals([...tops]..sort()));
    expect(find.text('语音消息默认展开文字'), findsNothing);
    expect(find.text('隐藏用户头像'), findsNothing);
    expect(find.text('单轮聊天只显示一次头像'), findsNothing);
    expect(find.text('大小'), findsNothing);
    expect(find.text('用户发消息自动回底'), findsNothing);
    expect(tester.takeException(), isNull);
    await shot(tester, key, 'chat-interface-wallpaper');
  });

  testWidgets('会话为文档样式时预览按文档渲染', (tester) async {
    final key = await pumpPage(
      tester,
      conversation(style: ChatDisplayStyle.document),
    );
    expect(
      tester
          .widgetList<MessageBubble>(find.byType(MessageBubble))
          .every((bubble) => bubble.documentStyle),
      isTrue,
    );
    await shot(tester, key, 'chat-interface-document');
  });

  testWidgets('更多选项跳到通用设置的其他子项', (tester) async {
    await pumpPage(tester, conversation());

    await tester.tap(find.byKey(const ValueKey('chat_interface_more_options')));
    await tester.pumpAndSettle();
    expect(find.byType(ChatUiSettingsPage), findsOneWidget);
    expect(
      tester
          .widget<ChatUiSettingsPage>(find.byType(ChatUiSettingsPage))
          .initialTab,
      ChatUiSettingsTab.other,
    );
    expect(find.text('隐藏用户头像'), findsOneWidget);
    expect(find.text('单轮聊天只显示一次头像'), findsOneWidget);

    expect(tester.takeException(), isNull);
  });

  testWidgets('行为标签分用户与 AI 两个自动回底及允许单次发送多条消息', (tester) async {
    final settings = FakeChatInterfaceSettingsNotifier(
      chatInterfaceTestSettings(),
    );
    final key = await pumpPage(tester, conversation(), settings: settings);
    await tester.tap(find.text('行为'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('chat_interface_edit_wallpaper')),
      findsNothing,
    );
    expect(settings.settings.autoScrollOnSend, isTrue);
    expect(settings.settings.allowMultiMessageSend, isFalse);
    expect(find.text('允许单次发送多条消息'), findsOneWidget);
    await shot(tester, key, 'chat-interface-behavior');

    await tester.tap(find.text('允许单次发送多条消息'));
    await tester.pumpAndSettle();
    expect(settings.settings.allowMultiMessageSend, isTrue);

    await tester.tap(find.text('用户发消息自动回底'));
    await tester.pumpAndSettle();
    expect(settings.settings.autoScrollOnSend, isFalse);
    expect(settings.settings.autoScrollOnAiReply, isTrue);

    await tester.tap(find.text('AI 发消息自动回底'));
    await tester.pumpAndSettle();
    expect(settings.settings.autoScrollOnAiReply, isFalse);
    expect(tester.takeException(), isNull);
  });
}
