/// 消息输入组件
/// 
/// 更新记录：
/// - 2025-12-06: 接入皮肤系统
/// - 2025-12-31: 拆分功能菜单和模型选择器到独立文件
library;
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import '../../../../ui/theme/skin_provider.dart';
import '../../../../ui/theme/tokens.dart';
import '../../../../ui/shared/effects/smooth_clip.dart';
import '../../../../ui/shared/widgets/meotalk_dialog.dart';
import '../../../../ui/shared/widgets/moe_toast.dart';
import '../../../../ui/shared/widgets/sheets/moe_bottom_sheet.dart';
import '../../../../ui/shared/widgets/list/moe_list_tile.dart';
import '../../../settings/app_settings.dart';

/// 消息输入组件
class Composer extends ConsumerStatefulWidget {
  final bool disabled;
  final ValueChanged<String> onSend;
  final ValueChanged<String>? onImageSelected; // 图片路径回调
  final ValueChanged<String>? onFileSelected; // 文件路径回调
  const Composer({
    super.key,
    required this.onSend,
    this.disabled = false,
    this.onImageSelected,
    this.onFileSelected,
  });

  @override
  ConsumerState<Composer> createState() => _ComposerState();
}

class _ComposerState extends ConsumerState<Composer> {
  final _ctrl = TextEditingController();
  final _inputFocus = FocusNode();
  // 合并用户单轮消息：3秒空闲聚合定时器
  Timer? _idleTimer;
  static const int _idleSeconds = 3;

  // 输入框位置状态：false=底部；true=中部（下方预留键盘/更多面板空间）
  bool _expanded = false;

  // 更多面板是否显示（键盘会盖在它上面；它始终在输入框下方占位）
  bool _showMorePanel = false;

  // 标记：用户是否主动触发了"收起键盘去显示更多面板"的操作
  // 用于区分"点击更多按钮收起键盘"和"点击键盘收起按钮"
  bool _pendingShowMorePanel = false;

  // 面板高度（不含 SafeArea.bottom）。
  // 设计目标：输入框处于“中部”时，下方永远预留出足够空间（键盘 or 更多面板），从而避免键盘收起/弹出导致输入框上下跳。
  // 采用“只增不减”的缓存策略：一旦见过更高的键盘，就把高度记住，后续切换不再缩小。
  // 面板高度（不含 SafeArea.bottom）。
  // 设计目标：输入框处于“中部”时，下方永远预留出足够空间（键盘 or 更多面板），从而避免键盘收起/弹出导致输入框上下跳。
  // 初始值给一个大概的键盘高度（270），后续会跟随实际键盘高度调整
  double _panelHeight = 270;

  // 用于识别“键盘刚刚收起”，从而决定是否把输入框回到底部
  double _lastViewInsetsBottom = 0;

  // 选中的图片路径（用于预览）
  String? _selectedImagePath;

  // 选中的文件（用于预览）
  String? _selectedFilePath;
  String? _selectedFileName;
  int? _selectedFileSizeBytes;

  @override
  void initState() {
    super.initState();
    // 监听文本变化以便空闲聚合（不依赖 TextField.onChanged，兼容性更高）
    _ctrl.addListener(() {
      if (!mounted) return;
      if (widget.disabled) return;
      _idleTimer?.cancel();
      _idleTimer = Timer(const Duration(seconds: _idleSeconds), _tryAutoSend);
    });

    // 当用户点回输入框（Focus 获得）时：保持“中部”状态，关闭更多面板
    _inputFocus.addListener(() {
      if (!mounted) return;
      if (!_inputFocus.hasFocus) return;
      if (!_expanded || _showMorePanel) {
        setState(() {
          _expanded = true;
          _showMorePanel = false;
        });
      }
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _inputFocus.dispose();
    _idleTimer?.cancel();
    super.dispose();
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

    // 如果有选中的文件，发送文件
    if (_selectedFilePath != null) {
      if (widget.onFileSelected == null) {
        MoeToast.brief(context, '当前页面暂未接入文件发送');
        return;
      }
      widget.onFileSelected!(_selectedFilePath!);
      setState(() {
        _selectedFilePath = null;
        _selectedFileName = null;
        _selectedFileSizeBytes = null;
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

  @override
  Widget build(BuildContext context) {
    final skin = context.skin;
    final colors = context.moeColors;
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final inputBgColor = isDark ? colors.panel : Colors.white;
    final bottomSafe = MediaQuery.paddingOf(context).bottom;
    final viewInsetsBottom = MediaQuery.viewInsetsOf(context).bottom;

    // 键盘高度变化时：更新面板高度，或在“键盘模式”下把输入框收回到底部
    if (viewInsetsBottom != _lastViewInsetsBottom) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _handleKeyboardInsetsChanged(viewInsetsBottom);
      });
    }

    // 更新记住的面板高度（用于键盘收起后更多面板的占位）
    if (viewInsetsBottom > 0) {
      final candidate = math.max(200.0, viewInsetsBottom);
      if ((candidate - _panelHeight).abs() > 1.0) {
        _panelHeight = candidate;
      }
    }

    final keyboardVisible = viewInsetsBottom > 0;

    // 关键：当用户直接点“键盘收起按钮”时，MediaQuery.viewInsets 会先变成 0，
    // 但 _handleKeyboardInsetsChanged 是 post-frame 回调，会导致出现一帧“中部空白占位”，产生“卡一下”的观感。
    // 这里用“本帧推断”提前把占位高度降为 0，让动画从这一帧就开始。
    // 但是！如果 _pendingShowMorePanel == true，说明用户是点击更多按钮收起键盘，此时不应该收起到底部。
    final keyboardJustHiddenThisFrame = _lastViewInsetsBottom > 0 && viewInsetsBottom == 0;
    final collapsingByKeyboardHide = keyboardJustHiddenThisFrame && _expanded && !_showMorePanel && !_pendingShowMorePanel;

    // 计算底部面板高度：
    // 1. 键盘弹出时：直接使用当前键盘高度，确保同步
    // 2. 键盘未弹出但处于中部状态：使用记住的面板高度
    // 3. 收起到底部时：高度为 0
    final double panelBodyHeight;
    if (!_expanded || collapsingByKeyboardHide) {
      panelBodyHeight = 0.0;
    } else if (keyboardVisible) {
      // 键盘弹出时，直接使用键盘高度，保证同步
      panelBodyHeight = viewInsetsBottom;
    } else {
      // 键盘未弹出但在中部状态，使用记住的面板高度
      panelBodyHeight = _panelHeight;
    }

    return TapRegion(
      onTapOutside: (_) => _collapseToBottom(),
      child: Container(
        color: colors.surface,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 图片预览区域（如果有选中的图片）
            if (_selectedImagePath != null) _buildImagePreview(),

            // 文件预览区域（如果有选中的文件）
            if (_selectedFilePath != null) _buildFilePreview(),

            // 输入栏区域
            Container(
              decoration: BoxDecoration(
                color: colors.surface,
                border: Border(
                  top: BorderSide(color: colors.border, width: 1),
                ),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  // 更多按钮（加号）
                  _buildMoreButton(isActive: _expanded && (_showMorePanel || keyboardVisible)),
                  const SizedBox(width: 8),
                  // 输入框
                  Expanded(
                    child: Container(
                      constraints: const BoxConstraints(minHeight: 42),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
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
                        onTap: _onInputTap,
                        onSubmitted: (_) => _submit(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  // 发送按钮
                  _buildSendButton(),
                ],
              ),
            ),

            // 更多面板占位区域：始终在输入框下方，占位高度会记住键盘高度
            AnimatedContainer(
              duration: kAnimFast,
              curve: Curves.easeOutCubic,
              height: panelBodyHeight,
              decoration: BoxDecoration(
                color: colors.surface,
                border: Border(
                  top: BorderSide(color: colors.border.withValues(alpha: 0.6), width: 1),
                ),
              ),
              child: _showMorePanel ? _buildMorePanel() : const SizedBox.shrink(),
            ),

            // 统一处理底部 SafeArea（避免“输入栏 SafeArea”把面板顶出一条空隙）
            if (bottomSafe > 0) SizedBox(height: bottomSafe),
          ],
        ),
      ),
    );
  }

  void _handleKeyboardInsetsChanged(double newInsetsBottom) {
    final oldInsets = _lastViewInsetsBottom;
    _lastViewInsetsBottom = newInsetsBottom;

    // 键盘弹出：更新面板高度（记住最近一次键盘高度）
    if (newInsetsBottom > 0) {
      // 注意：viewInsets.bottom 通常不包含 SafeArea.bottom，SafeArea 由下面统一的 SizedBox 处理。
      // 同时：如果键盘高度发生变化（例如切换了输入法），我们更新高度以匹配键盘，
      // 保证“中部”位置就是键盘顶部位置，消除缝隙或错位。
      final candidate = math.max(200.0, newInsetsBottom);
      if ((candidate - _panelHeight).abs() > 1.0) {
        setState(() {
          _panelHeight = candidate;
        });
      }
      return;
    }

    // 键盘从"有"变为"无"
    final keyboardJustHidden = oldInsets > 0 && newInsetsBottom == 0;
    if (keyboardJustHidden && _expanded) {
      // 区分两种键盘收起场景：
      if (_pendingShowMorePanel) {
        // 场景1：用户点击了"更多"按钮收起键盘 -> 显示更多面板，输入框保持在中部
        setState(() {
          _showMorePanel = true;
          _pendingShowMorePanel = false;
        });
      } else if (!_showMorePanel) {
        // 场景2：用户点击键盘收起按钮 -> 收回输入框到底部
        _collapseToBottom();
      }
      // 如果 _showMorePanel 已经是 true，说明更多面板正在显示，键盘收起后继续显示更多面板即可
    }
  }

  void _collapseToBottom() {
    if (!_expanded && !_showMorePanel) return;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _expanded = false;
      _showMorePanel = false;
    });
  }

  void _onInputTap() {
    if (widget.disabled) return;
    if (!_expanded || _showMorePanel) {
      setState(() {
        _expanded = true;
        _showMorePanel = false;
      });
    }
  }

  void _onMorePressed() {
    if (widget.disabled) return;

    final keyboardVisible = MediaQuery.viewInsetsOf(context).bottom > 0;

    // 底部 -> 中部 + 打开更多面板
    if (!_expanded) {
      FocusManager.instance.primaryFocus?.unfocus();
      setState(() {
        _expanded = true;
        _showMorePanel = true;
      });
      return;
    }

    // 中部：键盘在上层、更多面板在下方占位
    if (keyboardVisible) {
      // 键盘弹出时点"更多"：收键盘，等键盘收起后展示更多面板
      // 设置 _pendingShowMorePanel 标记，让 _handleKeyboardInsetsChanged 知道这是"切换到更多面板"而非"收起到底部"
      _pendingShowMorePanel = true;
      FocusManager.instance.primaryFocus?.unfocus();
      // 不在这里设置 _showMorePanel = true，等键盘真正收起后再设置
      return;
    }

    // 键盘未弹出：在“更多面板 <-> 键盘”之间切换
    if (_showMorePanel) {
      setState(() {
        _showMorePanel = false;
      });
      _inputFocus.requestFocus();
    } else {
      FocusManager.instance.primaryFocus?.unfocus();
      setState(() {
        _showMorePanel = true;
      });
    }
  }

  Widget _buildMoreButton({required bool isActive}) {
    final colors = context.moeColors;

    return MoeG2ClipRRect(
      radius: 12,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: _onMorePressed,
          child: Container(
            width: 42,
            height: 42,
            decoration: MoeG2Decoration(
              radius: 12,
              color: isActive ? colors.surfaceAlt : colors.surfaceAlt.withValues(alpha: 0.6),
              border: Border.all(color: colors.borderLight, width: 0.5),
            ),
            child: Icon(
              Icons.add,
              color: colors.text,
              size: 22,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMorePanel() {
    final colors = context.moeColors;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 14, 12, 12),
      child: GridView.count(
        crossAxisCount: 4,
        physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        children: [
          _MoreActionTile(
            icon: Icons.tune,
            label: '模型',
            onTap: _openModelPicker,
          ),
          _MoreActionTile(
            icon: Icons.photo_library_outlined,
            label: '相册',
            onTap: () => _pickImage(ImageSource.gallery),
          ),
          _MoreActionTile(
            icon: Icons.photo_camera_outlined,
            label: '拍照',
            onTap: () => _pickImage(ImageSource.camera),
          ),
          _MoreActionTile(
            icon: Icons.attach_file,
            label: '文件',
            onTap: _pickFile,
          ),
        ],
      ),
    );
  }

  Future<void> _openModelPicker() async {
    final settings = ref.read(appSettingsProvider).valueOrNull;
    if (settings == null) {
      MoeToast.brief(context, '设置加载中，请稍后再试');
      return;
    }
    final colors = context.moeColors;

    final models = settings.modelList;
    if (models.isEmpty) {
      await showMeoTalkAlert(
        context: context,
        title: '无法选择模型',
        message: '当前没有可用模型，请先在设置里配置提供商和模型。',
      );
      return;
    }

    final currentModel = settings.defaultModelName;
    final selected = await showMoeBottomSheet<String>(
      context: context,
      title: '选择模型',
      builder: (sheetContext) {
        return ListView(
          children: [
            for (final model in models)
              MoeListTile(
                leading: Icon(
                  model == currentModel ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                  color: model == currentModel ? colors.primary : colors.muted,
                  size: 20,
                ),
                title: Text(
                  settings.modelDisplayNames[model]?.trim().isNotEmpty == true
                      ? settings.modelDisplayNames[model]!
                      : model,
                ),
                subtitle: settings.modelDisplayNames[model]?.trim().isNotEmpty == true
                    ? Text(model)
                    : null,
                trailing: model == currentModel ? Icon(Icons.check, color: colors.primary, size: 18) : null,
                selected: model == currentModel,
                onTap: () => Navigator.of(sheetContext).pop(model),
              ),
          ],
        );
      },
    );

    if (selected == null || selected.trim().isEmpty) return;
    if (selected == currentModel) return;

    await ref.read(appSettingsProvider.notifier).setDefaultModelName(selected);
    if (!mounted) return;
    MoeToast.success(context, '已切换默认模型：$selected');
  }

  Future<void> _pickImage(ImageSource source) async {
    try {
      final picker = ImagePicker();
      final xfile = await picker.pickImage(source: source, imageQuality: 92);
      if (xfile == null) return;

      setState(() {
        _selectedImagePath = xfile.path;
        _selectedFilePath = null;
        _selectedFileName = null;
        _selectedFileSizeBytes = null;
        _expanded = true;
        _showMorePanel = false;
      });

      _inputFocus.requestFocus();
    } catch (e) {
      if (!mounted) return;
      MoeToast.error(context, '选择图片失败：$e');
    }
  }

  static const _supportedTextFileExts = <String>{
    'txt',
    'md',
    'markdown',
    'json',
    'yaml',
    'yml',
    'csv',
    'log',
    'xml',
    'ini',
    'conf',
    'toml',
    // 常见代码文件（按纯文本处理）
    'dart',
    'py',
    'js',
    'ts',
    'java',
    'kt',
    'swift',
    'go',
    'rs',
    'c',
    'cpp',
    'h',
    'hpp',
    'html',
    'css',
    'sh',
  };

  Future<void> _pickFile() async {
    try {
      final settings = ref.read(appSettingsProvider).valueOrNull;
      final maxMb = settings?.maxFileUploadMB ?? 10;

      final result = await FilePicker.platform.pickFiles(withData: false);
      if (result == null || result.files.isEmpty) return;

      final file = result.files.first;
      final path = file.path;
      if (path == null || path.trim().isEmpty) {
        MoeToast.error(context, '读取文件路径失败');
        return;
      }

      final sizeBytes = file.size;
      if (sizeBytes > maxMb * 1024 * 1024) {
        await showMeoTalkAlert(
          context: context,
          title: '文件太大',
          message: '当前最大支持 ${maxMb}MB，已拦截发送。',
        );
        return;
      }

      final ext = (file.extension ?? p.extension(path).replaceFirst('.', '')).toLowerCase();
      if (ext.isNotEmpty && !_supportedTextFileExts.contains(ext)) {
        await showMeoTalkAlert(
          context: context,
          title: '暂不支持该文件',
          message: '目前仅支持 txt/md/json/csv 等纯文本文件；该格式将无法让 AI 正确读取。',
        );
        return;
      }

      setState(() {
        _selectedFilePath = path;
        _selectedFileName = file.name;
        _selectedFileSizeBytes = sizeBytes;
        _selectedImagePath = null;
        _expanded = true;
        _showMorePanel = false;
      });

      _inputFocus.requestFocus();
    } catch (e) {
      if (!mounted) return;
      MoeToast.error(context, '选择文件失败：$e');
    }
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
              MoeG2ClipRRect(
                radius: 8,
                child: Image.file(
                  File(_selectedImagePath!),
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
                    customBorder: const CircleBorder(),
                    child: Container(
                      width: 24,
                      height: 24,
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.6),
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
                    color: context.moeColors.text.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilePreview() {
    final colors = context.moeColors;
    final fileName = _selectedFileName ?? (_selectedFilePath != null ? p.basename(_selectedFilePath!) : '文件附件');
    final sizeText =
        _selectedFileSizeBytes != null ? _formatFileSize(_selectedFileSizeBytes!) : '未知大小';

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(
          top: BorderSide(color: colors.border, width: 1),
        ),
      ),
      child: Row(
        children: [
          Stack(
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
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: () {
                      setState(() {
                        _selectedFilePath = null;
                        _selectedFileName = null;
                        _selectedFileSizeBytes = null;
                      });
                    },
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
                ),
              ),
            ],
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  fileName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
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

  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '${bytes}B';
    final kb = bytes / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(1)}KB';
    final mb = kb / 1024;
    if (mb < 1024) return '${mb.toStringAsFixed(1)}MB';
    final gb = mb / 1024;
    return '${gb.toStringAsFixed(1)}GB';
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

class _MoreActionTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _MoreActionTile({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;

    return Material(
      color: Colors.transparent,
      child: MoeG2ClipRRect(
        radius: 14,
        child: InkWell(
          onTap: onTap,
          child: Container(
            decoration: MoeG2Decoration(
              radius: 14,
              color: colors.surfaceAlt,
              border: Border.all(color: colors.borderLight, width: 0.5),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 26, color: colors.text),
                const SizedBox(height: 8),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: colors.text,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
