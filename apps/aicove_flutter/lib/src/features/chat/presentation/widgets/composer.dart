/// 消息输入组件（使用 chat_bottom_container 实现平滑键盘/面板切换）
///
/// 更新记录：
/// - 2026-02-27: 停止生成前增加二次确认弹窗，避免误触中断
/// - 2025-12-06: 接入皮肤系统
/// - 2025-12-31: 拆分功能菜单和模型选择器到独立文件
/// - 2025-01-xx: 使用 chat_bottom_container 重构键盘/面板切换逻辑
/// - 2025-01-15: 拆分附件预览、更多面板、附件选择服务到独立文件
library;

import 'dart:async';
import 'package:aicove_flutter/src/ui/theme/moe_interaction_theme.dart';

import 'package:chat_bottom_container/chat_bottom_container.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/index.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import '../../../../core/services/attachment_picker_service.dart';
import '../../../../core/services/clipboard_attachment_service.dart';
import '../../../../ui/theme/tokens.dart';
import '../../../settings/app_settings.dart';
import '../../../dialogue_options/application/dialogue_options_providers.dart';
import '../../chat_actions.dart';
import '../../application/chat_edit.dart';
import '../../application/composer_draft_store.dart';
import '../../application/conversation_model.dart';
import '../../chat_layer_providers.dart';
import '../../conversation_providers.dart';
import '../../domain/conversation.dart';
import '../../domain/role_agent_mode.dart';
import '../../domain/quoted_reply.dart';
import '../../../stickers/sticker_registry.dart';
import 'composer_model_picker_sheet.dart';
import 'composer_more_panel.dart';
import 'composer_sticker_panel.dart';
import 'thinking_level_sheet.dart';
import '../../../../core/api/thinking/thinking_fallback.dart';
import '../../../../core/api/thinking/thinking_level_labels.dart';
import '../../../../core/api/providers/provider_adapter_factory.dart';
import '../../../../core/api/thinking/thinking_level_resolver.dart';
import '../../../agent_context/providers/preset_recipe_provider.dart';

export '../../application/composer_draft_store.dart'
    show
        composerLegacyDraftStorageKey,
        composerDraftStorageKey,
        composerDecodeDraftAttachment,
        composerResolveRestorableDraftAttachment;

part 'composer_view_parts.dart';
part 'composer_action_parts.dart';

/// 自定义底部面板类型
enum ComposerPanelType { none, keyboard, more, sticker }

/// 消息输入组件
class Composer extends ConsumerStatefulWidget {
  final bool disabled;
  final FutureOr<void> Function(String) onSend;

  /// False means the page did not accept the submission; retain its draft.
  final FutureOr<bool> Function(String)? onSubmitText;
  final FutureOr<bool> Function(String imagePath, {String? text})?
  onSubmitImage;
  final FutureOr<bool> Function(Sticker sticker)? onSubmitSticker;
  final FutureOr<void> Function()? onConfirmStagedSend;
  final FutureOr<void> Function(String imagePath, {String? text})?
  onImageSelected;
  final FutureOr<void> Function(String filePath, {String? text})?
  onFileSelected;
  final Future<void> Function(
    ChatEditDraft draft,
    String text,
    SelectedAttachment? attachment,
  )?
  onSubmitEdit;
  final ValueChanged<double>? onHeightChanged;
  final VoidCallback? onInputTap;

  /// 输入框占位文字，默认“消息”；通话打字模式下提示文字会进通话。
  final String? hintText;
  const Composer({
    super.key,
    required this.onSend,
    this.disabled = false,
    this.onImageSelected,
    this.onSubmitText,
    this.onSubmitImage,
    this.onSubmitSticker,
    this.onConfirmStagedSend,
    this.onFileSelected,
    this.onSubmitEdit,
    this.onHeightChanged,
    this.onInputTap,
    this.hintText,
  });

  @override
  ConsumerState<Composer> createState() => _ComposerState();
}

class _ComposerState extends ConsumerState<Composer> {
  static const Duration _kKeyboardInterruptGuard = Duration(milliseconds: 280);

  final _rootKey = GlobalKey();
  final _ctrl = TextEditingController();
  final _inputFocus = FocusNode();
  Timer? _draftSaveTimer;
  AppLifecycleListener? _appLifecycleListener;
  String? _draftConversationId;
  ChatEditDraft? _editDraft;
  bool _invalidEditDraft = false;
  bool _editSubmitting = false;
  int? _plainSubmittingEpoch;
  bool _draftLoading = false;
  int _editSeedSerial = 0;
  int _draftScopeEpoch = 0;
  Future<void> _draftWrites = Future<void>.value();

  // chat_bottom_container 控制器
  final _panelController =
      ChatBottomPanelContainerController<ComposerPanelType>();
  ComposerPanelType _currentPanelType = ComposerPanelType.none;

  // 记录键盘高度，用于更多面板的高度
  static const _defaultPanelHeight = 270.0;
  double _keyboardHeight = _defaultPanelHeight;
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
  bool _isInterruptingGeneration = false;

  // 选中的附件
  SelectedAttachment? _selectedAttachment;

  /// part 扩展里不能直接调用受保护的 setState。
  void _rebuild(VoidCallback fn) => setState(fn);

  bool _isCustomPanel(ComposerPanelType? type) =>
      type == ComposerPanelType.more || type == ComposerPanelType.sticker;

  @override
  void initState() {
    super.initState();
    // 桌面端焦点粘性保护：输入法（如语音输入）可能短暂抢走焦点，自动恢复
    if (!_supportsSoftKeyboardPanel) {
      _inputFocus.addListener(_onDesktopFocusChange);
      _inputFocus.onKeyEvent = _onDesktopInputKey;
    }
    // 监听输入变化，自动保存草稿
    _ctrl.addListener(_onTextChanged);
    _appLifecycleListener = AppLifecycleListener(
      onStateChange: (state) {
        switch (state) {
          case AppLifecycleState.inactive:
          case AppLifecycleState.hidden:
          case AppLifecycleState.paused:
          case AppLifecycleState.detached:
            _persistDraftImmediately();
            break;
          case AppLifecycleState.resumed:
            break;
        }
      },
    );
    // 延迟检查是否有待编辑的文本
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_syncDraftScope(forceReload: true));
      _checkEditingText();
      _checkRecalledAttachment();
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
      // 是我们主动调用 unfocus() 的，不恢复
      _intentionalUnfocus = false;
      return;
    }
    // 被动丢失焦点（如输入法抢走），短暂延迟后自动恢复
    Future.delayed(const Duration(milliseconds: 100), () {
      if (!mounted || widget.disabled) return;
      if (_inputFocus.hasFocus) return; // 已经自行恢复
      if (_intentionalUnfocus) return; // 期间有主动失焦操作

      // 更多面板正在显示（或即将显示）时，不恢复焦点
      // 否则 chat_bottom_container 的内部焦点监听器会把 requestFocus 解读为
      // "用户要打字了"，自动切到 keyboard 模式并关闭面板
      if (_isCustomPanel(_desiredPanelType) ||
          _isCustomPanel(_currentPanelType)) {
        return;
      }

      // 如果当前路由不在最上层（有弹窗/底部弹窗/新页面盖在上面），不抢焦点
      final route = ModalRoute.of(context);
      if (route != null && !route.isCurrent) return;

      // 如果焦点移到了另一个文本输入框，说明是用户主动点击，不抢焦点
      final primaryFocus = FocusManager.instance.primaryFocus;
      if (primaryFocus != null && primaryFocus.context != null) {
        final editableState = primaryFocus.context!
            .findAncestorStateOfType<EditableTextState>();
        if (editableState != null) return;
      }

      _inputFocus.requestFocus();
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

  void _checkRecalledAttachment() {
    final recalledAttachment = ref.read(recalledAttachmentProvider);
    if (recalledAttachment != null) {
      ref.read(recalledAttachmentProvider.notifier).state = null;
      unawaited(_setSelectedAttachment(recalledAttachment));
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
    _draftSaveTimer?.cancel();
    // 在controller释放前捕获快照，退出编辑不触碰历史。
    unawaited(
      _saveDraftSnapshot(
        scopeId: _draftConversationId,
      ).catchError((Object _) {}),
    );
    _appLifecycleListener?.dispose();
    _ctrl.removeListener(_onTextChanged);
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

  // MediaQuery 已由全局缩放容器换算到布局坐标；只有原生通道的高度需要换算。
  double _liveKeyboardInsetLayout(BuildContext context) {
    return MediaQuery.viewInsetsOf(context).bottom;
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
      final fixedHeight = liveInset > _anchorPanelHeight
          ? liveInset
          : _anchorPanelHeight;
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
    // Floating IMEs may report only a tiny candidate strip. Actions still
    // need a usable viewport, independent of that keyboard's docking height.
    final minimumHeight = (MediaQuery.sizeOf(context).height * 0.4).clamp(
      120.0,
      _defaultPanelHeight,
    );
    return _clampToSafeArea(resolved).clamp(minimumHeight, double.infinity);
  }

  bool get _supportsSoftKeyboardPanel {
    return switch (defaultTargetPlatform) {
      TargetPlatform.android || TargetPlatform.iOS => true,
      TargetPlatform.fuchsia ||
      TargetPlatform.linux ||
      TargetPlatform.macOS ||
      TargetPlatform.windows => false,
    };
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
      case ComposerPanelType.sticker:
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
          data: target,
          forceHandleFocus: ChatBottomHandleFocus.requestFocus,
        );
        if (_supportsSoftKeyboardPanel) {
          _armKeyboardGuard();
        }
      case ComposerPanelType.keyboard:
        await _performKeyboardTransition(explicitShow: intent.explicitShow);
    }
  }

  Future<void> _performKeyboardTransition({required bool explicitShow}) async {
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

    final fromMorePanel = _isCustomPanel(_currentPanelType);
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

  /// Agent 会话（ADR0112）：运行中的输入可以插话或排到这轮做完后。
  bool get _isAgentChat =>
      ref.read(activeConversationProvider)?.effectiveAgentMode ==
      RoleAgentMode.tool;

  /// Agent 会话的桌面按键，对照 Pi：Enter 发送／运行中插话，Option(Alt)+Enter
  /// 运行中排到做完后，Shift+Enter 换行，Option(Alt)+↑ 把排队的话放回输入框。
  /// 输入法组字中不拦截。聊天模式保持原样。
  KeyEventResult _onDesktopInputKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent ||
        !_isAgentChat ||
        _ctrl.value.composing.isValid) {
      return KeyEventResult.ignored;
    }
    final keyboard = HardwareKeyboard.instance;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowUp && keyboard.isAltPressed) {
      _restoreQueuedInputs();
      return KeyEventResult.handled;
    }
    if (key != LogicalKeyboardKey.enter &&
        key != LogicalKeyboardKey.numpadEnter) {
      return KeyEventResult.ignored;
    }
    if (keyboard.isShiftPressed ||
        keyboard.isControlPressed ||
        keyboard.isMetaPressed) {
      return KeyEventResult.ignored;
    }
    if (ref.read(sendingProvider)) {
      unawaited(_queueWhileRunning(steer: !keyboard.isAltPressed));
    } else if (!widget.disabled) {
      unawaited(_submit());
    }
    return KeyEventResult.handled;
  }

  void _onMorePressed() {
    if (widget.disabled) return;
    final pendingTarget = _pendingPanelIntent?.target;
    final isMoreOpen =
        _isCustomPanel(_currentPanelType) || _isCustomPanel(pendingTarget);
    if (isMoreOpen) {
      _showKeyboardDirect();
    } else {
      _requestPanelIntent(ComposerPanelType.more);
    }
  }

  void _handlePanelAction(ComposerAction action) {
    // PC端（桌面端）：先收起面板，然后直接执行操作
    // 移动端：模型选择器需要先收面板再弹窗，其余操作直接执行
    switch (action) {
      case ComposerAction.model:
        _openModelPickerFromMorePanel();
      case ComposerAction.thinking:
        _openThinkingLevelFromMorePanel();
      case ComposerAction.gallery:
        _pickImage(ImageSource.gallery);
      case ComposerAction.attachment:
        _pickAttachment();
      case ComposerAction.call:
        MoeToast.brief(context, '通话功能即将上线');
      case ComposerAction.sticker:
        _requestPanelIntent(ComposerPanelType.sticker);
    }
  }

  Future<void> _openModelPickerFromMorePanel() async {
    // PC端（桌面端）：直接弹出模型选择器，不先收面板
    // 原因：PC端的焦点恢复逻辑（_onDesktopFocusChange）和 chat_bottom_container
    // 的 inputFocusNodeListener 在面板收起后会产生竞争，导致 showMoeBottomSheet
    // 弹出后立即被关闭。在PC端直接弹窗可以避免这个问题
    if (!_supportsSoftKeyboardPanel) {
      _requestPanelIntent(ComposerPanelType.none);
      // 不等待动画，直接弹出（面板收起是瞬间的，因为 PC 端没有键盘面板高度过渡）
      if (!mounted) return;
      await _openModelPicker();
      return;
    }
    // 移动端：原有逻辑，先收面板等动画再弹窗
    _requestPanelIntent(ComposerPanelType.none);
    await Future<void>.delayed(kAnimFast);
    if (!mounted) return;
    await _openModelPicker();
  }

  Future<void> _openThinkingLevelFromMorePanel() async {
    _requestPanelIntent(ComposerPanelType.none);
    if (_supportsSoftKeyboardPanel) {
      await Future<void>.delayed(kAnimFast);
    }
    if (!mounted) return;
    await _openThinkingLevelPicker();
  }

  @override
  Widget build(BuildContext context) {
    final editOwner = ref.watch(
      activeConversationProvider.select((c) => c?.id),
    );
    if (editOwner != null) {
      ref.listen<DialogueOptionPick?>(dialogueOptionPickProvider(editOwner), (
        _,
        pick,
      ) {
        if (pick == null || _readCurrentConversationId() != editOwner) return;
        ref.read(dialogueOptionPickProvider(editOwner).notifier).state = null;
        if (_editDraft != null || widget.disabled) {
          MoeToast.brief(context, '请先完成当前编辑，再使用对话选项');
          return;
        }
        if (pick.signature != null) {
          ref.read(dialogueOptionsConsumedProvider(editOwner).notifier).state =
              pick.signature;
        }
        final text = pick.text;
        final draft = _ctrl.text;
        final next = draft.isEmpty ? text : '$draft\n$text';
        _ctrl.value = TextEditingValue(
          text: next,
          selection: TextSelection.collapsed(offset: next.length),
        );
      });
      ref.listen<ChatEditSeed?>(chatEditSeedProvider(editOwner), (_, seed) {
        if (seed != null) _applyEditSeed(seed);
      });
    }
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
    ref.listen<SelectedAttachment?>(recalledAttachmentProvider, (
      previous,
      next,
    ) {
      if (next != null) {
        ref.read(recalledAttachmentProvider.notifier).state = null;
        unawaited(_setSelectedAttachment(next));
        _showKeyboardWithPreAnimation();
      }
    });
    ref.listen<Conversation?>(activeConversationProvider, (previous, next) {
      final previousId = ComposerDraftStore.normalizeScopeId(previous?.id);
      final nextId = ComposerDraftStore.normalizeScopeId(next?.id);
      if (previousId == nextId) return;
      unawaited(_syncDraftScope());
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
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildStagedConfirmBubble(),
                _buildComposerGlassLayer(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_editDraft != null || _invalidEditDraft)
                        _buildEditBanner(),
                      _buildQueuedInputs(),
                      _buildQuotedMessagePreview(),
                      if (_selectedAttachment != null)
                        _buildAttachmentPreview(_selectedAttachment!),
                      _buildInputBar(),
                    ],
                  ),
                ),
                _buildPanelContainer(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Floating glass surface around the composer input row.
class ComposerGlassLayer extends StatelessWidget {
  const ComposerGlassLayer({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 4, 12, 14),
    child: MoeFloatingSurface(
      key: const ValueKey('composer-floating-surface'),
      child: child,
    ),
  );
}

/// Idle composer appearance without input state, for static reproductions of
/// the chat screen such as the long-image export.
class ComposerIdlePreview extends StatelessWidget {
  const ComposerIdlePreview({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    Widget icon(IconData data, Color color) => SizedBox.square(
      dimension: 42,
      child: Icon(data, color: color, size: 24),
    );
    return ComposerGlassLayer(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Row(
          children: [
            icon(Icons.add_rounded, colors.muted),
            const SizedBox(width: 2),
            Expanded(
              child: Container(
                constraints: const BoxConstraints(minHeight: 42),
                alignment: Alignment.centerLeft,
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                child: Text(
                  '消息',
                  style: TextStyle(
                    fontSize: 16,
                    height: 1.4,
                    color: colors.muted,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 2),
            icon(Icons.arrow_upward_rounded, colors.accentColor),
          ],
        ),
      ),
    );
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
