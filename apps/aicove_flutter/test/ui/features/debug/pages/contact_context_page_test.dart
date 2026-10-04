import 'dart:io';
import 'dart:ui' as ui;

import 'package:aicove_flutter/src/features/chat/application/chat_ports.dart';
import 'package:aicove_flutter/src/features/chat/chat_layer_providers.dart';
import 'package:aicove_flutter/src/features/chat/conversation_providers.dart';
import 'package:aicove_flutter/src/features/chat/domain/chat_context_preview.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/ui/features/debug/pages/contact_context_page.dart';
import 'package:aicove_flutter/src/ui/theme/skin_provider.dart';
import 'package:aicove_flutter/src/ui/theme/skins/moetalk_skin.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

final _contact = Conversation(
  id: 'a',
  title: '小雪',
  displayName: '小雪',
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
);

class _Contacts extends ConversationsNotifier {
  @override
  Future<List<Conversation>> build() async => [
    _contact,
    _contact.copyWith(id: 'b', title: '阿澈', displayName: '阿澈'),
  ];
}

class _Port implements ChatContextPreviewPort {
  final requested = <String>[];

  @override
  Future<ChatContextPreview> preview(Conversation conversation) async {
    requested.add(conversation.id);
    return const ChatContextPreview(
      modelId: 'deepseek:deepseek-flash',
      presetName: null,
      messages: [
        {'role': 'system', 'content': '你是小雪，温柔的陪伴者。\n\n可以输出 <tts> 标签朗读。'},
        {'role': 'user', 'content': '今天有点累'},
        {
          'role': 'assistant',
          'content': '',
          'tool_calls': [
            {
              'function': {'name': 'draw_image', 'arguments': '{"prompt":"sea"}'},
            },
          ],
        },
        {'role': 'tool', 'name': 'draw_image', 'content': '图片已生成'},
      ],
      messageTokens: [32, 8, 12, 6],
      tools: [
        {
          'type': 'function',
          'function': {
            'name': 'draw_image',
            'description': '根据描述画一张图',
            'parameters': {'type': 'object'},
          },
        },
      ],
      sources: [
        ChatContextSource(label: '角色人设', content: '你是小雪，温柔的陪伴者。'),
        ChatContextSource(label: '语音合成', content: '可以输出 <tts> 标签朗读。'),
      ],
      plugins: [
        ChatContextPluginStatus(name: '语音合成', injected: true),
        ChatContextPluginStatus(name: '时间感知', injected: false, reason: '插件未启用'),
      ],
      inputTokens: 58,
      inputLimit: 217600,
      notes: ['话题边界还没有摘要，真实发送前会先自动整理一次'],
    );
  }
}

void main() {
  const capture = bool.fromEnvironment('WRITE_CONTACT_CONTEXT_PREVIEW');

  Future<_Port> mount(
    WidgetTester tester,
    Widget page, {
    double width = 400,
    GlobalKey? boundary,
  }) async {
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final port = _Port();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          conversationsProvider.overrideWith(_Contacts.new),
          chatContextPreviewPortProvider.overrideWithValue(port),
        ],
        child: SkinScope(
          skin: const MoeTalkSkin(),
          child: MaterialApp(
            theme: ThemeData(
              fontFamily: capture ? 'Preview' : null,
              extensions: [MoeColors.light()],
            ),
            home: RepaintBoundary(key: boundary, child: page),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return port;
  }

  testWidgets('选联系人后展示该联系人的完整上下文', (tester) async {
    final port = await mount(tester, const ContactContextListPage());
    await tester.enterText(find.byType(TextField), '阿');
    await tester.pumpAndSettle();
    expect(find.text('小雪'), findsNothing);
    await tester.enterText(find.byType(TextField), '');
    await tester.pumpAndSettle();
    await tester.tap(find.text('小雪'));
    await tester.pumpAndSettle();

    expect(port.requested, ['a']);
    expect(find.text('deepseek:deepseek-flash'), findsOneWidget);
    expect(find.text('未绑定预设'), findsOneWidget);
    expect(find.textContaining('还没有摘要'), findsOneWidget);
    expect(find.textContaining('系统  #1', findRichText: true), findsOneWidget);
    expect(find.textContaining('用户  #2', findRichText: true), findsOneWidget);
    expect(find.textContaining('→ 调用 draw_image'), findsOneWidget);
    expect(
      find.textContaining('工具结果 draw_image', findRichText: true),
      findsOneWidget,
    );

    await tester.tap(find.text('系统组成'));
    await tester.pumpAndSettle();
    expect(find.textContaining('角色人设', findRichText: true), findsOneWidget);
    expect(find.text('插件未启用'), findsOneWidget);

    await tester.tap(find.text('工具 1'));
    await tester.pumpAndSettle();
    expect(find.text('draw_image', findRichText: true), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('点开消息看全文，刷新会重新装配', (tester) async {
    final port = await mount(tester, ContactContextPage(conversation: _contact));
    expect(find.byType(SelectableText), findsNothing);
    await tester.tap(find.text('今天有点累'));
    await tester.pumpAndSettle();
    expect(find.byType(SelectableText), findsOneWidget);
    await tester.tap(find.byIcon(Icons.refresh_rounded));
    await tester.pumpAndSettle();
    expect(port.requested, ['a', 'a']);
  });

  for (final width in [400.0, 1000.0]) {
    testWidgets('contact context source rendered preview $width', (
      tester,
    ) async {
      if (!capture) return;
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
      final key = GlobalKey();
      await mount(
        tester,
        width < 900
            ? ContactContextPage(conversation: _contact)
            : const ContactContextListPage(),
        width: width,
        boundary: key,
      );
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final dir = Directory('../../.codex-temp/contact-context')
          ..createSync(recursive: true);
        await File(
          '${dir.path}/${width < 900 ? 'detail' : 'list'}-${width.toInt()}.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    });
  }
}
