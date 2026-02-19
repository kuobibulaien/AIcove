/// 消息输入组件（使用 chat_bottom_container 实现平滑键盘/面板切换）
///
/// 更新记录：
/// - 2025-12-06: 接入皮肤系统
/// - 2025-12-31: 拆分功能菜单和模型选择器到独立文件
/// - 2025-01-xx: 使用 chat_bottom_container 重构键盘/面板切换逻辑
/// - 2025-01-15: 拆分附件预览、更多面板、附件选择服务到独立文件
library;

import 'dart:async';
import 'dart:ui' as ui;

import 'package:chat_bottom_container/chat_bottom_container.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import '../../../../core/services/attachment_picker_service.dart';
import '../../../../ui/theme/skin_provider.dart';
import '../../../../ui/theme/tokens.dart';
import '../../../../ui/shared/effects/smooth_clip.dart';
import '../../../../ui/shared/widgets/meotalk_dialog.dart';
import '../../../../ui/shared/widgets/moe_toast.dart';
import '../../../../ui/shared/widgets/sheets/moe_bottom_sheet.dart';
import '../../../../ui/shared/widgets/list/moe_list_tile.dart';
import '../../../../ui/shared/widgets/media/attachment_preview.dart';
import '../../../settings/app_settings.dart';
import '../../chat_actions.dart';
import 'composer_more_panel.dart';

/// 自定义底部面板类型
enum ComposerPanelType { none, keyboard, more }

/// 消息输入组件
class Composer extends ConsumerStatefulWidget {
  final bool disabled;
  final ValueChanged<String> onSend;
  final ValueChanged<String>? onImageSelected;
  final ValueChanged<String>? onFileSelected;
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

  // chat_bottom_container 控制器
  final _panelController =
      ChatBottomPanelContainerController<ComposerPanelType>();
  ComposerPanelType _currentPanelType = ComposerPanelType.none;

  // 记录键盘高度，用于更多面板的高度
  double _keyboardHeight = 270;
  bool _suppressKeyboard = false;
  int _keyboardShowRequestId = 0;

  // 选中的附件
  SelectedAttachment? _selectedAttachment;

  @override
  void initState() {
    super.initState();
    // 延迟检查是否有待编辑的文本
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkEditingText();
    });
  }

  /// 检查是否有待编辑的文本，如果有则填充到输入框
  void _checkEditingText() {
    final editingText = ref.read(editingTextProvider);
    if (editingText != null && editingText.isNotEmpty) {
      _ctrl.text = editingText;
      _ctrl.selection = TextSelection.fromPosition(
        TextPosition(offset: editingText.length),
      );
      // 清除编辑文本状态
      ref.read(editingTextProvider.notifier).state = null;
      _showKeyboardWithPreAnimation();
    }
  }

  @override
  void dispose() {
    _keyboardShowRequestId += 1;
    _ctrl.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  void _cancelPendingKeyboardShow() {
    _keyboardShowRequestId += 1;
  }

  double _resolvedKeyboardPanelHeight(BuildContext context) {
    final nativeHeight = _panelController.keyboardHeight;
    final resolved = nativeHeight > 0 ? nativeHeight : _keyboardHeight;
    final safeAreaBottom = _panelController.safeAreaBottom;
    final minHeight = safeAreaBottom > 0 ? safeAreaBottom : 0.0;
    return resolved >= minHeight ? resolved : minHeight;
  }

  Widget _buildComposerGlassLayer({required Widget child}) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final tint = isDark
        ? Colors.black.withValues(alpha: 0.18)
        : Colors.white.withValues(alpha: 0.22);

    return ClipRect(
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 22, sigmaY: 22),
        child: ColoredBox(color: tint, child: child),
      ),
    );
  }

  Future<void> _showKeyboardWithPreAnimation() async {
    if (!mounted || widget.disabled) return;

    _cancelPendingKeyboardShow();
    final requestId = _keyboardShowRequestId;

    // 键盘已弹出时不重复处理，避免闪烁/重置动画。
    final keyboardVisible = MediaQuery.viewInsetsOf(context).bottom > 0;
    if (keyboardVisible && !_suppressKeyboard) return;

    // 从“更多面板”回到键盘：底部高度已经到位，直接弹键盘即可。
    if (_currentPanelType == ComposerPanelType.more) {
      setState(() => _suppressKeyboard = false);
      _panelController.updatePanelType(ChatBottomPanelType.keyboard);
      _inputFocus.requestFocus();
      SystemChannels.textInput.invokeMethod('TextInput.show');
      return;
    }

    // 先走一次“像更多面板一样的展开动画”，再真正弹出系统键盘。
    setState(() => _suppressKeyboard = true);
    _panelController.updatePanelType(
      ChatBottomPanelType.other,
      data: ComposerPanelType.keyboard,
      forceHandleFocus: ChatBottomHandleFocus.requestFocus,
    );
    SystemChannels.textInput.invokeMethod('TextInput.hide');

    await Future.delayed(kAnimXFast);
    if (!mounted) return;
    if (requestId != _keyboardShowRequestId) return;

    setState(() => _suppressKeyboard = false);
    _panelController.updatePanelType(ChatBottomPanelType.keyboard);
    SystemChannels.textInput.invokeMethod('TextInput.show');
  }

  void _submit() {
    final attachment = _selectedAttachment;
    if (attachment != null) {
      if (attachment.type == AttachmentType.image &&
          widget.onImageSelected != null) {
        widget.onImageSelected!(attachment.path);
      } else if (attachment.type == AttachmentType.file) {
        if (widget.onFileSelected == null) {
          MoeToast.brief(context, '当前页面暂未接入文件发送');
          return;
        }
        widget.onFileSelected!(attachment.path);
      }
      setState(() => _selectedAttachment = null);
      _ctrl.clear();
      return;
    }

    final t = _ctrl.text.trim();
    if (t.isEmpty || widget.disabled) return;
    widget.onSend(t);
    _ctrl.clear();
  }

  void _hidePanel() {
    _inputFocus.unfocus();
    if (_currentPanelType == ComposerPanelType.none) return;
    _panelController.updatePanelType(ChatBottomPanelType.none);
  }

  void _onMorePressed() {
    if (widget.disabled) return;
    _cancelPendingKeyboardShow();
    if (_currentPanelType == ComposerPanelType.more) {
      setState(() => _suppressKeyboard = false);
      _panelController.updatePanelType(ChatBottomPanelType.keyboard);
      _inputFocus.requestFocus();
      SystemChannels.textInput.invokeMethod('TextInput.show');
      return;
    }

    // 更多面板：保持输入框焦点，但不弹出键盘（readOnly + TextInput.hide）
    setState(() => _suppressKeyboard = true);
    _panelController.updatePanelType(
      ChatBottomPanelType.other,
      data: ComposerPanelType.more,
      forceHandleFocus: ChatBottomHandleFocus.requestFocus,
    );
    SystemChannels.textInput.invokeMethod('TextInput.hide');
  }

  @override
  Widget build(BuildContext context) {
    // 监听编辑文本变化
    ref.listen<String?>(editingTextProvider, (previous, next) {
      if (next != null && next.isNotEmpty) {
        _ctrl.text = next;
        _ctrl.selection = TextSelection.fromPosition(
          TextPosition(offset: next.length),
        );
        ref.read(editingTextProvider.notifier).state = null;
        _showKeyboardWithPreAnimation();
      }
    });

    return _buildComposerGlassLayer(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 引用消息预览
          _buildQuotedMessagePreview(),
          if (_selectedAttachment?.type == AttachmentType.image)
            ImageAttachmentPreview(
              imagePath: _selectedAttachment!.path,
              onRemove: () => setState(() => _selectedAttachment = null),
            ),
          if (_selectedAttachment?.type == AttachmentType.file)
            FileAttachmentPreview(
              filePath: _selectedAttachment!.path,
              fileName: _selectedAttachment!.name,
              fileSizeBytes: _selectedAttachment!.sizeBytes,
              onRemove: () => setState(() => _selectedAttachment = null),
            ),
          _buildInputBar(),
          _buildPanelContainer(),
        ],
      ),
    );
  }

  Widget _buildInputBar() {
    final skin = context.skin;
    final colors = context.moeColors;
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final inputBgColor = isDark
        ? colors.panel.withValues(alpha: 0.78)
        : Colors.white.withValues(alpha: 0.86);
    final inputStyle = skin.inputDecoration(colors);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          _buildMoreButton(
              isActive: _currentPanelType != ComposerPanelType.none),
          const SizedBox(width: 8),
          Expanded(
            child: Container(
              constraints: const BoxConstraints(minHeight: 42),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: MoeG2Decoration(
                radius: skin.buttonRadius,
                color: Colors.transparent,
                border: inputStyle.border,
                boxShadow: inputStyle.boxShadow,
              ),
              child: TextField(
                controller: _ctrl,
                focusNode: _inputFocus,
                minLines: 1,
                maxLines: 4,
                style: const TextStyle(fontSize: 16, height: 1.5),
                readOnly: _suppressKeyboard,
                showCursor: !_suppressKeyboard,
                decoration: InputDecoration.collapsed(
                  hintText: '说点什么...',
                  hintStyle: TextStyle(color: colors.muted),
                ),
                enabled: !widget.disabled,
                onTap: () {
                  if (widget.disabled) return;
                  if (_suppressKeyboard) {
                    _cancelPendingKeyboardShow();
                    setState(() => _suppressKeyboard = false);
                    _panelController
                        .updatePanelType(ChatBottomPanelType.keyboard);
                    _inputFocus.requestFocus();
                    SystemChannels.textInput.invokeMethod('TextInput.show');
                    return;
                  }
                  _showKeyboardWithPreAnimation();
                },
                onSubmitted: (_) => _submit(),
              ),
            ),
          ),
          const SizedBox(width: 8),
          _buildSendButton(),
        ],
      ),
    );
  }

  /// 构建引用消息预览
  Widget _buildQuotedMessagePreview() {
    final quoted = ref.watch(quotedMessageProvider);
    if (quoted == null) return const SizedBox.shrink();

    final colors = context.moeColors;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.transparent,
        border: Border(top: BorderSide(color: colors.border, width: 0.5)),
      ),
      child: Row(
        children: [
          Container(
            width: 3,
            height: 32,
            decoration: MoeG2Decoration(
              radius: 2,
              color: colors.accentColor,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  quoted.isUser ? '回复 我' : '回复 TA',
                  style: TextStyle(
                    fontSize: 12,
                    color: colors.accentColor,
                    fontWeight: MoeFontWeights.emphasis,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  quoted.content,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    color: colors.muted,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: () => ref.read(quotedMessageProvider.notifier).state = null,
            child: Icon(Icons.close, size: 18, color: colors.muted),
          ),
        ],
      ),
    );
  }

  Widget _buildPanelContainer() {
    return ChatBottomPanelContainer<ComposerPanelType>(
      controller: _panelController,
      inputFocusNode: _inputFocus,
      // 自定义面板容器动画：统一“键盘/更多面板”的展开回收节奏。
      customPanelContainer: (panelType, data) {
        final Widget panel;
        if (panelType == ChatBottomPanelType.keyboard) {
          final nativeHeight = _panelController.keyboardHeight;
          if (nativeHeight > 0) _keyboardHeight = nativeHeight;
          final height = _resolvedKeyboardPanelHeight(context);
          panel = SizedBox(width: double.infinity, height: height);
        } else {
          panel = _panelController.buildInPanel(panelType) ??
              const SizedBox.shrink();
        }
        final duration = _panelController.isKeyboardHeightChangedByItself
            ? kAnimXFast
            : (panelType == ChatBottomPanelType.none ? kAnim : kAnimFast);
        final switchKey = switch (panelType) {
          ChatBottomPanelType.none => 'none',
          ChatBottomPanelType.keyboard => 'keyboard',
          ChatBottomPanelType.other => 'other:${data?.name ?? 'null'}',
        };
        return Container(
          color: Colors.transparent,
          child: AnimatedSize(
            alignment: Alignment.topCenter,
            duration: duration,
            curve: Curves.easeOutCubic,
            child: AnimatedSwitcher(
              duration: kAnimFast,
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              transitionBuilder: (child, animation) {
                return FadeTransition(opacity: animation, child: child);
              },
              layoutBuilder: (currentChild, previousChildren) {
                return Stack(
                  alignment: Alignment.topCenter,
                  children: [
                    for (final child in previousChildren)
                      Positioned.fill(child: child),
                    if (currentChild != null) currentChild,
                  ],
                );
              },
              child: KeyedSubtree(key: ValueKey(switchKey), child: panel),
            ),
          ),
        );
      },
      otherPanelWidget: (type) {
        if (type == null) return const SizedBox.shrink();
        final height = _resolvedKeyboardPanelHeight(context);
        if (type == ComposerPanelType.keyboard) {
          return SizedBox(height: height);
        }
        if (type != ComposerPanelType.more) return const SizedBox.shrink();
        return SizedBox(
            height: height,
            child: ComposerMorePanel(onAction: _handlePanelAction));
      },
      onPanelTypeChange: (panelType, data) {
        setState(() {
          switch (panelType) {
            case ChatBottomPanelType.none:
              _cancelPendingKeyboardShow();
              _currentPanelType = ComposerPanelType.none;
              _suppressKeyboard = false;
            case ChatBottomPanelType.keyboard:
              _currentPanelType = ComposerPanelType.keyboard;
              _suppressKeyboard = false;
            case ChatBottomPanelType.other:
              if (data == ComposerPanelType.more) {
                _currentPanelType = ComposerPanelType.more;
                _suppressKeyboard = true;
              } else if (data == ComposerPanelType.keyboard) {
                _currentPanelType = ComposerPanelType.keyboard;
                _suppressKeyboard = true;
              } else {
                _currentPanelType = ComposerPanelType.none;
                _suppressKeyboard = false;
              }
          }
        });
      },
      changeKeyboardPanelHeight: (height) {
        // 某些机型/输入法：`MediaQuery.viewInsets.bottom` 在键盘收起时会“先归零再慢慢动画”，
        // 导致输入栏先掉下去被键盘盖住。这里用插件回调的原生键盘高度兜底，保证输入栏始终贴着键盘。
        final nativeHeight = _panelController.keyboardHeight;
        final resolved = nativeHeight > 0 ? nativeHeight : height;
        if (resolved > 0) _keyboardHeight = resolved;
        return resolved;
      },
      panelBgColor: Colors.transparent,
    );
  }

  void _handlePanelAction(ComposerAction action) {
    switch (action) {
      case ComposerAction.model:
        _openModelPicker();
      case ComposerAction.gallery:
        _pickImage(ImageSource.gallery);
      case ComposerAction.camera:
        _pickImage(ImageSource.camera);
      case ComposerAction.file:
        _pickFile();
    }
  }

  Widget _buildMoreButton({required bool isActive}) {
    final colors = context.moeColors;
    return SizedBox(
      width: 42,
      height: 42,
      child: IconButton(
        onPressed: _onMorePressed,
        style: IconButton.styleFrom(
          padding: EdgeInsets.zero,
          shape: const CircleBorder(),
        ),
        icon: Icon(
          isActive ? Icons.close_rounded : Icons.add_rounded,
          color: isActive ? colors.accentColor : colors.muted,
          size: 24,
        ),
      ),
    );
  }

  Widget _buildSendButton() {
    final colors = context.moeColors;
    return SizedBox(
      width: 42,
      height: 42,
      child: IconButton(
        onPressed: widget.disabled ? null : _submit,
        style: IconButton.styleFrom(
          padding: EdgeInsets.zero,
          shape: const CircleBorder(),
        ),
        icon: Icon(
          Icons.arrow_upward_rounded,
          color: widget.disabled ? colors.muted : colors.accentColor,
          size: 24,
        ),
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
                  model == currentModel
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  color: model == currentModel ? colors.primary : colors.muted,
                  size: 20,
                ),
                title: Text(
                  settings.modelDisplayNames[model]?.trim().isNotEmpty == true
                      ? settings.modelDisplayNames[model]!
                      : model,
                ),
                subtitle:
                    settings.modelDisplayNames[model]?.trim().isNotEmpty == true
                        ? Text(model)
                        : null,
                trailing: model == currentModel
                    ? Icon(Icons.check, color: colors.primary, size: 18)
                    : null,
                selected: model == currentModel,
                onTap: () => Navigator.of(sheetContext).pop(model),
              ),
          ],
        );
      },
    );

    if (selected == null || selected.trim().isEmpty || selected == currentModel)
      return;
    await ref.read(appSettingsProvider.notifier).setDefaultModelName(selected);
    if (!mounted) return;
    MoeToast.success(context, '已切换默认模型：$selected');
  }

  Future<void> _pickImage(ImageSource source) async {
    final result = await AttachmentPickerService.pickImage(source);
    if (!mounted) return;

    switch (result) {
      case AttachmentPickSuccess(:final attachment):
        setState(() => _selectedAttachment = attachment);
        _showKeyboardWithPreAnimation();
      case AttachmentPickError(:final message):
        MoeToast.error(context, message);
      case _:
        break;
    }
  }

  Future<void> _pickFile() async {
    final settings = ref.read(appSettingsProvider).valueOrNull;
    final maxMb = settings?.maxFileUploadMB ?? 10;

    final result = await AttachmentPickerService.pickFile(maxMb: maxMb);
    if (!mounted) return;

    switch (result) {
      case AttachmentPickSuccess(:final attachment):
        setState(() => _selectedAttachment = attachment);
        _showKeyboardWithPreAnimation();
      case AttachmentFileTooLarge(:final maxMb):
        await showMeoTalkAlert(
          context: context,
          title: '文件太大',
          message: '当前最大支持 ${maxMb}MB，已拦截发送。',
        );
      case AttachmentUnsupportedType():
        await showMeoTalkAlert(
          context: context,
          title: '暂不支持该文件',
          message: '目前仅支持 txt/md/json/csv 等纯文本文件；该格式将无法让 AI 正确读取。',
        );
      case AttachmentPickError(:final message):
        MoeToast.error(context, message);
      case _:
        break;
    }
  }
}
