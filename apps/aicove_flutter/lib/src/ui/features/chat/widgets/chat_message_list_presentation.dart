part of 'chat_message_list.dart';

extension _ChatMessageListPresentationX on _ChatMessageListState {
  void _hydrateInitialListItems([MessageFormatConfig? config]) {
    final effectiveConfig =
        config ?? _cachedFormatConfig ?? const MessageFormatConfig();
    final sourceMessages = _stableMessages;
    if (_shouldBypassDisplayCache(sourceMessages)) {
      _updateListItems(effectiveConfig);
      return;
    }
    final windowSignature = _buildWindowSignature(sourceMessages);
    final formatSignature = _buildFormatSignature(effectiveConfig);
    final cached = ChatMessageListDisplayCache.read(
      conversationId: widget.conversationId,
      windowSignature: windowSignature,
      formatSignature: formatSignature,
    );
    if (cached != null) {
      _applyDisplayCacheEntry(cached, effectiveConfig);
      return;
    }

    _updateListItems(effectiveConfig);
  }

  void _applyDisplayCacheEntry(
    ChatMessageListDisplayCacheEntry cached,
    MessageFormatConfig config,
  ) {
    _cachedFormatConfig = config;
    _cachedListItems = cached.listItems.cast<ChatMessageListItem>();
    _cachedChatImages = List<ImagePreviewItem>.from(cached.chatImages);
    _hasHydratedInitialListItems = true;
  }

  void _updateListItems([MessageFormatConfig? config]) {
    final effectiveConfig =
        config ?? _cachedFormatConfig ?? const MessageFormatConfig();
    final stableMessages = _stableMessages;
    final timelineMessages = _currentTimelineMessages;
    final shouldBypassDisplayCache =
        _shouldBypassDisplayCache(stableMessages) ||
        _hasTransientTimelineContent;
    final windowSignature = shouldBypassDisplayCache
        ? null
        : _buildWindowSignature(stableMessages);
    final formatSignature = shouldBypassDisplayCache
        ? null
        : _buildFormatSignature(effectiveConfig);
    if (!shouldBypassDisplayCache &&
        windowSignature != null &&
        formatSignature != null) {
      final cached = ChatMessageListDisplayCache.read(
        conversationId: widget.conversationId,
        windowSignature: windowSignature,
        formatSignature: formatSignature,
      );
      if (cached != null) {
        _applyDisplayCacheEntry(cached, effectiveConfig);
        return;
      }
    }

    _cachedFormatConfig = effectiveConfig;
    _cachedListItems = buildChatMessageListItems(
      messages: timelineMessages,
      config: effectiveConfig,
      tagPresentation: _tagPresentation,
    );
    _cachedChatImages = collectChatMessageListImages(timelineMessages);
    _hasHydratedInitialListItems = true;
    if (!shouldBypassDisplayCache &&
        windowSignature != null &&
        formatSignature != null) {
      ChatMessageListDisplayCache.write(
        conversationId: widget.conversationId,
        windowSignature: windowSignature,
        formatSignature: formatSignature,
        listItems: _cachedListItems.cast<Object>(),
        chatImages: _cachedChatImages,
      );
    }
  }

  String _buildWindowSignature(List<Message> messages) {
    if (messages.isEmpty) return 'empty';
    final buffer = StringBuffer()..write(messages.length);
    for (final message in messages) {
      final blocks = message.blocks;
      buffer
        ..write('|')
        ..write(message.id)
        ..write('@')
        ..write(message.createdAt.millisecondsSinceEpoch)
        ..write('#')
        ..write(message.status ?? 'sent')
        ..write('#')
        ..write(message.role)
        ..write('#')
        ..write(message.content.hashCode)
        ..write('#')
        ..write(blocks?.length ?? 0);
      if (blocks != null && blocks.isNotEmpty) {
        for (final block in blocks) {
          buffer
            ..write(':')
            ..write(block.runtimeType)
            ..write('=')
            ..write(block.id);
          if (block is TextBlock) {
            buffer
              ..write('@')
              ..write(block.content.hashCode)
              ..write('@')
              ..write(block.status);
          } else if (block is ImageBlock) {
            buffer
              ..write('@')
              ..write(block.url?.hashCode ?? 0)
              ..write('@')
              ..write(block.localPath?.hashCode ?? 0)
              ..write('@')
              ..write(block.base64?.hashCode ?? 0)
              ..write('@')
              ..write(block.width)
              ..write('x')
              ..write(block.height);
          }
        }
      }
    }
    return buffer.toString();
  }

  bool _shouldBypassDisplayCache(List<Message> stableMessages) {
    for (final message in stableMessages) {
      if (message.status == 'sending') {
        return true;
      }
    }
    return false;
  }

  String _buildFormatSignature(MessageFormatConfig config) {
    return '${buildMessageFormatProjectionSignature(config)}'
        '|tags:$_tagPresentationSignature';
  }

  SliverChildBuilderDelegate _buildSectionDelegate(
    BuildContext context,
    List<ChatMessageListItem> items,
    ChatActions actions, {
    required bool reverseForViewport,
  }) {
    return SliverChildBuilderDelegate(
      (context, index) {
        final item = reverseForViewport
            ? items[items.length - 1 - index]
            : items[index];
        return _buildListItemWidget(context, item, actions);
      },
      childCount: items.length,
      addAutomaticKeepAlives: false,
      addRepaintBoundaries: true,
      findChildIndexCallback: (key) => _findChildIndexForKey(
        key,
        items,
        reverseForViewport: reverseForViewport,
      ),
    );
  }

  void _recordAnimationDecision(Message message, bool animate) {
    final diagnostics = ref.read(frontendDiagnosticsProvider);
    if (!diagnostics.enabled) return;
    final viewport = _listDiagnosticContext;
    final pending = _pendingAnimationIds.contains(message.id);
    final state = (animate, pending, _userOwnsViewport);
    final previous = _diagnosticAnimationStates[message.id];
    if (previous == state) return;
    _diagnosticAnimationStates.remove(message.id);
    _diagnosticAnimationStates[message.id] = state;
    if (_diagnosticAnimationStates.length > 512) {
      _diagnosticAnimationStates.remove(_diagnosticAnimationStates.keys.first);
    }
    diagnostics.record(
      viewport.withParent(diagnostics.forMessage(message.id)),
      FrontendStage.animationDecision,
      messageId: message.id,
      facts: DiagnosticFacts(
        pageInstanceId: viewport.operationId,
        sourceMessageId: message.sourceMessageId,
        reason: animate
            ? DiagnosticReason.pendingAnimationId
            : (pending
                  ? DiagnosticReason.pinnedLatestTail
                  : DiagnosticReason.notPending),
        state: {
          'animate': animate,
          'viewportClock': true,
          'pending': pending,
          'previouslyBuilt': previous != null,
          'userOwnsViewport': _userOwnsViewport,
          'followLatest': _autoScrollEnabled,
          'initialLoading': widget.isInitialLoading,
          'pinLatestTail': widget.viewportController.shouldPinLatestTail,
          if (_scrollController.hasClients &&
              _scrollController.position.hasPixels)
            'pixels': _scrollController.position.pixels,
        },
      ),
    );
  }

  Widget _buildListItemWidget(
    BuildContext context,
    ChatMessageListItem item,
    ChatActions actions,
  ) {
    final itemKey = ValueKey<String>(_listItemStableKey(item));
    widget.onDebugItemBuilt?.call(itemKey.value);

    if (item is ChatTimeDividerItem) {
      return KeyedSubtree(
        key: itemKey,
        child: _buildTimeDivider(context, item.time),
      );
    }
    if (item is ChatNewTopicDividerItem) {
      return KeyedSubtree(key: itemKey, child: _buildNewTopicDivider(context));
    }
    if (item is ChatChunkedMessageItem) {
      final message = item.originalMessage;
      final isMe = message.role == 'user';
      final chunkId = '${message.id}_chunk_${item.chunkIndex}';
      final fold = item.fold;
      final chunkMessage = Message(
        id: chunkId,
        role: message.role,
        content: item.chunkText,
        // 折叠段用思考块承载，气泡按折叠组件显示。
        blocks: fold == null
            ? null
            : [
                ThinkingBlock(
                  id: '${chunkId}_fold',
                  messageId: chunkId,
                  content: fold.content,
                  title: fold.title,
                  status: fold.closed
                      ? BlockStatus.success
                      : BlockStatus.streaming,
                ),
              ],
        createdAt: message.createdAt,
        status: message.status,
      );
      final bubbleWidget = Padding(
        padding: const EdgeInsets.symmetric(
          vertical: _kMessageItemVerticalPadding,
        ),
        child: FrontendMessageProbe(
          messageId: message.id,
          hasText: !isMe && item.chunkText.trim().isNotEmpty,
          child: MessageBubble(
            isMe: isMe,
            message: chunkMessage,
            selectionWrapper: (child) =>
                ChatSelectableMessage(messageId: chunkMessage.id, child: child),
            avatarUrl: isMe ? null : widget.avatarUrl,
            displayName: isMe ? null : widget.displayName,
            showCorner: item.showCorner,
            showName: false,
            showAvatar: item.showAvatar,
            hideContactAvatar: widget.selection?.active == true,
            chatImages: _cachedChatImages,
            documentStyle: _documentStyle,
            onRetry: null,
            onLongPress: (bubbleBox, position) => _handleMessageLongPress(
              context,
              message,
              isMe,
              bubbleBox,
              position,
              selectionId: chunkMessage.id,
            ),
            onMediaLongPress: (mediaBox, block, position) =>
                _handleMediaLongPress(
                  context,
                  message,
                  isMe,
                  mediaBox,
                  block,
                  position,
                ),
          ),
        ),
      );

      final shouldAnimate =
          item.chunkIndex == 0 &&
          _pendingAnimationIds.contains(message.id) &&
          _shouldAnimatePendingMessage(message);
      if (item.chunkIndex == 0) {
        _recordAnimationDecision(message, shouldAnimate);
      }
      if (shouldAnimate) {
        _pendingAnimationIds.remove(message.id);
        final animationSerial = _markEntranceAnimationStarted();
        return AnimatedMessageItem(
          key: itemKey,
          onFinished: () => _handleEntranceAnimationFinished(animationSerial),
          child: bubbleWidget,
        );
      }
      return KeyedSubtree(key: itemKey, child: bubbleWidget);
    }
    Widget buildPlainChatBubble(
      BuildContext context,
      Message message,
      bool isMe,
      ChatMessageItem item,
      ChatActions actions,
    ) {
      final bubble = MessageBubble(
        isMe: isMe,
        message: message,
        selectionWrapper: (child) =>
            ChatSelectableMessage(messageId: message.id, child: child),
        avatarUrl: isMe ? null : widget.avatarUrl,
        displayName: isMe ? null : widget.displayName,
        showCorner: item.showCorner,
        showName: false,
        showAvatar: item.showAvatar,
        hideContactAvatar: widget.selection?.active == true,
        chatImages: _cachedChatImages,
        documentStyle: _documentStyle,
        onRetry: (isMe && message.status == 'failed')
            ? () => actions.recallFailedMessage(message.id)
            : null,
        onLongPress: (bubbleBox, position) => _handleMessageLongPress(
          context,
          message,
          isMe,
          bubbleBox,
          position,
        ),
        onMediaLongPress: (mediaBox, block, position) => _handleMediaLongPress(
          context,
          message,
          isMe,
          mediaBox,
          block,
          position,
        ),
      );
      if (isMe) return bubble;
      return FrontendMessageProbe(
        messageId: message.id,
        hasText:
            message.blocks?.whereType<TextBlock>().any(
              (block) =>
                  block.content.trim().isNotEmpty && block.content != '生成中...',
            ) ??
            message.content.trim().isNotEmpty,
        child: bubble,
      );
    }

    if (item is ChatMessageItem) {
      final message = item.message;
      final isMe = message.role == 'user';
      final bubbleWidget = Padding(
        padding: const EdgeInsets.symmetric(
          vertical: _kMessageItemVerticalPadding,
        ),
        // G2.1 活跃流通道：policy on 时仅活跃尾气泡的 Consumer 命中通道并随
        // 文本增长重建，其余气泡 select 恒 null；policy off 时不包 Consumer、
        // 不建订阅，气泡子树与改造前一致（B-01：off＝严格回滚面）。
        child: !_streamChannelEnabled
            ? buildPlainChatBubble(context, message, isMe, item, actions)
            : Consumer(
                builder: (context, ref, _) {
                  final live = ref.watch(
                    _chatVisibleStreamProjectionProvider((
                      conversationId: widget.conversationId,
                      messageId: message.id,
                    )),
                  );
                  return buildPlainChatBubble(
                    context,
                    resolveActiveStreamTailMessage(message, live),
                    isMe,
                    item,
                    actions,
                  );
                },
              ),
      );

      final shouldAnimate =
          _pendingAnimationIds.contains(message.id) &&
          _shouldAnimatePendingMessage(message);
      _recordAnimationDecision(message, shouldAnimate);
      if (shouldAnimate) {
        _pendingAnimationIds.remove(message.id);
        final animationSerial = _markEntranceAnimationStarted();
        return AnimatedMessageItem(
          key: itemKey,
          onFinished: () => _handleEntranceAnimationFinished(animationSerial),
          child: bubbleWidget,
        );
      }
      return KeyedSubtree(key: itemKey, child: bubbleWidget);
    }

    return KeyedSubtree(key: itemKey, child: const SizedBox.shrink());
  }

  Widget _buildJumpToBottomButton(BuildContext context) {
    final colors = context.moeColors;

    return Tooltip(
      message: '回到底部',
      child: MoeFloatingSurface(
        radius: _kJumpToBottomButtonSize / 2,
        child: InkWell(
          key: const ValueKey<String>('chat_jump_to_latest_badge'),
          onTap: widget.viewportController.onJumpToLatest,
          customBorder: const CircleBorder(),
          child: SizedBox(
            width: _kJumpToBottomButtonSize,
            height: _kJumpToBottomButtonSize,
            child: Center(
              child: Icon(
                Icons.keyboard_arrow_down_rounded,
                size: 24,
                color: colors.accentColor,
              ),
            ),
          ),
        ),
      ),
    );
  }

  bool _shouldAnimatePendingMessage(Message message) {
    if (widget.viewportController.shouldPinLatestTail &&
        message.role == 'assistant') {
      return false;
    }
    return true;
  }

  Widget _buildLoadingIndicator(BuildContext context) {
    return const Center(
      child: MoeFloatingSurface(
        radius: 999,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2.2),
          ),
        ),
      ),
    );
  }

  Widget _buildTimeDivider(BuildContext context, DateTime time) {
    final colors = context.moeColors;
    final timeStr = _formatChatTime(time);

    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        child: MoeFloatingSurface(
          radius: 12,
          shadows: const [],
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Text(
            timeStr,
            style: TextStyle(
              color: colors.muted,
              fontSize: 12,
              fontWeight: MoeFontWeights.normal,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildNewTopicDivider(BuildContext context) {
    final colors = context.moeColors;
    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 12),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Row(
          children: [
            Expanded(
              child: Container(
                height: 0.5,
                color: colors.muted.withValues(alpha: 0.3),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Text(
                '以上是历史消息',
                style: TextStyle(
                  color: colors.muted,
                  fontSize: 11,
                  fontWeight: MoeFontWeights.normal,
                ),
              ),
            ),
            Expanded(
              child: Container(
                height: 0.5,
                color: colors.muted.withValues(alpha: 0.3),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatChatTime(DateTime time) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final targetDay = DateTime(time.year, time.month, time.day);

    final dayDiff = today.difference(targetDay).inDays;

    String prefix;
    if (dayDiff <= 0) {
      prefix = '';
    } else if (dayDiff == 1) {
      prefix = '昨天 ';
    } else if (dayDiff == 2) {
      prefix = '前天 ';
    } else {
      const weekdays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
      prefix = '${weekdays[time.weekday - 1]} ';
    }

    final hh = time.hour.toString().padLeft(2, '0');
    final mm = time.minute.toString().padLeft(2, '0');

    return '$prefix$hh:$mm';
  }

  Future<void> _handleMessageLongPress(
    BuildContext context,
    Message message,
    bool isMe,
    RenderBox bubbleBox,
    Offset globalPosition, {
    String? selectionId,
  }) async {
    final actions = ref.read(chatActionsProvider);
    final enableEnhancedRegenerate =
        ref
            .read(appSettingsProvider)
            .valueOrNull
            ?.enhancedDialogueSettings
            .enabled ==
        true;

    final audioBlock = message.blocks?.whereType<AudioBlock>().firstOrNull;
    final audioText = audioBlock?.text?.trim();
    final canRegenerateAudio =
        audioBlock != null &&
        MediaRegenerationTarget.canRegenerate(message, audioBlock);
    final hasAudioText =
        audioBlock != null && audioText != null && audioText.isNotEmpty;
    final globalExpand =
        ref.read(appSettingsProvider).valueOrNull?.expandAudioText ?? true;
    final localExpand = ref.read(audioMessageTextExpandedProvider(message.id));
    final isAudioExpanded = localExpand ?? globalExpand;

    final effectiveMessageText = (hasAudioText && audioText.isNotEmpty)
        ? audioText
        : message.displayText;

    await showMessageActionMenu(
      context,
      targetBox: bubbleBox,
      globalPosition: globalPosition,
      isUserMessage: isMe,
      allowSelect: widget.selection != null && message.status != 'sending',
      messageText: effectiveMessageText,
      showEnhanceRegenerate: enableEnhancedRegenerate && !canRegenerateAudio,
      regenerateAudio: canRegenerateAudio,
      showTranscribe: hasAudioText,
      isAudioTextExpanded: isAudioExpanded,
      onAction: (action) async {
        if (!context.mounted) return;
        switch (action) {
          case MessageAction.select:
            widget.selection?.start(selectionId ?? message.id);
            break;
          case MessageAction.copy:
            MoeToast.show(context, '已复制到剪贴板');
            break;
          case MessageAction.toggleAudioText:
            final nextState = !isAudioExpanded;
            ref
                    .read(audioMessageTextExpandedProvider(message.id).notifier)
                    .state =
                nextState;
            break;
          case MessageAction.edit:
            widget.onEditMessage?.call(message);
            break;
          case MessageAction.regenerateMedia:
            if (audioBlock != null && canRegenerateAudio) {
              await _regenerateMedia(context, message, audioBlock);
            }
            break;
          case MessageAction.regenerate:
          case MessageAction.enhanceRegenerate:
            if (ChatPageConversationActions.isCharacterGreeting(message)) {
              MoeToast.show(context, '开场白不能重新生成');
              break;
            }
            if (action == MessageAction.regenerate) {
              widget.onRegenerateMessage?.call(message);
            } else {
              widget.onEnhanceRegenerateMessage?.call(message);
            }
            break;
          case MessageAction.quote:
            ref.read(quotedMessageProvider.notifier).state = QuotedMessage(
              id: message.id,
              content: effectiveMessageText,
              isUser: isMe,
            );
            break;
          case MessageAction.delete:
            if (message.status == 'sending') {
              MoeToast.show(context, '发送中的消息暂不可删除');
              break;
            }
            final ok = await showMeoTalkConfirm(
              context: context,
              title: '删除消息',
              message: '确定删除这条消息吗？',
              hint: '会从当前会话上下文和本地数据库中移除这条消息。',
              confirmText: '删除',
              isDanger: true,
            );
            if (ok == true && context.mounted) {
              await actions.deleteMessage(message.id);
              if (context.mounted) {
                MoeToast.show(context, '已删除消息');
              }
            }
            break;
          case MessageAction.save:
            break;
        }
      },
    );
  }

  Future<void> _regenerateMedia(
    BuildContext context,
    Message message,
    MessageBlock block,
  ) async {
    if (!MediaRegenerationTarget.canRegenerate(message, block)) return;
    final mediaLabel = MediaRegenerationTarget.kindOf(block)!.label;
    final actions = ref.read(chatActionsProvider);
    MoeToast.show(context, '正在重新生成$mediaLabel…');
    try {
      await actions.regenerateMedia(
        conversationId: widget.conversationId,
        messageId: message.id,
        blockId: block.id,
      );
      if (context.mounted) MoeToast.show(context, '$mediaLabel已重新生成');
    } catch (error) {
      if (context.mounted) {
        MoeToast.error(
          context,
          error is StateError
              ? error.message.toString()
              : '$mediaLabel重新生成失败，原$mediaLabel已保留',
        );
      }
    }
  }

  Future<void> _handleMediaLongPress(
    BuildContext context,
    Message message,
    bool isMe,
    RenderBox mediaBox,
    MessageBlock block,
    Offset globalPosition,
  ) async {
    final actions = ref.read(chatActionsProvider);
    final mediaType = block is AudioBlock ? MediaType.audio : MediaType.image;
    await showMediaActionMenu(
      context,
      targetBox: mediaBox,
      globalPosition: globalPosition,
      mediaType: mediaType,
      allowSelect: widget.selection != null && message.status != 'sending',
      allowDelete: true,
      allowRegenerate: MediaRegenerationTarget.canRegenerate(message, block),
      onAction: (action) async {
        if (!context.mounted) return;
        switch (action) {
          case MessageAction.select:
            widget.selection?.start(message.id);
            break;
          case MessageAction.regenerateMedia:
            await _regenerateMedia(context, message, block);
            break;
          case MessageAction.save:
            await saveChatMessageListMediaBlock(context, block);
            break;
          case MessageAction.quote:
            final quoteText = block is ImageBlock
                ? '[图片]'
                : block is AudioBlock
                ? '[语音]'
                : '[媒体]';
            ref.read(quotedMessageProvider.notifier).state = QuotedMessage(
              id: message.id,
              content: quoteText,
              isUser: isMe,
            );
            break;
          case MessageAction.delete:
            if (message.status == 'sending') {
              MoeToast.show(context, '发送中的消息暂不可删除');
              break;
            }
            final ok = await showMeoTalkConfirm(
              context: context,
              title: '删除消息',
              message: '确定删除这条消息吗？',
              hint: '会从当前会话上下文和本地数据库中移除这条消息。',
              confirmText: '删除',
              isDanger: true,
            );
            if (ok == true && context.mounted) {
              await actions.deleteMessage(message.id);
              if (context.mounted) {
                MoeToast.show(context, '已删除消息');
              }
            }
            break;
          default:
            break;
        }
      },
    );
  }
}
