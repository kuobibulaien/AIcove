import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/tokens.dart';
import '../../../../core/utils/data_image.dart';
import '../../../../core/widgets/image_crop_dialog.dart';
import '../../../settings/app_settings.dart';
import '../pages/log_viewer_page.dart';

/// 个人中心内容组件（无 AppBar，可复用）
class ProfileContent extends ConsumerStatefulWidget {
  const ProfileContent({super.key});

  @override
  ConsumerState<ProfileContent> createState() => _ProfileContentState();
}

class _ProfileContentState extends ConsumerState<ProfileContent> {
  final TextEditingController _nameController = TextEditingController();
  bool _isEditingName = false;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

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
          transitionDuration: const Duration(milliseconds: 250),
          reverseTransitionDuration: const Duration(milliseconds: 200),
          pageBuilder: (context, animation, secondaryAnimation) => ImageCropDialog(
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

  Future<void> _saveName() async {
    final name = _nameController.text.trim();
    if (name.isNotEmpty) {
      final settings = ref.read(appSettingsProvider.notifier);
      await settings.setUserName(name);
      setState(() {
        _isEditingName = false;
      });
    }
  }

  Widget _buildAvatarImage(String? url) {
    if (url == null || url.trim().isEmpty) {
      return const Icon(Icons.person, size: 60, color: moeMuted);
    }
    final trimmed = url.trim();

    // 1) data:image/base64
    final dataBytes = decodeDataImage(trimmed);
    if (dataBytes != null) {
      return Image.memory(
        dataBytes,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => const Icon(Icons.person, size: 60, color: moeMuted),
      );
    }

    // 2) 本地文件（旧版本兼容）
    if (File(trimmed).existsSync()) {
      return Image.file(
        File(trimmed),
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => const Icon(Icons.person, size: 60, color: moeMuted),
      );
    }

    // 3) 资产或网络
    final isNetwork = trimmed.startsWith('http://') || trimmed.startsWith('https://');
    if (!isNetwork && (trimmed.startsWith('assets/') || !trimmed.contains('://'))) {
      return Image.asset(
        trimmed,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => const Icon(Icons.person, size: 60, color: moeMuted),
      );
    }
    return Image.network(
      trimmed,
      fit: BoxFit.cover,
      errorBuilder: (_, __, ___) => const Icon(Icons.person, size: 60, color: moeMuted),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settingsAsync = ref.watch(appSettingsProvider);
    final settings = settingsAsync.valueOrNull;
    final userName = settings?.userName ?? '未设置';
    final userAvatar = settings?.userAvatar;

    if (!_isEditingName) {
      _nameController.text = settings?.userName ?? '';
    }

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
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.all(radiusBubble),
                    color: moeSurface,
                    border: Border.all(color: moeBorder, width: 2),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: _buildAvatarImage(userAvatar),
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
          if (_isEditingName)
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _nameController,
                    autofocus: true,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                    ),
                    decoration: const InputDecoration(
                      hintText: '输入名称',
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                    ),
                    onSubmitted: (_) => _saveName(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.check, color: moePrimary),
                  onPressed: _saveName,
                ),
                IconButton(
                  icon: const Icon(Icons.close, color: moeMuted),
                  onPressed: () {
                    setState(() {
                      _isEditingName = false;
                      _nameController.text = settings?.userName ?? '';
                    });
                  },
                ),
              ],
            )
          else
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  userName,
                  style: const TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.edit, size: 20, color: moeMuted),
                  onPressed: () {
                    setState(() {
                      _isEditingName = true;
                    });
                  },
                ),
              ],
            ),

          const SizedBox(height: 48),

          // 设置列表
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.person_outline),
                  title: const Text('个人信息'),
                  subtitle: Text(userName),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    setState(() {
                      _isEditingName = true;
                    });
                  },
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.photo_library_outlined),
                  title: const Text('更换头像'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _pickImage,
                ),
              ],
            ),
          ),

          const SizedBox(height: 16),

          // 关于信息
          Card(
            child: ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('关于'),
              subtitle: const Text('MyGril v1.0.0'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                showAboutDialog(
                  context: context,
                  applicationName: 'MyGril',
                  applicationVersion: '1.0.0',
                  applicationIcon: const Icon(Icons.chat_bubble_outline, size: 48),
                  children: const [
                    Text('一款简单顺手的聊天应用'),
                  ],
                );
              },
            ),
          ),

          const SizedBox(height: 16),

          // 日志查看器
          Card(
            child: ListTile(
              leading: const Icon(Icons.description_outlined),
              title: const Text('查看日志'),
              subtitle: const Text('查看系统运行日志'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (context) => const LogViewerPage(),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
