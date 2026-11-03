part of 'chat_page.dart';

/// Voice call binding, desktop call window scheduling, image preheating and
/// the shared wallpaper background of the chat page.
extension _ChatPageVoiceAndMedia on _ChatPageState {
  /// 订阅当前通话：逐句记录变化时刷新临时气泡、通话视图与悬浮窗。
  void _bindVoiceCall(ActiveVoiceCall? call) {
    if (identical(call, _boundCall)) return;
    final previous = _boundCall;
    previous?.removeListener(_onVoiceCallChanged);
    // 没接通的电话收尾后通话视图随之撤掉，原因改用提示告诉用户。
    final error = previous?.error;
    if (error != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) MoeToast.error(context, error);
      });
    }
    _boundCall = call;
    call?.addListener(_onVoiceCallChanged);
    _voiceCallMessages = call == null
        ? const <Message>[]
        : voiceCallLiveMessages(call);
  }

  /// 这个聊天里正在进行的通话：输入框打的字进通话；挂断收尾中不再接收输入。
  ActiveVoiceCall? _typingVoiceCall(String? conversationId) {
    final call = _boundCall;
    if (call == null || call.ending) return null;
    return call.conversationId == conversationId ? call : null;
  }

  Future<void> _openVoiceCall(Conversation conv) async {
    final current = ref.read(activeVoiceCallProvider);
    if (current != null && current.conversationId != conv.id) {
      MoeToast.brief(context, '正在和别的角色通话');
      return;
    }
    // 新拨的电话先查音色预设、密钥和识别来源，配不齐就提示，不进通话页。
    if (current == null) {
      if (_checkingVoiceCall) return;
      _checkingVoiceCall = true;
      final String? reason;
      try {
        reason = await ref
            .read(voiceCallFactoryProvider)
            .unavailableReason(conv);
      } finally {
        _checkingVoiceCall = false;
      }
      if (!mounted) return;
      if (reason != null) {
        MoeToast.error(context, '无法通话：$reason');
        return;
      }
    }
    final call = _voiceCalls.start(conv);
    // 在小窗里的提到前面，其余在聊天页里显示、已收起的回到通话视图。
    if (call.inWindow) {
      await VoiceCallWindows.open(context, call, conv);
    } else {
      call.restore();
    }
  }

  /// 桌面宽屏时通话放进独立小窗（参照微信）；拨出和接听来电都走这里。
  bool _wantsCallWindow(ActiveVoiceCall call, bool isWide) =>
      isWide &&
      VoiceCallWindows.supported &&
      !call.ending &&
      !identical(call, _windowFailedCall);

  void _openCallWindowLater(ActiveVoiceCall call, Conversation conv) {
    if (call.inWindow || _openingCallWindow) return;
    _openingCallWindow = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) {
        _openingCallWindow = false;
        return;
      }
      final opened = await VoiceCallWindows.open(context, call, conv);
      _openingCallWindow = false;
      if (!opened && mounted && !call.ending) {
        _updateState(() => _windowFailedCall = call);
        call.leaveWindow();
      }
    });
  }

  /// 通话期间输入框的文字只进通话，不进主对话。
  bool _sendToVoiceCall(ActiveVoiceCall call, String text) {
    final sent = call.sendText(text);
    if (sent) {
      _forceChatListToBottom();
    } else if (mounted) {
      MoeToast.brief(context, '通话还没接通，稍等一下');
    }
    return sent;
  }

  /// (注释已丢失)
  void _triggerImagePreload() {
    final targetId = widget.conversationId;
    if (targetId == null || targetId == _preloadedConversationId) {
      // (注释已丢失)
      return;
    }

    // 获取会话数据
    final initial = widget.initialConversation?.id == targetId
        ? widget.initialConversation
        : null;
    final conv =
        initial ??
        ref
            .read(conversationsProvider)
            .maybeWhen(
              data: (list) {
                for (final c in list) {
                  if (c.id == targetId) return c;
                }
                return null;
              },
              orElse: () => null,
            );
    final messages =
        ref.read(conversationMessagesProvider(targetId)).valueOrNull ??
        const <Message>[];

    if (conv != null) {
      _preloadImages(conv, messages);
    }
  }

  /// (注释已丢失)
  Future<void> _preloadImages(Conversation conv, List<Message> messages) async {
    if (_preloadedConversationId == conv.id) return;

    try {
      const maxMessagesToScan = 10; // (注释已丢失)
      const maxImagesToCache = 24; // (注释已丢失)

      final providers = <ImageProvider>[];

      // (注释已丢失)
      final avatarUrl = conv.avatarUrl ?? conv.characterImage;
      if (avatarUrl != null && avatarUrl.isNotEmpty) {
        final provider = _getImageProvider(avatarUrl);
        if (provider != null) {
          providers.add(provider);
        }
      }

      // (注释已丢失)
      final start = messages.length > maxMessagesToScan
          ? messages.length - maxMessagesToScan
          : 0;
      for (
        var i = start;
        i < messages.length && providers.length < maxImagesToCache;
        i++
      ) {
        final msg = messages[i];
        if (msg.blocks == null) continue;
        for (final block in msg.blocks!) {
          if (providers.length >= maxImagesToCache) break;
          final provider = _getBlockImageProvider(block);
          if (provider != null) {
            providers.add(provider);
          }
        }
      }

      if (providers.isNotEmpty && context.mounted) {
        ref
            .read(imagePreheatQueueProvider)
            .enqueueAllFromContext(context, providers);
      }

      _preloadedConversationId = conv.id;
    } catch (_) {
      // (注释已丢失)
    }
  }

  /// (注释已丢失)
  ImageProvider? _getImageProvider(String url) => chatImageProviderFor(url);

  /// (注释已丢失)
  ImageProvider? _getBlockImageProvider(MessageBlock block) {
    if (block is ImageBlock) {
      // (注释已丢失)
      if (block.base64 != null && block.base64!.isNotEmpty) return null;

      // 网络图片
      if (block.url != null && block.url!.isNotEmpty) {
        return CachedNetworkImageProvider(block.url!);
      }
      // 本地图片
      if (block.localPath != null && block.localPath!.isNotEmpty) {
        // 避免 existsSync 同步 IO
        return FileImage(File(block.localPath!));
      }
    } else if (block is EmojiBlock) {
      final path = block.path.trim();
      if (path.isNotEmpty) {
        return _getImageProvider(path);
      }
    }
    return null;
  }

  /// [callView] 显示时盖住聊天内容、共用同一张壁纸；聊天内容只是不画，
  /// 列表位置和草稿都还在。
  Widget _buildConversationBackground({
    required Conversation? conv,
    required Color fallbackColor,
    required Widget child,
    Widget? callView,
  }) {
    return MoeWorkspaceBackground(
      background: ChatWallpaperLayer.forConversation(
        conversation: conv,
        fallbackColor: fallbackColor,
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          TickerMode(
            enabled: callView == null,
            child: Offstage(offstage: callView != null, child: child),
          ),
          ?callView,
        ],
      ),
    );
  }
}
