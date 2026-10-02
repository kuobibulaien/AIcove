import 'dart:io';
import 'dart:ui' as ui;

import 'package:aicove_flutter/src/core/models/message_block.dart';
import 'package:aicove_flutter/src/core/utils/message_formatter.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/presentation/widgets/message_bubble.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/moe_code_block.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/moe_collapsible_bubble.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/moe_markdown_view.dart';
import 'package:aicove_flutter/src/ui/theme/skin_provider.dart';
import 'package:aicove_flutter/src/ui/theme/skins/moetalk_skin.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeAppSettingsNotifier extends AppSettingsNotifier {
  @override
  Future<AppSettings> build() async => AppSettings(
        ttsEnabled: false,
        defaultModelName: 'm',
        defaultPersonaPrompt: '',
        modelList: const ['m'],
        allKnownModels: const ['m'],
        modelDisplayNames: const {},
        modelTypes: const {},
        modelConfigs: const {},
        apiKey: '',
        apiBaseUrl: '',
        imageGenerationEnabled: false,
        maxFileUploadMB: 10,
        contextWindowTokens: 1000,
        customModels: const [],
        providers: const [],
        modelProviderMap: const {},
        backendApiKey: '',
        messageChunkingEnabled: false,
        messageFormatConfig: const MessageFormatConfig(),
        textScaleFactor: 1.0,
        uiScaleFactor: 1.0,
        imagePreviewScale: 1.0,
        autoReplySettings: const AutoReplySettings(),
        globalBackgroundColor: GlobalBackgroundColor.white,
        chatBackgroundColor: ChatBackgroundColor.defaultColor,
        isDarkMode: false,
        useSystemTheme: true,
        accentColor: 'FC96AA',
        hideUserAvatar: false,
      );
}

Widget _host(Widget child, {bool dark = false, String? fontFamily}) =>
    ProviderScope(
      overrides: [
        appSettingsProvider.overrideWith(_FakeAppSettingsNotifier.new),
      ],
      child: SkinScope(
        skin: const MoeTalkSkin(),
        child: MaterialApp(
          theme: ThemeData(
            brightness: dark ? Brightness.dark : Brightness.light,
            fontFamily: fontFamily,
            extensions: [dark ? MoeColors.dark() : MoeColors.light()],
          ),
          home: Scaffold(body: child),
        ),
      ),
    );


const _reply = """## 出门前的小清单

今天天气不错，适合去河边走走。记得带上这些：

- 一瓶水
- **防晒霜**（紫外线有点强）
- 手机和耳机

> 小提示：傍晚风大，带件薄外套。

| 时间 | 安排 |
|---|---|
| 15:00 | 出发 |
| 17:30 | 看日落 |

想记步数的话，可以用这段：

```python
steps = sum(day.steps for day in week)
print(f"本周一共走了 {steps} 步")
```
""";

Message _msg(String id, String role, String text) => Message.text(
      id: id,
      role: role,
      content: text,
      createdAt: DateTime(2026, 10, 1),
    );

void main() {
  for (final width in [360.0, 1000.0]) {
    for (final dark in [false, true]) {
      testWidgets('document assistant renders markdown full width $width dark=$dark',
          (tester) async {
        tester.view.physicalSize = Size(width, 1600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(_host(
          SingleChildScrollView(
            child: Column(children: [
              MessageBubble(
                isMe: true,
                message: _msg('u', 'user', '今天去哪玩？'),
                documentStyle: true,
              ),
              MessageBubble(
                isMe: false,
                message: _msg('a', 'assistant', _reply),
                documentStyle: true,
              ),
            ]),
          ),
          dark: dark,
        ));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byType(MoeMarkdownView), findsOneWidget);
        expect(find.byType(MoeCodeBlock), findsOneWidget);
        expect(find.textContaining('##'), findsNothing);
        expect(find.textContaining('```'), findsNothing);

        final assistant = tester.widget<Container>(
            find.byKey(const ValueKey('message_bubble_a')));
        expect(assistant.decoration, isNull, reason: '助手消息不画气泡');
        final user = tester.widget<Container>(
            find.byKey(const ValueKey('message_bubble_u')));
        expect(user.decoration, isNotNull, reason: '用户消息保留浅色块');

        final rect = tester.getRect(find.byKey(const ValueKey('message_bubble_a')));
        final userRect =
            tester.getRect(find.byKey(const ValueKey('message_bubble_u')));
        expect(rect.width, greaterThan(userRect.width), reason: '助手占满宽度');
        expect(rect.right, lessThanOrEqualTo(width));
      });
    }
  }

  testWidgets('unclosed fence and half table while streaming do not throw',
      (tester) async {
    for (var end = 10; end <= _reply.length; end += 37) {
      await tester.pumpWidget(_host(MessageBubble(
        isMe: false,
        message: _msg('s', 'assistant', _reply.substring(0, end)),
        documentStyle: true,
      )));
      expect(tester.takeException(), isNull, reason: 'prefix $end');
    }
  });

  testWidgets('bubble style keeps plain text and bubble decoration',
      (tester) async {
    await tester.pumpWidget(_host(MessageBubble(
      isMe: false,
      message: _msg('b', 'assistant', '**粗体**保持原样'),
    )));
    await tester.pumpAndSettle();
    expect(find.byType(MoeMarkdownView), findsNothing);
    expect(find.text('**粗体**保持原样'), findsOneWidget);
    final bubble =
        tester.widget<Container>(find.byKey(const ValueKey('message_bubble_b')));
    expect(bubble.decoration, isNotNull);
  });

  testWidgets('fold content renders markdown in document style', (tester) async {
    final message = Message(
      id: 'f',
      role: 'assistant',
      content: '- 甲\n- 乙',
      blocks: [ThinkingBlock(messageId: 'f', content: '- **甲**\n- 乙', title: '思考')],
      createdAt: DateTime(2026, 10, 1),
    );
    await tester.pumpWidget(_host(
        MessageBubble(isMe: false, message: message, documentStyle: true)));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(MoeCollapsibleBubble));
    await tester.pumpAndSettle();
    expect(find.descendant(
        of: find.byType(MoeCollapsibleBubble),
        matching: find.byType(MoeMarkdownView)), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  // 源码渲染预览：--dart-define=WRITE_DOCUMENT_MODE_PREVIEW=true 时写到 scratch/document-mode/preview/。
  const capture = bool.fromEnvironment('WRITE_DOCUMENT_MODE_PREVIEW');
  for (final width in [360.0, 1000.0]) {
    for (final dark in [false, true]) {
      testWidgets('document mode preview $width dark=$dark', (tester) async {
        if (!capture) return;
        tester.view.physicalSize = Size(width * 2, 1500 * 2);
        tester.view.devicePixelRatio = 2;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.runAsync(() async {
          Future<void> load(String family, String path) async {
            final loader = FontLoader(family)
              ..addFont(File(path).readAsBytes().then(ByteData.sublistView));
            await loader.load();
          }

          await load('Preview', '/System/Library/Fonts/STHeiti Medium.ttc');
          await load('Menlo', '/System/Library/Fonts/Menlo.ttc');
          await load('MaterialIcons',
              '${Platform.environment['HOME']}/dev-sdks/flutter-3.44.6/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
        });
        final key = GlobalKey();
        final fold = Message(
          id: 'f',
          role: 'assistant',
          content: '她想出去走走。',
          blocks: [
            ThinkingBlock(messageId: 'f', content: '她想出去走走。', title: '思考')
          ],
          createdAt: DateTime(2026, 10, 1),
        );
        await tester.pumpWidget(_host(
          RepaintBoundary(
            key: key,
            child: ColoredBox(
              color: dark ? Colors.black : Colors.white,
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: 16),
                children: [
                  MessageBubble(
                      isMe: true,
                      message: _msg('u', 'user', '今天天气好，帮我列个出门清单吧'),
                      documentStyle: true),
                  const SizedBox(height: 10),
                  MessageBubble(
                      isMe: false, message: fold, documentStyle: true),
                  const SizedBox(height: 4),
                  MessageBubble(
                    isMe: false,
                    message: _msg('a', 'assistant', _reply),
                    documentStyle: true,
                    showAvatar: false,
                  ),
                ],
              ),
            ),
          ),
          dark: dark,
          fontFamily: 'Preview',
        ));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.runAsync(() async {
          final boundary =
              key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: 2);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final dir = Directory('../../scratch/document-mode/preview')
            ..createSync(recursive: true);
          await File(
                  '${dir.path}/document-${width.toInt()}-${dark ? 'dark' : 'light'}.png')
              .writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      });
    }
  }
}
