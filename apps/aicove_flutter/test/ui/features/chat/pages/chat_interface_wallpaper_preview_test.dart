import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/ui/features/chat/pages/chat_interface_settings_page.dart';
import 'package:aicove_flutter/src/ui/features/chat/widgets/chat_wallpaper_background.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'chat_interface_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const mockBackgroundAsset = 'assets/mock/chat_background.png';
  const deferredPreviewWindow = Duration(milliseconds: 450);

  Conversation buildConversation({double? blurSigma}) {
    final now = DateTime(2026, 3, 15);
    return Conversation(
      id: 'conv_1',
      title: 'Test',
      displayName: '测试会话',
      chatBackgroundImage: mockBackgroundAsset,
      chatBackgroundBlurSigma: blurSigma,
      createdAt: now,
      updatedAt: now,
    );
  }

  String? wallpaperImage(WidgetTester tester) => tester
      .widget<ChatWallpaperLayer>(
        find.byKey(const ValueKey('chat_interface_wallpaper')),
      )
      .image;

  for (final blur in [24.0, 0.0]) {
    testWidgets('转场期先显示底色，再延后渲染壁纸与静态模糊层 blur=$blur', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1080, 2200);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final conv = buildConversation(blurSigma: blur);

      await tester.pumpWidget(
        chatInterfaceTestScope(
          conversation: conv,
          child: MaterialApp(
            home: ChatInterfaceSettingsPage(conversation: conv),
          ),
        ),
      );

      expect(wallpaperImage(tester), isNull);
      expect(
        find.byKey(const ValueKey<String>('chat_page_static_blur_layer')),
        findsNothing,
      );

      await tester.pump(deferredPreviewWindow);
      await tester.pump(const Duration(milliseconds: 320));

      expect(wallpaperImage(tester), mockBackgroundAsset);
      expect(
        find.byKey(const ValueKey<String>('chat_page_static_blur_layer')),
        blur > 0 ? findsOneWidget : findsNothing,
      );
      expect(find.byType(ImageFiltered), findsNothing);
    });
  }
}
