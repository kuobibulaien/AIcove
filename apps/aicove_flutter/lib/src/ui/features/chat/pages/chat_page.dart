import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../../../features/chat/domain/conversation.dart';
import '../../../../features/chat/domain/message.dart';
import '../../../../features/chat/providers2.dart';
import '../../../../features/chat/presentation/widgets/composer.dart';
import '../../../../features/chat/presentation/widgets/contact_edit_dialog.dart';
import '../../../../features/chat/services/chat_history_store.dart';
import '../../../../ui/features/character/pages/contact_edit_page.dart';
import '../../../../features/chat/presentation/widgets/chat_settings_dialog.dart';
import '../../../../ui/theme/tokens.dart';
import '../../../../ui/shared/animations/parallax_slide_page_route.dart';
import '../../../../ui/shared/effects/smooth_clip.dart';
import '../../../../ui/shared/widgets/index.dart';
import '../../../../features/settings/app_settings.dart';
import '../../../../core/database/database.dart' as db;
import '../../../../core/database/database_provider.dart';
import '../../../../core/models/message_block.dart';
import '../../../../core/utils/blurred_background_service.dart';
import '../../../../core/utils/data_image.dart';
import '../../../../core/utils/image_preheat_queue.dart';
import 'deferred_conversation_activation.dart';
import '../widgets/chat_message_list.dart';

const Duration kChatPageImagePrecacheDelay = Duration(milliseconds: 180);
const Duration kChatPageUnreadClearDelay = Duration(milliseconds: 160);
final Duration kChatPageDeferredEntryWindow = Duration(
  milliseconds: kAnimPage.inMilliseconds + 120,
);

class ChatPage extends ConsumerStatefulWidget {
  final String? conversationId;
  final Conversation? initialConversation;
  final bool showToggleButton;
  const ChatPage(
      {super.key,
      this.conversationId,
      this.initialConversation,
      this.showToggleButton = false});

  @override
  ConsumerState<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends ConsumerState<ChatPage> {
  /// (注释已丢失)
  bool _isLoadingMore = false;
  bool _databaseTimelineActivated = true;
  bool _persistentViewportHasMoreMessages = true;

  /// (注释已丢失)
  String? _preloadedConversationId;
  bool _didSchedulePrecache = false;
  double _composerOverlayHeight = 0;
  bool _autoScrollToBottomEnabled = true;
  int _forceScrollToBottomSignal = 0;
  Timer? _imagePrecacheTimer;
  Timer? _clearUnreadTimer;
  Timer? _deferredEntryTimer;
  String? _staticBackgroundBlurSource;
  ImageProvider? _staticBackgroundBlurProvider;
  bool _deferredEntryShellActive = false;
  bool _entrySideEffectsStarted = false;
  final DeferredConversationActivation _conversationActivation =
      DeferredConversationActivation();

  bool get _shouldDeferEntrySideEffects => _deferredEntryShellActive;

  @override
  void initState() {
    super.initState();
    final targetId = widget.conversationId;
    _databaseTimelineActivated = targetId == null;
    _persistentViewportHasMoreMessages = true;
    if (targetId == null) return;
    final initial = widget.initialConversation?.id == targetId
        ? widget.initialConversation
        : null;
    if (initial != null) {
      _beginDeferredEntryShell(targetId);
      return;
    }
    _startEntrySideEffects(targetId);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_shouldDeferEntrySideEffects) {
      return;
    }
    _scheduleImagePrecache();
  }

  void _beginDeferredEntryShell(String conversationId) {
    _deferredEntryShellActive = true;
    _deferredEntryTimer?.cancel();
    _deferredEntryTimer = Timer(kChatPageDeferredEntryWindow, () {
      if (!mounted || widget.conversationId != conversationId) return;
      setState(() {
        _deferredEntryShellActive = false;
      });
      _startEntrySideEffects(conversationId);
    });
  }

  void _startEntrySideEffects(String conversationId) {
    if (_entrySideEffectsStarted) return;
    _entrySideEffectsStarted = true;
    _scheduleConversationActivation(conversationId);
    _scheduleUnreadClear(conversationId);
    _scheduleImagePrecache();
  }

  void _scheduleImagePrecache() {
    if (_didSchedulePrecache) return;
    _didSchedulePrecache = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _didSchedulePrecache = false;
      if (!mounted) return;
      _imagePrecacheTimer?.cancel();
      _imagePrecacheTimer = Timer(kChatPageImagePrecacheDelay, () {
        if (!mounted) return;
        _triggerImagePreload();
      });
    });
  }

  void _scheduleUnreadClear(String conversationId) {
    _clearUnreadTimer?.cancel();
    _clearUnreadTimer = Timer(kChatPageUnreadClearDelay, () {
      if (!mounted) return;
      unawaited(ref.read(conversationsProvider.notifier).clearUnread(
            conversationId,
          ));
    });
  }

  void _scheduleConversationActivation(String conversationId) {
    _conversationActivation.schedule(
      conversationId: conversationId,
      isMounted: () => mounted,
      readActiveConversationId: () => ref.read(activeConversationIdProvider),
      activateConversation: (id) {
        ref.read(activeConversationIdProvider.notifier).state = id;
      },
    );
  }

  void _activateDatabaseTimeline(
    String conversationId, {
    bool loadMoreOnActivate = false,
  }) {
    if (_databaseTimelineActivated) {
      if (loadMoreOnActivate) {
        unawaited(_loadMoreMessages(conversationId));
      }
      return;
    }

    final visibleCountNotifier =
        ref.read(conversationVisibleCountProvider(conversationId).notifier);
    final currentVisibleCount = visibleCountNotifier.state;
    if (loadMoreOnActivate) {
      final targetVisibleCount = currentVisibleCount <
              kConversationInitialVisibleCount + kConversationVisiblePageSize
          ? kConversationInitialVisibleCount + kConversationVisiblePageSize
          : currentVisibleCount + kConversationVisiblePageSize;
      visibleCountNotifier.state = targetVisibleCount;
    }

    if (!mounted) return;
    setState(() {
      _databaseTimelineActivated = true;
      if (loadMoreOnActivate) {
        _isLoadingMore = true;
      }
    });

    if (loadMoreOnActivate) {
      Future<void>.delayed(const Duration(milliseconds: 120)).then((_) {
        if (!mounted) return;
        setState(() => _isLoadingMore = false);
      });
    }
  }

  /// 检查视觉兼容性，必要时弹窗确认
  ///
  /// 返回 true 表示可以继续发送，false 表示用户取消
  void _handleComposerHeightChanged(double height) {
    if (!mounted || !height.isFinite || height < 0) return;
    if ((height - _composerOverlayHeight).abs() < 0.5) return;
    setState(() => _composerOverlayHeight = height);
  }

  void _resumeChatListAutoScroll() {
    if (!mounted) return;
    if (_autoScrollToBottomEnabled) return;
    setState(() => _autoScrollToBottomEnabled = true);
  }

  void _forceChatListToBottom() {
    if (!mounted) return;
    setState(() {
      _autoScrollToBottomEnabled = true;
      _forceScrollToBottomSignal += 1;
    });
  }

  void _disableChatListAutoScroll() {
    if (!mounted) return;
    if (!_autoScrollToBottomEnabled) return;
    setState(() => _autoScrollToBottomEnabled = false);
  }

  Future<bool> _checkVisionCompat({
    required Conversation conv,
    bool currentMessageHasImage = false,
  }) async {
    final settings = await ref.read(appSettingsProvider.future);

    // 已勾选"不再提醒"→ 直接放行
    if (settings.skipVisionCompatDialog) return true;

    // 判断当前聊天模型是否支持视觉
    final chatModels = settings.defaultChatModels.isNotEmpty
        ? settings.defaultChatModels
        : [settings.defaultModelName];
    final primaryModel = chatModels.first;
    if (settings.hasChatModelCapability(
      primaryModel,
      ChatModelCapability.vision,
    )) {
      return true;
    }

    // 判断上下文 / 当前消息是否包含图片
    final history = await ref.read(chatHistoryStoreProvider).loadAllMessages(
          conv.id,
        );
    final historyHasImage = history.any((m) => m.images.isNotEmpty);
    if (!historyHasImage && !currentMessageHasImage) return true;

    // 需要弹窗
    if (!mounted) return false;
    final confirmed = await _showVisionCompatDialog(
      context: context,
      modelName: settings.getModelDisplayName(primaryModel),
      hasVisionModel: settings.defaultVisionModel != null &&
          settings.defaultVisionModel!.isNotEmpty,
    );
    return confirmed == true;
  }

  /// 显示视觉兼容性确认弹窗
  Future<bool?> _showVisionCompatDialog({
    required BuildContext context,
    required String modelName,
    required bool hasVisionModel,
  }) {
    var dontShowAgain = false;
    final colors = context.moeColors;

    return showDialog<bool>(
      context: context,
      barrierDismissible: true,
      barrierColor: Colors.black54,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          backgroundColor: colors.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: Text(
            '当前模型不支持图片',
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w600,
              color: colors.text,
            ),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '当前聊天模型（$modelName）不支持图片理解，'
                '上下文中的图片可能导致调用失败。',
                style: TextStyle(
                  fontSize: 14,
                  color: colors.textSecondary,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                hasVisionModel
                    ? '点击确认后，将通过视觉辅助模型自动将图片转为文字描述。\n'
                        '建议切换到原生支持多模态的模型（如 GPT-4o、Gemini）以获得最佳体验。'
                    : '建议前往设置中配置视觉辅助模型，'
                        '或切换到原生支持多模态的模型（如 GPT-4o、Gemini）。',
                style: TextStyle(
                  fontSize: 13,
                  color: colors.muted,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 16),
              // "不再提醒"复选框
              InkWell(
                borderRadius: BorderRadius.circular(4),
                onTap: () {
                  setDialogState(() => dontShowAgain = !dontShowAgain);
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 20,
                        height: 20,
                        child: Checkbox(
                          value: dontShowAgain,
                          onChanged: (v) {
                            setDialogState(() => dontShowAgain = v ?? false);
                          },
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '不再提醒',
                        style: TextStyle(
                          fontSize: 12,
                          color: colors.muted,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(
                '取消',
                style: TextStyle(color: colors.muted),
              ),
            ),
            TextButton(
              onPressed: () {
                if (dontShowAgain) {
                  ref
                      .read(appSettingsProvider.notifier)
                      .setSkipVisionCompatDialog(true);
                }
                Navigator.of(ctx).pop(true);
              },
              child: Text(
                hasVisionModel ? '使用视觉辅助模型发送' : '仍然发送',
                style: TextStyle(color: colors.accentColor),
              ),
            ),
          ],
          // "不再提醒"复选框放在 content 底部
          contentPadding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
        ),
      ),
    );
  }

  String _buildBriefSendErrorMessage(String rawError) {
    final text = rawError.trim();
    if (text.isEmpty) {
      return '发送失败，请到日志中心看详情';
    }

    final httpMatch =
        RegExp(r'HTTP\s*(\d{3})', caseSensitive: false).firstMatch(text);
    if (httpMatch != null) {
      return '发送失败（HTTP ${httpMatch.group(1)}）';
    }

    final lower = text.toLowerCase();
    if (lower.contains('timeout') || lower.contains('timed out')) {
      return '发送超时，请稍后重试';
    }
    if (lower.contains('socketexception') ||
        lower.contains('failed host lookup') ||
        lower.contains('connection refused')) {
      return '网络异常，请检查连接';
    }
    return '发送失败，请到日志中心看详情';
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
    final conv = initial ??
        ref.read(conversationsProvider).maybeWhen(
              data: (list) {
                for (final c in list) {
                  if (c.id == targetId) return c;
                }
                return null;
              },
              orElse: () => null,
            );
    final messages = _databaseTimelineActivated
        ? ref.read(conversationMessagesProvider(targetId)).valueOrNull ??
            const <Message>[]
        : const <Message>[];

    if (conv != null) {
      _preloadImages(conv, messages);
    }
  }

  /// (注释已丢失)
  Future<void> _preloadImages(
    Conversation conv,
    List<Message> messages,
  ) async {
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
      for (var i = start;
          i < messages.length && providers.length < maxImagesToCache;
          i++) {
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
        ref.read(imagePreheatQueueProvider).enqueueAllFromContext(
              context,
              providers,
            );
      }

      _preloadedConversationId = conv.id;
    } catch (_) {
      // (注释已丢失)
    }
  }

  /// (注释已丢失)
  ImageProvider? _getImageProvider(String url) {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return null;

    // (注释已丢失)
    if (trimmed.startsWith('data:image')) return null;

    final isNetwork =
        trimmed.startsWith('http://') || trimmed.startsWith('https://');
    final isAsset =
        trimmed.startsWith('assets/') || trimmed.startsWith('packages/');

    if (isNetwork) {
      return CachedNetworkImageProvider(trimmed);
    } else if (isAsset) {
      return AssetImage(trimmed);
    } else {
      // (注释已丢失)
      return FileImage(File(trimmed));
    }
  }

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

  Widget _buildConversationBackground({
    required Conversation? conv,
    required Color fallbackColor,
    required Widget child,
  }) {
    final raw = conv?.chatBackgroundImage?.trim();
    if (raw == null || raw.isEmpty) {
      return Container(color: fallbackColor, child: child);
    }

    final image = _buildBackgroundImage(raw);
    if (image == null) {
      return Container(color: fallbackColor, child: child);
    }
    final maskOpacity =
        (conv?.chatBackgroundMaskOpacity ?? 0.8).clamp(0.0, 1.0);
    final topMaskOpacity = (maskOpacity + 0.12).clamp(0.0, 1.0);
    final blurSigma = (conv?.chatBackgroundBlurSigma ?? 0.0).clamp(0.0, 30.0);
    final blurOverlayOpacity = _staticBlurOverlayOpacity(blurSigma);
    final blurOverlay = blurOverlayOpacity > 0
        ? _buildStaticBackgroundBlurLayer(
            raw,
            opacity: blurOverlayOpacity,
          )
        : null;

    return Container(
      color: fallbackColor,
      child: Stack(
        fit: StackFit.expand,
        children: [
          image,
          if (blurOverlay != null) blurOverlay,
          IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    fallbackColor.withValues(alpha: topMaskOpacity),
                    fallbackColor.withValues(
                        alpha: (maskOpacity * 0.9).clamp(0.0, 1.0)),
                    fallbackColor.withValues(alpha: maskOpacity),
                  ],
                ),
              ),
            ),
          ),
          child,
        ],
      ),
    );
  }

  double _staticBlurOverlayOpacity(double blurSigma) {
    if (blurSigma <= 0.1) return 0;
    return Curves.easeOut.transform((blurSigma / 30).clamp(0.0, 1.0));
  }

  Widget? _buildStaticBackgroundBlurLayer(
    String source, {
    required double opacity,
  }) {
    final blurAsset = BlurredBackgroundService.deriveBlurAssetPath(source);
    if (blurAsset == null) {
      _scheduleStaticBackgroundBlur(source);
    }
    Widget? layer;
    if (blurAsset != null) {
      layer = SizedBox.expand(
        child: Image.asset(
          blurAsset,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          filterQuality: FilterQuality.medium,
          errorBuilder: (_, __, ___) {
            final provider = _resolveStaticBackgroundBlurProvider(source);
            if (provider == null) return const SizedBox.shrink();
            return _buildStaticBackgroundBlurImage(provider);
          },
        ),
      );
    } else {
      final provider = _resolveStaticBackgroundBlurProvider(source);
      if (provider != null) {
        layer = _buildStaticBackgroundBlurImage(provider);
      }
    }

    if (layer == null) return null;
    return IgnorePointer(
      child: Opacity(
        key: const ValueKey<String>('chat_page_static_blur_layer'),
        opacity: opacity,
        child: layer,
      ),
    );
  }

  ImageProvider? _resolveStaticBackgroundBlurProvider(String source) {
    if (_staticBackgroundBlurSource != source) return null;
    return _staticBackgroundBlurProvider;
  }

  Widget _buildStaticBackgroundBlurImage(ImageProvider provider) {
    return SizedBox.expand(
      child: Image(
        image: provider,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        filterQuality: FilterQuality.medium,
        errorBuilder: (_, __, ___) => const SizedBox.shrink(),
      ),
    );
  }

  void _scheduleStaticBackgroundBlur(String source) {
    if (_staticBackgroundBlurSource == source) return;
    _staticBackgroundBlurSource = source;
    _staticBackgroundBlurProvider = null;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _staticBackgroundBlurSource != source) return;
      unawaited(
        BlurredBackgroundService.ensureBlur(source).then((provider) {
          if (!mounted || _staticBackgroundBlurSource != source) return;
          if (identical(_staticBackgroundBlurProvider, provider)) return;
          setState(() {
            _staticBackgroundBlurProvider = provider;
          });
        }),
      );
    });
  }

  Widget? _buildBackgroundImage(String raw) {
    final bytes = decodeDataImage(raw);
    if (bytes != null) {
      return Image.memory(
        bytes,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (_, __, ___) => const SizedBox.shrink(),
      );
    }

    final provider = _getImageProvider(raw);
    if (provider == null) return null;
    return Image(
      image: provider,
      fit: BoxFit.cover,
      gaplessPlayback: true,
      errorBuilder: (_, __, ___) => const SizedBox.shrink(),
    );
  }

  @override
  void didUpdateWidget(covariant ChatPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final targetId = widget.conversationId;
    if (targetId != oldWidget.conversationId) {
      _deferredEntryTimer?.cancel();
      _entrySideEffectsStarted = false;
      _deferredEntryShellActive = false;
      setState(() {
        _isLoadingMore = false;
        _autoScrollToBottomEnabled = true;
        _databaseTimelineActivated = targetId == null;
        _persistentViewportHasMoreMessages = true;
      });
      _preloadedConversationId = null;
      if (targetId == null) {
        return;
      }
      final initial = widget.initialConversation?.id == targetId
          ? widget.initialConversation
          : null;
      if (initial != null) {
        _beginDeferredEntryShell(targetId);
        return;
      }
      _startEntrySideEffects(targetId);
    }
  }

  @override
  void dispose() {
    _conversationActivation.clear();
    _imagePrecacheTimer?.cancel();
    _clearUnreadTimer?.cancel();
    _deferredEntryTimer?.cancel();
    super.dispose();
  }

  /// (注释已丢失)
  Future<void> _loadMoreMessages(String conversationId) async {
    if (_isLoadingMore) return;
    if (!_databaseTimelineActivated) {
      if (!_persistentViewportHasMoreMessages) return;
      _activateDatabaseTimeline(
        conversationId,
        loadMoreOnActivate: true,
      );
      return;
    }
    if (!ref.read(conversationHasMoreProvider(conversationId))) return;

    setState(() => _isLoadingMore = true);

    try {
      final notifier =
          ref.read(conversationVisibleCountProvider(conversationId).notifier);
      notifier.state += kConversationVisiblePageSize;
      await Future<void>.delayed(const Duration(milliseconds: 120));
    } catch (e) {
      debugPrint('加载更多消息失败: $e');
    } finally {
      if (mounted) {
        setState(() => _isLoadingMore = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final targetId = widget.conversationId;
    final initial = widget.initialConversation?.id == targetId
        ? widget.initialConversation
        : null;
    final deferEntryShell =
        targetId != null && initial != null && _deferredEntryShellActive;
    final targetConversation = targetId == null || deferEntryShell
        ? null
        : ref.watch(conversationSnapshotByIdProvider(targetId));
    final conv = targetId == null
        ? ref.watch(activeConversationProvider)
        : deferEntryShell
            ? initial
            : targetConversation ??
                ref.watch(
                  conversationByIdProvider(targetId)
                      .select((value) => value.valueOrNull),
                ) ??
                initial;
    final currentConversationId = conv?.id ?? targetId;
    final useDatabaseTimeline =
        _databaseTimelineActivated || currentConversationId == null;
    final messagesAsync = !useDatabaseTimeline
        ? const AsyncValue.data(<Message>[])
        : currentConversationId == null
            ? const AsyncValue.data(<Message>[])
            : ref.watch(conversationMessagesProvider(currentConversationId));
    final messages = messagesAsync.valueOrNull ?? const <Message>[];
    final hasMoreMessages = currentConversationId == null
        ? false
        : useDatabaseTimeline
            ? ref.watch(conversationHasMoreProvider(currentConversationId))
            : _persistentViewportHasMoreMessages;
    final transientMessages = deferEntryShell || currentConversationId == null
        ? const <Message>[]
        : ref.watch(
            conversationTransientMessagesProvider(currentConversationId));
    final actions = ref.read(chatActionsProvider); // (注释已丢失)
    final sidebarVisible = widget.showToggleButton && !deferEntryShell
        ? ref.watch(sidebarVisibleProvider)
        : false;
    final settingsAsync =
        deferEntryShell ? null : ref.watch(appSettingsProvider);
    final colors = context.moeColors;

    // 监听模型轮询通知，弹 toast 提示
    ref.listen<String?>(modelFailoverInfoProvider, (prev, next) {
      if (next != null && next.isNotEmpty && mounted) {
        MoeToast.info(context, '自动尝试下一个模型: $next');
      }
    });

    // 监听发送错误，弹出失败原因提示
    ref.listen<String?>(errorProvider, (prev, next) {
      if (next != null && next.isNotEmpty && mounted) {
        final briefMessage = _buildBriefSendErrorMessage(next);
        MoeToast.show(context, briefMessage,
            type: ToastType.error, duration: const Duration(seconds: 3));
      }
    });

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final chatBgColor = settingsAsync == null
        ? (isDark ? colors.bgMain : colors.surface)
        : settingsAsync.maybeWhen(
            data: (settings) {
              if (isDark) return colors.bgMain;
              return settings.chatBackgroundColor.color ?? colors.surface;
            },
            orElse: () => isDark ? colors.bgMain : colors.surface,
          );
    final hasCustomBackground =
        (conv?.chatBackgroundImage?.trim().isNotEmpty ?? false);
    final extendBehindAppBar = hasCustomBackground;
    final listTopSpacing = extendBehindAppBar
        ? MediaQuery.paddingOf(context).top + kToolbarHeight
        : 0.0;

    return Scaffold(
      // (注释已丢失)
      resizeToAvoidBottomInset: false,
      extendBodyBehindAppBar: extendBehindAppBar,
      appBar: AppBar(
        backgroundColor:
            hasCustomBackground ? Colors.transparent : colors.headerColor,
        foregroundColor: colors.headerContentColor,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        titleTextStyle: TextStyle(
          fontSize: 22, // (注释已丢失)
          fontWeight: MoeFontWeights.emphasis,
          color: colors.headerContentColor,
          letterSpacing: 0.8,
        ),
        bottom: hasCustomBackground
            ? null
            : PreferredSize(
                preferredSize: const Size.fromHeight(borderWidth),
                child: Container(
                  height: borderWidth,
                  decoration: BoxDecoration(
                    color: colors.divider,
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.04),
                        offset: const Offset(0, 1),
                        blurRadius: 0,
                      ),
                    ],
                  ),
                ),
              ),
        title: deferEntryShell
            ? Text(conv?.displayName ?? '聊天')
            : Consumer(
                builder: (context, ref, _) {
                  final status = ref.watch(chatStatusProvider);
                  final displayName = conv?.displayName ?? '聊天';
                  return Text(
                    status == ChatStatus.idle ? displayName : status.label,
                  );
                },
              ),
        centerTitle: false,
        leading: widget.showToggleButton && !deferEntryShell
            ? MoeG2ClipRRect(
                radius: 8,
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: () {
                      ref.read(sidebarVisibleProvider.notifier).state =
                          !sidebarVisible;
                    },
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Icon(
                        sidebarVisible ? Icons.menu_open : Icons.menu,
                        color: colors.headerContentColor,
                      ),
                    ),
                  ),
                ),
              )
            : null,
        actions: [
          if (!deferEntryShell && conv != null) ...[
            IconButton(
              icon: Icon(Icons.add_comment_outlined,
                  color: colors.headerContentColor),
              tooltip: '新话题',
              onPressed: () async {
                if (messages.isEmpty) {
                  MoeToast.brief(context, '当前没有聊天记录');
                  return;
                }
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('开始新话题'),
                    content: const Text('之前的聊天记录不会删除，但AI将只看到新话题中的消息。'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('取消'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: const Text('确定'),
                      ),
                    ],
                  ),
                );
                if (ok == true && context.mounted) {
                  final lastMsgId = messages.last.id;
                  await ref.read(conversationsProvider.notifier).updateOne(
                        conv.id,
                        (c) => c.copyWith(
                          contextStartMessageId: lastMsgId,
                          updatedAt: DateTime.now(),
                        ),
                      );
                  if (context.mounted) {
                    MoeToast.brief(context, '已开始新话题');
                  }
                }
              },
            ),
            IconButton(
              icon: Icon(Icons.more_horiz, color: colors.headerContentColor),
              tooltip: '更多',
              onPressed: () async {
                await showChatSettingsDialog(
                  context: context,
                  conversation: conv,
                  onSearchMessages: () {
                    showMoeBottomSheet(
                      context: context,
                      title: '查找聊天记录',
                      showCloseButton: true,
                      maxHeight: MediaQuery.sizeOf(context).height * 0.85,
                      builder: (context) =>
                          _ChatMessageSearchContent(conversation: conv),
                    );
                  },
                  onEditContact: () async {
                    // (注释已丢失)
                    final result =
                        await Navigator.of(context).push<ContactEditResult>(
                      ParallaxSlidePageRoute(
                          page: ContactEditPage(
                        conversation: conv,
                        editMode: EditMode.editConversation,
                      )),
                    );
                    if (result != null) {
                      await ref
                          .read(conversationsProvider.notifier)
                          .applyContactEdit(
                            conv.id,
                            displayName: result.displayName,
                            avatarUrl: result.avatarUrl,
                            clearAvatarUrl: result.clearAvatarUrl,
                            characterImage: result.characterImage,
                            clearCharacterImage: result.clearCharacterImage,
                            chatBackgroundImage: result.chatBackgroundImage,
                            clearChatBackgroundImage:
                                result.clearChatBackgroundImage,
                            clearChatBackgroundMaskOpacity:
                                result.clearChatBackgroundImage,
                            selfAddress: result.selfAddress,
                            clearSelfAddress: result.clearSelfAddress,
                            addressUser: result.addressUser,
                            clearAddressUser: result.clearAddressUser,
                            voiceFile: result.voiceFile,
                            clearVoiceFile: result.clearVoiceFile,
                            description: result.description,
                            clearDescription: result.clearDescription,
                            personaPrompt: result.personaPrompt,
                            enabledPlugins: result.enabledPlugins,
                            clearEnabledPlugins: result.clearEnabledPlugins,
                          );
                      if (!context.mounted) return;
                      MoeToast.brief(context, 'Character saved');
                    }
                  },
                  onChatBackgroundSettings: (result) async {
                    await ref
                        .read(conversationsProvider.notifier)
                        .applyContactEdit(
                          conv.id,
                          chatBackgroundImage: result.backgroundImage,
                          clearChatBackgroundImage: result.clearBackgroundImage,
                          chatBackgroundMaskOpacity: result.maskOpacity,
                          clearChatBackgroundMaskOpacity:
                              result.clearMaskOpacity,
                          chatBackgroundBlurSigma: result.blurSigma,
                          clearChatBackgroundBlurSigma: result.clearBlurSigma,
                        );
                    if (!context.mounted) return;
                    MoeToast.brief(context, 'Chat background updated');
                  },
                  onPinnedChanged: (value) async {
                    await ref
                        .read(conversationsProvider.notifier)
                        .updateConversationSettings(
                          conv.id,
                          isPinned: value,
                        );
                    if (!context.mounted) return;
                    MoeToast.brief(
                      context,
                      value ? 'Pinned' : 'Unpinned',
                    );
                  },
                  onMutedChanged: (value) async {
                    await ref
                        .read(conversationsProvider.notifier)
                        .updateConversationSettings(
                          conv.id,
                          isMuted: value,
                        );
                    if (!context.mounted) return;
                    MoeToast.brief(context, value ? '已开启免打扰' : '已关闭免打扰');
                  },
                  onNotificationSoundChanged: (value) async {
                    await ref
                        .read(conversationsProvider.notifier)
                        .updateConversationSettings(
                          conv.id,
                          notificationSound: value,
                        );
                    if (!context.mounted) return;
                    MoeToast.brief(context, value ? '已开启提示音' : '已关闭提示音');
                  },
                  onClearMessages: () async {
                    await ref
                        .read(conversationsProvider.notifier)
                        .clearMessages(conv.id);
                    if (!context.mounted) return;
                    MoeToast.brief(context, 'Chat history cleared');
                  },
                  onDeleteConversation: () async {
                    await ref
                        .read(conversationsProvider.notifier)
                        .deleteConversation(conv.id);
                    if (context.mounted && context.canPop()) context.pop();
                  },
                  onEnabledPluginsChanged: (plugins) async {
                    await ref
                        .read(conversationsProvider.notifier)
                        .updateConversationSettings(
                          conv.id,
                          enabledPlugins: plugins,
                          clearEnabledPlugins: plugins == null,
                        );
                    if (!context.mounted) return;
                    MoeToast.brief(context, 'Plugin settings updated');
                  },
                );
              },
            ),
          ],
          const SizedBox(width: 8),
        ],
      ),
      body: _buildConversationBackground(
        conv: conv,
        fallbackColor: chatBgColor,
        child: Stack(
          children: [
            // 消息列表（填满全屏，自带 bottom padding 避开 Composer 和键盘）
            Column(
              children: [
                if (listTopSpacing > 0) SizedBox(height: listTopSpacing),
                Expanded(
                  child: conv == null
                      ? const Center(child: CircularProgressIndicator())
                      : GestureDetector(
                          behavior: HitTestBehavior.translucent,
                          onTap: () {
                            final keyboardHeight =
                                MediaQuery.viewInsetsOf(context).bottom;
                            if (keyboardHeight > 0) {
                              SystemChannels.textInput
                                  .invokeMethod('TextInput.hide');
                              return;
                            }
                            FocusManager.instance.primaryFocus?.unfocus();
                          },
                          child: ChatMessageList(
                            key: ValueKey(conv.id),
                            conversationId: conv.id,
                            messages: messages,
                            transientMessages: transientMessages,
                            avatarUrl: conv.avatarUrl ?? conv.characterImage,
                            displayName: conv.displayName,
                            bottomOverlayHeight: _composerOverlayHeight,
                            autoScrollToBottomEnabled:
                                _autoScrollToBottomEnabled,
                            onAutoScrollDisabled: _disableChatListAutoScroll,
                            forceScrollToBottomSignal:
                                _forceScrollToBottomSignal,
                            allowPersistentViewportBoot:
                                !_databaseTimelineActivated,
                            onPersistentViewportBootMiss: () {
                              _activateDatabaseTimeline(conv.id);
                            },
                            onPersistentViewportVisibleCountResolved:
                                (visibleCount) {
                              final normalizedVisibleCount = visibleCount <
                                      kConversationInitialVisibleCount
                                  ? kConversationInitialVisibleCount
                                  : visibleCount;
                              final notifier = ref.read(
                                conversationVisibleCountProvider(conv.id)
                                    .notifier,
                              );
                              if (notifier.state != normalizedVisibleCount) {
                                notifier.state = normalizedVisibleCount;
                              }
                            },
                            onPersistentViewportHasMoreResolved: (hasMore) {
                              if (!mounted) return;
                              if (_persistentViewportHasMoreMessages !=
                                  hasMore) {
                                setState(() {
                                  _persistentViewportHasMoreMessages = hasMore;
                                });
                              }
                            },
                            expectedLastMessagePreview: conv.lastMessage,
                            expectedLastMessageTime: conv.lastMessageTime,
                            contextStartMessageId: conv.contextStartMessageId,
                            onLoadMore: () => _loadMoreMessages(conv.id),
                            isLoadingMore: _isLoadingMore,
                            hasMoreMessages: hasMoreMessages,
                            onEditMessage: (message) async {
                              _activateDatabaseTimeline(conv.id);
                              final text =
                                  await actions.editMessage(message.id);
                              if (text != null && text.isNotEmpty) {
                                ref.read(editingTextProvider.notifier).state =
                                    text;
                              }
                            },
                            onRegenerateMessage: (message) {
                              _activateDatabaseTimeline(conv.id);
                              if (ref.read(sendingProvider)) {
                                MoeToast.brief(
                                  context,
                                  'Please wait for current message to finish',
                                );
                                return;
                              }
                              actions.regenerate(message.id);
                            },
                            onEnhanceRegenerateMessage: (message) {
                              _activateDatabaseTimeline(conv.id);
                              if (ref.read(sendingProvider)) {
                                MoeToast.brief(
                                  context,
                                  'Please wait for current message to finish',
                                );
                                return;
                              }
                              actions.regenerateWithEnhancement(
                                message.id,
                              );
                            },
                          ),
                        ),
                ),
              ],
            ),
            // Composer 固定贴底；键盘位移由 Composer 内部面板容器处理
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Composer(
                onHeightChanged: _handleComposerHeightChanged,
                disabled: false,
                onInputTap: _resumeChatListAutoScroll,
                onSend: (text) async {
                  if (ref.read(sendingProvider)) {
                    MoeToast.brief(
                      context,
                      'Please wait for current message to finish',
                    );
                    return;
                  }
                  final conv = ref.read(activeConversationProvider);
                  if (conv != null) {
                    final ok = await _checkVisionCompat(conv: conv);
                    if (!ok) return;
                  }
                  final quoted = ref.read(quotedMessageProvider);
                  if (quoted != null) {
                    final quotedText = quoted.content.length > 30
                        ? '${quoted.content.substring(0, 30)}...'
                        : quoted.content;
                    final quotedPrefix = '> Quote: $quotedText\n\n';
                    if (conv != null) {
                      _activateDatabaseTimeline(conv.id);
                    }
                    _forceChatListToBottom();
                    actions.send(quotedPrefix + text);
                    ref.read(quotedMessageProvider.notifier).state = null;
                  } else {
                    if (conv != null) {
                      _activateDatabaseTimeline(conv.id);
                    }
                    _forceChatListToBottom();
                    actions.send(text);
                  }
                },
                onImageSelected: (imagePath, {String? text}) async {
                  if (ref.read(sendingProvider)) {
                    MoeToast.brief(
                      context,
                      'Please wait for current message to finish',
                    );
                    return;
                  }
                  final conv = ref.read(activeConversationProvider);
                  if (conv != null) {
                    final ok = await _checkVisionCompat(
                      conv: conv,
                      currentMessageHasImage: true,
                    );
                    if (!ok) return;
                    _activateDatabaseTimeline(conv.id);
                  }
                  _forceChatListToBottom();
                  actions.sendWithImage(imagePath, text: text);
                },
                onFileSelected: (filePath) {
                  if (ref.read(sendingProvider)) {
                    MoeToast.brief(
                      context,
                      'Please wait for current message to finish',
                    );
                    return;
                  }
                  final conv = ref.read(activeConversationProvider);
                  if (conv != null) {
                    _activateDatabaseTimeline(conv.id);
                  }
                  _forceChatListToBottom();
                  actions.sendWithFile(filePath);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChatMessageSearchContent extends ConsumerStatefulWidget {
  final Conversation conversation;

  const _ChatMessageSearchContent({required this.conversation});

  @override
  ConsumerState<_ChatMessageSearchContent> createState() =>
      _ChatMessageSearchContentState();
}

class _ChatMessageSearchContentState
    extends ConsumerState<_ChatMessageSearchContent> {
  final _searchCtrl = TextEditingController();
  Timer? _debounce;
  String _keyword = '';
  DateTime? _selectedDate;
  int _searchSeq = 0;

  bool _loading = false;
  String? _error;
  List<db.Message> _results = const [];

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  void _scheduleSearch() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      _runSearch();
    });
  }

  Future<void> _runSearch() async {
    final seq = ++_searchSeq;
    final keyword = _keyword.trim();
    final date = _selectedDate;

    // (注释已丢失)
    if (keyword.isEmpty && date == null) {
      if (!mounted || seq != _searchSeq) return;
      setState(() {
        _loading = false;
        _error = null;
        _results = const [];
      });
      return;
    }

    final int? startMs;
    final int? endMs;
    if (date == null) {
      startMs = null;
      endMs = null;
    } else {
      final start = DateTime(date.year, date.month, date.day);
      startMs = start.millisecondsSinceEpoch;
      endMs = start.add(const Duration(days: 1)).millisecondsSinceEpoch;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final repo = ref.read(messageRepositoryProvider);
      final rows = await repo.searchByConversation(
        widget.conversation.id,
        keyword: keyword.isEmpty ? null : keyword,
        startTime: startMs,
        endTime: endMs,
        limit: 200,
      );
      if (!mounted || seq != _searchSeq) return;
      setState(() {
        _loading = false;
        _results = rows;
      });
    } catch (e) {
      if (!mounted || seq != _searchSeq) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: now,
      initialDate: _selectedDate ?? now,
    );
    if (picked == null || !mounted) return;
    setState(() => _selectedDate = picked);
    _scheduleSearch();
  }

  void _clearDate() {
    setState(() => _selectedDate = null);
    _scheduleSearch();
  }

  void _clearKeyword() {
    setState(() {
      _searchCtrl.clear();
      _keyword = '';
    });
    _scheduleSearch();
  }

  String _formatDay(DateTime date) {
    final y = date.year.toString().padLeft(4, '0');
    final m = date.month.toString().padLeft(2, '0');
    final d = date.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  String _formatTime(DateTime time) {
    final ymd = _formatDay(time);
    final hh = time.hour.toString().padLeft(2, '0');
    final mm = time.minute.toString().padLeft(2, '0');
    return '$ymd $hh:$mm';
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final keyword = _keyword.trim();
    final date = _selectedDate;

    return Column(
      children: [
        // (注释已丢失)
        Padding(
          padding: const EdgeInsets.all(16),
          child: MoeTextField(
            controller: _searchCtrl,
            autofocus: true,
            hint: '输入关键词（可选）',
            prefixIcon: Icons.search,
            suffix: _searchCtrl.text.isNotEmpty
                ? IconButton(
                    icon: const Icon(Icons.clear, size: 20),
                    onPressed: _clearKeyword,
                  )
                : null,
            borderColor: colors.borderLight,
            focusBorderColor: colors.primary,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            onChanged: (value) {
              setState(() => _keyword = value);
              _scheduleSearch();
            },
          ),
        ),

        // (注释已丢失)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: MoeG2ClipRRect(
            radius: 12,
            child: Container(
              decoration: MoeG2Decoration(
                radius: 12,
                color: colors.surfaceAlt,
                border: Border.all(
                  color: colors.borderLight,
                  width: borderWidth,
                ),
              ),
              child: Material(
                color: Colors.transparent,
                child: ListTile(
                  dense: true,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
                  title: const Text('日期'),
                  subtitle: Text(date == null ? '全部' : _formatDay(date)),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: '选择日期',
                        icon: const Icon(Icons.calendar_month, size: 20),
                        color: moePrimary,
                        onPressed: _pickDate,
                      ),
                      if (date != null)
                        IconButton(
                          tooltip: '清除日期',
                          icon: const Icon(Icons.close, size: 20),
                          color: colors.muted,
                          onPressed: _clearDate,
                        ),
                    ],
                  ),
                  onTap: _pickDate,
                ),
              ),
            ),
          ),
        ),

        const SizedBox(height: 12),

        // (注释已丢失)
        Expanded(
          child: _loading
              ? const Center(child: MoeLoadingIndicator())
              : (_error != null)
                  ? MoeEmptyState(
                      icon: Icons.error_outline,
                      title: '搜索失败',
                      description: _error!,
                    )
                  : (keyword.isEmpty && date == null)
                      ? const MoeEmptyState(
                          icon: Icons.search,
                          title: '请输入关键词或选择日期',
                        )
                      : (_results.isEmpty)
                          ? const MoeEmptyState(
                              icon: Icons.search_off,
                              title: '未找到匹配的聊天记录',
                            )
                          : Column(
                              children: [
                                Padding(
                                  padding:
                                      const EdgeInsets.fromLTRB(16, 0, 16, 8),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          '共 ${_results.length} 条（最多显示 200 条）',
                                          style: TextStyle(
                                            fontSize: 12,
                                            color: colors.muted,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                Expanded(
                                  child: ListView.separated(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 16,
                                      vertical: 8,
                                    ),
                                    itemCount: _results.length,
                                    separatorBuilder: (_, __) =>
                                        const SizedBox(height: 8),
                                    itemBuilder: (context, index) {
                                      final m = _results[index];
                                      final time =
                                          DateTime.fromMillisecondsSinceEpoch(
                                              m.createdAt);
                                      final roleLabel =
                                          m.role == 'user' ? 'Me' : 'TA';
                                      final text = m.content.trim().isEmpty
                                          ? '[Non-text message]'
                                          : m.content.trim();

                                      return Container(
                                        padding: const EdgeInsets.all(12),
                                        decoration: MoeG2Decoration(
                                          radius: 8,
                                          color: colors.surfaceAlt,
                                          border: Border.all(
                                            color: colors.borderLight,
                                            width: borderWidth,
                                          ),
                                        ),
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Row(
                                              children: [
                                                Container(
                                                  padding: const EdgeInsets
                                                      .symmetric(
                                                      horizontal: 8,
                                                      vertical: 2),
                                                  decoration: MoeG2Decoration(
                                                    radius: 999,
                                                    color: colors.muted
                                                        .withValues(
                                                            alpha: 0.12),
                                                  ),
                                                  child: Text(
                                                    roleLabel,
                                                    style: TextStyle(
                                                      fontSize: 12,
                                                      color: colors.text,
                                                      fontWeight: MoeFontWeights
                                                          .emphasis,
                                                    ),
                                                  ),
                                                ),
                                                const SizedBox(width: 8),
                                                Expanded(
                                                  child: Text(
                                                    _formatTime(time),
                                                    style: TextStyle(
                                                      fontSize: 12,
                                                      color: colors.muted,
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ),
                                            const SizedBox(height: 8),
                                            Text(
                                              text,
                                              maxLines: 3,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                fontSize: 13,
                                                color: colors.text,
                                                height: 1.35,
                                              ),
                                            ),
                                          ],
                                        ),
                                      );
                                    },
                                  ),
                                ),
                              ],
                            ),
        ),
      ],
    );
  }
}
