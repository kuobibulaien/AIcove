/// 附件选择服务
///
/// 提供图片和文件选择的通用功能
library;

import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;

/// 选中的附件信息
class SelectedAttachment {
  final String path;
  final String? name;
  final int? sizeBytes;
  final AttachmentType type;

  const SelectedAttachment({
    required this.path,
    this.name,
    this.sizeBytes,
    required this.type,
  });
}

enum AttachmentType { image, file }

/// 附件选择结果
sealed class AttachmentPickResult {}

class AttachmentPickSuccess extends AttachmentPickResult {
  final SelectedAttachment attachment;
  AttachmentPickSuccess(this.attachment);
}

class AttachmentPickCancelled extends AttachmentPickResult {}

class AttachmentPickError extends AttachmentPickResult {
  final String message;
  AttachmentPickError(this.message);
}

class AttachmentFileTooLarge extends AttachmentPickResult {
  final int maxMb;
  AttachmentFileTooLarge(this.maxMb);
}

class AttachmentUnsupportedType extends AttachmentPickResult {
  final String extension;
  AttachmentUnsupportedType(this.extension);
}

/// 附件选择服务
class AttachmentPickerService {
  static const supportedTextFileExts = <String>{
    'txt', 'md', 'markdown', 'json', 'yaml', 'yml', 'csv', 'log', 'xml', 'ini', 'conf', 'toml',
    'dart', 'py', 'js', 'ts', 'java', 'kt', 'swift', 'go', 'rs', 'c', 'cpp', 'h', 'hpp', 'html', 'css', 'sh',
  };

  /// 选择图片
  static Future<AttachmentPickResult> pickImage(ImageSource source, {int imageQuality = 92}) async {
    try {
      final picker = ImagePicker();
      final xfile = await picker.pickImage(source: source, imageQuality: imageQuality);
      if (xfile == null) return AttachmentPickCancelled();

      return AttachmentPickSuccess(SelectedAttachment(
        path: xfile.path,
        type: AttachmentType.image,
      ));
    } catch (e) {
      return AttachmentPickError('选择图片失败：$e');
    }
  }

  /// 选择文件
  static Future<AttachmentPickResult> pickFile({int maxMb = 10}) async {
    try {
      final result = await FilePicker.platform.pickFiles(withData: false);
      if (result == null || result.files.isEmpty) return AttachmentPickCancelled();

      final file = result.files.first;
      final path = file.path;
      if (path == null || path.trim().isEmpty) {
        return AttachmentPickError('读取文件路径失败');
      }

      final sizeBytes = file.size;
      if (sizeBytes > maxMb * 1024 * 1024) {
        return AttachmentFileTooLarge(maxMb);
      }

      final ext = (file.extension ?? p.extension(path).replaceFirst('.', '')).toLowerCase();
      if (ext.isNotEmpty && !supportedTextFileExts.contains(ext)) {
        return AttachmentUnsupportedType(ext);
      }

      return AttachmentPickSuccess(SelectedAttachment(
        path: path,
        name: file.name,
        sizeBytes: sizeBytes,
        type: AttachmentType.file,
      ));
    } catch (e) {
      return AttachmentPickError('选择文件失败：$e');
    }
  }
}
