/// 附件预览组件（图片/文件）
///
/// 用于在输入框上方显示待发送的附件预览
library;

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import '../../../theme/tokens.dart';
import '../../effects/smooth_clip.dart';

/// 图片附件预览
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
    final colors = context.moeColors;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(top: BorderSide(color: colors.border, width: 1)),
      ),
      child: Row(
        children: [
          _buildThumbnail(colors),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '图片附件',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: MoeFontWeights.emphasis,
                    color: colors.text,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '点击发送按钮发送图片',
                  style: TextStyle(
                    fontSize: 12,
                    color: colors.text.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildThumbnail(MoeColors colors) {
    return Stack(
      children: [
        MoeG2ClipRRect(
          radius: 8,
          child: Image.file(
            File(imagePath),
            width: 80,
            height: 80,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => Container(
              width: 80,
              height: 80,
              decoration: MoeG2Decoration(
                radius: 8,
                color: Colors.grey.shade300,
              ),
              child: const Icon(Icons.broken_image, color: Colors.grey),
            ),
          ),
        ),
        Positioned(
          top: -4,
          right: -4,
          child: _RemoveButton(onTap: onRemove),
        ),
      ],
    );
  }
}

/// 文件附件预览
class FileAttachmentPreview extends StatelessWidget {
  final String filePath;
  final String? fileName;
  final int? fileSizeBytes;
  final VoidCallback onRemove;

  const FileAttachmentPreview({
    super.key,
    required this.filePath,
    this.fileName,
    this.fileSizeBytes,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final displayName = fileName ?? p.basename(filePath);
    final sizeText = fileSizeBytes != null ? _formatFileSize(fileSizeBytes!) : '未知大小';

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(top: BorderSide(color: colors.border, width: 1)),
      ),
      child: Row(
        children: [
          _buildIcon(colors),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: MoeFontWeights.emphasis,
                    color: colors.text,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '附件文件 · $sizeText',
                  style: TextStyle(
                    fontSize: 12,
                    color: colors.text.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildIcon(MoeColors colors) {
    return Stack(
      children: [
        Container(
          width: 80,
          height: 80,
          decoration: MoeG2Decoration(
            radius: 8,
            color: colors.surfaceAlt,
            border: Border.all(color: colors.borderLight, width: 0.5),
          ),
          child: Icon(Icons.insert_drive_file_outlined, color: colors.muted, size: 34),
        ),
        Positioned(
          top: -4,
          right: -4,
          child: _RemoveButton(onTap: onRemove),
        ),
      ],
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
        child: Container(
          width: 24,
          height: 24,
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.6),
            shape: BoxShape.circle,
          ),
          child: const Icon(Icons.close, size: 16, color: Colors.white),
        ),
      ),
    );
  }
}
