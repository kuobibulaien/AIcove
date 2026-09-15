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
import 'dart:convert';
import 'dart:io';

import 'package:aicove_flutter/src/ui/theme/moe_interaction_theme.dart';

import 'package:chat_bottom_container/chat_bottom_container.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/index.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../../../../core/services/attachment_picker_service.dart';
import '../../../../ui/theme/tokens.dart';
import '../../../../ui/shared/effects/smooth_clip.dart';
import '../../../settings/app_settings.dart';
import '../../chat_actions.dart';
import '../../application/chat_edit.dart';
import '../../chat_layer_providers.dart';
import '../../conversation_providers.dart';
import '../../domain/conversation.dart';
import 'composer_model_picker_sheet.dart';
import 'composer_more_panel.dart';
import 'thinking_level_sheet.dart';
import '../../../../core/api/thinking/thinking_level_labels.dart';
import '../../../../core/api/providers/provider_adapter_factory.dart';
import '../../../../core/api/thinking/thinking_level_resolver.dart';
import '../../../agent_context/providers/preset_recipe_provider.dart';

@visibleForTesting
const String composerLegacyDraftStorageKey = 'composer_draft_text';

const String _kComposerDraftKeyPrefix = 'composer_draft_v2:';
const int _kComposerDraftVersion = 1;
const String _kComposerDraftMediaDirectoryName = 'composer_drafts';

@visibleForTesting
String composerDraftStorageKey(String conversationId) =>
    '$_kComposerDraftKeyPrefix$conversationId';

@visibleForTesting
SelectedAttachment? composerDecodeDraftAttachment(dynamic rawAttachment) {
  if (rawAttachment is! Map) return null;

  final attachmentMap = Map<String, dynamic>.from(
    rawAttachment.cast<String, dynamic>(),
  );
  final path = (attachmentMap['path'] as String?)?.trim();
  if (path == null || path.isEmpty) return null;

  final typeName = (attachmentMap['type'] as String?)?.trim();
  final attachmentType = AttachmentType.values
      .where((candidate) => candidate.name == typeName)
      .firstOrNull;
  if (attachmentType == null) return null;

  return SelectedAttachment(
    path: path,
    name: attachmentMap['name'] as String?,
    sizeBytes: attachmentMap['sizeBytes'] as int?,
    type: attachmentType,
  );
}

@visibleForTesting
Future<SelectedAttachment?> composerResolveRestorableDraftAttachment(
  SelectedAttachment? attachment,
) async {
  if (attachment == null) return null;
  final path = attachment.path.trim();
  if (path.isEmpty) return null;
  try {
    final exists = await File(path).exists();
    if (!exists) return null;
    return attachment;
  } catch (_) {
    return null;
  }
}

/// 自定义底部面板类型
enum ComposerPanelType { none, keyboard, more }

/// 消息输入组件
class Composer extends ConsumerStatefulWidget {
  final bool disabled;
  final FutureOr<void> Function(String) onSend;
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
  const Composer({
    super.key,
    required this.onSend,
    this.disabled = false,
    this.onImageSelected,
    this.onFileSelected,
    this.onSubmitEdit,
    this.onHeightChanged,
    this.onInputTap,
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

  @override
  void initState() {
    super.initState();
    // 桌面端焦点粘性保护：输入法（如语音输入）可能短暂抢走焦点，自动恢复
    if (!_supportsSoftKeyboardPanel) {
      _inputFocus.addListener(_onDesktopFocusChange);
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
      if (_desiredPanelType == ComposerPanelType.more ||
          _currentPanelType == ComposerPanelType.more) {
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

  String? _normalizeDraftScopeId(String? scopeId) {
    final normalized = scopeId?.trim();
    if (normalized == null || normalized.isEmpty) return null;
    return normalized;
  }

  String _resolveDraftStorageKey(String? scopeId) {
    final normalizedScopeId = _normalizeDraftScopeId(scopeId);
    if (normalizedScopeId == null) {
      return composerLegacyDraftStorageKey;
    }
    return composerDraftStorageKey(normalizedScopeId);
  }

  String? _readCurrentConversationId() {
    return _normalizeDraftScopeId(ref.read(activeConversationProvider)?.id);
  }

  Future<void> _syncDraftScope({bool forceReload = false}) async {
    final nextScopeId = _readCurrentConversationId();
    final currentScopeId = _normalizeDraftScopeId(_draftConversationId);
    if (!forceReload && currentScopeId == nextScopeId) return;

    final epoch = ++_draftScopeEpoch;
    _draftSaveTimer?.cancel();
    final save = !forceReload && currentScopeId != null
        ? _saveDraftSnapshot(scopeId: currentScopeId)
        : Future<void>.value();
    _draftLoading = true;
    _draftConversationId = nextScopeId;
    if (mounted && !forceReload) {
      setState(() {
        _editDraft = null;
        _invalidEditDraft = false;
        _selectedAttachment = null;
        _ctrl.clear();
      });
    }
    try {
      await save;
      if (!mounted || epoch != _draftScopeEpoch) return;
      await _loadDraftSnapshot(scopeId: nextScopeId, replaceCurrent: true);
    } finally {
      if (mounted && epoch == _draftScopeEpoch) {
        setState(() => _draftLoading = false);
      }
    }
  }

  Future<_ComposerDraftSnapshot?> _readStoredDraftSnapshot(
    SharedPreferences prefs, {
    required String? scopeId,
  }) async {
    final draftKey = _resolveDraftStorageKey(scopeId);
    final scopedDraftRaw = prefs.getString(draftKey);
    if (scopedDraftRaw != null && scopedDraftRaw.isNotEmpty) {
      return _ComposerDraftSnapshot.fromStored(scopedDraftRaw);
    }

    if (draftKey == composerLegacyDraftStorageKey) {
      return null;
    }

    final legacyDraft = prefs.getString(composerLegacyDraftStorageKey);
    if (legacyDraft == null || legacyDraft.isEmpty) {
      return null;
    }

    final snapshot = _ComposerDraftSnapshot.fromStored(legacyDraft);
    if (snapshot == null) {
      await prefs.remove(composerLegacyDraftStorageKey);
      return null;
    }

    await prefs.setString(draftKey, snapshot.encode());
    await prefs.remove(composerLegacyDraftStorageKey);
    return snapshot;
  }

  Future<SelectedAttachment?> _resolveRestorableAttachment(
    SelectedAttachment? attachment,
  ) async {
    return composerResolveRestorableDraftAttachment(attachment);
  }

  void _applyDraftText(String text, {required bool replaceCurrent}) {
    if (!replaceCurrent && _ctrl.text.isNotEmpty) return;

    if (text.isEmpty) {
      if (replaceCurrent && _ctrl.text.isNotEmpty) {
        _ctrl.clear();
      }
      return;
    }

    if (_ctrl.text == text) return;
    _ctrl.text = text;
    _ctrl.selection = TextSelection.fromPosition(
      TextPosition(offset: text.length),
    );
  }

  bool _sameAttachment(SelectedAttachment? left, SelectedAttachment? right) {
    return left?.path == right?.path &&
        left?.type == right?.type &&
        left?.name == right?.name &&
        left?.sizeBytes == right?.sizeBytes;
  }

  Future<void> _loadDraftSnapshot({
    required String? scopeId,
    required bool replaceCurrent,
  }) async {
    final serial = _editSeedSerial;
    final epoch = _draftScopeEpoch;
    final prefs = await SharedPreferences.getInstance();
    final snapshot = await _readStoredDraftSnapshot(prefs, scopeId: scopeId);
    if (!mounted ||
        epoch != _draftScopeEpoch ||
        serial != _editSeedSerial ||
        scopeId != _readCurrentConversationId()) {
      return;
    }
    if (snapshot?.edit == null &&
        !(snapshot?.invalidEdit ?? false) &&
        (scopeId == null || ref.read(chatEditSeedProvider(scopeId)) == null)) {
      _applyDraftText(snapshot?.text ?? '', replaceCurrent: replaceCurrent);
    }
    final restoredAttachment = await _resolveRestorableAttachment(
      snapshot?.attachment,
    );
    if (!mounted ||
        epoch != _draftScopeEpoch ||
        serial != _editSeedSerial ||
        scopeId != _readCurrentConversationId()) {
      return;
    }
    final seed = scopeId == null
        ? null
        : ref.read(chatEditSeedProvider(scopeId));
    if (seed != null) {
      _applyEditSeed(seed);
      return;
    }
    setState(() {
      _editDraft = snapshot?.edit;
      _invalidEditDraft =
          (snapshot?.invalidEdit ?? false) ||
          (_editDraft != null &&
              (_editDraft!.conversationId != scopeId ||
                  (snapshot?.attachment != null &&
                      restoredAttachment == null)));
    });
    _applyDraftText(snapshot?.text ?? '', replaceCurrent: replaceCurrent);

    final shouldReplaceAttachment =
        replaceCurrent || _selectedAttachment == null;
    if (shouldReplaceAttachment &&
        !_sameAttachment(_selectedAttachment, restoredAttachment)) {
      setState(() => _selectedAttachment = restoredAttachment);
    }

    if (snapshot != null &&
        snapshot.edit == null &&
        !snapshot.invalidEdit &&
        snapshot.attachment != null &&
        restoredAttachment == null) {
      final sanitized = snapshot.copyWith(attachment: null);
      if (sanitized.isEmpty) {
        await prefs.remove(_resolveDraftStorageKey(scopeId));
      } else {
        await prefs.setString(
          _resolveDraftStorageKey(scopeId),
          sanitized.encode(),
        );
      }
    }
  }

  /// 输入变化时触发（带防抖保存草稿）
  void _onTextChanged() {
    if (_draftLoading) return;
    _scheduleDraftSave();
  }

  void _scheduleDraftSave() {
    _draftSaveTimer?.cancel();
    _draftSaveTimer = Timer(const Duration(milliseconds: 500), () {
      unawaited(
        _saveDraftSnapshot(
          scopeId: _draftConversationId,
        ).catchError((Object _) {}),
      );
    });
  }

  void _persistDraftImmediately() {
    _draftSaveTimer?.cancel();
    unawaited(
      _saveDraftSnapshot(
        scopeId: _draftConversationId,
      ).catchError((Object _) {}),
    );
  }

  /// 保存草稿到本地
  Future<void> _saveDraftSnapshot({String? scopeId}) {
    if (_draftLoading) return Future<void>.value();
    // await之前捕获owner及内容，串行写入防止旧保存覆盖取消/提交。
    final snapshot = _ComposerDraftSnapshot(
      text: _ctrl.text,
      attachment: _selectedAttachment,
      edit: _editDraft,
      invalidEdit: _invalidEditDraft,
    );
    final draftKey = _resolveDraftStorageKey(scopeId);
    final task = _draftWrites.then((_) async {
      final prefs = await SharedPreferences.getInstance();
      final ok = snapshot.isEmpty
          ? await prefs.remove(draftKey)
          : await prefs.setString(draftKey, snapshot.encode());
      if (!ok) throw StateError('草稿保存失败');
    });
    _draftWrites = task.catchError((Object _) {});
    return task;
  }

  /// 清除草稿（发送成功后调用）
  Future<void> _clearDraft({String? scopeId}) {
    final owner = scopeId ?? _draftConversationId;
    if (owner == _draftConversationId) _draftSaveTimer?.cancel();
    final key = _resolveDraftStorageKey(owner);
    final task = _draftWrites.then((_) async {
      final prefs = await SharedPreferences.getInstance();
      if (!await prefs.remove(key)) throw StateError('草稿清理失败');
    });
    _draftWrites = task.catchError((Object _) {});
    return task;
  }

  void _applyEditSeed(ChatEditSeed seed) {
    if (!mounted || _readCurrentConversationId() != seed.draft.conversationId) {
      return;
    }
    _editSeedSerial++;
    _draftLoading = false;
    _draftSaveTimer?.cancel();
    _draftConversationId = seed.draft.conversationId;
    ref.read(quotedMessageProvider.notifier).state = null;
    setState(() {
      _editDraft = seed.draft;
      _invalidEditDraft = false;
      _selectedAttachment = seed.attachment; // 包括null，清掉上一次的附件。
      _ctrl.text = seed.text; // 包括空串，纯图片编辑不能带上旧文本。
      _ctrl.selection = TextSelection.collapsed(offset: seed.text.length);
    });
    ref.read(chatEditSeedProvider(seed.draft.conversationId).notifier).state =
        null;
    unawaited(
      _saveDraftSnapshot(scopeId: seed.draft.conversationId).catchError((
        Object _,
      ) {
        if (mounted) MoeToast.error(context, '编辑草稿保存失败，原历史未改变');
      }),
    );
    _showKeyboardWithPreAnimation();
  }

  Future<void> _cancelEdit() async {
    if (_editSubmitting) return;
    final owner = _draftConversationId;
    _editSeedSerial++;
    setState(() {
      _editDraft = null;
      _invalidEditDraft = false;
      _selectedAttachment = null;
      _ctrl.clear();
    });
    try {
      await _clearDraft(scopeId: owner);
    } catch (_) {
      if (mounted) MoeToast.error(context, '草稿清理失败；原历史仍保留');
    }
  }

  Future<SelectedAttachment> _stabilizeAttachmentForDraft(
    SelectedAttachment attachment,
  ) async {
    if (attachment.type != AttachmentType.image) {
      return attachment;
    }

    final sourcePath = attachment.path.trim();
    if (sourcePath.isEmpty) {
      return attachment;
    }

    final sourceFile = File(sourcePath);
    if (!await sourceFile.exists()) {
      return attachment;
    }

    final rootDirectory = await getApplicationSupportDirectory();
    final draftDirectory = Directory(
      p.join(rootDirectory.path, _kComposerDraftMediaDirectoryName),
    );
    if (!await draftDirectory.exists()) {
      await draftDirectory.create(recursive: true);
    }

    final normalizedSourcePath = p.normalize(sourceFile.path);
    final normalizedDraftRoot = p.normalize(draftDirectory.path);
    if (normalizedSourcePath == normalizedDraftRoot ||
        p.isWithin(normalizedDraftRoot, normalizedSourcePath)) {
      return attachment;
    }

    final scopeId = _normalizeDraftScopeId(_draftConversationId) ?? 'global';
    final safeScopeId = scopeId.replaceAll(RegExp(r'[^a-zA-Z0-9_-]+'), '_');
    final extension = p.extension(normalizedSourcePath);
    final targetPath = p.join(
      draftDirectory.path,
      'draft_${safeScopeId}_${DateTime.now().millisecondsSinceEpoch}'
      '${extension.isNotEmpty ? extension : '.jpg'}',
    );

    try {
      await sourceFile.copy(targetPath);
      return SelectedAttachment(
        path: targetPath,
        name: attachment.name,
        sizeBytes: attachment.sizeBytes,
        type: attachment.type,
      );
    } catch (_) {
      return attachment;
    }
  }

  Future<void> _setSelectedAttachment(
    SelectedAttachment? attachment, {
    bool persistImmediately = true,
  }) async {
    if (_editSubmitting) return;
    final epoch = _draftScopeEpoch;
    final serial = _editSeedSerial;
    final nextAttachment = attachment == null
        ? null
        : await _stabilizeAttachmentForDraft(attachment);
    if (!mounted ||
        _editSubmitting ||
        epoch != _draftScopeEpoch ||
        serial != _editSeedSerial) {
      return;
    }
    if (_sameAttachment(_selectedAttachment, nextAttachment)) return;

    setState(() => _selectedAttachment = nextAttachment);
    if (persistImmediately) {
      _persistDraftImmediately();
    }
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

  Widget _buildComposerGlassLayer({required Widget child}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 14),
      child: MoeFloatingSurface(
        key: const ValueKey('composer-floating-surface'),
        child: child,
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
      if (_isInterruptingGeneration) return;
      final confirmed = await showMeoTalkConfirm(
        context: context,
        title: '停止生成？',
        message: '当前回复还在生成中，确认后将立即停止本次生成。',
        hint: '已生成的内容会保留，未生成部分不会继续输出。',
        cancelText: '继续生成',
        confirmText: '停止',
        isDanger: true,
      );
      if (!mounted || confirmed != true) return;
      if (!ref.read(sendingProvider)) return;
      setState(() => _isInterruptingGeneration = true);
      try {
        final stopped = await ref
            .read(chatActionsProvider)
            .interruptCurrentGeneration();
        if (!mounted) return;
        if (stopped) {
          MoeToast.brief(context, '已停止生成');
        }
      } finally {
        if (mounted) {
          setState(() => _isInterruptingGeneration = false);
        }
      }
      return;
    }

    await _submit();
  }

  Future<void> _submit() async {
    final attachment = _selectedAttachment;
    final text = _ctrl.text.trim();
    if (_editSubmitting || _draftLoading) return;
    if (_invalidEditDraft) {
      MoeToast.error(context, '编辑草稿或附件失效，请取消后重新编辑');
      return;
    }
    final edit = _editDraft;
    if (edit != null) {
      if (widget.disabled || (text.isEmpty && attachment == null)) return;
      if (widget.onSubmitEdit == null) {
        MoeToast.error(context, '当前页面不支持提交编辑');
        return;
      }
      setState(() => _editSubmitting = true);
      var locallyCommitted = false;
      try {
        await _saveDraftSnapshot(scopeId: edit.conversationId);
        await widget.onSubmitEdit!(edit, text, attachment);
        locallyCommitted = true;
        if (mounted &&
            _readCurrentConversationId() == edit.conversationId &&
            identical(_editDraft, edit)) {
          setState(() {
            _editDraft = null;
            _selectedAttachment = null;
            _ctrl.clear();
          });
        }
        await _clearDraft(scopeId: edit.conversationId);
      } catch (error) {
        if (mounted) {
          MoeToast.error(
            context,
            locallyCommitted
                ? '消息已提交，但草稿清理失败；再次进入时请取消旧草稿'
                : error is StateError
                ? error.message.toString()
                : '编辑提交失败，草稿已保留',
          );
        }
      } finally {
        if (mounted) setState(() => _editSubmitting = false);
      }
      return;
    }

    if (attachment != null) {
      if (attachment.type == AttachmentType.image &&
          widget.onImageSelected != null) {
        await widget.onImageSelected!(
          attachment.path,
          text: text.isNotEmpty ? text : null,
        );
      } else if (attachment.type == AttachmentType.file ||
          attachment.type == AttachmentType.audio ||
          attachment.type == AttachmentType.video) {
        if (widget.onFileSelected == null) {
          MoeToast.brief(context, '当前页面暂未接入文件发送');
          return;
        }
        await widget.onFileSelected!(
          attachment.path,
          text: text.isNotEmpty ? text : null,
        );
      }
      if (!mounted) return;
      setState(() => _selectedAttachment = null);
      _ctrl.clear();
      unawaited(_clearDraft());
      return;
    }

    if (text.isEmpty || widget.disabled) return;
    await widget.onSend(text);
    if (!mounted) return;
    _ctrl.clear();
    unawaited(_clearDraft());
  }

  void _onMorePressed() {
    if (widget.disabled) return;
    final pendingTarget = _pendingPanelIntent?.target;
    final isMoreOpen =
        _currentPanelType == ComposerPanelType.more ||
        pendingTarget == ComposerPanelType.more;
    if (isMoreOpen) {
      _showKeyboardDirect();
    } else {
      _requestPanelIntent(ComposerPanelType.more);
    }
  }

  @override
  Widget build(BuildContext context) {
    final editOwner = ref.watch(activeConversationProvider)?.id;
    if (editOwner != null) {
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
      final previousId = _normalizeDraftScopeId(previous?.id);
      final nextId = _normalizeDraftScopeId(next?.id);
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
                _buildComposerGlassLayer(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_editDraft != null || _invalidEditDraft)
                        Row(
                          children: [
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                _invalidEditDraft
                                    ? '编辑草稿失效，原历史未改变'
                                    : '发送后重新生成对话',
                                maxLines: 2,
                              ),
                            ),
                            TextButton(
                              key: const ValueKey('cancel_message_edit'),
                              onPressed: _editSubmitting ? null : _cancelEdit,
                              child: const Text('取消编辑'),
                            ),
                          ],
                        ),
                      _buildQuotedMessagePreview(),
                      if (_selectedAttachment?.type == AttachmentType.image)
                        ImageAttachmentPreview(
                          imagePath: _selectedAttachment!.path,
                          onRemove: () {
                            unawaited(_setSelectedAttachment(null));
                          },
                        ),
                      if (_selectedAttachment?.type == AttachmentType.file)
                        FileAttachmentPreview(
                          filePath: _selectedAttachment!.path,
                          fileName: _selectedAttachment!.name,
                          fileSizeBytes: _selectedAttachment!.sizeBytes,
                          leadingIcon: Icons.insert_drive_file_outlined,
                          onRemove: () {
                            unawaited(_setSelectedAttachment(null));
                          },
                        ),
                      if (_selectedAttachment?.type == AttachmentType.audio)
                        FileAttachmentPreview(
                          filePath: _selectedAttachment!.path,
                          fileName: _selectedAttachment!.name,
                          fileSizeBytes: _selectedAttachment!.sizeBytes,
                          leadingIcon: Icons.audiotrack_outlined,
                          onRemove: () {
                            unawaited(_setSelectedAttachment(null));
                          },
                        ),
                      if (_selectedAttachment?.type == AttachmentType.video)
                        FileAttachmentPreview(
                          filePath: _selectedAttachment!.path,
                          fileName: _selectedAttachment!.name,
                          fileSizeBytes: _selectedAttachment!.sizeBytes,
                          leadingIcon: Icons.movie_outlined,
                          onRemove: () {
                            unawaited(_setSelectedAttachment(null));
                          },
                        ),
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

  Widget _buildInputBar() {
    final colors = context.moeColors;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          _buildMoreButton(
            isActive: _currentPanelType == ComposerPanelType.more,
          ),
          const SizedBox(width: 2),
          Expanded(
            child: Container(
              constraints: const BoxConstraints(minHeight: 42),
              alignment: Alignment.centerLeft,
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
              child: TextField(
                controller: _ctrl,
                focusNode: _inputFocus,
                minLines: 1,
                maxLines: 4,
                textAlignVertical: TextAlignVertical.center,
                style: const TextStyle(fontSize: 16, height: 1.4),
                readOnly: _suppressKeyboard || _editSubmitting || _draftLoading,
                showCursor: !_suppressKeyboard,
                decoration: InputDecoration.collapsed(
                  hintText: '消息',
                  hintStyle: TextStyle(color: colors.muted),
                ).copyWith(visualDensity: VisualDensity.standard),
                enabled: !widget.disabled,
                onTap: () {
                  if (widget.disabled) return;
                  widget.onInputTap?.call();
                  final shouldExplicitShow =
                      _suppressKeyboard ||
                      _currentPanelType == ComposerPanelType.more;
                  _showKeyboardDirect(explicitShow: shouldExplicitShow);
                },
                onSubmitted: (_) => _onSendButtonPressed(),
              ),
            ),
          ),
          const SizedBox(width: 2),
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
            decoration: MoeG2Decoration(radius: 2, color: colors.accentColor),
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
                  style: TextStyle(fontSize: 13, color: colors.muted),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: () => ref.read(quotedMessageProvider.notifier).state = null,
            child: MoeButtonSurface(
              radius: 999,
              child: Icon(Icons.close, size: 18, color: colors.muted),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPanelContainer() {
    return ChatBottomPanelContainer<ComposerPanelType>(
      controller: _panelController,
      inputFocusNode: _inputFocus,
      // 自定义面板容器动画：统一“键盘↔更多面板”的展开回收节奏
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
          panel =
              _panelController.buildInPanel(panelType) ??
              const SizedBox.shrink();
        }
        final duration = _panelController.isKeyboardHeightChangedByItself
            ? kAnimXFast
            : (panelType == ChatBottomPanelType.none ? kAnim : kAnimFast);
        // Animate the panel height without applying group opacity to its
        // backdrop filter. Some Impeller backends reject that combination.
        return AnimatedSize(
          alignment: Alignment.topCenter,
          duration: duration,
          curve: Curves.easeOutCubic,
          child: panel,
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
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 14),
            child: MoeFloatingSurface(
              child: ComposerMorePanel(onAction: _handlePanelAction),
            ),
          ),
        );
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
    // PC端（桌面端）：先收起面板，然后直接执行操作
    // 移动端：模型选择器需要先收面板再弹窗，其余操作直接执行
    switch (action) {
      case ComposerAction.model:
        _openModelPickerFromMorePanel();
      case ComposerAction.thinking:
        _openThinkingLevelFromMorePanel();
      case ComposerAction.gallery:
        _pickImage(ImageSource.gallery);
      case ComposerAction.camera:
        _pickImage(ImageSource.camera);
      case ComposerAction.file:
        _pickFile();
      case ComposerAction.audio:
        _pickAudio();
      case ComposerAction.video:
        _pickVideo();
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

  /// 会话级思考档位：作用于当前会话 × 当前默认模型。
  Future<void> _openThinkingLevelPicker() async {
    final settings = ref.read(appSettingsProvider).valueOrNull;
    final conversation = ref.read(activeConversationProvider);
    if (settings == null || conversation == null) {
      MoeToast.brief(context, '设置加载中，请稍后再试');
      return;
    }
    final modelRef = settings.defaultModelName.trim();
    if (modelRef.isEmpty) {
      MoeToast.brief(context, '请先选择模型');
      return;
    }
    final providerId = settings.getModelProviderId(modelRef) ?? 'openai';
    final providerAuth = settings.providers
        .where((p) => p.id == providerId)
        .firstOrNull;
    final resolvedProvider = ProviderAdapterFactory.resolveProvider(
      providerId,
      customConfig: providerAuth?.customConfig,
      apiBaseUrl: providerAuth?.apiBaseUrl,
    );
    String? presetEffort;
    final recipeId = conversation.recipeId?.trim();
    if (recipeId != null && recipeId.isNotEmpty) {
      presetEffort = ref
          .read(presetRecipeProvider(recipeId))
          .valueOrNull
          ?.reasoningEffort;
    }
    final effective = resolveEffectiveThinkingLevel(
      providerType: resolvedProvider,
      modelId: settings.getRawModelId(modelRef),
      sessionLevel: conversation.thinkingLevels[modelRef],
      modelDefaultLevel: settings.getModelConfig(modelRef).thinkingLevel,
      presetReasoningEffort: presetEffort,
    );

    final result = await showThinkingLevelSheet(
      context,
      title: '思考档位 · ${settings.getModelDisplayName(modelRef)}',
      options: effective.options,
      current: effective.level,
      currentSource: effective.source,
      hasOwnSetting: conversation.thinkingLevels.containsKey(modelRef),
      clearLabel: '清除本会话设置，改用模型默认',
    );
    if (result == null || !mounted) return;

    await ref
        .read(conversationsProvider.notifier)
        .setConversationThinkingLevel(
          conversation.id,
          modelRef: modelRef,
          level: result.cleared ? null : result.level,
        );
    if (!mounted) return;
    MoeToast.success(
      context,
      result.cleared
          ? '已清除本会话的思考档位'
          : '本会话思考档位：${thinkingLevelTitle(result.level!, isNative: effective.options.isNative)}',
    );
  }

  Widget _buildMoreButton({required bool isActive}) {
    final colors = context.moeColors;
    return SizedBox(
      width: 42,
      height: 42,
      child: IconButton(
        onPressed: _onMorePressed,
        style: withoutHoverFeedback(
          IconButton.styleFrom(
            padding: EdgeInsets.zero,
            shape: const CircleBorder(),
          ),
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
    final isStopping = isGenerating && _isInterruptingGeneration;
    return SizedBox(
      width: 42,
      height: 42,
      child: IconButton(
        onPressed: (widget.disabled || isStopping)
            ? null
            : _onSendButtonPressed,
        tooltip: isStopping ? '正在停止' : (isGenerating ? '停止生成' : '发送'),
        style: withoutHoverFeedback(
          IconButton.styleFrom(
            padding: EdgeInsets.zero,
            shape: const CircleBorder(),
          ),
        ),
        icon: Icon(
          isStopping
              ? Icons.hourglass_top_rounded
              : (isGenerating
                    ? Icons.stop_rounded
                    : Icons.arrow_upward_rounded),
          color: (widget.disabled || isStopping)
              ? colors.muted
              : colors.accentColor,
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
    final models = loadedSettings.modelList;
    if (models.isEmpty) {
      await showMeoTalkAlert(
        context: context,
        title: '无法选择模型',
        message: '当前没有可用模型，请先在设置里配置提供商和模型。',
      );
      return;
    }

    final selected = await showComposerModelPickerSheet(context);
    if (selected == null || selected.trim().isEmpty) {
      return;
    }

    final latestSettings =
        ref.read(appSettingsProvider).valueOrNull ?? loadedSettings;
    if (selected == latestSettings.defaultModelName) {
      return;
    }

    await ref.read(appSettingsProvider.notifier).setDefaultModelName(selected);
    if (!mounted) return;
    final selectedLabel = latestSettings.getModelDisplayName(selected);
    final selectedProvider = latestSettings.getModelProviderId(selected);
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
        await _setSelectedAttachment(attachment);
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
        await _setSelectedAttachment(attachment);
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

  Future<void> _pickAudio() async {
    final settings = ref.read(appSettingsProvider).valueOrNull;
    final maxMb = settings?.maxFileUploadMB ?? 10;

    final result = await AttachmentPickerService.pickAudio(maxMb: maxMb);
    if (!mounted) return;

    switch (result) {
      case AttachmentPickSuccess(:final attachment):
        await _setSelectedAttachment(attachment);
        _showKeyboardWithPreAnimation();
      case AttachmentFileTooLarge(:final maxMb):
        await showMeoTalkAlert(
          context: context,
          title: '音频太大',
          message: '当前最大支持 ${maxMb}MB，已拦截发送。',
        );
      case AttachmentUnsupportedType():
        await showMeoTalkAlert(
          context: context,
          title: '暂不支持该音频',
          message: '目前仅支持 mp3/wav/m4a/ogg/opus 等常见音频格式。',
        );
      case AttachmentPickError(:final message):
        MoeToast.error(context, message);
      case _:
        break;
    }
  }

  Future<void> _pickVideo() async {
    final settings = ref.read(appSettingsProvider).valueOrNull;
    final maxMb = settings?.maxFileUploadMB ?? 10;

    final result = await AttachmentPickerService.pickVideo(maxMb: maxMb);
    if (!mounted) return;

    switch (result) {
      case AttachmentPickSuccess(:final attachment):
        await _setSelectedAttachment(attachment);
        _showKeyboardWithPreAnimation();
      case AttachmentFileTooLarge(:final maxMb):
        await showMeoTalkAlert(
          context: context,
          title: '视频太大',
          message: '当前最大支持 ${maxMb}MB，已拦截发送。',
        );
      case AttachmentUnsupportedType():
        await showMeoTalkAlert(
          context: context,
          title: '暂不支持该视频',
          message: '目前仅支持 mp4/mov/webm/mkv/avi 等常见视频格式。',
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

class _ComposerDraftSnapshot {
  final String text;
  final SelectedAttachment? attachment;
  final ChatEditDraft? edit;
  final bool invalidEdit;

  const _ComposerDraftSnapshot({
    required this.text,
    this.attachment,
    this.edit,
    this.invalidEdit = false,
  });

  bool get isEmpty =>
      text.isEmpty && attachment == null && edit == null && !invalidEdit;

  _ComposerDraftSnapshot copyWith({
    String? text,
    SelectedAttachment? attachment,
  }) {
    return _ComposerDraftSnapshot(
      text: text ?? this.text,
      attachment: attachment,
      edit: edit,
      invalidEdit: invalidEdit,
    );
  }

  String encode() {
    return jsonEncode(<String, Object?>{
      'version': _kComposerDraftVersion,
      'text': text,
      if (edit != null) 'edit': edit!.toJson(),
      if (invalidEdit) 'invalidEdit': true,
      if (attachment != null)
        'attachment': <String, Object?>{
          'path': attachment!.path,
          'name': attachment!.name,
          'sizeBytes': attachment!.sizeBytes,
          'type': attachment!.type.name,
        },
    });
  }

  static _ComposerDraftSnapshot? fromStored(String rawValue) {
    if (rawValue.isEmpty) return null;
    try {
      final decoded = jsonDecode(rawValue);
      if (decoded is! Map) {
        return _ComposerDraftSnapshot(text: rawValue);
      }
      final draftMap = Map<String, dynamic>.from(
        decoded.cast<String, dynamic>(),
      );
      final text = (draftMap['text'] as String?) ?? '';
      final attachment = _decodeAttachment(draftMap['attachment']);
      ChatEditDraft? edit;
      var invalid = draftMap['invalidEdit'] == true;
      if (draftMap.containsKey('edit')) {
        try {
          edit = ChatEditDraft.fromJson(
            Map<String, dynamic>.from(draftMap['edit'] as Map),
          );
        } catch (_) {
          invalid = true;
        }
      }
      return _ComposerDraftSnapshot(
        text: text,
        attachment: attachment,
        edit: edit,
        invalidEdit: invalid,
      );
    } catch (_) {
      // 结构化草稿损坏时禁止将原始JSON降级成普通聊天内容发送。
      return _ComposerDraftSnapshot(
        text: rawValue,
        invalidEdit: rawValue.trimLeft().startsWith('{'),
      );
    }
  }

  static SelectedAttachment? _decodeAttachment(dynamic rawAttachment) {
    return composerDecodeDraftAttachment(rawAttachment);
  }
}
