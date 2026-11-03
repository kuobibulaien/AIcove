import 'dart:io';
import 'dart:ui' as ui;

import 'package:aicove_flutter/src/features/chat/application/chat_view_prefs.dart';
import 'package:aicove_flutter/src/features/chat/conversation_providers.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/features/chat/presentation/widgets/message_bubble.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/ui/features/chat/pages/chat_interface_settings_page.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
    expect(find.text('编辑壁纸'), findsOneWidget);
    expect(find.text('样式'), findsOneWidget);
    expect(find.text('默认'), findsNothing, reason: '样式只剩气泡和文档');
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

  testWidgets('更多选项只列当前样式的细节', (tester) async {
    final settings = FakeChatInterfaceSettingsNotifier(
      chatInterfaceTestSettings(),
    );
    final key = await pumpPage(tester, conversation(), settings: settings);
    expect(find.text('气泡样式更多选项'), findsOneWidget);
    expect(find.text('消息分段'), findsNothing);

    await tester.tap(find.text('气泡样式更多选项'));
    await tester.pumpAndSettle();
    expect(find.text('消息分段'), findsOneWidget);
    // 分段标点和省略句末标点是全局设置，不在这里。
    expect(find.text('过滤句末标点'), findsNothing);
    expect(find.text('分段标点'), findsNothing);
    expect(find.text('显示工具调用'), findsNothing);
    await tester.ensureVisible(
      find.byKey(const ValueKey('bubble_show_thinking_switch')),
    );
    await tester.pumpAndSettle();
    await shot(tester, key, 'chat-interface-bubble-options');

    await tester.tap(find.byKey(const ValueKey('bubble_show_thinking_switch')));
    await tester.pumpAndSettle();
    expect(settings.settings.bubbleShowThinking, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('文档样式的更多选项是思维链与工具调用，默认都开', (tester) async {
    final settings = FakeChatInterfaceSettingsNotifier(
      chatInterfaceTestSettings(),
    );
    final key = await pumpPage(
      tester,
      conversation(style: ChatDisplayStyle.document),
      settings: settings,
    );
    await tester.tap(find.text('文档样式更多选项'));
    await tester.pumpAndSettle();
    expect(find.text('消息分段'), findsNothing);
    expect(settings.settings.documentShowThinking, isTrue);
    expect(settings.settings.documentShowToolCalls, isTrue);
    await shot(tester, key, 'chat-interface-document-options');

    await tester.ensureVisible(
      find.byKey(const ValueKey('document_show_tool_calls_switch')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('document_show_tool_calls_switch')),
    );
    await tester.pumpAndSettle();
    expect(settings.settings.documentShowToolCalls, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('行为标签分用户与 AI 两个自动回底及允许单次发送多条消息', (tester) async {
    final settings = FakeChatInterfaceSettingsNotifier(
      chatInterfaceTestSettings(),
    );
    final key = await pumpPage(tester, conversation(), settings: settings);
    await tester.tap(find.text('行为'));
    await tester.pumpAndSettle();
    expect(find.text('编辑壁纸'), findsNothing);
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

  testWidgets('图片大小、语音展开、隐藏头像只改这个联系人', (tester) async {
    final now = DateTime(2026, 10, 3);
    final other = Conversation(
      id: 'conv_2',
      title: 'Other',
      displayName: '芙宁娜',
      createdAt: now,
      updatedAt: now,
    );
    final conv = conversation();
    tester.view.physicalSize = viewSize * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    late WidgetRef ref;
    await tester.pumpWidget(
      chatInterfaceTestScope(
        conversation: conv,
        others: [other],
        child: MaterialApp(
          theme: ThemeData(extensions: [MoeColors.light()]),
          home: Consumer(
            builder: (context, r, _) {
              ref = r;
              return ChatInterfaceSettingsPage(conversation: conv);
            },
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 450));
    await tester.pumpAndSettle();
    expect(find.text('通用设置'), findsNothing);

    // 默认沿用全局值：隐藏用户头像、语音默认展开。
    final hideSwitch = find.byKey(
      const ValueKey('chat_interface_hide_user_avatar_switch'),
    );
    await tester.ensureVisible(hideSwitch);
    await tester.tap(hideSwitch);
    await tester.pumpAndSettle();
    final audioSwitch = find.byKey(
      const ValueKey('chat_interface_expand_audio_switch'),
    );
    await tester.ensureVisible(audioSwitch);
    await tester.tap(audioSwitch);
    await tester.pumpAndSettle();

    final stored = ref.read(conversationsProvider).value!;
    expect(stored[0].hideUserAvatar, isFalse);
    expect(stored[0].expandAudioText, isFalse);
    expect(stored[1].hideUserAvatar, isNull);
    expect(stored[1].expandAudioText, isNull);
    expect(ref.read(appSettingsProvider).value!.hideUserAvatar, isTrue);
    // 预览气泡跟着这个联系人的设置走。
    final preview = tester.element(find.byType(MessageBubble).first);
    expect(ChatViewScope.maybeOf(preview)?.hideUserAvatar, isFalse);
    expect(
      find.byKey(const ValueKey('chat_interface_image_scale_slider')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('消息分段只改这个联系人', (tester) async {
    final settings = FakeChatInterfaceSettingsNotifier(
      chatInterfaceTestSettings(),
    );
    final conv = conversation();
    tester.view.physicalSize = viewSize * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    late WidgetRef ref;
    await tester.pumpWidget(
      chatInterfaceTestScope(
        conversation: conv,
        settings: settings,
        child: MaterialApp(
          theme: ThemeData(extensions: [MoeColors.light()]),
          home: Consumer(
            builder: (context, r, _) {
              ref = r;
              return ChatInterfaceSettingsPage(conversation: conv);
            },
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 450));
    await tester.pumpAndSettle();
    await tester.tap(find.text('气泡样式更多选项'));
    await tester.pumpAndSettle();
    final chunking = find.byKey(const ValueKey('bubble_chunking_switch'));
    await tester.ensureVisible(chunking);
    await tester.tap(chunking);
    await tester.pumpAndSettle();

    final stored = ref.read(conversationsProvider).value!.single;
    expect(stored.chunkEnabled, isFalse);
    // 全局默认不动。
    expect(settings.settings.messageFormatConfig.enableChunking, isTrue);
    expect(tester.takeException(), isNull);
  });
}
