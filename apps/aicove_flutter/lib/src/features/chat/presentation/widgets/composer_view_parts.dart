part of 'composer.dart';

/// 输入框各块子视图：编辑横幅、附件预览、输入栏、排队输入、引用条、面板槽位与按钮。
extension _ComposerViewParts on _ComposerState {
  Widget _buildComposerGlassLayer({required Widget child}) =>
      ComposerGlassLayer(child: child);

  Widget _buildEditBanner() {
    return Row(
      children: [
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            _invalidEditDraft ? '编辑草稿失效，原历史未改变' : '发送后重新生成对话',
            maxLines: 2,
          ),
        ),
        TextButton(
          key: const ValueKey('cancel_message_edit'),
          onPressed: _editSubmitting ? null : _cancelEdit,
          child: const Text('取消编辑'),
        ),
      ],
    );
  }

  Widget _buildAttachmentPreview(SelectedAttachment attachment) {
    void remove() => unawaited(_setSelectedAttachment(null));
    return switch (attachment.type) {
      AttachmentType.image => ImageAttachmentPreview(
        imagePath: attachment.path,
        onRemove: remove,
      ),
      AttachmentType.file => FileAttachmentPreview(
        filePath: attachment.path,
        fileName: attachment.name,
        fileSizeBytes: attachment.sizeBytes,
        leadingIcon: Icons.insert_drive_file_outlined,
        onRemove: remove,
      ),
      AttachmentType.audio => FileAttachmentPreview(
        filePath: attachment.path,
        fileName: attachment.name,
        fileSizeBytes: attachment.sizeBytes,
        leadingIcon: Icons.audiotrack_outlined,
        onRemove: remove,
      ),
      AttachmentType.video => FileAttachmentPreview(
        filePath: attachment.path,
        fileName: attachment.name,
        fileSizeBytes: attachment.sizeBytes,
        leadingIcon: Icons.movie_outlined,
        onRemove: remove,
      ),
    };
  }

  Widget _buildInputBar() {
    final colors = context.moeColors;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          _buildMoreButton(
            isActive: _isCustomPanel(_currentPanelType),
          ),
          const SizedBox(width: 2),
          Expanded(
            child: Container(
              constraints: const BoxConstraints(minHeight: 42),
              alignment: Alignment.centerLeft,
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
              child: Actions(
                actions: {PasteTextIntent: _ComposerPasteAction(this)},
                child: TextField(
                  controller: _ctrl,
                  focusNode: _inputFocus,
                  minLines: 1,
                  maxLines: 4,
                  textAlignVertical: TextAlignVertical.center,
                  style: const TextStyle(fontSize: 16, height: 1.4),
                  readOnly:
                      _suppressKeyboard || _editSubmitting || _draftLoading,
                  showCursor: !_suppressKeyboard,
                  decoration: InputDecoration.collapsed(
                    hintText: _runningAgentHint ?? widget.hintText ?? '消息',
                    hintStyle: TextStyle(
                      color: colors.muted.withValues(alpha: _kComposerHintAlpha),
                    ),
                  ).copyWith(visualDensity: VisualDensity.standard),
                  enabled: !widget.disabled,
                  onTap: () {
                    if (widget.disabled) return;
                    widget.onInputTap?.call();
                    final shouldExplicitShow =
                        _suppressKeyboard || _isCustomPanel(_currentPanelType);
                    _showKeyboardDirect(explicitShow: shouldExplicitShow);
                  },
                  onEditingComplete: () {},
                  onSubmitted: (_) => _onSendButtonPressed(),
                  contextMenuBuilder: _buildInputContextMenu,
                  contentInsertionConfiguration: ContentInsertionConfiguration(
                    onContentInserted: _onKeyboardContentInserted,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 2),
          _buildSendButton(),
        ],
      ),
    );
  }

  /// 右键／长按菜单的「粘贴」走和快捷键同一套附件识别；iOS 原生菜单保持不变。
  Widget _buildInputContextMenu(
    BuildContext context,
    EditableTextState editableTextState,
  ) {
    if (SystemContextMenu.isSupportedByField(editableTextState)) {
      return SystemContextMenu.editableText(
        editableTextState: editableTextState,
      );
    }
    final items = [
      for (final item in editableTextState.contextMenuButtonItems)
        if (item.type == ContextMenuButtonType.paste)
          item.copyWith(
            onPressed: () {
              editableTextState.hideToolbar();
              unawaited(
                _pasteFromClipboard(
                  () => editableTextState.pasteText(
                    SelectionChangedCause.toolbar,
                  ),
                ),
              );
            },
          )
        else
          item,
    ];
    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: editableTextState.contextMenuAnchors,
      buttonItems: items,
    );
  }

  /// 暂存多条消息时，显示在发送按钮上方的小确认气泡。
  Widget _buildStagedConfirmBubble() {
    final convId = ref.watch(
      activeConversationProvider.select((c) => c?.id),
    );
    if (convId == null) return const SizedBox.shrink();
    final stagedCount = ref.watch(
      stagedUserMessagesProvider(convId).select((list) => list.length),
    );
    final isGenerating = ref.watch(sendingProvider);
    if (stagedCount <= 0 ||
        isGenerating ||
        _editDraft != null ||
        _invalidEditDraft) {
      return const SizedBox.shrink();
    }
    final colors = context.moeColors;
    final foreground = widget.disabled ? colors.muted : colors.accentColor;
    return Align(
      alignment: Alignment.centerRight,
      child: Padding(
        padding: const EdgeInsets.only(right: 12, bottom: 2),
        child: GestureDetector(
          key: const ValueKey('composer_confirm_staged_button'),
          behavior: HitTestBehavior.opaque,
          onTap: widget.disabled ? null : _onConfirmStagedPressed,
          child: MoeFloatingSurface(
            radius: 999,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.check_rounded, size: 16, color: foreground),
                const SizedBox(width: 4),
                Text(
                  '确认发送',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: MoeFontWeights.emphasis,
                    color: foreground,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Agent 运行中排队的输入：插话等这批工具跑完，排队等这轮做完；
  /// 停止或失败后没发出的标「未发出」，等用户放回输入框。
  Widget _buildQueuedInputs() {
    final convId = ref.watch(
      activeConversationProvider.select((c) => c?.id),
    );
    if (convId == null) return const SizedBox.shrink();
    final returned = ref.watch(returnedQueuedInputsProvider(convId));
    final queued = ref.watch(conversationQueuedInputsProvider(convId));
    if (returned.isEmpty && queued.isEmpty) return const SizedBox.shrink();
    final rows = [
      for (final text in returned) ('未发出', text),
      for (final input in queued) (input.steer ? '插话' : '做完再发', input.text),
    ];
    final colors = context.moeColors;
    return Padding(
      key: const ValueKey('composer_queued_inputs'),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 2),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final (label, text) in rows)
                  Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: '$label  ',
                          style: TextStyle(color: colors.accentColor),
                        ),
                        TextSpan(text: text.replaceAll('\n', ' ')),
                      ],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, color: colors.muted),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Tooltip(
            message: _supportsSoftKeyboardPanel
                ? '放回输入框'
                : '放回输入框（$_altKeyLabel+↑）',
            child: GestureDetector(
              onTap: _restoreQueuedInputs,
              child: MoeButtonSurface(
                radius: 999,
                child: Icon(Icons.undo_rounded, size: 18, color: colors.muted),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 构建引用消息预览
  Widget _buildQuotedMessagePreview() {
    final quoted = ref.watch(quotedMessageProvider);
    if (quoted == null) return const SizedBox.shrink();

    final colors = context.moeColors;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 2),
      child: Row(
        children: [
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: MoeQuoteBlock(
                label: quoted.isUser ? '回复 我' : '回复 TA',
                text: QuotedReply.parse(quoted.content)?.body ?? quoted.content,
                foregroundColor: colors.text,
                accentColor: colors.accentColor,
                maxLines: 1,
              ),
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
        if (type == ComposerPanelType.more) {
          return SizedBox(
            height: height,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 14),
              child: MoeFloatingSurface(
                child: ComposerMorePanel(onAction: _handlePanelAction),
              ),
            ),
          );
        }
        if (type == ComposerPanelType.sticker) {
          return SizedBox(
            height: height,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 14),
              child: MoeFloatingSurface(
                child: ComposerStickerPanel(
                  onBack: () => _requestPanelIntent(ComposerPanelType.more),
                  onStickerSelected: _handleStickerSelected,
                ),
              ),
            ),
          );
        }
        return const SizedBox.shrink();
      },
      onPanelTypeChange: (panelType, data) {
        _rebuild(() {
          switch (panelType) {
            case ChatBottomPanelType.none:
              _currentPanelType = ComposerPanelType.none;
              final switchingToMore =
                  _isCustomPanel(_desiredPanelType) ||
                  _isCustomPanel(_pendingPanelIntent?.target);
              if (!switchingToMore) {
                _suppressKeyboard = false;
                _holdPanelHeight = false;
              }
            case ChatBottomPanelType.keyboard:
              _currentPanelType = ComposerPanelType.keyboard;
              _suppressKeyboard = false;
            case ChatBottomPanelType.other:
              if (_isCustomPanel(data)) {
                _currentPanelType = data!;
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

  /// 运行中的输入提示，告诉用户这时发出去的话会怎么处理。
  String? get _runningAgentHint {
    final agentRunning = ref.watch(sendingProvider);
    if (!agentRunning) return null;
    return _supportsSoftKeyboardPanel
        ? '长按发送按钮，排队发送'
        : '插话，或 $_altKeyLabel+Enter 做完再发';
  }

  String get _altKeyLabel =>
      defaultTargetPlatform == TargetPlatform.macOS ? 'Option' : 'Alt';

  Widget _buildSendButton() {
    final isGenerating = ref.watch(sendingProvider);
    if (!isGenerating) {
      return _buildPlainSendButton(isGenerating);
    }
    return ValueListenableBuilder<bool>(
      valueListenable: _hasNonEmptyText,
      builder: (context, hasText, _) {
        // 有字时是插话（长按排到做完后），没字时仍是停止。
        if (!hasText) return _buildPlainSendButton(true);
        final colors = context.moeColors;
        return GestureDetector(
          onLongPress: widget.disabled
              ? null
              : () => _queueWhileRunning(steer: false),
          child: SizedBox(
            width: 42,
            height: 42,
            child: IconButton(
              key: const ValueKey('composer_steer_button'),
              onPressed: widget.disabled
                  ? null
                  : () => _queueWhileRunning(steer: true),
              // 手机上提示会抢走长按，提示写在输入框占位文字里。
              tooltip: _supportsSoftKeyboardPanel
                  ? null
                  : '插话（$_altKeyLabel+Enter：做完再发）',
              style: withoutHoverFeedback(
                IconButton.styleFrom(
                  padding: EdgeInsets.zero,
                  shape: const CircleBorder(),
                ),
              ),
              icon: Icon(
                Icons.arrow_upward_rounded,
                color: widget.disabled ? colors.muted : colors.accentColor,
                size: 24,
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildPlainSendButton(bool isGenerating) {
    final colors = context.moeColors;
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
}
