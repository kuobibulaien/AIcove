import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:aicove_flutter/src/ui/shared/effects/smooth_clip.dart';

import '../../../../ui/theme/tokens.dart';
import '../../../../core/utils/data_image.dart';
import '../../../../ui/shared/animations/parallax_slide_page_route.dart';
import '../../../../ui/shared/widgets/index.dart';
import '../../../settings/app_settings.dart';
import '../../../../ui/features/settings/pages/log_viewer_page.dart';
import '../../../../ui/features/debug/pages/ui_gallery_page.dart';

/// 个人中心内容组件（无 AppBar，可复用）
class ProfileContent extends ConsumerStatefulWidget {
  const ProfileContent({super.key});

  @override
  ConsumerState<ProfileContent> createState() => _ProfileContentState();
}

class _ProfileContentState extends ConsumerState<ProfileContent> {
  Future<void> _pickImage() async {
    // 与"添加角色"一致：使用 FilePicker 获取字节并存为 data:image/... 的数据URL
    // 这样可以避免 Android 上 content:// 或云盘返回的无效路径导致的 PlatformException
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        withData: true,
      );
      if (result == null || result.files.isEmpty) return;
      final file = result.files.first;
      if (file.bytes == null) return;

      // 打开裁剪弹窗
      if (!mounted) return;
      final croppedBytes = await Navigator.of(context).push<Uint8List>(
        PageRouteBuilder(
          opaque: false,
          barrierDismissible: false,
          barrierColor: Colors.black,
          transitionDuration: kAnim,
          reverseTransitionDuration: kAnim,
          pageBuilder: (context, animation, secondaryAnimation) =>
              ImageCropDialog(
            imageBytes: file.bytes!,
            fileName: file.name,
          ),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            // 组合淡入和轻微缩放效果
            final fadeAnimation = CurvedAnimation(
              parent: animation,
              curve: Curves.easeOut,
            );
            final scaleAnimation = Tween<double>(
              begin: 0.95,
              end: 1.0,
            ).animate(CurvedAnimation(
              parent: animation,
              curve: Curves.easeOutCubic,
            ));

            return FadeTransition(
              opacity: fadeAnimation,
              child: ScaleTransition(
                scale: scaleAnimation,
                child: child,
              ),
            );
          },
        ),
      );

      // 如果用户完成了裁剪，保存裁剪后的图片
      if (croppedBytes != null) {
        final dataUrl = buildDataImage(croppedBytes, fileName: file.name);
        final settings = ref.read(appSettingsProvider.notifier);
        await settings.setUserAvatar(dataUrl);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('选择图片失败: $e')),
        );
      }
    }
  }

  Future<void> _editName() async {
    await showMoeAutoSaveTextEditor(
        context: context,
        title: '个人名称',
        initialValue: ref.read(appSettingsProvider).valueOrNull?.userName ?? '',
        onSave: (text) async {
          if (text.trim().isEmpty) throw const FormatException('名称不能为空');
          await ref.read(appSettingsProvider.notifier).setUserName(text.trim());
        });
  }

  Widget _buildAvatarImage(String? url) {
    if (url == null || url.trim().isEmpty) {
      return const SizedBox.expand();
    }
    final trimmed = url.trim();

    // 1) data:image/base64
    final dataBytes = decodeDataImage(trimmed);
    if (dataBytes != null) {
      return Image.memory(
        dataBytes,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => const SizedBox.expand(),
      );
    }

    // 2) 本地文件（旧版本兼容）
    if (File(trimmed).existsSync()) {
      return Image.file(
        File(trimmed),
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => const SizedBox.expand(),
      );
    }

    // 3) 资产或网络
    final isNetwork =
        trimmed.startsWith('http://') || trimmed.startsWith('https://');
    if (!isNetwork &&
        (trimmed.startsWith('assets/') || !trimmed.contains('://'))) {
      return Image.asset(
        trimmed,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => const SizedBox.expand(),
      );
    }
    return Image.network(
      trimmed,
      fit: BoxFit.cover,
      errorBuilder: (_, __, ___) => const SizedBox.expand(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settingsAsync = ref.watch(appSettingsProvider);
    final settings = settingsAsync.valueOrNull;
    final userName = settings?.userName ?? '未设置';
    final userAvatar = settings?.userAvatar;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          const SizedBox(height: 32),

          // 头像区域
          GestureDetector(
            onTap: _pickImage,
            child: Stack(
              children: [
                Container(
                  width: 120,
                  height: 120,
                  decoration: MoeG2Decoration(
                    radius: radiusBubble.x,
                    color: moeSurface,
                    border: Border.all(color: moeBorder, width: 2),
                  ),
                  child: MoeG2ClipRRect(
                    radius: radiusBubble.x,
                    child: _buildAvatarImage(userAvatar),
                  ),
                ),
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: const BoxDecoration(
                      color: moePrimary,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.camera_alt,
                      size: 20,
                      color: Colors.white,
                    ),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 24),

          // 名称区域（自适应，避免小屏溢出）
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                userName,
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: MoeFontWeights.emphasis,
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                icon: const Icon(Icons.edit, size: 20, color: moeMuted),
                onPressed: _editName,
              ),
            ],
          ),

          const SizedBox(height: 48),

          // 设置列表 - 使用 MoeSettingsGroup 统一管理
          MoeSettingsGroup(
            titleFirst: true,
            margin: EdgeInsets.zero,
            children: [
              MoeSettingsRow(
                icon: Icons.person_outline,
                label: '个人信息',
                subtitle: userName,
                onTap: _editName,
              ),
              MoeSettingsRow(
                icon: Icons.photo_library_outlined,
                label: '更换头像',
                onTap: _pickImage,
              ),
              MoeSettingsRow(
                icon: Icons.info_outline,
                label: '关于',
                subtitle: 'AIcove v1.0.0',
                onTap: () {
                  showAboutDialog(
                    context: context,
                    applicationName: 'AIcove',
                    applicationVersion: '1.0.0',
                    applicationIcon:
                        const Icon(Icons.chat_bubble_outline, size: 48),
                    children: const [
                      Text('一款简单顺手的聊天应用'),
                    ],
                  );
                },
              ),
              MoeSettingsRow(
                icon: Icons.description_outlined,
                label: '查看日志',
                subtitle: '查看系统运行日志',
                onTap: () {
                  MoeWorkspace.navigatorOf(context).push(
                    ParallaxSlidePageRoute(page: const LogViewerPage()),
                  );
                },
              ),
              MoeSettingsRow(
                icon: Icons.palette_outlined,
                label: 'UI 组件库',
                subtitle: '查看所有公共组件样式',
                onTap: () {
                  MoeWorkspace.navigatorOf(context).push(
                    ParallaxSlidePageRoute(page: const UiGalleryPage()),
                  );
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}
