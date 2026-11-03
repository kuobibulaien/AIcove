import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/widgets.dart';
import 'package:image_gallery_saver_plus/image_gallery_saver_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import '../meotalk_dialog.dart';
import '../moe_toast.dart';

/// Saves an image file to the device: Android goes to the system gallery,
/// iOS and desktop ask where to save. The file is saved as-is so animated
/// and transparent images keep their format.
Future<void> saveImageFileToDevice(
  BuildContext context,
  File source, {
  required String namePrefix,
}) async {
  try {
    if (!await source.exists()) {
      if (context.mounted) MoeToast.show(context, '文件不存在');
      return;
    }
    final extension = await imageFileExtension(source);
    if (!context.mounted) return;
    await _save(context, source, null, extension, namePrefix);
  } catch (_) {
    if (context.mounted) MoeToast.error(context, '保存失败，请重试');
  }
}

/// Same as [saveImageFileToDevice] for images that only exist in memory.
Future<void> saveImageBytesToDevice(
  BuildContext context,
  Uint8List bytes, {
  required String namePrefix,
}) async {
  try {
    final extension = imageBytesExtension(bytes) ?? 'png';
    File? file;
    if (Platform.isAndroid) {
      // The gallery plugin re-encodes raw bytes as JPEG; a file keeps the
      // original format.
      final dir = await getTemporaryDirectory();
      file = File(
        '${dir.path}/save_${DateTime.now().microsecondsSinceEpoch}.$extension',
      );
      await file.writeAsBytes(bytes, flush: true);
    }
    try {
      if (!context.mounted) return;
      await _save(context, file, bytes, extension, namePrefix);
    } finally {
      if (file != null && await file.exists()) await file.delete();
    }
  } catch (_) {
    if (context.mounted) MoeToast.error(context, '保存失败，请重试');
  }
}

Future<void> _save(
  BuildContext context,
  File? file,
  Uint8List? bytes,
  String extension,
  String namePrefix,
) async {
  final fileName =
      '${namePrefix}_${DateTime.now().millisecondsSinceEpoch}.$extension';

  if (Platform.isAndroid) {
    final granted = await _ensureAndroidGalleryPermission(context);
    if (!context.mounted) return;
    if (!granted) {
      MoeToast.show(context, '未授予相册权限，无法保存');
      return;
    }
    final result = await ImageGallerySaverPlus.saveFile(
      file!.path,
      name: fileName,
    );
    if (context.mounted) {
      MoeToast.show(
        context,
        _isGallerySaveSuccess(result) ? '已保存到相册' : '保存到相册失败',
      );
    }
    return;
  }

  final mobile = Platform.isIOS;
  final path = await FilePicker.platform.saveFile(
    dialogTitle: '保存图片',
    fileName: fileName,
    type: FileType.custom,
    allowedExtensions: [extension],
    bytes: mobile ? bytes ?? await file!.readAsBytes() : null,
  );
  if (path == null) return;
  if (!mobile) {
    if (bytes != null) {
      await File(path).writeAsBytes(bytes, flush: true);
    } else {
      await file!.copy(path);
    }
  }
  if (context.mounted) MoeToast.show(context, '已保存');
}

/// Extension from the file's own header, falling back to its name.
Future<String> imageFileExtension(File file) async {
  final handle = await file.open();
  try {
    final sniffed = imageBytesExtension(await handle.read(12));
    if (sniffed != null) return sniffed;
  } finally {
    await handle.close();
  }
  final name = file.uri.pathSegments.last;
  final dot = name.lastIndexOf('.');
  final fromName = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
  return RegExp(r'^[a-z0-9]{1,5}$').hasMatch(fromName) ? fromName : 'png';
}

String? imageBytesExtension(List<int> bytes) {
  bool startsWith(List<int> magic, [int offset = 0]) {
    if (bytes.length < offset + magic.length) return false;
    for (var i = 0; i < magic.length; i++) {
      if (bytes[offset + i] != magic[i]) return false;
    }
    return true;
  }

  if (startsWith(const [0x89, 0x50, 0x4E, 0x47])) return 'png';
  if (startsWith(const [0xFF, 0xD8, 0xFF])) return 'jpg';
  if (startsWith(const [0x47, 0x49, 0x46, 0x38])) return 'gif';
  if (startsWith(const [0x52, 0x49, 0x46, 0x46]) &&
      startsWith(const [0x57, 0x45, 0x42, 0x50], 8)) {
    return 'webp';
  }
  if (startsWith(const [0x42, 0x4D])) return 'bmp';
  return null;
}

Future<bool> _ensureAndroidGalleryPermission(BuildContext context) async {
  if (await _hasAndroidGalleryPermission()) return true;
  if (!context.mounted) return false;

  final confirm = await showMeoTalkConfirm(
    context: context,
    title: '需要相册权限',
    message: '保存图片到系统相册需要相册访问权限。',
    hint: '授权后可直接将图片保存到你的相册。',
    cancelText: '取消',
    confirmText: '去授权',
  );
  if (confirm != true) return false;

  final photosStatus = await Permission.photos.request();
  if (photosStatus.isGranted || photosStatus.isLimited) return true;

  final storageStatus = await Permission.storage.request();
  return storageStatus.isGranted;
}

Future<bool> _hasAndroidGalleryPermission() async {
  final photosStatus = await Permission.photos.status;
  if (photosStatus.isGranted || photosStatus.isLimited) return true;

  final storageStatus = await Permission.storage.status;
  return storageStatus.isGranted;
}

bool _isGallerySaveSuccess(dynamic result) {
  if (result is bool) return result;
  if (result is Map) {
    final success = result['isSuccess'] ?? result['success'];
    if (success is bool) return success;
    if (success is num) return success != 0;
  }
  return false;
}
