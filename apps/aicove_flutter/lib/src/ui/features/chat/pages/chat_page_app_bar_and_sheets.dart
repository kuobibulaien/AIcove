part of 'chat_page.dart';

/// Header, selection toolbar, conversation menu, message list/composer wiring
/// and the confirmation dialogs of the chat page.
extension _ChatPageAppBarAndSheets on _ChatPageState {
  void _openCharacterSettings(Conversation conv) => MoeWorkspace.open(
    context,
    ContactEditPage(
      conversation: conv,
      initialSnapshot: ContactEditSnapshot.fromConversation(conv),
      editMode: EditMode.editConversation,
    ),
  );

  Future<bool> _confirmAction(String title, String message) async =>
      await showMeoTalkDialog(
        context: context,
        useRootNavigator: false,
        title: title,
        content: Text(message),
        cancelText: '取消',
        confirmText: '确定',
        isDanger: true,
      ) ==
      true;

  Future<void> _deleteSelected(Conversation conv) async {
    final ids = _selection.selectedMessages
        .map((message) => message.id)
        .toList();
    if (ids.isEmpty || _selectionBusy) return;
    if (!await _confirmAction(
          '删除消息',
          '删除选中的 ${ids.length} 条消息？仅从聊天界面隐藏，不影响原始历史和模型上下文。',
        ) ||
        !mounted) {
      return;
    }
    _updateState(() => _selectionBusy = true);
    try {
      await ref
          .read(chatPageConversationActionsProvider)
          .hideMessages(conv.id, ids);
      if (mounted) _selection.clear();
    } catch (_) {
      if (mounted) MoeToast.error(context, '删除失败，请重试');
    } finally {
      if (mounted) _updateState(() => _selectionBusy = false);
    }
  }

  Future<void> _showShareSheet(Conversation conv) async {
    final messages = List<Message>.of(_selection.selectedMessages);
    final chatSize = context.size ?? MediaQuery.sizeOf(context);
    final background = ChatWallpaperLayer.forConversation(
      conversation: conv,
      fallbackColor: resolveChatBackgroundColor(
        context,
        ref.read(appSettingsProvider).valueOrNull?.lightChatBackground,
      ),
    );
    final height = MediaQuery.sizeOf(context).height * 0.85;
    final exported = await showMoeBottomSheet<String>(
      context: context,
      title: '分享',
      showCloseButton: true,
      maxHeight: height,
      builder: (sheetContext) => ChatShareSheet(
        onExport: () => Navigator.of(sheetContext).pop('export'),
        onSend: (id, note) => ref
            .read(chatActionsProvider)
            .forwardMessages(
              conversationId: id,
              sourceTitle: conv.displayName,
              messages: messages,
              note: note,
            ),
      ),
    );
    if (!mounted) return;
    if (exported == 'sent') {
      _selection.clear();
      MoeToast.show(context, '已分享');
      return;
    }
    if (exported != 'export') return;
    MoeWorkspace.open(
      context,
      ChatImageExportPage(
        messages: messages,
        title: conv.displayName,
        avatarUrl: conv.avatarUrl,
        characterImage: conv.characterImage,
        background: background,
        chatSize: chatSize,
        showBackButton: MoeWorkspace.showsBackButton(context),
        documentStyle:
            ref
                .read(
                  chatDisplayPolicyProvider((
                    conv.effectiveDisplayStyle,
                    conv.chunkOverride,
                  )),
                )
                .style ==
            ChatDisplayStyle.document,
      ),
    );
  }

  void _measureAssistantPanel(bool visible) =>
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final box = _assistantPanelKey.currentContext?.findRenderObject();
        final height = visible && box is RenderBox ? box.size.height : 0.0;
        if ((height - _assistantPanelHeight).abs() >= 0.5) {
          _updateState(() => _assistantPanelHeight = height);
        }
      });

  Widget _buildAssistantPanel(bool visible) {
    _measureAssistantPanel(visible);
    if (!visible) return const SizedBox.shrink();
    // Cards come and go inside the panel without rebuilding this page.
    return NotificationListener<SizeChangedLayoutNotification>(
      onNotification: (_) {
        _measureAssistantPanel(true);
        return true;
      },
      child: SizeChangedLayoutNotifier(
        child: KeyedSubtree(
          key: _assistantPanelKey,
          child: AssistantActivityPanel(conversationId: _shownConversationId),
        ),
      ),
    );
  }

  Widget _buildSelectionToolbar(Conversation? conv) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_selection.active) return;
      final box = _selectionBarKey.currentContext?.findRenderObject();
      if (box is RenderBox &&
          (box.size.height - _composerOverlayHeight).abs() >= 0.5) {
        _updateState(() => _composerOverlayHeight = box.size.height);
      }
    });
    final enabled = conv != null && _selection.count > 0 && !_selectionBusy;
    return SafeArea(
      key: _selectionBarKey,
      top: false,
      minimum: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          MoeFloatingSurface(
            radius: 999,
            child: IconButton(
              onPressed: enabled ? () => _deleteSelected(conv) : null,
              style: withoutHoverFeedback(
                IconButton.styleFrom(
                  foregroundColor: Theme.of(context).colorScheme.error,
                  fixedSize: const Size(48, 48),
                  shape: const CircleBorder(),
                  padding: EdgeInsets.zero,
                ),
              ),
              icon: const Icon(Icons.delete_outline, size: 22),
              tooltip: '删除',
            ),
          ),
          const Spacer(),
          MoeFloatingSurface(
            radius: 999,
            child: IconButton(
              style: withoutHoverFeedback(
                IconButton.styleFrom(
                  fixedSize: const Size(48, 48),
                  shape: const CircleBorder(),
                  padding: EdgeInsets.zero,
                ),
              ),
              onPressed: enabled ? () => _showShareSheet(conv) : null,
              icon: const Icon(Icons.share_outlined, size: 22),
              tooltip: '分享',
            ),
          ),
        ],
      ),
    );
  }

  void _showConversationMenu(Conversation conv) {
    final box = _chatMenuKey.currentContext?.findRenderObject();
    if (box is! RenderBox) return;
    final position = _chatMenuPosition;
    _chatMenuPosition = null;
    MoePopupMenu.show(
      context,
      targetBox: box,
      globalPosition: position,
      vertical: true,
      alignToEnd: true,
      items: [
        MoePopupMenuItem(
          label: '详情',
          onTap: () => _openCharacterSettings(conv),
        ),
        MoePopupMenuItem(
          label: '聊天界面',
          onTap: () => MoeWorkspace.open(
            context,
            ChatInterfaceSettingsPage(conversation: conv),
          ),
        ),
        if (conv.allowsPlugin('image'))
          MoePopupMenuItem(
            label: '绘图风格',
            onTap: () => showDrawingPresetPicker(
              context: context,
              ref: ref,
              personaPrompt: conv.personaPrompt,
              onSelected: (presetId) => _switchDrawingPreset(conv, presetId),
            ),
          ),
        MoePopupMenuItem(
          label: '酒馆预设',
          onTap: () => MoeWorkspace.open(
            context,
            ChatTavernPresetPage(conversationId: conv.id),
          ),
        ),
        if (conv.effectiveAgentMode == RoleAgentMode.tool)
          MoePopupMenuItem(
            label: ref.read(assistantAlwaysAskProvider).valueOrNull == true
                ? '修改前不再每次问我'
                : '修改前每次问我',
            onTap: () async {
              final next =
                  ref.read(assistantAlwaysAskProvider).valueOrNull != true;
              await ref.read(assistantAlwaysAskProvider.notifier).set(next);
              if (mounted) {
                MoeToast.brief(
                  context,
                  next ? '之后所有 Agent 的修改都会先问你' : '所有 Agent 的工具恢复直接执行',
                );
              }
            },
          ),
        MoePopupMenuItem(
          label: '压缩上下文',
          onTap: () => showTopicCompactionDialog(
            context,
            ref,
            ownerId: conv.id,
            isGenerating: ref.read(sendingProvider),
          ),
        ),
        MoePopupMenuItem(
          label: '清空历史记录',
          onTap: () async {
            if (!await _confirmAction('清空历史记录', '确定清空与该角色的所有聊天记录吗？此操作不可撤销。') ||
                !mounted) {
              return;
            }
            try {
              await ref
                  .read(chatPageConversationActionsProvider)
                  .clearMessages(conv.id);
              if (mounted) MoeToast.brief(context, '历史记录已清空');
            } catch (_) {
              if (mounted) MoeToast.error(context, '清空失败，请重试');
            }
          },
        ),
        MoePopupMenuItem(
          label: '删除该角色',
          danger: true,
          onTap: () async {
            if (!await _confirmAction('删除该角色', '确定删除该角色及其所有消息记录吗？此操作不可撤销。') ||
                !mounted) {
              return;
            }
            try {
              await ref
                  .read(chatPageConversationActionsProvider)
                  .deleteConversation(conv.id);
              if (mounted) Navigator.of(context).maybePop();
            } catch (_) {
              if (mounted) MoeToast.error(context, '删除失败，请重试');
            }
          },
        ),
      ],
    );
  }

  Future<void> _switchDrawingPreset(Conversation conv, String? presetId) async {
    try {
      await ref
          .read(chatPageConversationActionsProvider)
          .switchDrawingPreset(conv, presetId);
      if (!mounted) return;
      final presetName = presetId == null
          ? '跟随默认'
          : ref
                .read(drawingPresetCatalogProvider)
                .valueOrNull
                ?.presets
                .where((preset) => preset.id == presetId)
                .firstOrNull
                ?.name;
      MoeToast.brief(
        context,
        presetName == null ? '绘图风格已切换' : '绘图风格：$presetName',
      );
    } catch (_) {
      if (mounted) MoeToast.error(context, '切换失败，请重试');
    }
  }

  FutureOr<bool> _checkVisionCompat({
    required Conversation conv,
    bool currentMessageHasImage = false,
  }) {
    final decisionOrFuture = ref
        .read(chatPageSendSupportProvider)
        .resolveVisionCompatibility(
          conversation: conv,
          currentMessageHasImage: currentMessageHasImage,
        );
    if (decisionOrFuture is ChatPageVisionCompatibilityDecision) {
      if (!mounted || !_isCurrentSendOwner(conv.id)) return false;
      if (decisionOrFuture.canSend) return true;
      return _confirmVisionCompat(conv.id, decisionOrFuture.modelDisplayName);
    }
    return decisionOrFuture.then((decision) {
      if (!mounted || !_isCurrentSendOwner(conv.id)) return false;
      if (decision.canSend) return true;
      return _confirmVisionCompat(conv.id, decision.modelDisplayName);
    });
  }

  Future<bool> _confirmVisionCompat(
    String convId,
    String? modelDisplayName,
  ) async {
    final confirmed = await _showVisionCompatDialog(
      context: context,
      modelName: modelDisplayName ?? '当前模型',
    );
    return confirmed == true && _isCurrentSendOwner(convId);
  }

  Future<void> _cancelModelFailoverRequest(
    ModelFailoverPromptRequest request,
  ) async {
    final stopped = await ref
        .read(chatActionsProvider)
        .interruptCurrentGeneration(convId: request.conversationId);
    if (stopped || !mounted) {
      return;
    }

    ref
        .read(modelFailoverPromptProvider.notifier)
        .dismiss(
          request.conversationId,
          defaultDecision: ModelFailoverDecision.cancel,
        );
  }

  Future<void> _showModelFailoverPrompt(
    ModelFailoverPromptRequest request,
  ) async {
    if (!mounted) {
      ref
          .read(modelFailoverPromptProvider.notifier)
          .dismiss(request.conversationId);
      return;
    }
    if (_activeFailoverPromptRequestId == request.requestId) {
      return;
    }
    _activeFailoverPromptRequestId = request.requestId;

    var handledByTitleAction = false;

    try {
      final result = await showMeoTalkDialog(
        context: context,
        title: '模型请求失败',
        titleActionText: '取消',
        barrierDismissible: false,
        cancelText: '重试当前模型',
        confirmText: '尝试下一个模型',
        onTitleAction: () {
          handledByTitleAction = true;
          Navigator.of(context, rootNavigator: true).pop();
          unawaited(_cancelModelFailoverRequest(request));
        },
        content: ModelFailoverErrorContent(request: request),
      );

      if (!mounted) {
        ref
            .read(modelFailoverPromptProvider.notifier)
            .dismiss(request.conversationId);
        return;
      }
      if (result == null) {
        if (!handledByTitleAction) {
          ref
              .read(modelFailoverPromptProvider.notifier)
              .dismiss(request.conversationId);
        }
        return;
      }

      ref
          .read(modelFailoverPromptProvider.notifier)
          .resolve(
            request.conversationId,
            request.requestId,
            result == false
                ? ModelFailoverDecision.retryCurrent
                : ModelFailoverDecision.tryNext,
          );
    } finally {
      _activeFailoverPromptRequestId = null;
    }
  }

  /// 显示视觉兼容性确认弹窗
  Future<bool?> _showVisionCompatDialog({
    required BuildContext context,
    required String modelName,
  }) {
    var dontShowAgain = false;
    final colors = context.moeColors;

    return showDialog<bool>(
      context: context,
      barrierDismissible: true,
      barrierColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => MeoTalkDialog(
          title: '当前模型不支持图片',
          cancelText: '取消',
          confirmText: '仍然发送',
          onCancel: () => Navigator.of(ctx).pop(false),
          onConfirm: () {
            if (dontShowAgain) {
              ref
                  .read(appSettingsProvider.notifier)
                  .setSkipVisionCompatDialog(true);
            }
            Navigator.of(ctx).pop(true);
          },
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '当前聊天模型（$modelName）不支持图片理解，'
                '上下文中的图片可能导致调用失败。',
              ),
              const SizedBox(height: 8),
              Text(
                '请切换到支持图片输入的聊天模型。继续发送仅会使用已有文字内容。',
                style: TextStyle(
                  fontSize: 13,
                  color: colors.muted,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 12),
              // "不再提醒"复选框
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () =>
                    setDialogState(() => dontShowAgain = !dontShowAgain),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      MoeCheckbox(
                        value: dontShowAgain,
                        onChanged: (v) =>
                            setDialogState(() => dontShowAgain = v),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '不再提醒',
                        style: TextStyle(
                          fontSize: 13,
                          color: colors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  MoeChatHeader _buildAppBar({
    required Conversation? conv,
    required String? currentConversationId,
    required bool deferEntryShell,
    required bool isGenerating,
    required ChatStatus chatStatus,
    required double toolbarHeight,
    required double nativeInset,
  }) {
    final colors = context.moeColors;
    return MoeChatHeader(
      showBackButton: MoeWorkspace.showsBackButton(context),
      nativeInset: nativeInset,
      toolbarHeight: toolbarHeight,
      // 标题区太窄（窄屏且按钮多）时先让出头像，只留名字。
      title: LayoutBuilder(
        builder: (context, box) => Row(
          children: [
            if (conv != null &&
                box.maxWidth >=
                    telegramChatHeaderAvatarSize +
                        telegramChatHeaderGap +
                        48) ...[
              MoeAvatar(
                name: conv.displayName,
                avatarUrl: conv.avatarUrl,
                characterImage: conv.characterImage,
                size: telegramChatHeaderAvatarSize,
              ),
              const SizedBox(width: telegramChatHeaderGap),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _selection.active
                        ? '已选 ${_selection.count} 条消息'
                        : conv?.displayName ?? '聊天',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colors.text,
                      fontSize: telegramChatHeaderTitleSize,
                      height: 1.2,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (!deferEntryShell)
                    ValueListenableBuilder<List<TraceEvent>>(
                      valueListenable: TraceStore.instance.entriesForSession(
                        currentConversationId,
                      ),
                      builder: (context, traceEvents, _) {
                        final name = conv?.displayName ?? '聊天';
                        final title = resolveChatPageAppBarTitle(
                          displayName: name,
                          conversationId: currentConversationId,
                          chatStatus: chatStatus,
                          traceEvents: traceEvents,
                        );
                        return Text(
                          title == name ? '' : title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: telegramChatHeaderStatusSize,
                            height: 1.2,
                            color: title == name
                                ? colors.muted
                                : colors.primary,
                          ),
                        );
                      },
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        if (_selection.active)
          IconButton(
            tooltip: '取消选择',
            onPressed: _selectionBusy ? null : _selection.clear,
            icon: const Icon(Icons.close),
          ),
        if (!_selection.active && !deferEntryShell && conv != null) ...[
          // 通话属于语音插件：全局或这个角色关掉语音时不提供通话。
          if (_canVoiceCall(conv))
            IconButton(
              tooltip: '语音通话',
              icon: Icon(Icons.call_outlined, color: colors.headerContentColor),
              onPressed: isGenerating ? null : () => _openVoiceCall(conv),
            ),
          Listener(
            onPointerDown: (event) => _chatMenuPosition = event.position,
            child: IconButton(
              icon: Icon(Icons.more_horiz, color: colors.headerContentColor),
              tooltip: '更多',
              key: _chatMenuKey,
              onPressed: () => _showConversationMenu(conv),
            ),
          ),
        ],
      ],
    );
  }

  bool _canVoiceCall(Conversation conv) =>
      ref.watch(ttsPluginConfigProvider).enabled &&
      (conv.enabledPlugins?.contains('tts') ?? true);

  /// 没接通的通话气泡点一下回拨，和顶栏电话按钮同一个入口。
  void _callBack(Conversation conv) {
    if (ref.read(sendingProvider)) {
      _showSendingInProgressToast();
      return;
    }
    unawaited(_openVoiceCall(conv));
  }

  Widget _buildMessageList({
    required Conversation conv,
    required bool isAgent,
    required List<Message> messages,
    required bool isInitialLoading,
    required List<Message> transientMessages,
    required double listTopSpacing,
    required bool hasMoreMessages,
    required ChatActions actions,
  }) {
    final list = ChatMessageList(
      key: ValueKey(conv.id),
      conversationId: conv.id,
      recipeId: conv.recipeId,
      chatDisplayStyle: conv.effectiveDisplayStyle,
      chunkOverride: conv.chunkOverride,
      quickPanels: isAgent,
      showTimeDividers:
          ref.watch(timeAwarenessPluginConfigProvider).enabled &&
          (conv.enabledPlugins?.contains('time_awareness') ?? true),
      selection: _selection,
      messages: messages,
      isInitialLoading: isInitialLoading,
      transientMessages: transientMessages,
      avatarUrl: conv.avatarUrl ?? conv.characterImage,
      displayName: conv.displayName,
      topOverlayHeight: listTopSpacing,
      bottomOverlayHeight: _composerOverlayHeight + _assistantPanelHeight,
      viewportController: _viewportController,
      contextStartMessageId: conv.contextStartMessageId,
      onLoadMore: () => _loadMoreMessages(conv.id),
      isLoadingMore: _isLoadingMore,
      hasMoreMessages: hasMoreMessages,
      onEditMessage: (message) async {
        try {
          await actions.editMessage(message.id);
        } catch (error) {
          if (mounted &&
              context.mounted &&
              ref.read(activeConversationProvider)?.id == conv.id) {
            MoeToast.error(
              context,
              error is StateError ? error.message.toString() : '无法进入编辑，原历史未改变',
            );
          }
        }
      },
      onRegenerateMessage: (message, guidance) async {
        if (ref.read(sendingProvider)) {
          _showSendingInProgressToast();
          return;
        }
        _forceChatListToBottom();
        await actions.regenerate(message.id, guidance: guidance);
      },
      onEnhanceRegenerateMessage: (message) {
        if (ref.read(sendingProvider)) {
          _showSendingInProgressToast();
          return;
        }
        _forceChatListToBottom();
        actions.regenerateWithEnhancement(message.id);
      },
    );
    if (!_canVoiceCall(conv)) return list;
    return CallBackScope(onCallBack: () => _callBack(conv), child: list);
  }

  Widget _buildComposer({
    required ActiveVoiceCall? typingCall,
    required ChatActions actions,
  }) {
    return Composer(
      onHeightChanged: _handleComposerHeightChanged,
      disabled: false,
      onSubmitEdit: (draft, text, attachment) async {
        final owner = ref.read(activeConversationProvider);
        if (owner == null ||
            owner.id != draft.conversationId ||
            ref.read(sendingProvider)) {
          throw StateError('会话已切换或正在发送，草稿已保留');
        }
        final compatible = await _checkVisionCompat(
          conv: owner,
          currentMessageHasImage: attachment?.type == AttachmentType.image,
        );
        if (!compatible ||
            !mounted ||
            ref.read(activeConversationProvider)?.id != owner.id) {
          throw StateError('未确认发送，编辑草稿已保留');
        }
        await actions.submitEditedMessage(
          draft,
          text: text,
          attachment: attachment,
        );
        if (mounted && ref.read(activeConversationProvider)?.id == owner.id) {
          _forceChatListToBottom();
        }
      },
      onInputTap: _resumeChatListAutoScroll,
      onSend: (text) async {
        await _submitPlainTextSend(text);
      },
      onSubmitText: _submitPlainTextSend,
      onImageSelected: (imagePath, {String? text}) async {
        await _submitImageSend(imagePath, text: text);
      },
      onSubmitImage: _submitImageSend,
      onSubmitSticker: _submitStickerSend,
      onConfirmStagedSend: () async {
        if (typingCall != null) return;
        if (ref.read(sendingProvider)) {
          _showSendingInProgressToast();
          return;
        }
        final conv = ref.read(activeConversationProvider);
        if (conv == null || !_isCurrentSendOwner(conv.id)) return;
        final staged = ref.read(stagedUserMessagesProvider(conv.id));
        if (staged.isEmpty) return;
        final hasImage = staged.any((m) => m.images.isNotEmpty);
        final compat = _checkVisionCompat(
          conv: conv,
          currentMessageHasImage: hasImage,
        );
        final ok = compat is bool ? compat : await compat;
        if (!ok ||
            !mounted ||
            !_isCurrentSendOwner(conv.id) ||
            ref.read(sendingProvider)) {
          return;
        }
        _diagnostics.begin(
          FrontendStage.sendRequested,
          conversationId: conv.id,
        );
        _forceChatListToBottom();
        await actions.confirmStagedMessages(convId: conv.id);
      },
      hintText: typingCall != null ? '通话中，打字给对方' : null,
      onFileSelected: (filePath, {String? text}) async {
        if (typingCall != null) {
          MoeToast.brief(context, '通话中只能打字');
          return;
        }
        if (ref.read(sendingProvider)) {
          _showSendingInProgressToast();
          return;
        }
        final convId = _resolveCurrentConversationId();
        if (ref.read(appSettingsProvider).valueOrNull?.allowMultiMessageSend ??
            false) {
          _forceChatListToBottom();
          await actions.stageWithFile(filePath, text: text, convId: convId);
          return;
        }
        _diagnostics.begin(FrontendStage.sendRequested, conversationId: convId);
        _forceChatListToBottom();
        unawaited(actions.sendWithFile(filePath, text: text));
      },
    );
  }
}
