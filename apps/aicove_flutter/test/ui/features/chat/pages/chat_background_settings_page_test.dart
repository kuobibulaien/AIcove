import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/ui/features/chat/pages/chat_background_settings_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const mockBackgroundAsset = 'assets/mock/chat_background.png';
  const deferredPreviewWindow = Duration(milliseconds: 450);

  Conversation buildConversation({
    double? blurSigma,
    String? backgroundImage,
  }) {
    final now = DateTime(2026, 3, 15);
    return Conversation(
      id: 'conv_1',
      title: 'Test',
      displayName: '测试会话',
      chatBackgroundImage: backgroundImage,
      chatBackgroundBlurSigma: blurSigma,
      createdAt: now,
      updatedAt: now,
    );
  }

  testWidgets('聊天背景预览在转场期先显示轻壳，再延后渲染静态模糊层', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1080, 2200);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: ChatBackgroundSettingsPage(
          conversation: buildConversation(
            blurSigma: 24,
            backgroundImage: mockBackgroundAsset,
          ),
        ),
      ),
    );

    expect(find.text('正在准备背景预览'), findsOneWidget);
    expect(
      find.byKey(
          const ValueKey<String>('chat_background_settings_static_blur_layer')),
      findsNothing,
    );
    expect(find.byType(ImageFiltered), findsNothing);

    await tester.pump(deferredPreviewWindow);
    await tester.pump(const Duration(milliseconds: 320));

    expect(find.text('正在准备背景预览'), findsNothing);
    expect(
      find.byKey(
          const ValueKey<String>('chat_background_settings_static_blur_layer')),
      findsOneWidget,
    );
    expect(find.byType(ImageFiltered), findsNothing);
  });

  testWidgets('聊天背景无模糊时转场结束后也不渲染静态模糊层', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1080, 2200);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: ChatBackgroundSettingsPage(
          conversation: buildConversation(
            blurSigma: 0,
            backgroundImage: mockBackgroundAsset,
          ),
        ),
      ),
    );

    expect(find.text('正在准备背景预览'), findsOneWidget);
    expect(find.byType(ImageFiltered), findsNothing);

    await tester.pump(deferredPreviewWindow);
    await tester.pump(const Duration(milliseconds: 320));

    expect(find.text('正在准备背景预览'), findsNothing);
    expect(
      find.byKey(
          const ValueKey<String>('chat_background_settings_static_blur_layer')),
      findsNothing,
    );
    expect(find.byType(ImageFiltered), findsNothing);
  });
}
