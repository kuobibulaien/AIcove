part of 'composer.dart';

/// 输入框动作：草稿绑定与恢复、发送与插话、思考档位、模型选择、图片与附件选择。
extension _ComposerActionParts on _ComposerState {
  String? _readCurrentConversationId() {
    return ComposerDraftStore.normalizeScopeId(
      ref.read(activeConversationProvider)?.id,
    );
  }

  Future<void> _syncDraftScope({bool forceReload = false}) async {
    final nextScopeId = _readCurrentConversationId();
    final currentScopeId = ComposerDraftStore.normalizeScopeId(
      _draftConversationId,
    );
    if (!forceReload && currentScopeId == nextScopeId) return;

    final epoch = ++_draftScopeEpoch;
    _draftSaveTimer?.cancel();
    final save = !forceReload && currentScopeId != null
        ? _saveDraftSnapshot(scopeId: currentScopeId)
        : Future<void>.value();
    _draftLoading = true;
    _draftConversationId = nextScopeId;
    if (mounted && !forceReload) {
      _rebuild(() {
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
        _rebuild(() => _draftLoading = false);
      }
    }
  }

  Future<SelectedAttachment?> _resolveRestorableAttachment(
    SelectedAttachment? attachment,
  ) async {
    return ComposerDraftStore.resolveRestorableAttachment(attachment);
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
    final snapshot = await ComposerDraftStore.read(scopeId: scopeId);
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
    _rebuild(() {
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
      _rebuild(() => _selectedAttachment = restoredAttachment);
    }

    if (snapshot != null &&
        snapshot.edit == null &&
        !snapshot.invalidEdit &&
        snapshot.attachment != null &&
        restoredAttachment == null) {
      final sanitized = snapshot.copyWith(attachment: null);
      await ComposerDraftStore.write(scopeId, sanitized);
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
    final snapshot = ComposerDraftSnapshot(
      text: _ctrl.text,
      attachment: _selectedAttachment,
      edit: _editDraft,
      invalidEdit: _invalidEditDraft,
    );
    final task = _draftWrites.then((_) async {
      final ok = await ComposerDraftStore.write(scopeId, snapshot);
      if (!ok) throw StateError('草稿保存失败');
    });
    _draftWrites = task.catchError((Object _) {});
    return task;
  }

  /// 清除草稿（发送成功后调用）
  Future<void> _clearDraft({String? scopeId}) {
    final owner = scopeId ?? _draftConversationId;
    if (owner == _draftConversationId) _draftSaveTimer?.cancel();
    final task = _draftWrites.then((_) async {
      if (!await ComposerDraftStore.clear(owner)) throw StateError('草稿清理失败');
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
    _rebuild(() {
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
    _rebuild(() {
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

  Future<void> _setSelectedAttachment(
    SelectedAttachment? attachment, {
    bool persistImmediately = true,
  }) async {
    if (_editSubmitting) return;
    final epoch = _draftScopeEpoch;
    final serial = _editSeedSerial;
    final nextAttachment = attachment == null
        ? null
        : await ComposerDraftStore.stabilizeAttachment(
            attachment,
            scopeId: _draftConversationId,
          );
    if (!mounted ||
        _editSubmitting ||
        epoch != _draftScopeEpoch ||
        serial != _editSeedSerial) {
      return;
    }
    if (_sameAttachment(_selectedAttachment, nextAttachment)) return;

    _rebuild(() => _selectedAttachment = nextAttachment);
    if (persistImmediately) {
      _persistDraftImmediately();
    }
  }

  bool get _isInputCurrentlyActive => _inputFocus.hasFocus;

  void _keepInputActiveAfterSend(
    bool wasInputActive, {
    required int scopeEpoch,
    required String? scopeId,
  }) {
    if (!wasInputActive ||
        !mounted ||
        widget.disabled ||
        _intentionalUnfocus ||
        scopeEpoch != _draftScopeEpoch ||
        scopeId != _readCurrentConversationId() ||
        _isCustomPanel(_desiredPanelType) ||
        _isCustomPanel(_currentPanelType)) {
      return;
    }
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return;
    final primaryFocus = FocusManager.instance.primaryFocus;
    if (primaryFocus != null &&
        primaryFocus != _inputFocus &&
        primaryFocus.context?.findAncestorStateOfType<EditableTextState>() !=
            null) {
      return;
    }
    if (!_inputFocus.hasFocus) {
      _inputFocus.requestFocus();
    }
  }

  Future<void> _onConfirmStagedPressed() async {
    if (widget.disabled || ref.read(sendingProvider)) return;
    final wasInputActive = _isInputCurrentlyActive;
    final scopeEpoch = _draftScopeEpoch;
    final scopeId = _readCurrentConversationId();
    final confirm = widget.onConfirmStagedSend;
    if (confirm != null) {
      await confirm();
    } else {
      await ref.read(chatActionsProvider).confirmStagedMessages();
    }
    _keepInputActiveAfterSend(
      wasInputActive,
      scopeEpoch: scopeEpoch,
      scopeId: scopeId,
    );
  }

  /// 把输入框里的文字排进正在运行的 Agent；运行恰好已结束时按普通发送。
  Future<void> _queueWhileRunning({required bool steer}) async {
    final text = _ctrl.text.trim();
    if (text.isEmpty) return;
    if (_editDraft != null || _selectedAttachment != null) {
      MoeToast.brief(context, '运行中只能插入文字，附件和编辑请等这轮做完');
      return;
    }
    final wasInputActive = _isInputCurrentlyActive;
    final scopeEpoch = _draftScopeEpoch;
    final scopeId = _readCurrentConversationId();
    final quoted = ref.read(quotedMessageProvider);
    final composed = quoted == null
        ? text
        : QuotedReply.compose(quotedContent: quoted.content, text: text);
    final queued = ref
        .read(chatActionsProvider)
        .queueWhileRunning(composed, steer: steer);
    if (!queued) {
      await _submit();
      return;
    }
    if (quoted != null) ref.read(quotedMessageProvider.notifier).state = null;
    _ctrl.clear();
    _keepInputActiveAfterSend(
      wasInputActive,
      scopeEpoch: scopeEpoch,
      scopeId: scopeId,
    );
    unawaited(_clearDraft(scopeId: scopeId));
  }

  /// 未发出和排队中的话放回输入框，排在已有草稿前面。编辑旧消息时不放，
  /// 免得混进编辑内容。
  void _restoreQueuedInputs() {
    final convId = _readCurrentConversationId();
    // 草稿还在加载时放回，会被随后加载的草稿覆盖。
    if (convId == null || _draftLoading) return;
    if (_editDraft != null) {
      MoeToast.brief(context, '正在编辑旧消息，结束编辑后再放回');
      return;
    }
    final restored = ref.read(chatActionsProvider).takeQueuedInputs(convId);
    if (restored.isEmpty) return;
    final current = _ctrl.text.trim();
    final merged = [...restored, if (current.isNotEmpty) current].join('\n');
    _ctrl.value = TextEditingValue(
      text: merged,
      selection: TextSelection.collapsed(offset: merged.length),
    );
    _inputFocus.requestFocus();
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
      _rebuild(() => _isInterruptingGeneration = true);
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
          _rebuild(() => _isInterruptingGeneration = false);
        }
      }
      return;
    }

    await _submit();
  }

  Future<void> _submit() async {
    final wasInputActive = _isInputCurrentlyActive;
    final attachment = _selectedAttachment;
    final draftText = _ctrl.text;
    final text = draftText.trim();
    final scopeId = _readCurrentConversationId();
    final scopeEpoch = _draftScopeEpoch;
    if (_editSubmitting ||
        _plainSubmittingEpoch == scopeEpoch ||
        _draftLoading) {
      return;
    }
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
      _rebuild(() => _editSubmitting = true);
      var locallyCommitted = false;
      try {
        await _saveDraftSnapshot(scopeId: edit.conversationId);
        await widget.onSubmitEdit!(edit, text, attachment);
        locallyCommitted = true;
        if (mounted &&
            _readCurrentConversationId() == edit.conversationId &&
            identical(_editDraft, edit)) {
          _rebuild(() {
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
        if (mounted) _rebuild(() => _editSubmitting = false);
      }
      return;
    }

    bool draftUnchanged() =>
        mounted &&
        _draftScopeEpoch == scopeEpoch &&
        _readCurrentConversationId() == scopeId &&
        _ctrl.text == draftText &&
        identical(_selectedAttachment, attachment);

    _plainSubmittingEpoch = scopeEpoch;
    try {
      if (attachment != null) {
        if (attachment.type == AttachmentType.image) {
          final submit = widget.onSubmitImage;
          if (submit != null) {
            final accepted = await submit(
              attachment.path,
              text: text.isEmpty ? null : text,
            );
            if (!accepted) return;
          } else if (widget.onImageSelected != null) {
            await widget.onImageSelected!(
              attachment.path,
              text: text.isEmpty ? null : text,
            );
          } else {
            return;
          }
        } else {
          if (widget.onFileSelected == null) {
            MoeToast.brief(context, '当前页面暂未接入文件发送');
            return;
          }
          await widget.onFileSelected!(
            attachment.path,
            text: text.isEmpty ? null : text,
          );
        }
        if (!draftUnchanged()) return;
        _rebuild(() => _selectedAttachment = null);
      } else {
        if (text.isEmpty || widget.disabled) return;
        final submit = widget.onSubmitText;
        if (submit != null) {
          // 同步放行时不挂起，输入框在点击发送的同一帧清空。
          final result = submit(text);
          final accepted = result is bool ? result : await result;
          if (!accepted) return;
        } else {
          await widget.onSend(text);
        }
        if (!draftUnchanged()) return;
      }
      _ctrl.clear();
      _keepInputActiveAfterSend(
        wasInputActive,
        scopeEpoch: scopeEpoch,
        scopeId: scopeId,
      );
      unawaited(_clearDraft(scopeId: scopeId));
    } finally {
      if (_plainSubmittingEpoch == scopeEpoch) _plainSubmittingEpoch = null;
    }
  }

  /// 会话级思考档位：作用于当前会话 × 本会话当前使用的模型。
  Future<void> _openThinkingLevelPicker() async {
    final settings = ref.read(appSettingsProvider).valueOrNull;
    final conversation = ref.read(activeConversationProvider);
    if (settings == null || conversation == null) {
      MoeToast.brief(context, '设置加载中，请稍后再试');
      return;
    }
    final modelRef = conversationPrimaryModel(settings, conversation).trim();
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

    final modelFullId = '$providerId:${settings.getRawModelId(modelRef)}';
    final lowestResolved = effective.level.isLowest
        ? await ThinkingFallbackMemory.instance.recall(modelFullId)
        : null;
    if (!mounted) return;

    final result = await showThinkingLevelSheet(
      context,
      title: '思考档位 · ${settings.getModelDisplayName(modelRef)}',
      options: effective.options,
      current: effective.level,
      currentSource: effective.source,
      hasOwnSetting: conversation.thinkingLevels.containsKey(modelRef),
      clearLabel: '清除本会话设置，改用模型默认',
      lowestResolved: lowestResolved,
    );
    if (result == null || !mounted) return;
    if (result.redetect) {
      await ThinkingFallbackMemory.instance.forget(modelFullId);
      if (!mounted) return;
      MoeToast.success(context, '已清除，下次发送时重新检测最低档');
      return;
    }

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

    final conversation = ref.read(activeConversationProvider);
    if (conversation == null) return;
    final rawSessionModel = conversation.sessionProvider?.trim();
    final selection = await showComposerModelPickerSheet(
      context,
      sessionModel: (rawSessionModel?.isEmpty ?? true) ? null : rawSessionModel,
    );
    if (selection == null || !mounted) return;

    final latestSettings =
        ref.read(appSettingsProvider).valueOrNull ?? loadedSettings;
    // 写回打开弹窗时的那个会话；比较库里的原值，失效的选择也要能清掉。
    final stored =
        (ref.read(conversationSnapshotByIdProvider(conversation.id)) ??
                conversation)
            .sessionProvider
            ?.trim();
    final selected = selection.modelRef;
    if (selected == ((stored?.isEmpty ?? true) ? null : stored)) return;

    await ref
        .read(conversationsProvider.notifier)
        .setConversationModel(conversation.id, selected);
    if (!mounted) return;
    if (selected == null) {
      MoeToast.success(context, '本会话已改为跟随默认模型');
      return;
    }
    final selectedLabel = latestSettings.getModelDisplayName(selected);
    final selectedProviderId = latestSettings.getModelProviderId(selected);
    final selectedProviderName =
        selectedProviderId == null || selectedProviderId.isEmpty
            ? ''
            : latestSettings.getProviderDisplayName(selectedProviderId);
    final summary = selectedProviderName.isEmpty
        ? selectedLabel
        : '$selectedLabel ($selectedProviderName)';
    MoeToast.success(context, '本会话模型：$summary');
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

  Future<void> _pickAttachment() async {
    final settings = ref.read(appSettingsProvider).valueOrNull;
    final maxMb = settings?.maxFileUploadMB ?? 10;

    final result = await AttachmentPickerService.pickAttachment(maxMb: maxMb);
    if (!mounted) return;
    await _applyAttachmentResult(result);
  }

  /// 粘贴：剪贴板里有文件或图片就放进附件，否则交回默认的文字粘贴。
  Future<void> _pasteFromClipboard(VoidCallback pasteText) async {
    if (widget.disabled ||
        _suppressKeyboard ||
        _editSubmitting ||
        _draftLoading) {
      return;
    }
    final settings = ref.read(appSettingsProvider).valueOrNull;
    final maxMb = settings?.maxFileUploadMB ?? 10;
    final scopeId = _draftConversationId;
    final result = await ClipboardAttachmentService.read(maxMb: maxMb);
    // 读剪贴板期间切了会话就作废，免得贴进别的会话。
    if (!mounted || _draftConversationId != scopeId) return;
    if (result == null) {
      pasteText();
      return;
    }
    await _applyAttachmentResult(result);
  }

  /// 安卓输入法（如剪贴板栏、表情键盘）直接插入的图片。
  Future<void> _onKeyboardContentInserted(
    KeyboardInsertedContent content,
  ) async {
    final data = content.data;
    if (widget.disabled || data == null || data.isEmpty) return;
    final settings = ref.read(appSettingsProvider).valueOrNull;
    final scopeId = _draftConversationId;
    final result = await ClipboardAttachmentService.saveImage(
      data,
      maxMb: settings?.maxFileUploadMB ?? 10,
    );
    if (!mounted || _draftConversationId != scopeId) return;
    await _applyAttachmentResult(result);
  }

  Future<void> _applyAttachmentResult(AttachmentPickResult result) async {
    switch (result) {
      case AttachmentPickSuccess(:final attachment):
        await _setSelectedAttachment(attachment);
        _showKeyboardWithPreAnimation();
      case AttachmentFileTooLarge(:final maxMb):
        await showMeoTalkAlert(
          context: context,
          title: '附件太大',
          message: '当前最大支持 ${maxMb}MB，已拦截发送。',
        );
      case AttachmentUnsupportedType():
        await showMeoTalkAlert(
          context: context,
          title: '暂不支持该附件',
          message:
              '目前支持 txt/md/json/csv 等纯文本、mp3/wav/m4a 等音频、mp4/mov/webm 等视频及常见图片。',
        );
      case AttachmentPickError(:final message):
        MoeToast.error(context, message);
      case _:
        break;
    }
  }

  Future<void> _handleStickerSelected(Sticker sticker) async {
    if (widget.disabled || _editSubmitting || _draftLoading) return;
    if (_editDraft != null || _invalidEditDraft) {
      MoeToast.brief(context, '请先完成或取消当前消息编辑');
      return;
    }
    final submit = widget.onSubmitSticker;
    if (submit == null) return;
    final accepted = await submit(sticker);
    if (accepted && mounted) {
      _requestPanelIntent(ComposerPanelType.none);
    }
  }
}

/// 接管输入框的粘贴快捷键，没有附件内容时回到默认的文字粘贴。
class _ComposerPasteAction extends Action<PasteTextIntent> {
  _ComposerPasteAction(this.state);

  final _ComposerState state;

  @override
  Object? invoke(PasteTextIntent intent) {
    // callingAction 只在本次调用期间有效，异步前先取出。
    final fallback = callingAction;
    unawaited(state._pasteFromClipboard(() => fallback?.invoke(intent)));
    return null;
  }
}
