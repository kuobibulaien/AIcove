/// 附件预览组件（图片/文件）
///
/// 用于在输入框上方显示待发送的附件预览
library;

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/buttons/moe_button_surface.dart';
import 'package:path/path.dart' as p;
import '../../../theme/tokens.dart';
import '../../effects/smooth_clip.dart';

/// 图片附件预览（紧凑悬浮缩略图）
class ImageAttachmentPreview extends StatelessWidget {
  final String imagePath;
  final VoidCallback onRemove;

  const ImageAttachmentPreview({
    super.key,
    required this.imagePath,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.only(left: 16, top: 8, right: 16),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            MoeG2ClipRRect(
              radius: 8,
              child: Image.file(
                File(imagePath),
                width: 56,
                height: 56,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => Container(
                  width: 56,
                  height: 56,
                  decoration: MoeG2Decoration(
                    radius: 8,
                    color: Colors.grey.shade300,
                  ),
                  child: const Icon(
                    Icons.broken_image,
                    color: Colors.grey,
                    size: 20,
                  ),
                ),
              ),
            ),
            Positioned(
              top: -6,
              right: -6,
              child: _RemoveButton(onTap: onRemove),
            ),
          ],
        ),
      ),
    );
  }
}

/// 文件附件预览（紧凑悬浮 chip）
class FileAttachmentPreview extends StatelessWidget {
  final String filePath;
  final String? fileName;
  final int? fileSizeBytes;
  final IconData leadingIcon;
  final VoidCallback onRemove;

  const FileAttachmentPreview({
    super.key,
    required this.filePath,
    this.fileName,
    this.fileSizeBytes,
    this.leadingIcon = Icons.insert_drive_file_outlined,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final displayName = fileName ?? p.basename(filePath);
    final sizeText = fileSizeBytes != null
        ? _formatFileSize(fileSizeBytes!)
        : null;

    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.only(left: 16, top: 8, right: 16),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              constraints: const BoxConstraints(maxWidth: 200),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: MoeG2Decoration(
                radius: 10,
                color: colors.surfaceAlt,
                border: Border.all(color: colors.borderLight, width: 0.5),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(leadingIcon, color: colors.muted, size: 20),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: MoeFontWeights.emphasis,
                            color: colors.text,
                          ),
                        ),
                        if (sizeText != null)
                          Text(
                            sizeText,
                            style: TextStyle(fontSize: 10, color: colors.muted),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Positioned(
              top: -6,
              right: -6,
              child: _RemoveButton(onTap: onRemove),
            ),
          ],
        ),
      ),
    );
  }

  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '${bytes}B';
    final kb = bytes / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(1)}KB';
    final mb = kb / 1024;
    if (mb < 1024) return '${mb.toStringAsFixed(1)}MB';
    final gb = mb / 1024;
    return '${gb.toStringAsFixed(1)}GB';
  }
}

/// 移除按钮（内部复用）
class _RemoveButton extends StatelessWidget {
  final VoidCallback onTap;
  const _RemoveButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: MoeButtonSurface(
          width: 20,
          height: 20,
          tintColor: Colors.black.withValues(alpha: 0.6),
          radius: 999,
          child: Icon(Icons.close, size: 12, color: context.moeColors.text),
        ),
      ),
    );
  }
}
