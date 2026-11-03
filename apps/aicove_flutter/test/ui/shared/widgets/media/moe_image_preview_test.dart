import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_view/photo_view.dart';

import 'package:aicove_flutter/src/ui/shared/widgets/media/image_save.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/media/moe_image_preview.dart';

void main() {
  testWidgets('MoeImagePreview 单图模式为 PhotoView 提供纵向手势协作作用域', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: _SinglePreviewLauncher()));

    await tester.tap(find.text('打开单图预览'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(MoeImagePreview), findsOneWidget);
    expect(find.byType(PhotoView), findsOneWidget);

    final scopeFinder = find.byType(PhotoViewGestureDetectorScope);
    expect(scopeFinder, findsOneWidget);

    final scope = tester.widget<PhotoViewGestureDetectorScope>(scopeFinder);
    expect(scope.axis, Axis.vertical);
  });

  testWidgets('MoeImagePreview 画廊模式为 PhotoView 提供横向手势协作作用域', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: _PreviewLauncher()));

    await tester.tap(find.text('打开预览'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(MoeImagePreview), findsOneWidget);
    expect(find.byType(PhotoView), findsOneWidget);

    final scopeFinder = find.byType(PhotoViewGestureDetectorScope);
    expect(scopeFinder, findsOneWidget);

    final scope = tester.widget<PhotoViewGestureDetectorScope>(scopeFinder);
    expect(scope.axis, Axis.horizontal);
  });

  testWidgets('看图页右上角是关闭、右下角是保存', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: _PreviewLauncher()));

    await tester.tap(find.text('打开预览'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    final viewer = tester.getRect(find.byType(MoeImagePreview));
    final close = tester.getCenter(find.byTooltip('关闭'));
    final save = tester.getCenter(find.byTooltip('保存图片'));
    expect(close.dx, greaterThan(viewer.center.dx));
    expect(close.dy, lessThan(viewer.center.dy));
    expect(save.dx, greaterThan(viewer.center.dx));
    expect(save.dy, greaterThan(viewer.center.dy));
  });

  test('按文件头识别图片格式', () {
    expect(imageBytesExtension(_kTransparentPngBytes), 'png');
    expect(imageBytesExtension(const [0xFF, 0xD8, 0xFF, 0xE0]), 'jpg');
    expect(imageBytesExtension('GIF89a'.codeUnits), 'gif');
    expect(imageBytesExtension('RIFF\x00\x00\x00\x00WEBP'.codeUnits), 'webp');
    expect(imageBytesExtension(const [1, 2, 3]), isNull);
  });
}

class _PreviewLauncher extends StatelessWidget {
  const _PreviewLauncher();

  @override
  Widget build(BuildContext context) {
    final image = MemoryImage(_kTransparentPngBytes);
    return Scaffold(
      body: Center(
        child: TextButton(
          onPressed: () {
            MoeImagePreview.showGallery(
              context,
              images: [
                ImagePreviewItem(provider: image, heroTag: 'preview_image_1'),
                ImagePreviewItem(provider: image, heroTag: 'preview_image_2'),
              ],
            );
          },
          child: const Text('打开预览'),
        ),
      ),
    );
  }
}

class _SinglePreviewLauncher extends StatelessWidget {
  const _SinglePreviewLauncher();

  @override
  Widget build(BuildContext context) {
    final image = MemoryImage(_kTransparentPngBytes);
    return Scaffold(
      body: Center(
        child: TextButton(
          onPressed: () {
            MoeImagePreview.show(
              context,
              image,
              heroTag: 'single_preview_image',
            );
          },
          child: const Text('打开单图预览'),
        ),
      ),
    );
  }
}

final Uint8List _kTransparentPngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jL8QAAAAASUVORK5CYII=',
);
