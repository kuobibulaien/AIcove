import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const captureReleaseSourcePreview = bool.fromEnvironment(
  'WRITE_RELEASE_FIX_PREVIEW',
);

Future<void> loadReleasePreviewFonts(WidgetTester tester) async {
  if (!captureReleaseSourcePreview) return;
  await tester.runAsync(() async {
    final font = File('/System/Library/Fonts/STHeiti Medium.ttc');
    if (await font.exists()) {
      await (FontLoader(
        'ReleasePreview',
      )..addFont(font.readAsBytes().then(ByteData.sublistView))).load();
    }
    await (FontLoader('packages/lucide_icons/Lucide')
      ..addFont(rootBundle.load('packages/lucide_icons/assets/lucide.ttf')))
        .load();
    final sdk = Platform.environment['FLUTTER_ROOT'];
    if (sdk != null) {
      final icons = File(
        '$sdk/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
      );
      if (await icons.exists()) {
        await (FontLoader(
          'MaterialIcons',
        )..addFont(icons.readAsBytes().then(ByteData.sublistView))).load();
      }
    }
  });
}

Future<void> saveReleaseSourcePreview(
  WidgetTester tester,
  GlobalKey key,
  String name,
) async {
  if (!captureReleaseSourcePreview) return;
  await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 2);
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final root = Directory(
        const String.fromEnvironment(
          'RELEASE_PREVIEW_DIR',
          defaultValue: '../../.codex-temp/public-release-lifecycle-previews',
        ),
      );
      await root.create(recursive: true);
      await File(
        '${root.path}/$name.png',
      ).writeAsBytes(bytes!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}
