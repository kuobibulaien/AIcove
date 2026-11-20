import 'package:aicove_flutter/src/core/models/message_block.dart';
import 'package:aicove_flutter/src/core/utils/message_formatter.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/presentation/widgets/message_bubble.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/ui/shared/effects/smooth_clip.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/moe_content_surface.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/moe_floating_surface.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/moe_static_blur_layer.dart';
import 'package:aicove_flutter/src/ui/theme/skin_provider.dart';
import 'package:aicove_flutter/src/ui/theme/skins/moetalk_skin.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeAppSettingsNotifier extends AppSettingsNotifier {
  _FakeAppSettingsNotifier(this._settings);

  final AppSettings _settings;

  @override
  Future<AppSettings> build() async => _settings;
}

AppSettings _minimalSettings() {
  return const AppSettings(
    ttsEnabled: true,
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

Widget _surfaceHost(Widget child) {
  return MaterialApp(
    theme: ThemeData(extensions: [MoeColors.light()]),
    home: Scaffold(body: Center(child: child)),
  );
}

void main() {
  setUp(() => MoeLiquidGlassService.setMockState(available: false));
  tearDown(() => MoeLiquidGlassService.setMockState());

  testWidgets(
    'MoeFloatingSurface selects ClipRect, ClipRRect, or ClipPath by radius',
    (tester) async {
      await tester.pumpWidget(
        _surfaceHost(
          const Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              MoeFloatingSurface(
                key: ValueKey('surface-rect'),
                radius: 0,
                child: SizedBox(width: 40, height: 24),
              ),
              MoeFloatingSurface(
                key: ValueKey('surface-pill'),
                radius: 999,
                child: SizedBox(width: 80, height: 32),
              ),
              MoeFloatingSurface(
                key: ValueKey('surface-g2'),
                radius: 20,
                child: SizedBox(width: 80, height: 32),
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();

      final rectSurface = find.byKey(const ValueKey('surface-rect'));
      expect(
        find.descendant(of: rectSurface, matching: find.byType(ClipRect)),
        findsOneWidget,
      );
      expect(
        find.descendant(of: rectSurface, matching: find.byType(ClipPath)),
        findsNothing,
      );
      expect(
        find.descendant(of: rectSurface, matching: find.byType(ClipRRect)),
        findsNothing,
      );

      final pillSurface = find.byKey(const ValueKey('surface-pill'));
      expect(
        find.descendant(of: pillSurface, matching: find.byType(ClipRRect)),
        findsOneWidget,
      );
      expect(
        find.descendant(of: pillSurface, matching: find.byType(ClipPath)),
        findsNothing,
      );

      final g2Surface = find.byKey(const ValueKey('surface-g2'));
      expect(
        find.descendant(of: g2Surface, matching: find.byType(ClipPath)),
        findsOneWidget,
      );
      expect(
        find.descendant(of: g2Surface, matching: find.byType(ClipRRect)),
        findsNothing,
      );
      expect(
        find.descendant(of: g2Surface, matching: find.byType(ClipRect)),
        findsNothing,
      );
    },
  );

  testWidgets(
    'MoeContentSurface and smooth clip widgets use ClipRect when radius <= 0',
    (tester) async {
      await tester.pumpWidget(
        _surfaceHost(
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const MoeContentSurface(
                key: ValueKey('content-rect'),
                radius: 0,
                child: SizedBox(width: 40, height: 24),
              ),
              const SmoothClipRRect(
                key: ValueKey('smooth-rect'),
                radius: 0,
                child: SizedBox(width: 40, height: 24),
              ),
              MoeG2ClipRRect(
                key: const ValueKey('g2-rect'),
                radius: 0,
                child: const SizedBox(width: 40, height: 24),
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();

      for (final keyName in ['content-rect', 'smooth-rect', 'g2-rect']) {
        final target = find.byKey(ValueKey(keyName));
        expect(
          find.descendant(of: target, matching: find.byType(ClipRect)),
          findsOneWidget,
        );
        expect(
          find.descendant(of: target, matching: find.byType(ClipPath)),
          findsNothing,
        );
      }
    },
  );

  testWidgets(
    'MoeStaticBlurLayer forwards Image.opacity instead of wrapping Opacity',
    (tester) async {
      const blur = 12.0;
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 120,
              height: 120,
              child: MoeStaticBlurLayer(
                source: 'assets/characters/images/nahida.jpg',
                blur: blur,
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final layer = find.byType(MoeStaticBlurLayer);
      expect(
        find.descendant(of: layer, matching: find.byType(Opacity)),
        findsNothing,
      );
      final imageFinder = find.descendant(
        of: layer,
        matching: find.byType(Image),
      );
      expect(imageFinder, findsOneWidget);
      final image = tester.widget<Image>(imageFinder);
      expect(image.opacity, isNotNull);
      expect(
        image.opacity!.value,
        closeTo(MoeStaticBlurLayer.opacityFor(blur), 1e-6),
      );
    },
  );

  testWidgets(
    'TypingDotsIndicator isolates repaints with RepaintBoundary and avoids Opacity',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(
              child: TypingDotsIndicator(color: Colors.pink),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));

      final indicator = find.byType(TypingDotsIndicator);
      expect(
        find.descendant(of: indicator, matching: find.byType(RepaintBoundary)),
        findsOneWidget,
      );
      expect(
        find.descendant(of: indicator, matching: find.byType(Opacity)),
        findsNothing,
      );
      expect(
        find.descendant(of: indicator, matching: find.byType(DecoratedBox)),
        findsNWidgets(3),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'EmojiBlock inside MessageBubble pauses TickerMode outside viewport + 48px and resumes when scrolled back',
    (tester) async {
      final scrollController = ScrollController();
      addTearDown(scrollController.dispose);

      final message = Message(
        id: 'sticker-msg',
        role: 'assistant',
        content: '',
        createdAt: DateTime(2026),
        blocks: [
          EmojiBlock(
            id: 'emoji-1',
            messageId: 'sticker-msg',
            emojiId: 'test_sticker',
            path:
                'assets/stickers/builtin/xiaokumao/05130a04d2990c3431e4a6d9470e97eb.webp',
          ),
        ],
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appSettingsProvider.overrideWith(
              () => _FakeAppSettingsNotifier(_minimalSettings()),
            ),
          ],
          child: SkinScope(
            skin: const MoeTalkSkin(),
            child: MaterialApp(
              theme: ThemeData(extensions: [MoeColors.light()]),
              home: Scaffold(
                body: Align(
                  alignment: Alignment.topCenter,
                  child: SizedBox(
                    key: const ValueKey('sticker-viewport'),
                    width: 360,
                    height: 360,
                    child: SingleChildScrollView(
                      controller: scrollController,
                      child: Column(
                        children: [
                          const SizedBox(height: 12),
                          MessageBubble(
                            isMe: false,
                            message: message,
                            showAvatar: false,
                            hideContactAvatar: true,
                          ),
                          const SizedBox(height: 1200),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      final stickerImage = find.descendant(
        of: find.byType(MessageBubble),
        matching: find.byType(Image),
      );
      expect(stickerImage, findsOneWidget);
      expect(TickerMode.valuesOf(tester.element(stickerImage)).enabled, isTrue);

      final viewportTop = tester
          .getTopLeft(find.byKey(const ValueKey('sticker-viewport')))
          .dy;
      final stickerBottom = tester.getBottomLeft(stickerImage).dy;
      final baseOffset = stickerBottom - viewportTop;

      // Within the 48px prewarm margin outside the top edge: stays enabled.
      scrollController.jumpTo(baseOffset + 24);
      await tester.pump();
      await tester.pump();
      expect(TickerMode.valuesOf(tester.element(stickerImage)).enabled, isTrue);

      // Past the 48px prewarm margin outside the viewport: pauses TickerMode.
      scrollController.jumpTo(baseOffset + 64);
      await tester.pump();
      await tester.pump();
      expect(TickerMode.valuesOf(tester.element(stickerImage)).enabled, isFalse);

      // Scrolled back into view: resumes TickerMode.
      scrollController.jumpTo(0);
      await tester.pump();
      await tester.pump();
      expect(TickerMode.valuesOf(tester.element(stickerImage)).enabled, isTrue);
    },
  );
}
