/// 剪贴板附件读取：粘贴时把剪贴板里的文件或图片变成输入框附件。
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pasteboard/pasteboard.dart';

import 'attachment_picker_service.dart';

class ClipboardAttachmentService {
  /// 读剪贴板；返回 null 表示没有可当附件的内容，按原样粘贴文字。
  ///
  /// 文件优先：Finder／资源管理器复制文件时，剪贴板还会带文件图标和文件名文字。
  static Future<AttachmentPickResult?> read({required int maxMb}) async {
    try {
      if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
        final files = await Pasteboard.files();
        final path = files.firstWhere(
          (f) => f.trim().isNotEmpty && File(f).existsSync(),
          orElse: () => '',
        );
        if (path.isNotEmpty) {
          return AttachmentPickerService.classifyFile(
            path: path,
            name: p.basename(path),
            sizeBytes: File(path).lengthSync(),
            maxMb: maxMb,
          );
        }
      }

      final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
      if (!prefersImageOver(text)) return null;
      final bytes = await Pasteboard.image;
      if (bytes == null || bytes.isEmpty) return null;
      return saveImage(bytes, maxMb: maxMb);
    } catch (e) {
      return AttachmentPickError('读取剪贴板失败：$e');
    }
  }

  /// 剪贴板同时有图片和文字时，只有文字为空或只是一个网址（浏览器「复制图片」）才取图片；
  /// 表格、文档复制的文字往往附带一张渲染图，这时应粘贴文字。
  static bool prefersImageOver(String? text) {
    final trimmed = text?.trim() ?? '';
    if (trimmed.isEmpty) return true;
    return !trimmed.contains(RegExp(r'\s')) &&
        RegExp(r'^(https?|file|data):', caseSensitive: false).hasMatch(trimmed);
  }

  /// 把图片字节落成临时文件；后续由草稿存储复制进草稿目录。
  ///
  /// 剪贴板给的格式因平台而异（Windows 是 BMP，安卓是原图），按文件头认格式，
  /// 模型不常收的格式转成 PNG。
  static Future<AttachmentPickResult> saveImage(
    Uint8List bytes, {
    required int maxMb,
  }) async {
    var data = bytes;
    var ext = imageExtensionOf(data);
    if (ext == null) {
      final decoded = img.decodeImage(data);
      if (decoded == null) return AttachmentUnsupportedType('image');
      data = img.encodePng(decoded);
      ext = 'png';
    }
    if (data.length > maxMb * 1024 * 1024) {
      return AttachmentFileTooLarge(maxMb);
    }
    final dir = await getTemporaryDirectory();
    final file = File(
      p.join(dir.path, 'pasted_${DateTime.now().microsecondsSinceEpoch}.$ext'),
    );
    await file.writeAsBytes(data, flush: true);
    return AttachmentPickSuccess(
      SelectedAttachment(
        path: file.path,
        name: p.basename(file.path),
        sizeBytes: data.length,
        type: AttachmentType.image,
      ),
    );
  }

  /// 能直接发送的图片格式按文件头识别；认不出返回 null。
  static String? imageExtensionOf(Uint8List b) {
    bool at(int offset, List<int> sig) =>
        b.length >= offset + sig.length &&
        List.generate(
          sig.length,
          (i) => b[offset + i] == sig[i],
        ).every((x) => x);
    if (at(0, const [0x89, 0x50, 0x4E, 0x47])) return 'png';
    if (at(0, const [0xFF, 0xD8, 0xFF])) return 'jpg';
    if (at(0, const [0x47, 0x49, 0x46, 0x38])) return 'gif';
    if (at(0, const [0x52, 0x49, 0x46, 0x46]) &&
        at(8, const [0x57, 0x45, 0x42, 0x50])) {
      return 'webp';
    }
    if (at(4, const [0x66, 0x74, 0x79, 0x70]) &&
        (at(8, 'heic'.codeUnits) ||
            at(8, 'heix'.codeUnits) ||
            at(8, 'mif1'.codeUnits))) {
      return 'heic';
    }
    return null;
  }
}
