/// 消息输入组件（使�?chat_bottom_container 实现平滑键盘/面板切换�?
///
/// 更新记录�?
/// - 2025-12-06: 接入皮肤系统
/// - 2025-12-31: 拆分功能菜单和模型选择器到独立文件
/// - 2025-01-xx: 使用 chat_bottom_container 重构键盘/面板切换逻辑
/// - 2025-01-15: 拆分附件预览、更多面板、附件选择服务到独立文�?
library;

import 'dart:async';
import 'dart:ui' as ui;

import 'package:chat_bottom_container/chat_bottom_container.dart';
import 'package:flutter/foundation.dart';
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

/// 自定义底部面板类�?
enum ComposerPanelType { none, keyboard, more }

/// 消息输入组件
class Composer extends ConsumerStatefulWidget {
  final bool disabled;
  final ValueChanged<String> onSend;
  final void Function(String imagePath, {String? text})? onImageSelected;
  final ValueChanged<String>? onFileSelected;
  final ValueChanged<double>? onHeightChanged;
  const Composer({
    super.key,
    required this.onSend,
    this.disabled = false,
    this.onImageSelected,
    this.onFileSelected,
    this.onHeightChanged,
  });

  @override
  ConsumerState<Composer> createState() => _ComposerState();
}

class _ComposerState extends ConsumerState<Composer> {
  static const Duration _kKeyboardInterruptGuard = Duration(milliseconds: 280);

  final _rootKey = GlobalKey();
  final _ctrl = TextEditingController();
  final _inputFocus = FocusNode();

  // chat_bottom_container 控制�?
  final _panelController =
      ChatBottomPanelContainerController<ComposerPanelType>();
  ComposerPanelType _currentPanelType = ComposerPanelType.none;

  // 记录键盘高度，用于更多面板的高度
  double _keyboardHeight = 270;
  // 输入态锚点高度：用于“键盘 <-> 更多面板”切换时保持输入框不跳动
  double _anchorPanelHeight = 0;
  bool _holdPanelHeight = false;
  bool _suppressKeyboard = false;

  /// 桌面端焦点粘性保护：区分主动失焦和被动失焦（如输入法抢焦点）
  bool _intentionalUnfocus = false;
  ComposerPanelType _desiredPanelType = ComposerPanelType.none;
  _PanelIntent? _pendingPanelIntent;
  bool _isProcessingPanelIntent = false;
  bool _isKeyboardGuardActive = false;
  Timer? _keyboardGuardTimer;
  double _lastReportedHeight = -1;

  // 选中的附�?
  SelectedAttachment? _selectedAttachment;

  @override
  void initState() {
    super.initState();
    // 桌面端焦点粘性保护：输入法（如语音输入）可能短暂抢走焦点，自动恢�?
    if (!_supportsSoftKeyboardPanel) {
      _inputFocus.addListener(_onDesktopFocusChange);
    }
    // 延迟检查是否有待编辑的文本
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkEditingText();
      _reportHeightIfNeeded();
    });
  }

  @override
  void didUpdateWidget(covariant Composer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.onHeightChanged != oldWidget.onHeightChanged) {
      _lastReportedHeight = -1;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _reportHeightIfNeeded();
      });
    }
  }

  /// 桌面端焦点变化监听：检测被动失焦并自动恢复
  void _onDesktopFocusChange() {
    if (_inputFocus.hasFocus) {
      // 焦点回来了，重置标志
      _intentionalUnfocus = false;
      return;
    }
    // 焦点丢失
    if (_intentionalUnfocus) {
      // 是我们主动调�?unfocus() 的，不恢�?
      _intentionalUnfocus = false;
      return;
    }
    // 被动丢失焦点（如输入法抢走），短暂延迟后自动恢复
    Future.delayed(const Duration(milliseconds: 100), () {
      if (!mounted || widget.disabled) return;
      if (_inputFocus.hasFocus) return; // 已经自行恢复
      if (_intentionalUnfocus) return; // 期间有主动失焦操�?

      // 更多面板正在显示（或即将显示）时，不恢复焦点�?
      // 否则 chat_bottom_container 的内部焦点监听器会把 requestFocus 解读�?
      // "用户要打字了"，自动切�?keyboard 模式并关闭面板�?
      if (_desiredPanelType == ComposerPanelType.more ||
          _currentPanelType == ComposerPanelType.more) {
        return;
      }

      // 如果当前路由不在最上层（有弹窗/底部弹窗/新页面盖在上面），不抢焦�?
      final route = ModalRoute.of(context);
      if (route != null && !route.isCurrent) return;

      // 如果焦点移到了另一个文本输入框，说明是用户主动点击，不抢焦�?
      final primaryFocus = FocusManager.instance.primaryFocus;
      if (primaryFocus != null && primaryFocus.context != null) {
        final editableState =
            primaryFocus.context!.findAncestorStateOfType<EditableTextState>();
        if (editableState != null) return;
      }

      _inputFocus.requestFocus();
    });
  }

  /// 检查是否有待编辑的文本，如果有则填充到输入�?
  void _checkEditingText() {
    final editingText = ref.read(editingTextProvider);
    if (editingText != null && editingText.isNotEmpty) {
      _ctrl.text = editingText;
      _ctrl.selection = TextSelection.fromPosition(
        TextPosition(offset: editingText.length),
      );
      // 清除编辑文本状�?
      ref.read(editingTextProvider.notifier).state = null;
      _showKeyboardWithPreAnimation();
    }
  }

  void _reportHeightIfNeeded() {
    final onHeightChanged = widget.onHeightChanged;
    if (!mounted || onHeightChanged == null) return;

    final renderObject = _rootKey.currentContext?.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) return;

    final height = renderObject.size.height;
    if (!height.isFinite || height < 0) return;
    if ((height - _lastReportedHeight).abs() < 0.5) return;

    _lastReportedHeight = height;
    onHeightChanged(height);
  }

  @override
  void dispose() {
    _keyboardGuardTimer?.cancel();
    _inputFocus.removeListener(_onDesktopFocusChange);
    _ctrl.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  double _uiScaleFactor() {
    final settingsAsync = ref.read(appSettingsProvider);
    final rawScale = settingsAsync.maybeWhen(
      data: (settings) => settings.uiScaleFactor,
      orElse: () => 1.0,
    );
    return rawScale.clamp(kMinUiScaleFactor, kMaxUiScaleFactor).toDouble();
  }

  double _toLayoutHeight(double rawHeight) {
    if (rawHeight <= 0) return 0;
    final scale = _uiScaleFactor();
    if ((scale - 1.0).abs() < 0.001) return rawHeight;
    return rawHeight / scale;
  }

  double _liveKeyboardInsetLayout(BuildContext context) {
    return _toLayoutHeight(MediaQuery.viewInsetsOf(context).bottom);
  }

  double _nativeKeyboardHeightLayout() {
    return _toLayoutHeight(_panelController.keyboardHeight);
  }

  double _safeAreaBottomLayout() {
    return _toLayoutHeight(_panelController.safeAreaBottom);
  }

  double _clampToSafeArea(double height) {
    final safeAreaBottom = _safeAreaBottomLayout();
    return height >= safeAreaBottom ? height : safeAreaBottom;
  }

  void _capturePanelAnchor(BuildContext context) {
    final liveInset = _liveKeyboardInsetLayout(context);
    if (liveInset > 0) {
      _anchorPanelHeight = liveInset;
      _keyboardHeight = liveInset;
      return;
    }
    final nativeHeight = _nativeKeyboardHeightLayout();
    if (nativeHeight > 0) {
      _anchorPanelHeight = nativeHeight;
      _keyboardHeight = nativeHeight;
      return;
    }
    if (_keyboardHeight > 0) {
      _anchorPanelHeight = _keyboardHeight;
    }
  }

  double _keyboardPanelHeight(BuildContext context) {
    final liveInset = _liveKeyboardInsetLayout(context);

    // 从“更多面板”切回键盘时，先固定在锚点高度，等系统键盘高度追平后再释放。
    if (_holdPanelHeight && _anchorPanelHeight > 0) {
      final fixedHeight =
          liveInset > _anchorPanelHeight ? liveInset : _anchorPanelHeight;
      if (liveInset >= _anchorPanelHeight - 1) {
        _holdPanelHeight = false;
      }
      return _clampToSafeArea(fixedHeight);
    }

    if (liveInset > 0) {
      _keyboardHeight = liveInset;
      _anchorPanelHeight = liveInset;
      return _clampToSafeArea(liveInset);
    }

    // 键盘隐藏且输入框失焦时，回到底部待机态，避免卡在“中部”。
    if (!_inputFocus.hasFocus) {
      return _clampToSafeArea(0);
    }

    if (_holdPanelHeight && _anchorPanelHeight > 0) {
      return _clampToSafeArea(_anchorPanelHeight);
    }
    return _clampToSafeArea(0);
  }

  double _morePanelHeight(BuildContext context) {
    final liveInset = _liveKeyboardInsetLayout(context);
    // 当处于 hold 状态时（如键盘收起、切换到更多面板的过程中），
    // 不要让动画过程中逐渐减小的 liveInset 覆盖我们的目标高度锚点。
    if (liveInset > 0 && !_holdPanelHeight) {
      _keyboardHeight = liveInset;
      _anchorPanelHeight = liveInset;
    }
    final nativeHeight = _nativeKeyboardHeightLayout();
    final resolved = _anchorPanelHeight > 0
        ? _anchorPanelHeight
        : (nativeHeight > 0 ? nativeHeight : _keyboardHeight);
    if (resolved > 0) _keyboardHeight = resolved;
    return _clampToSafeArea(resolved);
  }

  bool get _supportsSoftKeyboardPanel {
    if (kIsWeb) return false;
    return switch (defaultTargetPlatform) {
      TargetPlatform.android || TargetPlatform.iOS => true,
      TargetPlatform.fuchsia ||
      TargetPlatform.linux ||
      TargetPlatform.macOS ||
      TargetPlatform.windows =>
        false,
    };
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

  void _showKeyboardWithPreAnimation() {
    _requestPanelIntent(
      ComposerPanelType.keyboard,
      preferPreAnimation: true,
      explicitShow: true,
    );
  }

  void _showKeyboardDirect({bool explicitShow = true}) {
    _requestPanelIntent(
      ComposerPanelType.keyboard,
      preferPreAnimation: false,
      explicitShow: explicitShow,
    );
  }

  void _requestPanelIntent(
    ComposerPanelType target, {
    bool preferPreAnimation = true,
    bool explicitShow = true,
  }) {
    if (!mounted) return;
    if (widget.disabled && target != ComposerPanelType.none) return;
    _desiredPanelType = target;
    _pendingPanelIntent = _PanelIntent(
      target: target,
      preferPreAnimation: preferPreAnimation,
      explicitShow: explicitShow,
    );
    _drainPanelIntents();
  }

  void _drainPanelIntents() {
    if (!mounted || _isProcessingPanelIntent || _isKeyboardGuardActive) return;

    final next = _pendingPanelIntent;
    if (next == null) return;

    _pendingPanelIntent = null;
    _isProcessingPanelIntent = true;
    _performPanelIntent(next).whenComplete(() {
      _isProcessingPanelIntent = false;
      _drainPanelIntents();
    });
  }

  void _armKeyboardGuard([Duration duration = _kKeyboardInterruptGuard]) {
    _isKeyboardGuardActive = true;
    _keyboardGuardTimer?.cancel();
    _keyboardGuardTimer = Timer(duration, () {
      _isKeyboardGuardActive = false;
      _drainPanelIntents();
    });
  }

  Future<void> _performPanelIntent(_PanelIntent intent) async {
    if (!mounted) return;
    final target = intent.target;
    if (widget.disabled && target != ComposerPanelType.none) return;

    switch (target) {
      case ComposerPanelType.none:
        _holdPanelHeight = false;
        _intentionalUnfocus = true;
        _inputFocus.unfocus();
        if (_currentPanelType != ComposerPanelType.none) {
          _panelController.updatePanelType(ChatBottomPanelType.none);
        }
        if (_suppressKeyboard) {
          setState(() => _suppressKeyboard = false);
        }
      case ComposerPanelType.more:
        _capturePanelAnchor(context);
        _holdPanelHeight = true;
        // 先设 readOnly 抑制键盘，再**立刻同步**切面板类型。
        // 两步在同一个同步调用链里完成，下一帧才真正重建，
        // 这样包的 onKeyboardHeightChange(0) 触发时 panelType 已经是 other，
        // 不会抢先把面板切成 none（消除竞争窗口）。
        if (!_suppressKeyboard) {
          setState(() => _suppressKeyboard = true);
        }
        _panelController.updatePanelType(
          ChatBottomPanelType.other,
          data: ComposerPanelType.more,
          forceHandleFocus: ChatBottomHandleFocus.requestFocus,
        );
        if (_supportsSoftKeyboardPanel) {
          _armKeyboardGuard();
        }
      case ComposerPanelType.keyboard:
        await _performKeyboardTransition(
          explicitShow: intent.explicitShow,
        );
    }
  }

  Future<void> _performKeyboardTransition({
    required bool explicitShow,
  }) async {
    if (!mounted || widget.disabled) return;

    if (!_supportsSoftKeyboardPanel) {
      if (_suppressKeyboard) {
        setState(() => _suppressKeyboard = false);
      }
      if (_currentPanelType != ComposerPanelType.none) {
        _panelController.updatePanelType(ChatBottomPanelType.none);
      }
      _holdPanelHeight = false;
      _desiredPanelType = ComposerPanelType.none;
      _inputFocus.requestFocus();
      return;
    }

    final keyboardVisible = MediaQuery.viewInsetsOf(context).bottom > 0;
    if (keyboardVisible &&
        !_suppressKeyboard &&
        _currentPanelType == ComposerPanelType.keyboard) {
      return;
    }

    final fromMorePanel = _currentPanelType == ComposerPanelType.more;
    if (fromMorePanel) {
      _capturePanelAnchor(context);
      _holdPanelHeight = true;
    } else {
      _holdPanelHeight = false;
    }
    final shouldSyncReadOnly = _suppressKeyboard;
    if (shouldSyncReadOnly) {
      setState(() => _suppressKeyboard = false);
    }
    if (shouldSyncReadOnly) {
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || _desiredPanelType != ComposerPanelType.keyboard) return;
    }
    _panelController.updatePanelType(ChatBottomPanelType.keyboard);
    _inputFocus.requestFocus();
    if (explicitShow || fromMorePanel) {
      await SystemChannels.textInput.invokeMethod('TextInput.show');
    }
    _armKeyboardGuard();
  }

  Future<void> _onSendButtonPressed() async {
    if (widget.disabled) return;

    final isGenerating = ref.read(sendingProvider);
    if (isGenerating) {
      final shouldStop = await showMeoTalkConfirm(
        context: context,
        title: '停止生成',
        message: '当前消息还在生成中，确认停止吗？',
        hint: '停止后，本次尚未完成的回复不会继续显示。',
        cancelText: '继续生成',
        confirmText: '停止',
        isDanger: true,
      );
      if (!mounted || shouldStop != true) return;

      final stopped =
          await ref.read(chatActionsProvider).interruptCurrentGeneration();
      if (!mounted) return;
      if (stopped) {
        MoeToast.brief(context, '已停止生成');
      }
      return;
    }

    _submit();
  }

  void _submit() {
    final attachment = _selectedAttachment;
    final text = _ctrl.text.trim();

    if (attachment != null) {
      if (attachment.type == AttachmentType.image &&
          widget.onImageSelected != null) {
        widget.onImageSelected!(
          attachment.path,
          text: text.isNotEmpty ? text : null,
        );
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

    if (text.isEmpty || widget.disabled) return;
    widget.onSend(text);
    _ctrl.clear();
  }

  void _onMorePressed() {
    if (widget.disabled) return;
    final pendingTarget = _pendingPanelIntent?.target;
    final isMoreOpen = _currentPanelType == ComposerPanelType.more ||
        pendingTarget == ComposerPanelType.more;
    if (isMoreOpen) {
      _showKeyboardDirect();
    } else {
      _requestPanelIntent(ComposerPanelType.more);
    }
  }

  @override
  Widget build(BuildContext context) {
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

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _reportHeightIfNeeded();
    });

    return NotificationListener<SizeChangedLayoutNotification>(
      onNotification: (_) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _reportHeightIfNeeded();
        });
        return false;
      },
      child: SizeChangedLayoutNotifier(
        child: Container(
          key: _rootKey,
          child: TextFieldTapRegion(
            child: _buildComposerGlassLayer(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildQuotedMessagePreview(),
                  if (_selectedAttachment?.type == AttachmentType.image)
                    ImageAttachmentPreview(
                      imagePath: _selectedAttachment!.path,
                      onRemove: () =>
                          setState(() => _selectedAttachment = null),
                    ),
                  if (_selectedAttachment?.type == AttachmentType.file)
                    FileAttachmentPreview(
                      filePath: _selectedAttachment!.path,
                      fileName: _selectedAttachment!.name,
                      fileSizeBytes: _selectedAttachment!.sizeBytes,
                      onRemove: () =>
                          setState(() => _selectedAttachment = null),
                    ),
                  _buildInputBar(),
                  _buildPanelContainer(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildInputBar() {
    final skin = context.skin;
    final colors = context.moeColors;
    final inputStyle = skin.inputDecoration(colors);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          _buildMoreButton(
              isActive: _currentPanelType == ComposerPanelType.more),
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
                  final shouldExplicitShow = _suppressKeyboard ||
                      _currentPanelType == ComposerPanelType.more;
                  _showKeyboardDirect(explicitShow: shouldExplicitShow);
                },
                onSubmitted: (_) => _onSendButtonPressed(),
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
      // 自定义面板容器动画：统一“键�?更多面板”的展开回收节奏�?
      customPanelContainer: (panelType, data) {
        final Widget panel;
        if (panelType == ChatBottomPanelType.keyboard) {
          if (_supportsSoftKeyboardPanel) {
            final height = _keyboardPanelHeight(context);
            panel = SizedBox(width: double.infinity, height: height);
          } else {
            panel = const SizedBox.shrink();
          }
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
        final height = _morePanelHeight(context);
        if (type == ComposerPanelType.keyboard) {
          if (!_supportsSoftKeyboardPanel) return const SizedBox.shrink();
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
              _currentPanelType = ComposerPanelType.none;
              final switchingToMore =
                  _desiredPanelType == ComposerPanelType.more ||
                      _pendingPanelIntent?.target == ComposerPanelType.more;
              if (!switchingToMore) {
                _suppressKeyboard = false;
                _holdPanelHeight = false;
              }
            case ChatBottomPanelType.keyboard:
              _currentPanelType = ComposerPanelType.keyboard;
              _suppressKeyboard = false;
            case ChatBottomPanelType.other:
              if (data == ComposerPanelType.more) {
                _currentPanelType = ComposerPanelType.more;
                _suppressKeyboard = true;
                _holdPanelHeight = true;
              } else if (data == ComposerPanelType.keyboard) {
                _currentPanelType = ComposerPanelType.keyboard;
                _suppressKeyboard = true;
                _holdPanelHeight = true;
              } else {
                _currentPanelType = ComposerPanelType.none;
                _suppressKeyboard = false;
                _holdPanelHeight = false;
              }
          }

          if (_pendingPanelIntent == null && !_isProcessingPanelIntent) {
            _desiredPanelType = _currentPanelType;
          }
        });
      },
      changeKeyboardPanelHeight: (height) {
        final liveHeight = _toLayoutHeight(height);
        if (liveHeight > 0) {
          _keyboardHeight = liveHeight;
          if (!_holdPanelHeight || liveHeight >= _anchorPanelHeight) {
            _anchorPanelHeight = liveHeight;
          }
          final effectiveHeight = _holdPanelHeight && _anchorPanelHeight > 0
              ? (liveHeight > _anchorPanelHeight
                  ? liveHeight
                  : _anchorPanelHeight)
              : liveHeight;
          return _clampToSafeArea(effectiveHeight);
        }
        if (_holdPanelHeight && _anchorPanelHeight > 0) {
          return _clampToSafeArea(_anchorPanelHeight);
        }
        return _clampToSafeArea(0);
      },
      panelBgColor: Colors.transparent,
    );
  }

  void _handlePanelAction(ComposerAction action) {
    // PC端（桌面端）：先收起面板，然后直接执行操�?
    // 移动端：模型选择器需要先收面板再弹窗，其余操作直接执�?
    switch (action) {
      case ComposerAction.model:
        _openModelPickerFromMorePanel();
      case ComposerAction.gallery:
        _pickImage(ImageSource.gallery);
      case ComposerAction.camera:
        _pickImage(ImageSource.camera);
      case ComposerAction.file:
        _pickFile();
    }
  }

  Future<void> _openModelPickerFromMorePanel() async {
    // PC端（桌面端）：直接弹出模型选择器，不先收面�?
    // 原因：PC端的焦点恢复逻辑（_onDesktopFocusChange）和 chat_bottom_container
    // �?inputFocusNodeListener 在面板收起后会产生竞争，导致 showMoeBottomSheet
    // 弹出后立即被关闭。在PC端直接弹窗可以避免这个问题�?
    if (!_supportsSoftKeyboardPanel) {
      _requestPanelIntent(ComposerPanelType.none);
      // 不等待动画，直接弹出（面板收起是瞬间的，因为 PC 端没有键盘面板高度过渡）
      if (!mounted) return;
      await _openModelPicker();
      return;
    }
    // 移动端：原有逻辑，先收面板等动画再弹�?
    _requestPanelIntent(ComposerPanelType.none);
    await Future<void>.delayed(kAnimFast);
    if (!mounted) return;
    await _openModelPicker();
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
    final isGenerating = ref.watch(sendingProvider);
    return SizedBox(
      width: 42,
      height: 42,
      child: IconButton(
        onPressed: widget.disabled ? null : _onSendButtonPressed,
        tooltip: isGenerating ? '停止生成' : '发送',
        style: IconButton.styleFrom(
          padding: EdgeInsets.zero,
          shape: const CircleBorder(),
        ),
        icon: Icon(
          isGenerating ? Icons.pause_rounded : Icons.arrow_upward_rounded,
          color: widget.disabled ? colors.muted : colors.accentColor,
          size: 24,
        ),
      ),
    );
  }

  Future<void> _openModelPicker() async {
    var settings = ref.read(appSettingsProvider).valueOrNull;
    if (settings == null) {
      try {
        settings = await ref.read(appSettingsProvider.future);
      } catch (_) {}
    }
    if (!mounted) return;
    if (settings == null) {
      MoeToast.brief(context, '设置加载中，请稍后再试');
      return;
    }
    final loadedSettings = settings;
    final colors = context.moeColors;
    final models = loadedSettings.modelList;
    if (models.isEmpty) {
      await showMeoTalkAlert(
        context: context,
        title: '无法选择模型',
        message: '当前没有可用模型，请先在设置里配置提供商和模型。',
      );
      return;
    }

    final currentModel = loadedSettings.defaultModelName;
    final selected = await showMoeBottomSheet<String>(
      context: context,
      title: '选择模型',
      useRootNavigator: true,
      builder: (sheetContext) {
        return ListView(
          children: [
            for (final model in models)
              Builder(
                builder: (_) {
                  final modelId = loadedSettings.getRawModelId(model);
                  final displayName = loadedSettings.getModelDisplayName(model);
                  final providerId = loadedSettings.getModelProviderId(model);
                  // 优先显示供应商的显示名称，而非技�?ID
                  final providerLabel = providerId != null
                      ? loadedSettings.providers
                              .where((p) => p.id == providerId)
                              .map((p) => p.displayName ?? p.id)
                              .firstOrNull ??
                          providerId
                      : null;
                  final subtitleParts = <String>[
                    if (providerLabel != null && providerLabel.isNotEmpty)
                      providerLabel,
                    if (displayName != modelId) modelId,
                  ];
                  return MoeListTile(
                    leading: Icon(
                      model == currentModel
                          ? Icons.radio_button_checked
                          : Icons.radio_button_unchecked,
                      color:
                          model == currentModel ? colors.primary : colors.muted,
                      size: 20,
                    ),
                    title: Text(displayName),
                    subtitle: subtitleParts.isEmpty
                        ? null
                        : Text(subtitleParts.join(' / ')),
                    trailing: model == currentModel
                        ? Icon(Icons.check, color: colors.primary, size: 18)
                        : null,
                    selected: model == currentModel,
                    onTap: () => Navigator.of(sheetContext).pop(model),
                  );
                },
              ),
          ],
        );
      },
    );

    if (selected == null ||
        selected.trim().isEmpty ||
        selected == currentModel) {
      return;
    }
    await ref.read(appSettingsProvider.notifier).setDefaultModelName(selected);
    if (!mounted) return;
    final selectedLabel = loadedSettings.getModelDisplayName(selected);
    final selectedProvider = loadedSettings.getModelProviderId(selected);
    final summary = selectedProvider == null || selectedProvider.isEmpty
        ? selectedLabel
        : '$selectedLabel ($selectedProvider)';
    MoeToast.success(context, '已切换默认模型：$summary');
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
          message: '目前仅支持 txt/md/json/csv 等纯文本文件；该格式无法让 AI 正确读取。',
        );
      case AttachmentPickError(:final message):
        MoeToast.error(context, message);
      case _:
        break;
    }
  }
}

class _PanelIntent {
  final ComposerPanelType target;
  final bool preferPreAnimation;
  final bool explicitShow;

  const _PanelIntent({
    required this.target,
    required this.preferPreAnimation,
    required this.explicitShow,
  });
}
