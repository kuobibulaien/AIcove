import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:aicove_flutter/src/core/media/cloud_image.dart';
import 'package:aicove_flutter/src/core/media/media_asset.dart';
import 'package:aicove_flutter/src/core/media/media_store.dart';
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
  for (final (viewport, thumbnail) in [
    (420.0, false),
    (1000.0, false),
    (420.0, true),
    (1000.0, true),
  ]) {
    testWidgets(
      'synced image keeps its clip aligned at width $viewport, thumbnail=$thumbnail',
      (tester) async {
        await tester.binding.setSurfaceSize(Size(viewport, 490));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        late Directory root;
        late MediaStore media;
        late File file;
        final asset = MediaAsset(
          id: 'a' * 64,
          mimeType: 'image/png',
          byteLength: 1,
          createdAtMs: 1,
          width: thumbnail ? 1216 : 832,
          height: thumbnail ? 832 : 1216,
        );
        await tester.runAsync(() async {
          final font = Platform.environment['AICOVE_IMAGE_LAYOUT_FONT'];
          if (font != null) {
            await (FontLoader('LayoutPreview')..addFont(
                  File(font).readAsBytes().then((b) => ByteData.sublistView(b)),
                ))
                .load();
          }
          root = await Directory.systemTemp.createTemp('cloud-photo-layout-');
          media = MediaStore(Directory('${root.path}/media'), 'fixture');
          final picture = img.Image(
            width: asset.width! ~/ 4,
            height: asset.height! ~/ 4,
          );
          for (var y = 0; y < picture.height; y++) {
            for (var x = 0; x < picture.width; x++) {
              picture.setPixelRgb(x, y, 35 + x ~/ 3, 110 + y ~/ 4, 155);
            }
          }
          file = File('${root.path}/portrait.png')
            ..writeAsBytesSync(img.encodePng(picture));
          await media.save(
            LocalMedia(
              asset,
              originalPath: thumbnail ? null : file.path,
              thumbnailPath: thumbnail ? file.path : null,
            ),
          );
          MediaStore.use(media);
        });
        addTearDown(() async {
          await media.close();
          await root.delete(recursive: true);
        });
        final boundary = GlobalKey();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [appSettingsProvider.overrideWith(_Settings.new)],
            child: SkinScope(
              skin: const MoeTalkSkin(),
              child: MaterialApp(
                theme: ThemeData(
                  fontFamily:
                      Platform.environment['AICOVE_IMAGE_LAYOUT_FONT'] == null
                      ? null
                      : 'LayoutPreview',
                ),
                home: Scaffold(
                  body: RepaintBoundary(
                    key: boundary,
                    child: ColoredBox(
                      color: const Color(0xfff0f1f4),
                      child: Align(
                        alignment: Alignment.topCenter,
                        child: SizedBox(
                          width: viewport > 600 ? 680 : viewport,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const SizedBox(height: 24),
                              MessageBubble(
                                isMe: false,
                                showAvatar: false,
                                hideContactAvatar: true,
                                message: Message.text(
                                  id: 'text',
                                  role: 'assistant',
                                  content: '图片与文字对齐，保留原比例和圆角。',
                                ),
                              ),
                              const SizedBox(height: 6),
                              MessageBubble(
                                isMe: false,
                                showAvatar: false,
                                hideContactAvatar: true,
                                message: Message.fromBlocks(
                                  id: 'photo',
                                  role: 'assistant',
                                  blocks: [
                                    ImageBlock(
                                      id: 'image-block',
                                      messageId: 'photo',
                                      localPath: asset.reference,
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
          ),
        );
        for (var i = 0; i < 60; i++) {
          await tester.runAsync(() async {
            await Future<void>.delayed(const Duration(milliseconds: 20));
          });
          await tester.pump();
          if (tester
              .widgetList<RawImage>(find.byType(RawImage))
              .any((w) => w.image != null)) {
            break;
          }
        }
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final imageFinder = find.descendant(
          of: find.byType(CloudImage),
          matching: find.byType(RawImage),
        );
        expect(imageFinder, findsOneWidget);
        final clip = find.ancestor(
          of: find.byType(CloudImage),
          matching: find.byType(MoeG2ClipRRect),
        );
        expect(clip, findsOneWidget);
        final imageRect = tester.getRect(imageFinder);
        final clipRect = tester.getRect(clip);
        final textRect = tester.getRect(
          find.byKey(const ValueKey('message_bubble_text')),
        );
        expect(
          clipRect.width / clipRect.height,
          closeTo(asset.width! / asset.height!, .001),
        );
        expect(imageRect.left, closeTo(textRect.left, .01));
        expect(
          imageRect,
          rectMoreOrLessEquals(clipRect, epsilon: .001),
          reason: 'Round clipping must follow the actual photo bounds',
        );
        expect(
          tester.widget<MoeG2ClipRRect>(clip).radius,
          const MoeTalkSkin().bubbleRadius,
        );
        expect(find.text('原图暂存于其他设备'), findsNothing);
        final output = Platform.environment['AICOVE_IMAGE_LAYOUT_PREVIEW'];
        if (output != null) {
          await tester.runAsync(() async {
            final image =
                await (boundary.currentContext!.findRenderObject()!
                        as RenderRepaintBoundary)
                    .toImage(pixelRatio: 2);
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            await File(
              '$output-${viewport.toInt()}-${thumbnail ? 'thumbnail' : 'original'}.png',
            ).writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
