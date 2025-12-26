/// 消息输入组件
/// 
/// 更新记录：
/// - 2025-12-06: 接入皮肤系统
import 'dart:async';
import 'dart:io';
import 'package:file_picker/file_picker.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import '../../../../core/theme/skin_provider.dart';
import '../../../../core/theme/tokens.dart';
import '../../../../core/widgets/moe_toast.dart';
import '../../../settings/app_settings.dart';

/// 消息输入组件
class Composer extends ConsumerStatefulWidget {
  final bool disabled;
  final ValueChanged<String> onSend;
  final ValueChanged<String>? onImageSelected; // 图片路径回调
  const Composer({
    super.key,
    required this.onSend,
    this.disabled = false,
    this.onImageSelected,
  });

  @override
  ConsumerState<Composer> createState() => _ComposerState();
}

class _ComposerState extends ConsumerState<Composer> with SingleTickerProviderStateMixin {
  final _ctrl = TextEditingController();
  final _inputFocus = FocusNode();
  bool _isMenuExpanded = false;
  late AnimationController _animController;
  late Animation<double> _animation;
  // 合并用户单轮消息：3秒空闲聚合定时器
  Timer? _idleTimer;
  static const int _idleSeconds = 3;
  // 选中的图片路径（用于预览）
  String? _selectedImagePath;

  @override
  void initState() {
    super.initState();
    _inputFocus.addListener(() {
      if (_inputFocus.hasFocus) {
        _closeActionsMenu();
      }
    });
    // 监听文本变化以便空闲聚合（不依赖 TextField.onChanged，兼容性更高）
    _ctrl.addListener(() {
      if (!mounted) return;
      if (widget.disabled) return;
      _idleTimer?.cancel();
      _idleTimer = Timer(const Duration(seconds: _idleSeconds), _tryAutoSend);
    });
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    );
    _animation = CurvedAnimation(
      parent: _animController,
      curve: Curves.easeInOut,
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _inputFocus.dispose();
    _animController.dispose();
    _idleTimer?.cancel();
    super.dispose();
  }

  void _submit() {
    _idleTimer?.cancel();

    // 如果有选中的图片，发送图片
    if (_selectedImagePath != null && widget.onImageSelected != null) {
      widget.onImageSelected!(_selectedImagePath!);
      setState(() {
        _selectedImagePath = null;
      });
      _ctrl.clear();
      return;
    }

    // 否则发送文本消息
    final t = _ctrl.text.trim();
    if (t.isEmpty || widget.disabled) return;
    widget.onSend(t);
    _ctrl.clear();
  }

  // 从相册选择图片（使用 file_picker，兼容性好且流程简洁）
  Future<void> _pickImageFromGallery() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        withData: true,
      );
      
      // 用户取消选择或没有数据时直接返回
      if (result == null || result.files.isEmpty) return;
      
      final file = result.files.first;
      
      // 优先使用路径（如果可用）
      if (file.path != null && file.path!.isNotEmpty) {
        if (!mounted) return;
        setState(() => _selectedImagePath = file.path);
        return;
      }
      
      // 如果没有路径，使用字节数据并保存为临时文件
      if (file.bytes != null && file.bytes!.isNotEmpty) {
        final ext = _extFromName(file.name);
        final tmpPath = await _saveTempImage(file.bytes!, ext: ext);
        if (!mounted) return;
        setState(() => _selectedImagePath = tmpPath);
        return;
      }
      
      // 如果既没有路径也没有字节，显示提示
      if (mounted) {
        MoeToast.brief(context, '未能获取图片数据');
      }
    } catch (e) {
      if (mounted) {
        MoeToast.error(context, '选择图片失败: $e');
      }
    }
  }

  // 拍照
  Future<void> _takePhoto() async {
    try {
      final picker = ImagePicker();
      final XFile? photo = await picker.pickImage(
        source: ImageSource.camera,
      );

      if (photo != null) {
        try {
          if (photo.path.isNotEmpty && await File(photo.path).exists()) {
            if (!mounted) return;
            setState(() => _selectedImagePath = photo.path);
          } else {
            final bytes = await photo.readAsBytes();
            final tmp = await _saveTempImage(bytes, ext: 'jpg');
            if (!mounted) return;
            setState(() => _selectedImagePath = tmp);
          }
        } catch (_) {
          final bytes = await photo.readAsBytes();
          final tmp = await _saveTempImage(bytes, ext: 'jpg');
          if (!mounted) return;
          setState(() => _selectedImagePath = tmp);
        }
      }
    } catch (e) {
      if (mounted) {
        MoeToast.error(context, '拍照失败: $e');
      }
    }
  }
  // 将字节保存为临时图片文件，返回本地路径
  Future<String> _saveTempImage(List<int> bytes, {String ext = 'jpg'}) async {
    final dir = Directory.systemTemp;
    final file = File('${dir.path}/picked_${DateTime.now().millisecondsSinceEpoch}.$ext');
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  // 从文件名推断扩展名
  String _extFromName(String name) {
    final i = name.lastIndexOf('.');
    if (i > 0 && i < name.length - 1) {
      final ext = name.substring(i + 1).toLowerCase();
      if (ext.length <= 5) return ext;
    }
    return 'jpg';
  }



  // 拼音/组合输入检测，避免误触发
  bool _isComposingActive() {
    final composing = _ctrl.value.composing;
    return composing.isValid && !composing.isCollapsed;
  }

  // 空闲到点后尝试发送；若仍在组合中，则顺延1秒
  void _tryAutoSend() {
    if (widget.disabled) return;
    if (_isComposingActive()) {
      _idleTimer = Timer(const Duration(seconds: 1), _tryAutoSend);
      return;
    }
    final t = _ctrl.text.trim();
    if (t.isEmpty) return;
    widget.onSend(t);
    _ctrl.clear();
  }

  void _toggleActionsMenu() {
    // 收起键盘
    FocusScope.of(context).unfocus();

    setState(() {
      _isMenuExpanded = !_isMenuExpanded;
      if (_isMenuExpanded) {
        _animController.forward();
      } else {
        _animController.reverse();
      }
    });
  }

  void _closeActionsMenu() {
    if (_isMenuExpanded) {
      setState(() {
        _isMenuExpanded = false;
        _animController.reverse();
      });
    }
  }

  void _showModelSelector() {
    final settingsAsync = ref.read(appSettingsProvider);
    final settings = settingsAsync.maybeWhen(
      data: (s) => s,
      orElse: () => null,
    );
    if (settings == null) return;

    final visibleModels = List<String>.from(settings.modelList);
    visibleModels.sort((a, b) {
      final la = settings.getModelDisplayName(a).toLowerCase();
      final lb = settings.getModelDisplayName(b).toLowerCase();
      return la.compareTo(lb);
    });

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => _ModelSelectorSheet(
        models: visibleModels,
        currentModel: settings.defaultModelName,
        onSelectModel: (m) {
          ref.read(appSettingsProvider.notifier).setDefaultModelName(m);
          Navigator.pop(context);
        },
        getDisplayName: settings.getModelDisplayName,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final skin = context.skin;
    final colors = context.moeColors;
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final inputBgColor = isDark ? colors.panel : Colors.white;

    // 使用 SafeArea(bottom:true) 确保输入栏不被系统“小白条/导航条”遮挡
    return Container(
      color: colors.surface,
      child: SafeArea(
        top: false,
        left: false,
        right: false,
        bottom: true,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 图片预览区域（如果有选中的图片）
            if (_selectedImagePath != null) _buildImagePreview(),
            // 输入栏区域（固定在上方）
            Container(
          decoration: BoxDecoration(
            color: colors.surface,
            border: Border(
              top: BorderSide(color: colors.border, width: 1),
            ),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11), // 11*2+42=64，与底栏高度一致
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              // 加号按钮
              _buildPlusButton(),
              const SizedBox(width: 8),
              // 输入框
              Expanded(
                child: Container(
                  constraints: const BoxConstraints(minHeight: 42), // 确保最小高度与按钮一致
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6), // 减少垂直padding使总高度为42px
                  decoration: skin.inputDecoration(colors).copyWith(
                    color: inputBgColor,
                  ),
                  child: TextField(
                    controller: _ctrl,
                    focusNode: _inputFocus,
                    minLines: 1,
                    maxLines: 4,
                    style: const TextStyle(fontSize: 16, height: 1.5),
                    decoration: InputDecoration.collapsed(
                      hintText: '说点什么...',
                      hintStyle: TextStyle(color: colors.muted),
                    ),
                    enabled: !widget.disabled,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // 发送按钮
              _buildSendButton(),
            ],
          ),
        ),
        // 功能菜单区域（从下方展开，像抽屉）
        SizeTransition(
          sizeFactor: _animation,
          axisAlignment: 1.0, // 从底部展开
          child: Container(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.4, // 最大高度为屏幕的40%
            ),
            decoration: BoxDecoration(
              color: colors.surface,
            ),
            child: SingleChildScrollView(
              child: _ActionsMenuContent(
                onSelectModel: () {
                  _closeActionsMenu();
                  _showModelSelector();
                },
                onPickImage: () {
                  _closeActionsMenu();
                  _pickImageFromGallery();
                },
                onTakePhoto: () {
                  _closeActionsMenu();
                  _takePhoto();
                },
                onActionTap: (String action) {
                  _closeActionsMenu();
                  MoeToast.brief(context, '$action功能开发中');
                },
              ),
            ),
          ),
        ),
      ],
        ),
      ),
    );
  }

  /// 构建图片预览组件
  Widget _buildImagePreview() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: context.moeColors.surface,
        border: Border(
          top: BorderSide(color: context.moeColors.border, width: 1),
        ),
      ),
      child: Row(
        children: [
          // 图片缩略图
          Stack(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.file(
                  File(_selectedImagePath!),
                  width: 80,
                  height: 80,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => Container(
                    width: 80,
                    height: 80,
                    decoration: BoxDecoration(
                      color: Colors.grey.shade300,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(Icons.broken_image, color: Colors.grey),
                  ),
                ),
              ),
              // 关闭按钮
              Positioned(
                top: -4,
                right: -4,
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: () {
                      setState(() {
                        _selectedImagePath = null;
                      });
                    },
                    borderRadius: BorderRadius.circular(12),
                    child: Container(
                      width: 24,
                      height: 24,
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.6),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.close,
                        size: 16,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(width: 12),
          // 图片信息
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '图片附件',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: context.moeColors.text,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '点击发送按钮发送图片',
                  style: TextStyle(
                    fontSize: 12,
                    color: context.moeColors.text.withOpacity(0.6),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPlusButton() {
    final colors = context.moeColors;
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final plusBgColor = isDark ? colors.surface : Colors.white;

    return Material(
      color: plusBgColor,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: widget.disabled ? null : _toggleActionsMenu,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            border: Border.all(color: colors.border),
            borderRadius: BorderRadius.circular(8),
          ),
          child: AnimatedRotation(
            turns: _isMenuExpanded ? 0.125 : 0, // 45度旋转
            duration: const Duration(milliseconds: 250),
            child: Icon(Icons.add, size: 24, color: colors.muted),
          ),
        ),
      ),
    );
  }

  Widget _buildSendButton() {
    return Material(
      color: moePrimary,
      shape: const CircleBorder(),
      elevation: 2,
      child: InkWell(
        onTap: widget.disabled ? null : _submit,
        customBorder: const CircleBorder(),
        child: Container(
          width: 42,
          height: 42,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(
              colors: [moeHeaderGradientStart, moeHeaderGradientEnd],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
          child: const Icon(Icons.send_rounded, color: Colors.white, size: 20),
        ),
      ),
    );
  }
}

// 功能菜单内容
class _ActionsMenuContent extends StatelessWidget {
  final VoidCallback onSelectModel;
  final VoidCallback onPickImage;
  final VoidCallback onTakePhoto;
  final ValueChanged<String> onActionTap;

  const _ActionsMenuContent({
    required this.onSelectModel,
    required this.onPickImage,
    required this.onTakePhoto,
    required this.onActionTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
      child: GridView.count(
        shrinkWrap: true,
        crossAxisCount: 4,
        mainAxisSpacing: 8,
        crossAxisSpacing: 12,
        childAspectRatio: 0.78,
        physics: const NeverScrollableScrollPhysics(),
        children: [
          _ActionButton(
            icon: Icons.smart_toy_outlined,
            label: '选择模型',
            onTap: onSelectModel,
          ),
          _ActionButton(
            icon: Icons.image_outlined,
            label: '照片',
            onTap: onPickImage,
          ),
          _ActionButton(
            icon: Icons.camera_alt_outlined,
            label: '拍照',
            onTap: onTakePhoto,
          ),
          _ActionButton(
            icon: Icons.phone_outlined,
            label: '语音通话',
            onTap: () => onActionTap('语音通话'),
          ),
          _ActionButton(
            icon: Icons.videocam_outlined,
            label: '视频通话',
            onTap: () => onActionTap('视频通话'),
          ),
          _ActionButton(
            icon: Icons.shuffle_outlined,
            label: '戳一戳',
            onTap: () => onActionTap('戳一戳'),
          ),
          _ActionButton(
            icon: Icons.card_giftcard_outlined,
            label: '红包',
            onTap: () => onActionTap('红包'),
          ),
          _ActionButton(
            icon: Icons.location_on_outlined,
            label: '位置',
            onTap: () => onActionTap('位置'),
          ),
          _ActionButton(
            icon: Icons.folder_outlined,
            label: '文件',
            onTap: () => onActionTap('文件'),
          ),
        ],
      ),
    );
  }
}

// 功能按钮组件
class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final tileBgColor = isDark ? colors.panel : Colors.white;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: tileBgColor,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: colors.border),
            ),
            child: Icon(icon, size: 26, color: colors.muted),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 10,
              color: colors.text,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

// 模型选择器弹窗
class _ModelSelectorSheet extends StatelessWidget {
  final List<String> models;
  final String currentModel;
  final ValueChanged<String> onSelectModel;
  final String Function(String) getDisplayName;

  const _ModelSelectorSheet({
    required this.models,
    required this.currentModel,
    required this.onSelectModel,
    required this.getDisplayName,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final sheetBgColor = isDark ? colors.surface : Colors.white;

    return Container(
      decoration: BoxDecoration(
        color: sheetBgColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      ),
      // 使用 SafeArea 处理系统小白条，键盘高度在上层页面包裹处理，避免入侵内部结构
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 顶部拖动指示器
            Container(
              margin: const EdgeInsets.only(top: 8, bottom: 8),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: colors.muted.withOpacity(0.3),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            // 标题
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                '选择AI模型',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: colors.text,
                ),
              ),
            ),
            Divider(height: 1, color: colors.border),
            // 模型列表
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: models.length,
                itemBuilder: (context, index) {
                  final model = models[index];
                  final displayName = getDisplayName(model);
                  final isSelected = model == currentModel;

                  return Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: () => onSelectModel(model),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                        decoration: BoxDecoration(
                          color: isSelected ? colors.surface : Colors.transparent,
                          border: Border(
                            bottom: BorderSide(
                              color: colors.borderLight,
                              width: index < models.length - 1 ? 1 : 0,
                            ),
                          ),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                displayName,
                                style: TextStyle(
                                  fontSize: 14,
                                  color: colors.text,
                                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                                ),
                              ),
                            ),
                            if (isSelected)
                              Icon(
                                Icons.check_circle,
                                color: colors.primary,
                                size: 20,
                              ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}
