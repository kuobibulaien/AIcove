import 'dart:io';
import 'dart:ui' as ui;

import 'package:aicove_flutter/src/core/utils/markdown_fence.dart';
import 'package:aicove_flutter/src/core/utils/message_formatter.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/presentation/widgets/message_bubble.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/moe_code_block.dart';
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

const _dart = 'void main() {\n  print("hi"); // greet\n}';

Iterable<Color?> _spanColors(InlineSpan span) sync* {
  if (span is TextSpan) {
    yield span.style?.color;
    for (final child in span.children ?? const <InlineSpan>[]) {
      yield* _spanColors(child);
    }
  }
}

void main() {
  group('splitFencedText', () {
    test('prose and code alternate, adjacent newlines trimmed', () {
      final parts = splitFencedText('看这里：\n```dart\nx\n```\n完成。');
      expect(parts, hasLength(3));
      expect((parts[0] as FencedProsePart).text, '看这里：');
      expect((parts[1] as FencedCodePart).block.code, 'x');
      expect((parts[2] as FencedProsePart).text, '完成。');
    });

    test('text without fences is one prose part', () {
      final parts = splitFencedText('普通一句话');
      expect((parts.single as FencedProsePart).text, '普通一句话');
    });
  });

  group('highlightCode', () {
    const base = TextStyle(color: Color(0xff000000), fontSize: 13);

    test('known language and aliases produce coloured spans', () {
      for (final lang in ['dart', 'py', 'sh']) {
        final span = highlightCode(
          lang == 'dart' ? _dart : 'print("hi")',
          language: lang,
          base: base,
          brightness: Brightness.light,
        );
        expect(
          _spanColors(span).whereType<Color>().toSet().length,
          greaterThan(1),
          reason: lang,
        );
      }
    });

    test('unknown or empty language stays plain', () {
      for (final lang in ['', 'brainfuck']) {
        final span = highlightCode('x = 1',
            language: lang, base: base, brightness: Brightness.light);
        expect(span.text, 'x = 1');
        expect(span.children, isNull);
      }
    });
  });

  testWidgets('copy button writes the code to the clipboard', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));

    await tester.pumpWidget(
        _host(const MoeCodeBlock(code: _dart, language: 'dart')));
    expect(find.text('dart'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('moe_code_block_copy')));
    await tester.pump();
    expect(copied, _dart);
    await tester.pump(const Duration(seconds: 3));
  });

  for (final dark in [false, true]) {
    testWidgets('bubble renders fenced code with prose, narrow, dark=$dark',
        (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final message = Message.text(
        id: 'm1',
        role: 'assistant',
        content: '试试这个：\n```dart\n$_dart\nfinal veryLongVariableNameThatOverflowsTheBubbleWidth = 1;\n```\n记得保存。',
        createdAt: DateTime(2026, 10, 1),
      );
      await tester.pumpWidget(
        _host(MessageBubble(isMe: false, message: message), dark: dark),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(MoeCodeBlock), findsOneWidget);
      expect(find.text('试试这个：'), findsOneWidget);
      expect(find.text('记得保存。'), findsOneWidget);
      expect(find.textContaining('```'), findsNothing);
      final block = tester.getRect(find.byType(MoeCodeBlock));
      expect(block.right, lessThanOrEqualTo(360));
    });
  }

  // 源码渲染预览：--dart-define=WRITE_CODE_BLOCK_PREVIEW=true 时写到 scratch/code-block/。
  const capture = bool.fromEnvironment('WRITE_CODE_BLOCK_PREVIEW');
  for (final width in [360.0, 1000.0]) {
    for (final dark in [false, true]) {
      testWidgets('code block preview $width dark=$dark', (tester) async {
        if (!capture) return;
        tester.view.physicalSize = Size(width * 2, 1000);
        tester.view.devicePixelRatio = 2;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.runAsync(() async {
          final loader = FontLoader('Preview')
            ..addFont(File('/System/Library/Fonts/STHeiti Medium.ttc')
                .readAsBytes()
                .then(ByteData.sublistView));
          await loader.load();
          final mono = FontLoader('Menlo')
            ..addFont(File('/System/Library/Fonts/Menlo.ttc')
                .readAsBytes()
                .then(ByteData.sublistView));
          await mono.load();
          final icons = FontLoader('MaterialIcons')
            ..addFont(File(
              '${Platform.environment['HOME']}/dev-sdks/flutter-3.44.6/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
            ).readAsBytes().then(ByteData.sublistView));
          await icons.load();
        });
        final key = GlobalKey();
        Message msg(String id, String role, String text) => Message.text(
            id: id, role: role, content: text, createdAt: DateTime(2026, 10, 1));
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
                      message: msg('u', 'user', '帮我写个 Dart 的问候函数')),
                  const SizedBox(height: 6),
                  MessageBubble(
                    isMe: false,
                    message: msg(
                      'a',
                      'assistant',
                      '好呀，像这样：\n```dart\n/// 打招呼\nString greet(String name) {\n  final hour = DateTime.now().hour;\n  return hour < 12 ? "早上好，\$name！" : "你好，\$name！";\n}\n```\n复制过去就能用～',
                    ),
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
          final dir = Directory('../../scratch/code-block')
            ..createSync(recursive: true);
          await File(
                  '${dir.path}/code-block-${width.toInt()}-${dark ? 'dark' : 'light'}.png')
              .writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      });
    }
  }
}
