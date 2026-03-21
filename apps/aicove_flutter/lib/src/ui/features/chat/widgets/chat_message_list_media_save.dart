import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_gallery_saver_plus/image_gallery_saver_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../../core/models/message_block.dart';
import '../../../../ui/shared/widgets/meotalk_dialog.dart';
import '../../../../ui/shared/widgets/moe_toast.dart';

Future<void> saveChatMessageListMediaBlock(
  BuildContext context,
  MessageBlock block,
) async {
  try {
    String? sourcePath;
    String defaultFileName;
    final isImage = block is ImageBlock;

    if (isImage) {
      sourcePath = block.localPath;
      if (sourcePath == null || sourcePath.isEmpty) {
        if (block.url != null && block.url!.isNotEmpty) {
          _showToast(context, '网络图片请在预览中保存');
          return;
        }
        if (block.base64 != null && block.base64!.isNotEmpty) {
          final tempDir = await getTemporaryDirectory();
          if (!context.mounted) return;
          final tempFile = File(
            '${tempDir.path}/save_${DateTime.now().millisecondsSinceEpoch}.png',
          );
          final bytes = _decodeBase64Image(block.base64!);
          if (bytes == null) {
            _showToast(context, '图片数据无效');
            return;
          }
          await tempFile.writeAsBytes(bytes);
          sourcePath = tempFile.path;
        }
      }
      final ext =
          sourcePath != null ? sourcePath.split('.').last.toLowerCase() : 'png';
      defaultFileName = 'image_${DateTime.now().millisecondsSinceEpoch}.$ext';
    } else if (block is AudioBlock) {
      sourcePath = block.url;
      final ext = sourcePath.split('.').last.toLowerCase();
      defaultFileName = 'audio_${DateTime.now().millisecondsSinceEpoch}.$ext';
    } else {
      return;
    }

    if (!context.mounted) return;
    if (sourcePath == null || sourcePath.isEmpty) {
      _showToast(context, '文件不存在');
      return;
    }

    final sourceFile = File(sourcePath);
    if (!sourceFile.existsSync()) {
      _showToast(context, '文件不存在');
      return;
    }

    if (Platform.isAndroid && isImage) {
      final granted = await _ensureAndroidGalleryPermission(context);
      if (!context.mounted) return;
      if (!granted) {
        _showToast(context, '未授予相册权限，无法保存');
        return;
      }

      final result = await ImageGallerySaverPlus.saveFile(
        sourceFile.path,
        name: defaultFileName,
      );
      if (!context.mounted) return;
      _showToast(
        context,
        _isGallerySaveSuccess(result) ? '已保存到相册' : '保存到相册失败',
      );
      return;
    }

    if (Platform.isAndroid || Platform.isIOS) {
      final bytes = await sourceFile.readAsBytes();
      final savePath = await FilePicker.platform.saveFile(
        dialogTitle: '保存文件',
        fileName: defaultFileName,
        bytes: bytes,
      );
      if (!context.mounted) return;
      if (savePath == null) return;
      _showToast(context, '已保存');
      return;
    }

    final savePath = await FilePicker.platform.saveFile(
      dialogTitle: '保存文件',
      fileName: defaultFileName,
    );
    if (!context.mounted) return;
    if (savePath == null) return;
    await sourceFile.copy(savePath);
    if (!context.mounted) return;
    _showToast(context, '已保存');
  } catch (e) {
    if (!context.mounted) return;
    _showToast(context, '保存失败: $e');
  }
}

Future<bool> _ensureAndroidGalleryPermission(BuildContext context) async {
  final hasPermission = await _hasAndroidGalleryPermission();
  if (hasPermission) return true;
  if (!context.mounted) return false;

  final confirm = await showMeoTalkConfirm(
    context: context,
    title: '需要相册权限',
    message: '保存图片到系统相册需要相册访问权限。',
    hint: '授权后可直接将聊天图片保存到你的相册。',
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

List<int>? _decodeBase64Image(String base64Str) {
  try {
    return base64Decode(base64Str);
  } catch (_) {
    return null;
  }
}

void _showToast(BuildContext context, String message) {
  if (!context.mounted) return;
  MoeToast.show(context, message);
}
