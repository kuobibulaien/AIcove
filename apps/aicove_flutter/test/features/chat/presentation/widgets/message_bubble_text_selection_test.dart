import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/core/utils/message_formatter.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/presentation/widgets/message_action_sheet.dart';
import 'package:aicove_flutter/src/features/chat/presentation/widgets/message_bubble.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/ui/theme/skin_provider.dart';
import 'package:aicove_flutter/src/ui/theme/skins/moetalk_skin.dart';

class _FakeAppSettingsNotifier extends AppSettingsNotifier {
  @override
  Future<AppSettings> build() async => const AppSettings(
    ttsEnabled: false,
    defaultModelName: 'deepseek-chat',
    defaultPersonaPrompt: '',
    modelList: <String>['deepseek-chat'],
    allKnownModels: <String>['deepseek-chat'],
    modelDisplayNames: <String, String>{},
    modelTypes: <String, String>{},
    modelConfigs: <String, ModelConfig>{},
    apiKey: '',
    apiBaseUrl: 'https://api.openai.com/v1',
    imageGenerationEnabled: false,
    maxFileUploadMB: 10,
    contextWindowTokens: 272000,
    customModels: <CustomModel>[],
    providers: <ProviderAuth>[],
    modelProviderMap: <String, String>{},
    backendApiKey: '',
    messageChunkingEnabled: false,
    messageFormatConfig: MessageFormatConfig(),
    textScaleFactor: 1.0,
    uiScaleFactor: 1.0,
    imagePreviewScale: 1.0,
    autoReplySettings: AutoReplySettings(),
    globalBackgroundColor: GlobalBackgroundColor.white,
    chatBackgroundColor: ChatBackgroundColor.defaultColor,
    isDarkMode: false,
    useSystemTheme: true,
    accentColor: 'FC96AA',
    hideUserAvatar: true,
  );
}

const _text = 'alpha beta gamma delta epsilon';

class _Press {
  _Press(this.position, this.selectedText);
  final Offset position;
  final String? selectedText;
}

Future<List<_Press>> _pumpBubble(
  WidgetTester tester, {
  required double width,
  bool openMenu = false,
  String text = _text,
  bool documentStyle = false,
}) async {
  final presses = <_Press>[];
  await tester.binding.setSurfaceSize(Size(width, 800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appSettingsProvider.overrideWith(_FakeAppSettingsNotifier.new),
      ],
      child: SkinScope(
        skin: const MoeTalkSkin(),
        child: MaterialApp(
          home: Scaffold(
            body: ListView(
              children: [
                const SizedBox(height: 200),
                MessageBubble(
                  isMe: false,
                  documentStyle: documentStyle,
                  message: Message.text(
                    id: 'm1',
                    role: 'assistant',
                    content: text,
                  ),
                  onLongPress: (box, position, selectedText) {
                    presses.add(_Press(position, selectedText));
                    if (!openMenu) return;
                    showMessageActionMenu(
                      tester.element(find.byType(MessageBubble)),
                      targetBox: box,
                      globalPosition: position,
                      isUserMessage: false,
                      messageText: _text,
                      selectedText: selectedText,
                      onAction: (_) {},
                    );
                  },
                ),
                const SizedBox(height: 1200),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return presses;
}

Offset _wordCenter(WidgetTester tester, String word) =>
    _wordRect(tester, word).center;

Rect _wordRect(WidgetTester tester, String word, {Finder? within}) {
  final paragraph = tester.renderObject<RenderParagraph>(
    find.descendant(
      of: within ?? find.byType(MessageBubble),
      matching: find.byType(RichText),
    ),
  );
  final start = _text.indexOf(word);
  final boxes = paragraph.getBoxesForSelection(
    TextSelection(baseOffset: start, extentOffset: start + word.length),
  );
  final rect = boxes.first.toRect();
  return Rect.fromPoints(
    paragraph.localToGlobal(rect.topLeft),
    paragraph.localToGlobal(rect.bottomRight),
  );
}

void main() {
  for (final width in [360.0, 1000.0]) {
    testWidgets('touch long press without moving opens menu: $width', (
      tester,
    ) async {
      final presses = await _pumpBubble(tester, width: width);
      final gesture = await tester.startGesture(_wordCenter(tester, 'beta'));
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      expect(presses, isEmpty, reason: 'menu waits for the finger to lift');
      await gesture.up();
      await tester.pumpAndSettle();

      expect(presses, hasLength(1));
      expect(presses.single.selectedText, isNull);
      expect(tester.takeException(), isNull);
    });

    testWidgets('touch long press then slide selects text: $width', (
      tester,
    ) async {
      final presses = await _pumpBubble(tester, width: width);
      final gesture = await tester.startGesture(_wordCenter(tester, 'beta'));
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      await gesture.moveTo(_wordCenter(tester, 'delta'));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(presses, hasLength(1));
      expect(presses.single.selectedText, 'beta gamma delta');
      expect(tester.takeException(), isNull);
    });

    testWidgets('quick touch drag scrolls without menu: $width', (
      tester,
    ) async {
      final presses = await _pumpBubble(tester, width: width);
      final before = tester.getTopLeft(find.byType(MessageBubble)).dy;
      await tester.dragFrom(_wordCenter(tester, 'beta'), const Offset(0, -150));
      await tester.pumpAndSettle();

      expect(
        tester.getTopLeft(find.byType(MessageBubble)).dy,
        lessThan(before),
      );
      expect(presses, isEmpty);
    });

    testWidgets('mouse drag selects and right click keeps it: $width', (
      tester,
    ) async {
      final presses = await _pumpBubble(tester, width: width);
      final mouse = await tester.startGesture(
        _wordRect(tester, 'alpha').centerLeft + const Offset(1, 0),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      await mouse.moveTo(
        _wordRect(tester, 'gamma').centerRight - const Offset(1, 0),
      );
      await tester.pump();
      await mouse.up();
      await tester.pumpAndSettle();
      expect(presses, isEmpty);

      final right = await tester.startGesture(
        _wordCenter(tester, 'beta'),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await right.up();
      await tester.pumpAndSettle();

      expect(presses, hasLength(1));
      expect(presses.single.selectedText, 'alpha beta gamma');
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('menu copies only the selected text', (tester) async {
    String? clipboard;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboard = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await _pumpBubble(tester, width: 360, openMenu: true);
    final gesture = await tester.startGesture(_wordCenter(tester, 'gamma'));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    await gesture.moveTo(_wordCenter(tester, 'delta'));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    await tester.tap(find.text('复制选中'));
    await tester.pumpAndSettle();
    expect(clipboard, 'gamma delta');
  });

  for (final width in [360.0, 1000.0]) {
    testWidgets('touch double tap opens full screen text: $width', (
      tester,
    ) async {
      final presses = await _pumpBubble(tester, width: width);
      final at = _wordCenter(tester, 'beta');
      await tester.tapAt(at);
      await tester.pump(const Duration(milliseconds: 80));
      await tester.tapAt(at);
      await tester.pumpAndSettle();

      final viewer = find.byKey(const ValueKey('message_text_viewer_text'));
      expect(viewer, findsOneWidget);
      expect(tester.widget<Text>(viewer).data, _text);
      expect(presses, isEmpty);

      // 有选区时轻点只收起选区，没有选区时轻点关闭。
      final viewerAt = _wordRect(tester, 'beta', within: viewer).center;
      final hold = await tester.startGesture(viewerAt);
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      await hold.up();
      await tester.pumpAndSettle();
      await tester.tapAt(viewerAt);
      await tester.pumpAndSettle();
      expect(viewer, findsOneWidget);
      await tester.tapAt(const Offset(20, 20));
      await tester.pumpAndSettle();
      expect(viewer, findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('two slow taps do not open full screen', (tester) async {
    await _pumpBubble(tester, width: 360);
    final at = _wordCenter(tester, 'beta');
    await tester.tapAt(at);
    await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 100));
    await tester.tapAt(at);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('message_text_viewer_text')),
      findsNothing,
    );
  });

  testWidgets('mouse double click selects a word instead', (tester) async {
    await _pumpBubble(tester, width: 1000);
    final at = _wordCenter(tester, 'beta');
    for (var i = 0; i < 2; i++) {
      final mouse = await tester.startGesture(
        at,
        kind: PointerDeviceKind.mouse,
      );
      await mouse.up();
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('message_text_viewer_text')),
      findsNothing,
    );
  });

  testWidgets('full screen keeps line breaks of rendered markdown', (
    tester,
  ) async {
    await _pumpBubble(
      tester,
      width: 360,
      documentStyle: true,
      text: '第一段**加粗**\n\n- 列表一\n- 列表二',
    );
    final at = tester.getCenter(find.textContaining('第一段', findRichText: true));
    await tester.tapAt(at);
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tapAt(at);
    await tester.pumpAndSettle();
    final text = tester
        .widget<Text>(find.byKey(const ValueKey('message_text_viewer_text')))
        .data;
    // 各段之间补回换行，Markdown 记号不出现。
    expect(text, '第一段加粗\n列表一\n列表二');
  });
}
