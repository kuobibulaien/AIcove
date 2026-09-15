/// WallpaperSection - 角色编辑页：壁纸行
///
/// 单行展示当前壁纸缩略图与状态，点击弹出更换/清除操作。
/// 上传后聊天页与本页共用同一张背景图。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../../core/utils/data_image.dart';
import '../../../../ui/shared/effects/smooth_clip.dart';
import '../../../../ui/shared/widgets/index.dart';
import '../../../../ui/theme/tokens.dart';

class WallpaperSection extends StatelessWidget {
  /// 已解码的壁纸字节（data:image 来源）；为空时按 rawValue 解析。
  final Uint8List? imageBytes;
  final String rawValue;
  final VoidCallback onPick;
  final VoidCallback onClear;

  const WallpaperSection({
    super.key,
    required this.imageBytes,
    required this.rawValue,
    required this.onPick,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    final hasWallpaper = rawValue.trim().isNotEmpty;

    return MoeSettingsGroup(
      margin: EdgeInsets.zero,
      children: [
        MoeSettingsRow(
          iconWidget: _buildThumbnail(context, hasWallpaper),
          label: '壁纸',
          subtitle: hasWallpaper ? '聊天页与本页共用此背景' : '未设置，默认空白',
          showDivider: false,
          onTap: () => _openActions(context, hasWallpaper),
        ),
      ],
    );
  }

  void _openActions(BuildContext context, bool hasWallpaper) {
    showMoeActionSheet(
      context: context,
      title: '壁纸',
      actions: [
        MoeSheetAction(
          label: hasWallpaper ? '更换壁纸' : '上传壁纸',
          icon: Icons.photo_library_outlined,
          onTap: onPick,
        ),
        if (hasWallpaper)
          MoeSheetAction(
            label: '清除壁纸',
            icon: Icons.delete_outline,
            isDestructive: true,
            onTap: onClear,
          ),
      ],
    );
  }

  Widget _buildThumbnail(BuildContext context, bool hasWallpaper) {
    final colors = context.moeColors;
    return MoeG2ClipRRect(
      radius: 8,
      child: SizedBox(
        width: 40,
        height: 40,
        child: hasWallpaper
            ? _buildImage(colors)
            : ColoredBox(
                color: colors.surfaceAlt.withValues(alpha: 0.35),
                child: Icon(Icons.wallpaper, size: 20, color: colors.muted),
              ),
      ),
    );
  }

  Widget _buildImage(MoeColors colors) {
    final bytes = imageBytes ?? decodeDataImage(rawValue.trim());
    if (bytes != null) {
      return Image.memory(
        bytes,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _fallbackIcon(colors),
      );
    }

    final raw = rawValue.trim();
    if (raw.startsWith('http://') || raw.startsWith('https://')) {
      return Image.network(
        raw,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _fallbackIcon(colors),
      );
    }
    if (raw.startsWith('assets/') || raw.startsWith('packages/')) {
      return Image.asset(
        raw,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _fallbackIcon(colors),
      );
    }
    return Image.file(
      File(raw),
      fit: BoxFit.cover,
      errorBuilder: (_, __, ___) => _fallbackIcon(colors),
    );
  }

  Widget _fallbackIcon(MoeColors colors) {
    return ColoredBox(
      color: colors.surfaceAlt.withValues(alpha: 0.35),
      child: Icon(Icons.image_not_supported_outlined,
          size: 18, color: colors.muted),
    );
  }
}
