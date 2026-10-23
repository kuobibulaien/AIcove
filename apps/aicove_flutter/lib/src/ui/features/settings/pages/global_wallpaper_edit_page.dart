import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/settings/app_settings.dart';
import '../../../shared/widgets/index.dart';
import '../../../theme/tokens.dart';
import '../../wallpaper/pages/wallpaper_editor_page.dart';
import '../../wallpaper/widgets/wallpaper_preview_samples.dart';

/// 全局壁纸的编辑入口：与角色壁纸共用 [WallpaperEditorPage]，按壁纸保存调节；
/// 自定义壁纸还可以在这里删除。
class GlobalWallpaperEditPage extends ConsumerWidget {
  const GlobalWallpaperEditPage({
    super.key,
    required this.wallpaper,
    this.custom,
  });

  /// 内置壁纸，或 [GlobalWallpaper.custom]（此时 [custom] 必填）。
  final GlobalWallpaper wallpaper;
  final CustomWallpaper? custom;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isCustom = custom != null;
    final key = custom?.id ?? wallpaper.value;
    final style =
        ref
            .read(appSettingsProvider)
            .valueOrNull
            ?.wallpaperStyleFor(key, custom: isCustom) ??
        WallpaperStyle.defaultFor(custom: isCustom);
    return WallpaperEditorPage(
      source: isCustom
          ? custom!.imagePath
          : wallpaper.assetFor(
              GlobalWallpaperSlot.page,
              Theme.of(context).brightness,
            ),
      style: style,
      defaultStyle: WallpaperStyle.defaultFor(custom: isCustom),
      kind: WallpaperPreviewKind.home,
      fallbackAlignment: wallpaper.alignment,
      onSave: (_, style) => ref
          .read(appSettingsProvider.notifier)
          .setGlobalWallpaperStyle(
            key,
            style ?? WallpaperStyle.defaultFor(custom: isCustom),
          ),
      onDelete: isCustom ? () => _delete(context, ref) : null,
    );
  }

  Future<bool> _delete(BuildContext context, WidgetRef ref) async {
    final confirmed = await showMeoTalkConfirm(
      context: context,
      title: '删除壁纸',
      message: '确认删除这张壁纸吗？图片会从本机移除。',
      cancelText: '取消',
      confirmText: '删除',
      isDanger: true,
    );
    if (confirmed != true) return false;
    await ref
        .read(appSettingsProvider.notifier)
        .removeCustomGlobalWallpaper(custom!.id);
    return true;
  }
}
