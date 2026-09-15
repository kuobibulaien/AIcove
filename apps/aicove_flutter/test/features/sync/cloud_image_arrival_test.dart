import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:aicove_flutter/src/core/media/cloud_image.dart';
import 'package:aicove_flutter/src/core/media/media_asset.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/moe_floating_surface.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:aicove_flutter/src/core/media/media_store.dart';

void main() {
  for (final viewport in [420.0, 1000.0]) {
    testWidgets('placeholder opens and refreshes at $viewport', (tester) async {
      await tester.binding.setSurfaceSize(Size(viewport, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
      late Directory root;
      late MediaStore source, receiver;
      late LocalMedia record;
      await tester.runAsync(() async {
        final font = Platform.environment['AICOVE_SYNC_PREVIEW_FONT'];
        if (font != null) {
          await (FontLoader('SyncPreview')..addFont(
                File(
                  font,
                ).readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
              ))
              .load();
        }
        final iconFont = Platform.environment['AICOVE_SYNC_ICON_FONT'];
        if (iconFont != null) {
          await (FontLoader('MaterialIcons')..addFont(
                File(
                  iconFont,
                ).readAsBytes().then((b) => ByteData.sublistView(b)),
              ))
              .load();
        }
        root = await Directory.systemTemp.createTemp('sync-image-arrival-');
        source = MediaStore(Directory('${root.path}/source'), 'source');
        receiver = MediaStore(Directory('${root.path}/receiver'), 'receiver');
        final picture = img.Image(width: 240, height: 140);
        for (var y = 0; y < 140; y++) {
          for (var x = 0; x < 240; x++) {
            picture.setPixelRgb(x, y, 70 + x ~/ 2, 120 + y ~/ 2, 190);
          }
        }
        final file = File('${root.path}/fixture.png')
          ..writeAsBytesSync(img.encodePng(picture));
        record = await source.register(
          file.path,
          createdAtMs: 1,
          mimeType: 'image/png',
        );
        receiver.downloadBlob = (digest, target) async {
          await target.writeAsBytes(
            await File(record.thumbnailPath!).readAsBytes(),
          );
        };
        await receiver.receive(
          record.asset,
          now: DateTime.utc(2026, 9, 13),
          download: false,
        );
        MediaStore.use(receiver);
      });
      addTearDown(() async {
        await source.close();
        await receiver.close();
        await root.delete(recursive: true);
      });
      final boundary = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MoeGlassTheme(
            enabled: viewport == 420,
            blurSigma: 16,
            child: child!,
          ),
          theme: ThemeData(
            fontFamily: Platform.environment['AICOVE_SYNC_PREVIEW_FONT'] == null
                ? null
                : 'SyncPreview',
          ),
          home: Scaffold(
            body: Center(
              child: RepaintBoundary(
                key: boundary,
                child: SizedBox(
                  width: 340,
                  height: 220,
                  child: CloudImage(mediaId: record.asset.id),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(Image), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('原图暂存于其他设备'), findsNothing);
      expect(find.text('加载原图'), findsNothing);
      final preview = Platform.environment['AICOVE_SYNC_PREVIEW'];
      Future<void> capture(String suffix, Finder target) async {
        if (preview == null) return;
        await tester.runAsync(() async {
          final render = tester.renderObject<RenderRepaintBoundary>(target);
          final image = await render.toImage(pixelRatio: 2);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            '$preview-${viewport.toInt()}-$suffix.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }

      await capture('placeholder', find.byKey(boundary));
      await tester.tap(find.byType(CloudImage));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(Dialog), findsOneWidget);
      for (var i = 0; i < 40 && find.text('加载原图').evaluate().isEmpty; i++) {
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        });
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.text('加载原图'), findsOneWidget);
      expect(
        find.ancestor(
          of: find.text('加载原图'),
          matching: find.byType(MoeFloatingSurface),
        ),
        findsOneWidget,
      );

      final dialogRect = tester.getRect(find.byType(Dialog));
      final buttonRect = tester.getRect(find.text('加载原图'));
      expect(buttonRect.center.dx, lessThan(dialogRect.center.dx));
      expect(buttonRect.center.dy, greaterThan(dialogRect.center.dy));
      await capture(
        'viewer',
        find
            .ancestor(
              of: find.byType(Dialog),
              matching: find.byType(RepaintBoundary),
            )
            .first,
      );
      await tester.tap(find.text('加载原图'));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump(const Duration(milliseconds: 300));
      for (
        var i = 0;
        i < 40 && find.text('加载失败，点击重试').evaluate().isEmpty;
        i++
      ) {
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        });
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.text('加载失败，点击重试'), findsOneWidget);
      expect(find.textContaining('原图暂存于其他设备'), findsNothing);
      await tester.runAsync(() async {
        final asset = MediaAsset.fromJson({
          ...record.asset.toJson(),
          'original_blob': record.asset.originalSha256,
        });
        await receiver.save(LocalMedia(asset));
        receiver.downloadBlob = (digest, target) async {
          await target.writeAsBytes(
            await File(
              digest == record.asset.originalSha256
                  ? record.originalPath!
                  : record.thumbnailPath!,
            ).readAsBytes(),
          );
        };
      });
      await tester.tap(find.text('加载失败，点击重试'));
      await tester.pump();
      expect(find.text('加载原图中…'), findsOneWidget);
      for (
        var i = 0;
        i < 60 && find.text('加载原图中…').evaluate().isNotEmpty;
        i++
      ) {
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        });
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.runAsync(() async {
        expect(
          (await receiver.original(
            record.asset.id,
            allowDownload: false,
          )).existsSync(),
          isTrue,
        );
      });
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('加载失败，点击重试'), findsNothing);
      expect(find.text('加载原图'), findsNothing);
      await tester.tap(find.byTooltip('关闭'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.runAsync(() async {
        await receiver.receive(record.asset, now: DateTime.utc(2026, 9, 13));
      });
      await tester.pump();
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump(const Duration(milliseconds: 300));
      for (
        var attempt = 0;
        attempt < 30 && find.byType(Image).evaluate().isEmpty;
        attempt++
      ) {
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        });
        await tester.pump();
      }
      expect(find.byType(Image), findsOneWidget);
      for (var attempt = 0; attempt < 50; attempt++) {
        final rendered = tester.widgetList<RawImage>(find.byType(RawImage));
        if (rendered.any((widget) => widget.image != null)) break;
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        });
        await tester.pump();
      }
      expect(
        tester
            .widgetList<RawImage>(find.byType(RawImage))
            .any((widget) => widget.image != null),
        isTrue,
      );
      final output = Platform.environment['AICOVE_SYNC_PREVIEW'];
      if (output != null) {
        await tester.runAsync(() async {
          final image =
              await (boundary.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary)
                  .toImage(pixelRatio: 2);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(output).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
