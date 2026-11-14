import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:aicove_flutter/src/core/models/block_status.dart';
import 'package:aicove_flutter/src/core/models/message_block.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/presentation/widgets/message_bubble.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/ui/shared/effects/smooth_clip.dart';
import 'package:aicove_flutter/src/ui/theme/skin_provider.dart';
import 'package:aicove_flutter/src/ui/theme/skins/moetalk_skin.dart';

class _Settings extends AppSettingsNotifier {
  @override
  Future<AppSettings> build() async => mapUiModelsToAppSettings({});
}

void main() {
  testWidgets(
    'pending ImageBlock renders loading placeholder at target aspect ratio and fills in-place without layout shift',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(420, 760));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      late Directory tempDir;
      late File imageFile;
      await tester.runAsync(() async {
        final cjkFont = File('/System/Library/Fonts/STHeiti Medium.ttc');
        if (await cjkFont.exists()) {
          await (FontLoader('PreviewFont')
                ..addFont(cjkFont.readAsBytes().then(ByteData.sublistView)))
              .load();
        }
        tempDir = await Directory.systemTemp.createTemp('pending_image_bubble_');
        final picture = img.Image(width: 208, height: 304);
        for (var y = 0; y < picture.height; y++) {
          for (var x = 0; x < picture.width; x++) {
            picture.setPixelRgb(
              x,
              y,
              70 + (x * 110 ~/ picture.width),
              130 + (y * 80 ~/ picture.height),
              215,
            );
          }
        }
        imageFile = File('${tempDir.path}/resolved.png')
          ..writeAsBytesSync(img.encodePng(picture));
      });
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      var mediaMenuTriggered = 0;
      final boundaryKey = GlobalKey();

      Widget buildScene({required Message imageMessage}) {
        return ProviderScope(
          overrides: [appSettingsProvider.overrideWith(_Settings.new)],
          child: SkinScope(
            skin: const MoeTalkSkin(),
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: ThemeData(fontFamily: 'PreviewFont'),
              home: Scaffold(
                backgroundColor: const Color(0xFFF3F4F7),
                body: RepaintBoundary(
                  key: boundaryKey,
                  child: ColoredBox(
                    color: const Color(0xFFF3F4F7),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 20,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          MessageBubble(
                            isMe: false,
                            showAvatar: false,
                            hideContactAvatar: true,
                            message: Message.text(
                              id: 'msg_text_before',
                              role: 'assistant',
                              content: '给你拍一张海边日落的照片，稍等一下～',
                            ),
                          ),
                          const SizedBox(height: 6),
                          MessageBubble(
                            isMe: false,
                            showAvatar: false,
                            hideContactAvatar: true,
                            message: imageMessage,
                            onMediaLongPress: (_, __, ___) {
                              mediaMenuTriggered += 1;
                            },
                          ),
                          const SizedBox(height: 6),
                          MessageBubble(
                            isMe: false,
                            showAvatar: false,
                            hideContactAvatar: true,
                            message: Message.text(
                              id: 'msg_text_after',
                              role: 'assistant',
                              content: '海风吹过来的时候特别舒服。',
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      }

      final pendingMessage = Message.fromBlocks(
        id: 'msg_img_1',
        role: 'assistant',
        status: 'sending',
        blocks: [
          ImageBlock(
            id: 'msg_img_1__b0_image',
            messageId: 'msg_img_1',
            prompt: 'sunset beach',
            width: 832,
            height: 1216,
            status: BlockStatus.pending,
          ),
        ],
      );

      await tester.pumpWidget(buildScene(imageMessage: pendingMessage));
      await tester.pump(const Duration(milliseconds: 120));

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byIcon(Icons.broken_image), findsNothing);

      final pendingClipFinder = find.ancestor(
        of: find.byType(CircularProgressIndicator),
        matching: find.byType(MoeG2ClipRRect),
      );
      expect(pendingClipFinder, findsOneWidget);
      final pendingClipRect = tester.getRect(pendingClipFinder);
      expect(
        pendingClipRect.width / pendingClipRect.height,
        closeTo(832 / 1216, 0.005),
      );

      final afterTextRectBeforeFill = tester.getRect(
        find.text('海风吹过来的时候特别舒服。'),
      );

      // Right-click / long-press on a pending placeholder should not trigger the media menu.
      final gesture = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await gesture.addPointer(location: pendingClipRect.center);
      await gesture.down(pendingClipRect.center);
      await gesture.up();
      await tester.pump();
      expect(mediaMenuTriggered, 0);

      // Now fill the image in-place with the resolved ImageBlock.
      final resolvedMessage = Message.fromBlocks(
        id: 'msg_img_1',
        role: 'assistant',
        blocks: [
          ImageBlock(
            id: 'msg_img_1__b0_image',
            messageId: 'msg_img_1',
            localPath: imageFile.path,
            prompt: 'sunset beach',
            width: 832,
            height: 1216,
            status: BlockStatus.success,
          ),
        ],
      );

      final previewPath = Platform.environment['AICOVE_PENDING_IMAGE_PREVIEW'];
      if (previewPath != null && previewPath.isNotEmpty) {
        await tester.binding.setSurfaceSize(const Size(780, 560));
        await tester.pumpWidget(
          ProviderScope(
            overrides: [appSettingsProvider.overrideWith(_Settings.new)],
            child: SkinScope(
              skin: const MoeTalkSkin(),
              child: MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: ThemeData(fontFamily: 'PreviewFont'),
                home: Scaffold(
                  backgroundColor: const Color(0xFFF3F4F7),
                  body: RepaintBoundary(
                    key: boundaryKey,
                    child: ColoredBox(
                      color: const Color(0xFFF3F4F7),
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    '生图中（原位圆角占位框，不挡后续文字）',
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                      color: Color(0xFF5A6270),
                                    ),
                                  ),
                                  const SizedBox(height: 12),
                                  MessageBubble(
                                    isMe: false,
                                    showAvatar: false,
                                    hideContactAvatar: true,
                                    message: Message.text(
                                      id: 'left_1',
                                      role: 'assistant',
                                      content: '给你拍一张海边日落的照片，稍等一下～',
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  MessageBubble(
                                    isMe: false,
                                    showAvatar: false,
                                    hideContactAvatar: true,
                                    message: pendingMessage,
                                  ),
                                  const SizedBox(height: 6),
                                  MessageBubble(
                                    isMe: false,
                                    showAvatar: false,
                                    hideContactAvatar: true,
                                    message: Message.text(
                                      id: 'left_2',
                                      role: 'assistant',
                                      content: '海风吹过来的时候特别舒服。',
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 24),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    '生图完成（同尺寸原位填入，零跳变）',
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                      color: Color(0xFF5A6270),
                                    ),
                                  ),
                                  const SizedBox(height: 12),
                                  MessageBubble(
                                    isMe: false,
                                    showAvatar: false,
                                    hideContactAvatar: true,
                                    message: Message.text(
                                      id: 'right_1',
                                      role: 'assistant',
                                      content: '给你拍一张海边日落的照片，稍等一下～',
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  MessageBubble(
                                    isMe: false,
                                    showAvatar: false,
                                    hideContactAvatar: true,
                                    message: resolvedMessage,
                                  ),
                                  const SizedBox(height: 6),
                                  MessageBubble(
                                    isMe: false,
                                    showAvatar: false,
                                    hideContactAvatar: true,
                                    message: Message.text(
                                      id: 'right_2',
                                      role: 'assistant',
                                      content: '海风吹过来的时候特别舒服。',
                                    ),
                                  ),
                                ],
                              ),
                            ),
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
        for (var i = 0; i < 30; i++) {
          await tester.runAsync(() async {
            await Future<void>.delayed(const Duration(milliseconds: 20));
          });
          await tester.pump(const Duration(milliseconds: 25));
          if (tester
              .widgetList<RawImage>(find.byType(RawImage))
              .any((w) => w.image != null)) {
            break;
          }
        }
        await tester.pump(const Duration(milliseconds: 650));
        await tester.runAsync(() async {
          final boundary = boundaryKey.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: 2);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(previewPath).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
        await tester.binding.setSurfaceSize(const Size(420, 760));
      }

      await tester.pumpWidget(buildScene(imageMessage: resolvedMessage));
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.byType(CircularProgressIndicator), findsNothing);
      final resolvedClipFinder = find.ancestor(
        of: find.byType(Image),
        matching: find.byType(MoeG2ClipRRect),
      );
      expect(resolvedClipFinder, findsOneWidget);
      final resolvedClipRect = tester.getRect(resolvedClipFinder);
      expect(
        resolvedClipRect,
        rectMoreOrLessEquals(pendingClipRect, epsilon: 0.01),
        reason: 'Filling the placeholder in-place must not shift bubble bounds',
      );

      final afterTextRectAfterFill = tester.getRect(
        find.text('海风吹过来的时候特别舒服。'),
      );
      expect(
        afterTextRectAfterFill.top,
        closeTo(afterTextRectBeforeFill.top, 0.01),
        reason: 'Subsequent messages must not jump when placeholder fills in-place',
      );
    },
  );
}
