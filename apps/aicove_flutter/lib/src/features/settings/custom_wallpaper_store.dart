import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Copies a picked image into app storage as the custom global wallpaper.
/// Each save gets a fresh name so cached images of the old file never stick.
Future<String> saveCustomWallpaperFile(
  Uint8List bytes,
  String fileName,
) async {
  final dir = Directory(
    p.join((await getApplicationDocumentsDirectory()).path, 'wallpapers'),
  );
  await dir.create(recursive: true);
  final ext = p.extension(fileName).toLowerCase();
  final file = File(
    p.join(
      dir.path,
      'global_custom_${DateTime.now().millisecondsSinceEpoch}'
      '${ext.isEmpty ? '.img' : ext}',
    ),
  );
  await file.writeAsBytes(bytes, flush: true);
  return file.path;
}

/// Removes a replaced custom wallpaper; only files inside app storage.
Future<void> deleteCustomWallpaperFile(String path) async {
  final dir = p.join(
    (await getApplicationDocumentsDirectory()).path,
    'wallpapers',
  );
  if (!p.isWithin(dir, path)) return;
  final file = File(path);
  if (await file.exists()) await file.delete();
}
