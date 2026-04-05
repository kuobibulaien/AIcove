import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../../../features/chat/chat_actions.dart';
import '../../../../features/chat/application/chat_page_conversation_actions.dart';
import '../../../../features/chat/application/chat_page_send_support.dart'
    show chatPageSendSupportProvider;
import '../../../../features/chat/conversation_providers.dart'
    show
        activeConversationIdProvider,
        activeConversationProvider,
        conversationsProvider,
        resolvedConversationByIdProvider;
import '../../../../features/chat/conversation_timeline_providers.dart'
    show
        conversationHasMoreProvider,
        kConversationInitialVisibleCount,
        conversationMessagesProvider,
        conversationVisibleCountProvider,
        kConversationVisiblePageSize;
import '../../../../features/chat/services/conversation_short_window_store.dart'
    show ConversationTimelineCache, conversationTimelineCacheProvider;
import '../../../../features/chat/domain/conversation.dart';
import '../../../../features/chat/domain/message.dart';
import '../../../../features/chat/presentation/widgets/composer.dart';
import '../../../../features/chat/presentation/widgets/contact_edit_dialog.dart';
import '../../../../ui/features/character/pages/contact_edit_page.dart';
import '../../../../features/chat/presentation/widgets/chat_settings_dialog.dart';
import '../../../../ui/theme/tokens.dart';
import '../../../../ui/shared/animations/parallax_slide_page_route.dart';
import '../../../../ui/shared/effects/smooth_clip.dart';
import '../../../../ui/shared/widgets/index.dart';
import '../../../../features/settings/app_settings.dart';
import '../../../../core/models/message_block.dart';
import '../../../../core/utils/blurred_background_service.dart';
import '../../../../core/utils/data_image.dart';
import '../../../../core/utils/image_preheat_queue.dart';
import '../../../../features/observability/trace_models.dart';
import '../../../../features/observability/trace_query_service.dart';
import '../../../../features/observability/trace_store.dart';
import '../../../../ui/features/settings/pages/log_formatters.dart';
import 'deferred_conversation_activation.dart';
import '../widgets/chat_message_list.dart';
import '../widgets/chat_viewport_controller.dart';
import '../widgets/chat_message_search_content.dart';

const Duration kChatPageImagePrecacheDelay = Duration(milliseconds: 180);
const Duration kChatPageUnreadClearDelay = Duration(milliseconds: 160);

@visibleForTesting
Future<int> resolveChatPageLoadMoreVisibleCount({
  required ConversationTimelineCache store,
  required String conversationId,
  required int currentVisibleCount,
  int pageSize = kConversationVisiblePageSize,
}) async {
  final localMessageCount = await store.loadCachedMessageCount(conversationId);
  if (localMessageCount > currentVisibleCount) {
    return localMessageCount;
  }

  final addedCount = await store.loadOlderMessages(
    conversationId: conversationId,
    pageSize: pageSize,
  );
  if (addedCount <= 0) {
    return currentVisibleCount;
  }
  return currentVisibleCount + addedCount;
}

@visibleForTesting
List<Message> resolveChatPageLoadingFallbackMessages({
  required String? conversationId,
  required String? cachedConversationId,
  required List<Message> cachedMessages,
  required bool isGenerating,
  List<Message>? inMemoryTimelineMessages,
}) {
  final normalizedConversationId = conversationId?.trim();
  if (normalizedConversationId == null || normalizedConversationId.isEmpty) {
    return const <Message>[];
  }

  final fallbackMessages = cachedConversationId == normalizedConversationId
      ? cachedMessages
      : (inMemoryTimelineMessages ?? const <Message>[]);
  if (isGenerating) {
    return fallbackMessages;
  }

  return <Message>[
    for (final message in fallbackMessages)
      if (!(message.role == 'assistant' && message.status == 'sending'))
        message,
  ];
}

@visibleForTesting
String resolveChatPageAppBarTitle({
  required String displayName,
  required String? conversationId,
  required ChatStatus chatStatus,
  required List<TraceEvent> traceEvents,
}) {
  final normalizedDisplayName =
      displayName.trim().isEmpty ? '聊天' : displayName.trim();
  final statusLabel = switch (chatStatus) {
    ChatStatus.generatingImage ||
    ChatStatus.generatingVoice ||
    ChatStatus.toolCalling =>
      chatStatus.label.trim(),
    _ => '',
  };
  if (statusLabel.isNotEmpty) {
    return statusLabel;
  }
  final normalizedConversationId = conversationId?.trim() ?? '';
  if (normalizedConversationId.isEmpty || traceEvents.isEmpty) {
    return normalizedDisplayName;
  }

  final conversationEvents = traceEvents
      .where((event) => event.sessionId == normalizedConversationId)
      .toList(growable: false);
  if (conversationEvents.isEmpty) {
    return normalizedDisplayName;
  }

  TraceTurnSummary? activeTurn;
  for (final turn in TraceQueryService.aggregateTurns(conversationEvents)) {
    if (turn.status == TraceEventStatus.running.value) {
      activeTurn = turn;
      break;
    }
  }
  if (activeTurn == null) {
    return normalizedDisplayName;
  }

  final timeline = TraceQueryService.sortEvents(
    conversationEvents
        .where((event) => event.traceId == activeTurn!.traceId)
        .toList(growable: false),
  );
  if (timeline.isEmpty) {
    return normalizedDisplayName;
  }

  final stageLabel = stageToZh(timeline.last.stage).trim();
  if (stageLabel.isEmpty || stageLabel == timeline.last.stage) {
    return normalizedDisplayName;
  }
  return stageLabel;
}

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

  /// (注释已丢失)
  String? _preloadedConversationId;
  bool _didSchedulePrecache = false;
  double _composerOverlayHeight = 0;
  late final ChatViewportController _viewportController;
  Timer? _imagePrecacheTimer;
  Timer? _clearUnreadTimer;
  String? _staticBackgroundBlurSource;
  ImageProvider? _staticBackgroundBlurProvider;
  bool _deferredEntryShellActive = false;
  String? _entrySideEffectsConversationId;
  String? _timelineDisplayCacheConversationId;
  List<Message> _timelineDisplayCacheMessages = const <Message>[];
  int? _activeFailoverPromptRequestId;
  late final ModelFailoverPromptController _modelFailoverPromptController;
  final DeferredConversationActivation _conversationActivation =
      DeferredConversationActivation();

  bool get _shouldDeferEntrySideEffects => _deferredEntryShellActive;

  @override
  void initState() {
    super.initState();
    _viewportController = ChatViewportController();
    _modelFailoverPromptController =
        ref.read(modelFailoverPromptProvider.notifier);
    final targetId = widget.conversationId;
    if (targetId == null) return;
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

  void _startEntrySideEffects(String conversationId) {
    final normalizedConversationId = conversationId.trim();
    if (normalizedConversationId.isEmpty) return;
    if (_entrySideEffectsConversationId == normalizedConversationId) return;
    _entrySideEffectsConversationId = normalizedConversationId;
    _scheduleConversationActivation(conversationId);
    _scheduleUnreadClear(conversationId);
    _scheduleImagePrecache();
  }

  void _ensureImplicitConversationEntrySideEffects(String? conversationId) {
    if (widget.conversationId != null) return;
    final normalizedConversationId = conversationId?.trim();
    if (normalizedConversationId == null || normalizedConversationId.isEmpty) {
      return;
    }
    if (_entrySideEffectsConversationId == normalizedConversationId) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_resolveCurrentConversationId() != normalizedConversationId) {
        return;
      }
      _startEntrySideEffects(normalizedConversationId);
    });
  }

  String? _resolveCurrentConversationId() {
    final explicitConversationId = widget.conversationId?.trim();
    if (explicitConversationId != null && explicitConversationId.isNotEmpty) {
      return explicitConversationId;
    }
    final activeConversationId = ref.read(activeConversationIdProvider)?.trim();
    if (activeConversationId != null && activeConversationId.isNotEmpty) {
      return activeConversationId;
    }
    return null;
  }

  List<Message> _resolveMessagesForDisplay({
    required String? conversationId,
    required AsyncValue<List<Message>> messagesAsync,
    required bool isGenerating,
    List<Message>? inMemoryTimelineMessages,
  }) {
    final normalizedConversationId = conversationId?.trim();
    if (normalizedConversationId == null || normalizedConversationId.isEmpty) {
      _timelineDisplayCacheConversationId = null;
      _timelineDisplayCacheMessages = const <Message>[];
      return const <Message>[];
    }

    if (messagesAsync.hasValue) {
      final directMessages = messagesAsync.valueOrNull ?? const <Message>[];
      _timelineDisplayCacheConversationId = normalizedConversationId;
      _timelineDisplayCacheMessages = directMessages;
      return directMessages;
    }

    if (_timelineDisplayCacheConversationId != normalizedConversationId) {
      return resolveChatPageLoadingFallbackMessages(
        conversationId: normalizedConversationId,
        cachedConversationId: _timelineDisplayCacheConversationId,
        cachedMessages: _timelineDisplayCacheMessages,
        isGenerating: isGenerating,
        inMemoryTimelineMessages: inMemoryTimelineMessages,
      );
    }

    return resolveChatPageLoadingFallbackMessages(
      conversationId: normalizedConversationId,
      cachedConversationId: _timelineDisplayCacheConversationId,
      cachedMessages: _timelineDisplayCacheMessages,
      isGenerating: isGenerating,
    );
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
      unawaited(ref.read(chatPageConversationActionsProvider).clearUnread(
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

  /// 检查视觉兼容性，必要时弹窗确认
  ///
  /// 返回 true 表示可以继续发送，false 表示用户取消
  void _handleComposerHeightChanged(double height) {
    if (!mounted || !height.isFinite || height < 0) return;
    if ((height - _composerOverlayHeight).abs() < 0.5) return;
    setState(() => _composerOverlayHeight = height);
  }

  void _resumeChatListAutoScroll() {
    _viewportController.onComposerTapped();
  }

  void _forceChatListToBottom() {
    _viewportController.onUserSend();
  }

  void _showSendingInProgressToast() {
    MoeToast.brief(
      context,
      'Please wait for current message to finish',
    );
  }

  Future<bool> _preparePlainTextSend() async {
    if (ref.read(sendingProvider)) {
      _showSendingInProgressToast();
      return false;
    }
    final conv = ref.read(activeConversationProvider);
    if (conv != null) {
      final ok = await _checkVisionCompat(conv: conv);
      if (!ok) return false;
    }
    return true;
  }

  void _dispatchPlainTextSend(
    String text, {
    bool throughComposer = true,
  }) {
    _forceChatListToBottom();
    final actions = ref.read(chatActionsProvider);
    if (throughComposer) {
      unawaited(actions.sendComposerText(text));
      return;
    }
    unawaited(actions.send(text));
  }

  Future<bool> _checkVisionCompat({
    required Conversation conv,
    bool currentMessageHasImage = false,
  }) async {
    final decision =
        await ref.read(chatPageSendSupportProvider).resolveVisionCompatibility(
              conversation: conv,
              currentMessageHasImage: currentMessageHasImage,
            );
    if (decision.canSend) {
      return true;
    }

    if (!mounted) return false;
    final confirmed = await _showVisionCompatDialog(
      context: context,
      modelName: decision.modelDisplayName ?? '当前模型',
      hasVisionModel: decision.hasVisionModel,
    );
    return confirmed == true;
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

    ref.read(modelFailoverPromptProvider.notifier).dismiss(
          defaultDecision: ModelFailoverDecision.cancel,
        );
  }

  Future<void> _showModelFailoverPrompt(
    ModelFailoverPromptRequest request,
  ) async {
    if (!mounted) {
      ref.read(modelFailoverPromptProvider.notifier).dismiss();
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
        content: Text(
          '当前模型“${request.failedModelName}”这次请求失败。\n'
          '要继续重试当前模型，还是改为尝试下一个模型“${request.nextModelName}”？',
        ),
      );

      if (!mounted) {
        ref.read(modelFailoverPromptProvider.notifier).dismiss();
        return;
      }
      if (result == null) {
        if (!handledByTitleAction) {
          ref.read(modelFailoverPromptProvider.notifier).dismiss();
        }
        return;
      }

      ref.read(modelFailoverPromptProvider.notifier).resolve(
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
    final messages =
        ref.read(conversationMessagesProvider(targetId)).valueOrNull ??
            const <Message>[];

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
      _entrySideEffectsConversationId = null;
      _timelineDisplayCacheConversationId = null;
      _timelineDisplayCacheMessages = const <Message>[];
      _deferredEntryShellActive = false;
      setState(() => _isLoadingMore = false);
      _viewportController.onConversationChanged();
      _preloadedConversationId = null;
      if (targetId == null) {
        return;
      }
      _startEntrySideEffects(targetId);
    }
  }

  @override
  void dispose() {
    _modelFailoverPromptController.dismiss();
    _conversationActivation.clear();
    _imagePrecacheTimer?.cancel();
    _clearUnreadTimer?.cancel();
    _viewportController.dispose();
    super.dispose();
  }

  /// (注释已丢失)
  Future<void> _loadMoreMessages(String conversationId) async {
    if (_isLoadingMore) return;
    if (!ref.read(conversationHasMoreProvider(conversationId))) return;

    setState(() => _isLoadingMore = true);

    try {
      final store = ref.read(conversationTimelineCacheProvider);
      final visibleCountNotifier =
          ref.read(conversationVisibleCountProvider(conversationId).notifier);
      final currentVisibleCount = visibleCountNotifier.state;
      final nextVisibleCount = await resolveChatPageLoadMoreVisibleCount(
        store: store,
        conversationId: conversationId,
        currentVisibleCount: currentVisibleCount,
      );
      if (nextVisibleCount > currentVisibleCount) {
        visibleCountNotifier.state = nextVisibleCount;
      }
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
        : ref.watch(resolvedConversationByIdProvider(targetId));
    final conv = targetId == null
        ? ref.watch(activeConversationProvider)
        : deferEntryShell
            ? initial
            : targetConversation ?? initial;
    final currentConversationId = conv?.id ?? targetId;
    _ensureImplicitConversationEntrySideEffects(currentConversationId);
    final messagesAsync = currentConversationId == null
        ? const AsyncValue.data(<Message>[])
        : ref.watch(conversationMessagesProvider(currentConversationId));
    final isGenerating = ref.watch(sendingProvider);
    final inMemoryTimelineMessages = currentConversationId == null
        ? null
        : ref
            .read(conversationTimelineCacheProvider)
            .peekWindow(
              conversationId: currentConversationId,
              limit: kConversationInitialVisibleCount,
            )
            ?.messages;
    final messages = _resolveMessagesForDisplay(
      conversationId: currentConversationId,
      messagesAsync: messagesAsync,
      isGenerating: isGenerating,
      inMemoryTimelineMessages: inMemoryTimelineMessages,
    );
    final hasMoreMessages = currentConversationId == null
        ? false
        : ref.watch(conversationHasMoreProvider(currentConversationId));
    const transientMessages = <Message>[];
    final actions = ref.read(chatActionsProvider); // (注释已丢失)
    final sidebarVisible = widget.showToggleButton && !deferEntryShell
        ? ref.watch(sidebarVisibleProvider)
        : false;
    final chatStatus = ref.watch(chatStatusProvider);
    final settingsAsync =
        deferEntryShell ? null : ref.watch(appSettingsProvider);
    final colors = context.moeColors;

    // 监听模型切换确认请求，弹公共确认框
    ref.listen<ModelFailoverPromptRequest?>(modelFailoverPromptProvider,
        (prev, next) {
      if (next == null || !mounted) return;
      unawaited(_showModelFailoverPrompt(next));
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
            : ValueListenableBuilder<List<TraceEvent>>(
                valueListenable: TraceStore.instance.entries,
                builder: (context, traceEvents, _) {
                  final displayName = conv?.displayName ?? '聊天';
                  return Text(
                    resolveChatPageAppBarTitle(
                      displayName: displayName,
                      conversationId: currentConversationId,
                      chatStatus: chatStatus,
                      traceEvents: traceEvents,
                    ),
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
                  final lastMsgId = messages.last.sourceMessageIdOrSelf;
                  await ref
                      .read(chatPageConversationActionsProvider)
                      .startNewTopic(
                        conversationId: conv.id,
                        lastMessageId: lastMsgId,
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
                      builder: (context) => ChatMessageSearchContent(
                        conversationId: conv.id,
                      ),
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
                          .read(chatPageConversationActionsProvider)
                          .applyConversationEdits(
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
                        .read(chatPageConversationActionsProvider)
                        .applyConversationEdits(
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
                        .read(chatPageConversationActionsProvider)
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
                        .read(chatPageConversationActionsProvider)
                        .updateConversationSettings(
                          conv.id,
                          isMuted: value,
                        );
                    if (!context.mounted) return;
                    MoeToast.brief(context, value ? '已开启免打扰' : '已关闭免打扰');
                  },
                  onNotificationSoundChanged: (value) async {
                    await ref
                        .read(chatPageConversationActionsProvider)
                        .updateConversationSettings(
                          conv.id,
                          notificationSound: value,
                        );
                    if (!context.mounted) return;
                    MoeToast.brief(context, value ? '已开启提示音' : '已关闭提示音');
                  },
                  onClearMessages: () async {
                    await ref
                        .read(chatPageConversationActionsProvider)
                        .clearMessages(conv.id);
                    if (!context.mounted) return;
                    MoeToast.brief(context, 'Chat history cleared');
                  },
                  onDeleteConversation: () async {
                    await ref
                        .read(chatPageConversationActionsProvider)
                        .deleteConversation(conv.id);
                    if (context.mounted && context.canPop()) context.pop();
                  },
                  onEnabledPluginsChanged: (plugins) async {
                    await ref
                        .read(chatPageConversationActionsProvider)
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
                            viewportController: _viewportController,
                            contextStartMessageId: conv.contextStartMessageId,
                            onLoadMore: () => _loadMoreMessages(conv.id),
                            isLoadingMore: _isLoadingMore,
                            hasMoreMessages: hasMoreMessages,
                            onEditMessage: (message) async {
                              final text =
                                  await actions.editMessage(message.id);
                              if (text != null && text.isNotEmpty) {
                                ref.read(editingTextProvider.notifier).state =
                                    text;
                              }
                            },
                            onRegenerateMessage: (message) async {
                              if (ref.read(sendingProvider)) {
                                _showSendingInProgressToast();
                                return;
                              }
                              await actions.regenerate(message.id);
                            },
                            onEnhanceRegenerateMessage: (message) {
                              if (ref.read(sendingProvider)) {
                                _showSendingInProgressToast();
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
                  final canSend = await _preparePlainTextSend();
                  if (!canSend) return;
                  _dispatchPlainTextSend(text);
                },
                onImageSelected: (imagePath, {String? text}) async {
                  if (ref.read(sendingProvider)) {
                    _showSendingInProgressToast();
                    return;
                  }
                  final conv = ref.read(activeConversationProvider);
                  if (conv != null) {
                    final ok = await _checkVisionCompat(
                      conv: conv,
                      currentMessageHasImage: true,
                    );
                    if (!ok) return;
                  }
                  _forceChatListToBottom();
                  actions.sendWithImage(imagePath, text: text);
                },
                onFileSelected: (filePath) {
                  if (ref.read(sendingProvider)) {
                    _showSendingInProgressToast();
                    return;
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
