import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/ui/features/chat/widgets/chat_wallpaper_background.dart';
import 'package:aicove_flutter/src/ui/features/wallpaper/pages/wallpaper_editor_page.dart';
import 'package:aicove_flutter/src/ui/features/wallpaper/widgets/wallpaper_preview_samples.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/index.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'pages/chat_interface_test_support.dart';

const _globalStyle = WallpaperStyle(mask: 0.1, blur: 5);

Conversation _conversation({double? mask, double? blur}) => Conversation(
  id: 'follow_global',
  title: 'Test',
  displayName: 'Test',
  createdAt: DateTime(2026, 10, 21),
  updatedAt: DateTime(2026, 10, 21),
  chatBackgroundMaskOpacity: mask,
  chatBackgroundBlurSigma: blur,
);

Widget _scope(Conversation conversation, Widget home) => chatInterfaceTestScope(
  conversation: conversation,
  child: MaterialApp(
    theme: ThemeData(extensions: [MoeColors.light()]),
    builder: (context, child) => MoeWallpaperTheme(
      wallpaper: GlobalWallpaper.catnap,
      style: _globalStyle,
      child: child!,
    ),
    home: home,
  ),
);

Slider _slider(WidgetTester tester, String key) => tester.widget<Slider>(
  find.descendant(of: find.byKey(ValueKey(key)), matching: find.byType(Slider)),
);

void main() {
  testWidgets('chat without its own image applies its own mask and blur over '
      'the global wallpaper, and the global ones until adjusted', (
    tester,
  ) async {
    MoeWallpaperView view() =>
        tester.widget<MoeWallpaperView>(find.byType(MoeWallpaperView));

    await tester.pumpWidget(
      _scope(
        _conversation(),
        ChatWallpaperLayer.forConversation(
          conversation: _conversation(),
          fallbackColor: telegramChatBackground,
        ),
      ),
    );
    expect(view().source, 'assets/wallpapers/catnap_light.webp');
    expect(view().style, _globalStyle);

    final own = _conversation(mask: 0.6, blur: 70);
    await tester.pumpWidget(
      _scope(
        own,
        ChatWallpaperLayer.forConversation(
          conversation: own,
          fallbackColor: telegramChatBackground,
        ),
      ),
    );
    expect(view().source, 'assets/wallpapers/catnap_light.webp');
    expect(view().style.mask, 0.6);
    expect(view().style.blur, 70);
  });

  testWidgets('editor adjusts a chat that follows the global wallpaper', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 860);
    addTearDown(tester.view.reset);
    final saved = <WallpaperStyle?>[];
    final conversation = _conversation();
    await tester.pumpWidget(
      _scope(
        conversation,
        Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (context) => WallpaperEditorPage(
                    source: null,
                    style: resolveChatWallpaperStyle(context, conversation),
                    defaultStyle: kDefaultChatWallpaperStyle,
                    followStyle: _globalStyle,
                    kind: WallpaperPreviewKind.chat,
                    conversation: conversation,
                    canChangeImage: true,
                    onSave: (_, style) async => saved.add(style),
                  ),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final blur = _slider(tester, 'wallpaper_blur_slider');
    expect(blur.onChanged, isNotNull);
    expect(blur.value, _globalStyle.blur);
    expect(_slider(tester, 'wallpaper_mask_slider').onChanged, isNotNull);

    blur.onChanged!(60);
    await tester.pump();
    final preview = tester.widget<MoeWallpaperView>(
      find.descendant(
        of: find.byKey(const ValueKey('wallpaper_preview_narrow')),
        matching: find.byType(MoeWallpaperView),
      ),
    );
    expect(preview.style.blur, 60);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(saved, hasLength(1));
    expect(saved.single!.blur, 60);
    expect(saved.single!.mask, _globalStyle.mask);
    expect(tester.takeException(), isNull);
  });
}
