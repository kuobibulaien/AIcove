import '../../../../core/media/media_store.dart';
import '../../../../core/media/media_asset.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../../../core/models/message_block.dart';
import '../../../../features/stickers/sticker_library.dart';
import '../../../../ui/shared/widgets/media/image_save.dart';
import '../../../../ui/shared/widgets/moe_toast.dart';

/// Saves a rendered PNG using the same platform destinations as chat media.
Future<void> saveChatImageBytes(BuildContext context, Uint8List bytes) =>
    saveImageBytesToDevice(context, bytes, namePrefix: 'chat');

Future<void> saveChatMessageListMediaBlock(
  BuildContext context,
  MessageBlock block,
) async {
  try {
    if (block is ImageBlock) {
      final sourcePath = block.mediaId == null
          ? block.localPath
          : (await (await MediaStore.shared).original(block.mediaId!)).path;
      if (!context.mounted) return;
      if (sourcePath != null && sourcePath.isNotEmpty) {
        await saveImageFileToDevice(
          context,
          File(sourcePath),
          namePrefix: 'image',
        );
        return;
      }
      if (block.url != null && block.url!.isNotEmpty) {
        _showToast(context, '网络图片请在预览中保存');
        return;
      }
      final bytes = block.base64 == null
          ? null
          : _decodeBase64Image(block.base64!);
      if (bytes == null || bytes.isEmpty) {
        _showToast(context, '图片数据无效');
        return;
      }
      await saveImageBytesToDevice(context, bytes, namePrefix: 'image');
      return;
    }
    if (block is EmojiBlock) {
      final rawPath = block.path.trim();
      final mediaId = mediaIdFromReference(rawPath);
      final sourcePath = mediaId == null
          ? StickerLibrary.resolveLocalPath(rawPath, stickerId: block.emojiId)
          : (await (await MediaStore.shared).original(mediaId)).path;
      if (!context.mounted) return;
      await saveImageFileToDevice(
        context,
        File(sourcePath),
        namePrefix: 'sticker',
      );
      return;
    }
    if (block is AudioBlock) {
      await _saveAudioFile(context, block.url);
    }
  } on OriginalMediaUnavailable catch (error) {
    if (context.mounted) _showToast(context, error.toString());
  } catch (e) {
    if (!context.mounted) return;
    _showToast(context, '保存失败: $e');
  }
}

Future<void> _saveAudioFile(BuildContext context, String sourcePath) async {
  final ext = sourcePath.split('.').last.toLowerCase();
  final defaultFileName = 'audio_${DateTime.now().millisecondsSinceEpoch}.$ext';
  final sourceFile = File(sourcePath);
  if (sourcePath.isEmpty || !sourceFile.existsSync()) {
    _showToast(context, '文件不存在');
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
}

Uint8List? _decodeBase64Image(String base64Str) {
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
