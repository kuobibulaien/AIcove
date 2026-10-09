import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:aicove_flutter/src/ui/shared/effects/smooth_clip.dart';

import '../../../../ui/theme/tokens.dart';
import '../../../../core/utils/data_image.dart';
import '../../../../ui/shared/widgets/index.dart';
import '../../../settings/app_settings.dart';
import '../../../app_update/app_update_dialog.dart';
import '../../../app_update/app_update_service.dart';
import '../../../../ui/shared/widgets/moe_scroll_edge.dart';

const _githubUrl = 'https://github.com/kuobibulaien/AIcove';

/// 个人中心内容组件（无 AppBar，可复用）
class ProfileContent extends ConsumerStatefulWidget {
  const ProfileContent({super.key});

  @override
  ConsumerState<ProfileContent> createState() => _ProfileContentState();
}

class _ProfileContentState extends ConsumerState<ProfileContent> {
  bool _checkingUpdate = false;

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
              ImageCropDialog(imageBytes: file.bytes!, fileName: file.name),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            // 组合淡入和轻微缩放效果
            final fadeAnimation = CurvedAnimation(
              parent: animation,
              curve: Curves.easeOut,
            );
            final scaleAnimation = Tween<double>(begin: 0.95, end: 1.0).animate(
              CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
            );

            return FadeTransition(
              opacity: fadeAnimation,
              child: ScaleTransition(scale: scaleAnimation, child: child),
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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('选择图片失败: $e')));
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
      },
    );
  }

  Future<void> _openGithub() async {
    final opened = await launchUrl(
      Uri.parse(_githubUrl),
      mode: LaunchMode.externalApplication,
    ).catchError((_) => false);
    if (opened || !mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('无法打开链接：$_githubUrl')));
  }

  Future<void> _checkForUpdate() async {
    if (_checkingUpdate) return;
    final service = AppUpdateService();
    if (!service.canCheck) {
      MoeToast.show(context, '开发版本不检查更新');
      return;
    }
    setState(() => _checkingUpdate = true);
    try {
      final release = await service.checkForUpdate(manual: true);
      if (!mounted) return;
      if (release == null) {
        MoeToast.show(context, '已是最新版本', type: ToastType.success);
      } else {
        await showAppUpdateDialog(context, release);
      }
    } catch (_) {
      if (mounted) {
        MoeToast.show(context, '检查更新失败，请稍后再试', type: ToastType.error);
      }
    } finally {
      if (mounted) setState(() => _checkingUpdate = false);
    }
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
      padding: moeUnderBarPadding(context, const EdgeInsets.all(24)),
      child: Column(
        children: [
          const SizedBox(height: 32),

          // 头像区域
          GestureDetector(
            onTap: _pickImage,
            child: Container(
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
                icon: Icons.info_outline,
                label: '关于',
                subtitle: '在 GitHub 查看项目',
                onTap: _openGithub,
              ),
              MoeSettingsRow(
                icon: Icons.system_update_outlined,
                label: '检查更新',
                subtitle: _checkingUpdate
                    ? '检查中…'
                    : kAppReleaseTag.isEmpty
                        ? '开发版本'
                        : '当前版本 $kAppReleaseTag',
                onTap: _checkForUpdate,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
