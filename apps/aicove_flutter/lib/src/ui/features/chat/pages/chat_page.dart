import '../../../theme/moe_interaction_theme.dart';
import 'chat_image_export_page.dart';
import '../widgets/voice_autoplay_prompt.dart';
import '../widgets/chat_share_sheet.dart';
import '../../plugins/widgets/drawing_preset_picker_sheet.dart';
import '../widgets/chat_message_selection.dart';
import 'chat_interface_settings_page.dart';
import 'chat_tavern_preset_page.dart';
import 'dart:async';
import 'dart:io';
import '../../../shared/widgets/desktop_window_frame.dart';
import '../../character/pages/contact_edit_page.dart';
import '../../character/services/contact_edit_snapshot_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../../../features/chat/chat_actions.dart';
import '../../../../features/chat/application/chat_page_conversation_actions.dart';
import '../../../../features/chat/application/chat_view_prefs.dart';
import '../../../../features/chat/application/chat_page_send_support.dart'
    show ChatPageVisionCompatibilityDecision, chatPageSendSupportProvider;
import '../../../../features/chat/conversation_providers.dart'
    show
        activeConversationIdProvider,
        activeConversationProvider,
        chatDisplayPolicyProvider,
        conversationSnapshotByIdProvider,
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
import '../../../../features/chat/domain/model_request_error_report.dart';
import '../../../../features/chat/presentation/widgets/composer.dart';
import '../../../../features/plugins/image/drawing_preset_provider.dart';
import '../../../../features/stickers/sticker_registry.dart';
import '../../../../features/plugins/plugin_providers.dart'
    show timeAwarenessPluginConfigProvider, ttsPluginConfigProvider;
import '../../../../ui/theme/tokens.dart';
import '../../../../ui/shared/widgets/index.dart';
import '../../../../features/settings/app_settings.dart';
import '../../../../core/models/message_block.dart';
import '../../../../core/services/attachment_picker_service.dart';
import '../../../../core/utils/image_preheat_queue.dart';
import '../../../../features/observability/trace_models.dart';
import '../../../../features/observability/frontend_diagnostics_port.dart';
import '../../../../features/observability/frontend_diagnostics_provider.dart';
import '../../../../features/observability/trace_query_service.dart';
import '../../../../features/observability/trace_store.dart';
import '../../../../ui/features/settings/pages/log_formatters.dart';
import 'deferred_conversation_activation.dart';
import '../../../../features/assistant/application/assistant_approvals.dart';
import '../../assistant/widgets/assistant_activity_panel.dart';
import '../../assistant/widgets/assistant_onboarding_view.dart';
import '../../../../features/assistant/application/assistant_onboarding_controller.dart';
import '../../../../features/assistant/domain/assistant_onboarding.dart';
import '../widgets/chat_message_list.dart';
import '../widgets/model_failover_error_content.dart';
import '../widgets/topic_compaction_button.dart';
import '../../../../features/context/application/context_manager.dart'
    show ManualCompactionSessionState;
import '../../../../features/context/providers/context_providers.dart'
    show manualCompactionSessionProvider, manualCompactionStateProvider;
import '../widgets/frontend_message_probe.dart';
import '../widgets/chat_viewport_controller.dart';
import '../widgets/chat_wallpaper_background.dart';
import '../../voice_call/widgets/call_record_bubble.dart';
import '../../voice_call/widgets/voice_call_view.dart';
import '../../voice_call/window/voice_call_window_launcher.dart';
import '../../voice_call/widgets/voice_call_floating_window.dart';
import '../../voice_call/widgets/voice_call_live_messages.dart';
import '../../../../features/voice_call/application/active_voice_call.dart';
import '../../../../features/voice_call/providers/voice_call_providers.dart'
    show ActiveVoiceCallNotifier, activeVoiceCallProvider, voiceCallFactoryProvider;

part 'chat_page_app_bar_and_sheets.dart';
part 'chat_page_helpers.dart';
part 'chat_page_voice_and_media.dart';

const Duration kChatPageImagePrecacheDelay = Duration(milliseconds: 180);
const Duration kChatPageUnreadClearDelay = Duration(milliseconds: 160);

/// 聊天页的会话订阅值：只按 [Conversation.sameChatPageConfig] 判断变化，
/// 摘要字段变了仍视为相等，`select` 保留旧实例而不重建页面。
class _ChatPageConversation {
  const _ChatPageConversation(this.value);

  final Conversation? value;

  @override
  bool operator ==(Object other) =>
      other is _ChatPageConversation &&
      (value == null
          ? other.value == null
          : value!.sameChatPageConfig(other.value));

  @override
  int get hashCode => value?.id.hashCode ?? 0;
}

class ChatPage extends ConsumerStatefulWidget {
  final String? conversationId;
  final Conversation? initialConversation;
  final bool showToggleButton;
  const ChatPage({
    super.key,
    this.conversationId,
    this.initialConversation,
    this.showToggleButton = false,
  });

  @override
  ConsumerState<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends ConsumerState<ChatPage> {
  final _chatMenuKey = GlobalKey();
  Offset? _chatMenuPosition;

  final _selection = ChatMessageSelection();
  bool _selectionBusy = false;
  final _selectionBarKey = GlobalKey();
  double _normalComposerHeight = 0;


  void _updateState(VoidCallback fn) => setState(fn);

  void _selectionChanged() {
    if (!mounted) return;
    if (_selection.active) FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      if (!_selection.active) _composerOverlayHeight = _normalComposerHeight;
    });
  }

  late final FrontendDiagnosticsPort _diagnostics;
  FrontendDiagnosticContext? _diagnosticEntry;
  String? _diagnosticLayoutScheduledFor;
  bool _diagnosticLayoutRecorded = false;

  void _observeFrontendEntry(
    String? conversationId,
    AsyncValue<List<Message>> messages,
  ) {
    if (conversationId == null) return;
    if (_diagnosticEntry?.conversationId != conversationId) {
      _diagnostics.record(
        _diagnosticEntry,
        _diagnosticLayoutRecorded
            ? FrontendStage.pageLeft
            : FrontendStage.pageLeftBeforeLayout,
        once: true,
      );
      _diagnosticEntry = _diagnostics.begin(
        FrontendStage.pageOpened,
        conversationId: conversationId,
      );
      _diagnosticLayoutRecorded = false;
    }
    final entry = _diagnosticEntry;
    if (messages.hasError) {
      _diagnostics.record(
        entry,
        FrontendStage.historyFailed,
        error: messages.error,
        stackTrace: messages.stackTrace,
        once: true,
      );
    }
    if (!messages.hasValue) return;
    _diagnostics.record(
      entry,
      FrontendStage.historyReady,
      itemCount: messages.valueOrNull?.length,
      once: true,
    );
    if (_diagnosticLayoutRecorded ||
        _diagnosticLayoutScheduledFor == entry?.operationId) {
      return;
    }
    _diagnosticLayoutScheduledFor = entry?.operationId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_diagnosticLayoutScheduledFor == entry?.operationId) {
        _diagnosticLayoutScheduledFor = null;
      }
      if (!mounted ||
          _diagnosticEntry != entry ||
          !isDiagnosticLayoutVisible(context)) {
        return;
      }
      _diagnosticLayoutRecorded = true;
      _diagnostics.record(entry, FrontendStage.pageLayoutReady, once: true);
    });
  }

  /// (注释已丢失)
  bool _isLoadingMore = false;

  /// (注释已丢失)
  String? _preloadedConversationId;
  bool _didSchedulePrecache = false;
  double _composerOverlayHeight = 0;

  /// Height of the assistant's approval and undo panel above the composer.
  double _assistantPanelHeight = 0;
  final _assistantPanelKey = GlobalKey();
  late final ChatViewportController _viewportController;
  Timer? _imagePrecacheTimer;
  Timer? _clearUnreadTimer;
  late final AppLifecycleListener _lifecycle;
  Animation<double>? _entryRouteAnimation;
  String? _pendingUnreadConversationId;
  bool _imagePrecachePending = false;
  bool _deferredEntryShellActive = false;
  String? _entrySideEffectsConversationId;
  String? _timelineDisplayCacheConversationId;
  List<Message> _timelineDisplayCacheMessages = const <Message>[];
  int? _activeFailoverPromptRequestId;
  String? _failoverPresenterConversationId;
  VoidCallback? _detachFailoverPresenter;
  late final ModelFailoverPromptController _modelFailoverPromptController;
  final DeferredConversationActivation _conversationActivation =
      DeferredConversationActivation();

  bool get _routeTransitionInProgress =>
      _entryRouteAnimation?.status == AnimationStatus.forward ||
      _entryRouteAnimation?.status == AnimationStatus.reverse;

  bool get _shouldDeferEntrySideEffects =>
      _deferredEntryShellActive || _routeTransitionInProgress;

  void _bindEntryRouteAnimation() {
    final animation = ModalRoute.of(context)?.animation;
    if (identical(animation, _entryRouteAnimation)) return;
    _entryRouteAnimation?.removeStatusListener(_onEntryRouteStatus);
    _entryRouteAnimation = animation;
    animation?.addStatusListener(_onEntryRouteStatus);
  }

  void _onEntryRouteStatus(AnimationStatus status) {
    if (!mounted || status != AnimationStatus.completed) return;
    final pendingUnread = _pendingUnreadConversationId;
    if (pendingUnread != null) _scheduleUnreadClear(pendingUnread);
    if (_imagePrecachePending) _scheduleImagePrecache();
  }

  @override
  void initState() {
    super.initState();
    _selection.addListener(_selectionChanged);
    _lifecycle = AppLifecycleListener(onResume: _clearUnreadIfShown);
    _diagnostics = ref.read(frontendDiagnosticsProvider);
    if (widget.conversationId != null) {
      _diagnosticEntry = _diagnostics.begin(
        FrontendStage.pageOpened,
        conversationId: widget.conversationId,
      );
    }
    _viewportController = ChatViewportController();
    _modelFailoverPromptController = ref.read(
      modelFailoverPromptProvider.notifier,
    );
    _voiceCalls = ref.read(activeVoiceCallProvider.notifier);
    final targetId = widget.conversationId;
    if (targetId == null) return;
    _startEntrySideEffects(targetId);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _bindEntryRouteAnimation();
    // Also runs when a route pushed over this page pops: counts that arrived
    // while it was covered are read once the page shows again.
    _clearUnreadIfShown();
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
    _imagePrecachePending = true;
    if (_didSchedulePrecache || _routeTransitionInProgress) return;
    _didSchedulePrecache = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _didSchedulePrecache = false;
      if (!mounted || _routeTransitionInProgress) return;
      _imagePrecacheTimer?.cancel();
      _imagePrecacheTimer = Timer(kChatPageImagePrecacheDelay, () {
        if (!mounted || _routeTransitionInProgress) return;
        _imagePrecachePending = false;
        _triggerImagePreload();
      });
    });
  }

  void _scheduleUnreadClear(String conversationId) {
    _pendingUnreadConversationId = conversationId;
    _clearUnreadTimer?.cancel();
    if (_routeTransitionInProgress) return;
    _clearUnreadTimer = Timer(kChatPageUnreadClearDelay, () {
      if (!mounted ||
          _routeTransitionInProgress ||
          !_isShownToUser ||
          _resolveCurrentConversationId() != conversationId) {
        return;
      }
      _pendingUnreadConversationId = null;
      unawaited(
        ref
            .read(chatPageConversationActionsProvider)
            .clearUnread(conversationId),
      );
    });
  }

  /// Messages that arrive on their own (proactive replies) raise the unread
  /// count; while this page shows that conversation in the foreground they
  /// are read already. Counts that arrive while the app is away wait for it
  /// to come back.
  void _clearUnreadIfShown() {
    if (!mounted) return;
    final conversationId = _resolveCurrentConversationId();
    if (conversationId == null) return;
    final unread =
        ref.read(conversationSnapshotByIdProvider(conversationId))?.unreadCount;
    if (unread == null || unread <= 0 || !_isShownToUser) return;
    _scheduleUnreadClear(conversationId);
  }

  /// This page is the top route and the app is in the foreground.
  bool get _isShownToUser {
    if (ModalRoute.of(context)?.isCurrent == false) return false;
    final state = SchedulerBinding.instance.lifecycleState;
    return state == null || state == AppLifecycleState.resumed;
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
    _normalComposerHeight = height;
    if (_selection.active) return;
    if ((height - _composerOverlayHeight).abs() < 0.5) return;
    setState(() => _composerOverlayHeight = height);
  }

  void _resumeChatListAutoScroll() {
    _viewportController.onComposerTapped();
  }

  void _forceChatListToBottom() {
    final autoScroll =
        ref.read(appSettingsProvider).valueOrNull?.autoScrollOnSend ?? true;
    if (!autoScroll) return;
    _viewportController.onUserSend();
  }

  late final ActiveVoiceCallNotifier _voiceCalls;
  ActiveVoiceCall? _boundCall;
  List<Message> _voiceCallMessages = const <Message>[];


  void _onVoiceCallChanged() {
    final call = _boundCall;
    if (!mounted || call == null) return;
    final next = voiceCallLiveMessages(call);
    final previous = _voiceCallMessages;
    final changed =
        next.length != previous.length ||
        !next.every((m) => previous.any((p) => p.id == m.id));
    setState(() {
      // 列表按引用判断临时消息是否变化，没变就沿用原列表。
      if (changed) _voiceCallMessages = next;
    });
    if (next.length > previous.length) _forceChatListToBottom();
  }


  /// 最近一次构建时的会话；聊天页关掉时只挂断这个聊天里的通话。
  String? _shownConversationId;

  bool _checkingVoiceCall = false;


  /// 没打开成功的小窗：这通电话改在聊天页里显示，不再反复尝试。
  ActiveVoiceCall? _windowFailedCall;
  bool _openingCallWindow = false;


  void _showSendingInProgressToast() {
    MoeToast.brief(context, 'Please wait for current message to finish');
  }

  bool _isCurrentSendOwner(String conversationId) =>
      mounted &&
      _resolveCurrentConversationId() == conversationId &&
      ref.read(activeConversationProvider)?.id == conversationId;

  /// 返回 bool 表示已同步判定；返回 Future 表示还要走识图检查。
  FutureOr<bool> _preparePlainTextSend() {
    if (!mounted) return false;
    if (ref.read(sendingProvider)) {
      _showSendingInProgressToast();
      return false;
    }
    final conv = ref.read(activeConversationProvider);
    if (conv == null || !_isCurrentSendOwner(conv.id)) return false;
    final compat = _checkVisionCompat(conv: conv);
    if (compat is bool) {
      return compat &&
          _isCurrentSendOwner(conv.id) &&
          !ref.read(sendingProvider);
    }
    return compat.then(
      (ok) => ok && _isCurrentSendOwner(conv.id) && !ref.read(sendingProvider),
    );
  }

  FutureOr<bool> _submitPlainTextSend(String text) {
    if (!mounted) return false;
    final owner = ref.read(activeConversationProvider)?.id;
    final call = _typingVoiceCall(owner);
    if (call != null) return _sendToVoiceCall(call, text);
    if (owner == null) return false;
    final prepared = _preparePlainTextSend();
    if (prepared is bool) return _finishPlainTextSend(owner, text, prepared);
    return prepared.then((ok) => _finishPlainTextSend(owner, text, ok));
  }

  bool _finishPlainTextSend(String owner, String text, bool prepared) {
    if (!prepared || !_isCurrentSendOwner(owner) || ref.read(sendingProvider)) {
      return false;
    }
    if (ref.read(appSettingsProvider).valueOrNull?.allowMultiMessageSend ??
        false) {
      _forceChatListToBottom();
      ref.read(chatActionsProvider).stageComposerText(text, convId: owner);
      return true;
    }
    _dispatchPlainTextSend(text);
    return true;
  }

  Future<bool> _submitImageSend(String imagePath, {String? text}) async {
    if (!mounted) return false;
    if (_typingVoiceCall(ref.read(activeConversationProvider)?.id) != null) {
      MoeToast.brief(context, '通话中只能打字');
      return false;
    }
    if (ref.read(sendingProvider)) {
      _showSendingInProgressToast();
      return false;
    }
    final conv = ref.read(activeConversationProvider);
    if (conv == null || !_isCurrentSendOwner(conv.id)) return false;
    final ok = await _checkVisionCompat(
      conv: conv,
      currentMessageHasImage: true,
    );
    if (!ok || !_isCurrentSendOwner(conv.id) || ref.read(sendingProvider)) {
      return false;
    }
    if (ref.read(appSettingsProvider).valueOrNull?.allowMultiMessageSend ??
        false) {
      _forceChatListToBottom();
      ref
          .read(chatActionsProvider)
          .stageWithImage(imagePath, text: text, convId: conv.id);
      return true;
    }
    _diagnostics.begin(
      FrontendStage.sendRequested,
      conversationId: conv.id,
    );
    _forceChatListToBottom();
    unawaited(ref.read(chatActionsProvider).sendWithImage(imagePath, text: text));
    return true;
  }

  Future<bool> _submitStickerSend(Sticker sticker) async {
    if (!mounted) return false;
    if (_typingVoiceCall(ref.read(activeConversationProvider)?.id) != null) {
      MoeToast.brief(context, '通话中只能打字');
      return false;
    }
    if (ref.read(sendingProvider)) {
      _showSendingInProgressToast();
      return false;
    }
    final conv = ref.read(activeConversationProvider);
    if (conv == null || !_isCurrentSendOwner(conv.id)) return false;
    final ok = await _checkVisionCompat(conv: conv);
    if (!ok || !_isCurrentSendOwner(conv.id) || ref.read(sendingProvider)) {
      return false;
    }
    if (ref.read(appSettingsProvider).valueOrNull?.allowMultiMessageSend ??
        false) {
      _forceChatListToBottom();
      ref.read(chatActionsProvider).stageSticker(sticker, convId: conv.id);
      return true;
    }
    _diagnostics.begin(
      FrontendStage.sendRequested,
      conversationId: conv.id,
    );
    _forceChatListToBottom();
    unawaited(ref.read(chatActionsProvider).sendSticker(sticker));
    return true;
  }

  void _dispatchPlainTextSend(String text, {bool throughComposer = true}) {
    _diagnostics.begin(
      FrontendStage.sendRequested,
      conversationId: _resolveCurrentConversationId(),
    );
    _forceChatListToBottom();
    final actions = ref.read(chatActionsProvider);
    if (throughComposer) {
      unawaited(actions.sendComposerText(text));
      return;
    }
    unawaited(actions.send(text));
  }


  /// 登记本页正在看哪个会话：没有页面在看的会话，模型失败时直接换下一个。
  void _bindFailoverPresenter(String? conversationId) {
    if (conversationId == _failoverPresenterConversationId) return;
    final detachPrevious = _detachFailoverPresenter;
    _failoverPresenterConversationId = conversationId;
    _detachFailoverPresenter = conversationId == null
        ? null
        : _modelFailoverPromptController.attachPresenter(conversationId);
    // 注销可能结束旧会话的待决请求，不能在 build 里改状态。
    if (detachPrevious != null) scheduleMicrotask(detachPrevious);
    if (conversationId == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _failoverPresenterConversationId != conversationId) {
        return;
      }
      final pending = ref.read(modelFailoverPromptForProvider(conversationId));
      if (pending != null) unawaited(_showModelFailoverPrompt(pending));
    });
  }

  @override
  void didUpdateWidget(covariant ChatPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final targetId = widget.conversationId;
    if (targetId != oldWidget.conversationId) {
      _selection.clear();
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
    _diagnostics.record(
      _diagnosticEntry,
      _diagnosticLayoutRecorded
          ? FrontendStage.pageLeft
          : FrontendStage.pageLeftBeforeLayout,
      once: true,
    );
    _detachFailoverPresenter?.call();
    _boundCall?.removeListener(_onVoiceCallChanged);
    // 通话视图嵌在这个聊天页里；聊天页关掉就挂断。
    _voiceCalls.hangUpIn(_shownConversationId);
    _conversationActivation.clear();
    _entryRouteAnimation?.removeStatusListener(_onEntryRouteStatus);
    _imagePrecacheTimer?.cancel();
    _clearUnreadTimer?.cancel();
    _lifecycle.dispose();
    _selection.removeListener(_selectionChanged);
    _selection.dispose();
    _viewportController.dispose();
    super.dispose();
  }

  /// (注释已丢失)
  Future<void> _loadMoreMessages(String conversationId) async {
    if (_isLoadingMore) return;
    if (!ref.read(conversationHasMoreProvider(conversationId))) return;
    final diagnosticEntry = _diagnosticEntry;

    setState(() => _isLoadingMore = true);

    try {
      final store = ref.read(conversationTimelineCacheProvider);
      final visibleCountNotifier = ref.read(
        conversationVisibleCountProvider(conversationId).notifier,
      );
      final currentVisibleCount = visibleCountNotifier.state;
      final nextVisibleCount = await resolveChatPageLoadMoreVisibleCount(
        store: store,
        conversationId: conversationId,
        currentVisibleCount: currentVisibleCount,
      );
      if (nextVisibleCount > currentVisibleCount) {
        visibleCountNotifier.state = nextVisibleCount;
      }
    } catch (e, stack) {
      _diagnostics.record(
        diagnosticEntry,
        FrontendStage.historyFailed,
        error: e,
        stackTrace: stack,
      );
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
    // 只订阅聊天页用到的字段：落库更新摘要（最后一条、未读、更新时间）
    // 时不重建整页，改名、换背景、切模式、新话题等仍立即刷新。
    final targetConversation = targetId == null || deferEntryShell
        ? null
        : ref
              .watch(
                resolvedConversationByIdProvider(
                  targetId,
                ).select(_ChatPageConversation.new),
              )
              .value;
    final conv = targetId == null
        ? ref
              .watch(
                activeConversationProvider.select(_ChatPageConversation.new),
              )
              .value
        : deferEntryShell
        ? initial
        : targetConversation ?? initial;
    final currentConversationId = conv?.id ?? targetId;
    _bindFailoverPresenter(currentConversationId);
    final isAssistant = conv?.id == kAicoveAssistantId;
    // Approvals, cards and the undo bar serve every role with software management.
    final isAgent = conv?.hasAssistantCapability == true;
    final assistantScript =
        isAssistant && ref.watch(assistantScriptActiveProvider);
    // Loaded ahead so the「更多」menu shows the current choice.
    if (isAgent) ref.watch(assistantAlwaysAskProvider);
    final assistantNeedsModel = isAssistant &&
        ref.watch(
          appSettingsProvider.select(
            (s) => s.valueOrNull != null && !hasUsableChatModel(s.value!),
          ),
        );
    _ensureImplicitConversationEntrySideEffects(currentConversationId);
    final messagesAsync = currentConversationId == null
        ? const AsyncValue.data(<Message>[])
        : ref.watch(conversationMessagesProvider(currentConversationId));
    _observeFrontendEntry(currentConversationId, messagesAsync);
    final isGenerating = ref.watch(sendingProvider);
    final loadedMessages = messagesAsync.valueOrNull;
    // 只有库里消息还没就绪时才用内存窗口兜底，免得每次构建都拷一份。
    final inMemoryTimelineMessages =
        currentConversationId == null ||
            (loadedMessages != null && loadedMessages.isNotEmpty)
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
    _shownConversationId = currentConversationId;
    _bindVoiceCall(ref.watch(activeVoiceCallProvider));
    // 切到别的角色时，这个聊天里的通话随之挂断。
    ref.listen<String?>(
      activeConversationProvider.select((c) => c?.id),
      (_, next) => _voiceCalls.hangUpIfAwayFrom(next),
    );
    final callHere = _boundCall?.conversationId == currentConversationId
        ? _boundCall
        : null;
    final stagedMessages = currentConversationId == null
        ? const <Message>[]
        : ref.watch(stagedUserMessagesProvider(currentConversationId));
    // 通话内容与暂存消息只作前端临时显示；确认后暂存消息按顺序落库。
    final callMessages = callHere != null
        ? _voiceCallMessages
        : const <Message>[];
    final transientMessages = stagedMessages.isEmpty
        ? callMessages
        : callMessages.isEmpty
        ? stagedMessages
        : <Message>[...stagedMessages, ...callMessages];
    final typingCall = _typingVoiceCall(currentConversationId);
    // 桌面宽屏的通话在独立小窗里；其余时候通话视图和聊天共用壁纸、占满聊天页，
    // 收起后成悬浮窗。
    final isWide = MoeWorkspace.maybeOf(context)?.isWide ?? false;
    final windowCall =
        callHere != null &&
        (callHere.inWindow || _wantsCallWindow(callHere, isWide));
    if (windowCall && conv != null) _openCallWindowLater(callHere, conv);
    final showCall =
        callHere != null && conv != null && !windowCall && !callHere.minimized;
    final actions = ref.read(chatActionsProvider); // (注释已丢失)
    final colors = context.moeColors;

    if (currentConversationId != null) {
      ref.listen<int>(
        conversationSnapshotByIdProvider(
          currentConversationId,
        ).select((c) => c?.unreadCount ?? 0),
        (_, next) {
          if (next > 0) _clearUnreadIfShown();
        },
      );

      // 只处理本页会话的模型切换确认；请求在别处结束时关掉还开着的弹框。
      ref.listen<ModelFailoverPromptRequest?>(
        modelFailoverPromptForProvider(currentConversationId),
        (prev, next) {
          if (!mounted) return;
          if (next != null) {
            unawaited(_showModelFailoverPrompt(next));
          } else if (prev != null &&
              _activeFailoverPromptRequestId == prev.requestId) {
            Navigator.of(context, rootNavigator: true).maybePop();
          }
        },
      );

      // 本页会话发送失败时弹一句原因；切走后原因留在列表底部。
      ref.listen<String?>(conversationErrorProvider(currentConversationId), (
        prev,
        next,
      ) {
        if (next != null && next.isNotEmpty && mounted) {
          MoeToast.show(
            context,
            ModelRequestErrorReport.brief(next),
            type: ToastType.error,
            duration: const Duration(seconds: 4),
          );
        }
      });

      // 另一台设备正在生成当前会话回复时，给一句轻提示，不阻断本机发送。
      ref.listen<String?>(
        conversationRemoteRunningNoticeProvider(currentConversationId),
        (prev, next) {
          if (next != null && next.isNotEmpty && mounted) {
            MoeToast.info(context, next);
            ref
                .read(
                  conversationRemoteRunningNoticeProvider(
                    currentConversationId,
                  ).notifier,
                )
                .state = null;
          }
        },
      );

      // 后台手动压缩完成或失败时给出轻提示，再点一次「更多」即可确认开启。
      ref.listen<ManualCompactionSessionState>(
        manualCompactionStateProvider(currentConversationId),
        (prev, next) {
          final notice = next.notice;
          if (notice != null && notice.id != prev?.notice?.id && mounted) {
            if (notice.isError) {
              MoeToast.error(context, notice.message);
            } else {
              MoeToast.info(context, notice.message);
            }
            ref
                .read(manualCompactionSessionProvider)
                .clearNotice(currentConversationId, notice.id);
          }
        },
      );
    }

    final chatBgColor = resolveChatBackgroundColor(context);
    final textScaler = MediaQuery.textScalerOf(context);
    final toolbarHeight = MoeChatHeader.heightFor(textScaler);
    final listTopSpacing =
        toolbarHeight +
        telegramChatHeaderVerticalInset * 2 +
        telegramChatHeaderGap +
        MediaQuery.paddingOf(context).top;
    final nativeInset =
        isDesktop &&
            Platform.isMacOS &&
            MoeWorkspace.ownsWindowControls(context)
        ? 88.0
        : 0.0;

    return PopScope(
      // 通话视图里返回是回到聊天，不挂断。
      canPop: !_selection.active && !showCall,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (showCall) {
          callHere.minimize();
        } else if (!_selectionBusy) {
          _selection.clear();
        }
      },
      child: Scaffold(
        backgroundColor: Colors.transparent,
        // (注释已丢失)
        resizeToAvoidBottomInset: false,
        extendBodyBehindAppBar: true,
        appBar: showCall
            ? null
            : _buildAppBar(
                conv: conv,
                currentConversationId: currentConversationId,
                deferEntryShell: deferEntryShell,
                isGenerating: isGenerating,
                toolbarHeight: toolbarHeight,
                nativeInset: nativeInset,
              ),
        body: _buildConversationBackground(
          conv: conv,
          fallbackColor: chatBgColor,
          callView: showCall
              ? VoiceCallView(
                  conversation: conv,
                  call: callHere,
                  onCollapse: callHere.minimize,
                )
              : null,
          child: assistantScript && conv != null
              ? AssistantOnboardingView(
                  displayName: conv.displayName,
                  avatarUrl: conv.avatarUrl ?? conv.characterImage,
                  topPadding: listTopSpacing,
                )
              : Stack(
            children: [
              if (conv != null &&
                  messagesAsync.hasValue &&
                  messages.isEmpty &&
                  stagedMessages.isEmpty)
                Center(
                  child: MoeFloatingSurface(
                    radius: 20,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 12,
                    ),
                    child: Text(
                      assistantNeedsModel
                          ? '先到「设置 · 模型」配好模型，就能和我聊啦'
                          : '暂无消息',
                      style: TextStyle(color: colors.text, fontSize: 14),
                    ),
                  ),
                ),
              // 消息列表（填满全屏，自带 bottom padding 避开 Composer 和键盘）
              Column(
                children: [
                  Expanded(
                    child: conv == null
                        ? const Center(child: CircularProgressIndicator())
                        : GestureDetector(
                            behavior: HitTestBehavior.translucent,
                            onTap: () {
                              final keyboardHeight = MediaQuery.viewInsetsOf(
                                context,
                              ).bottom;
                              if (keyboardHeight > 0) {
                                SystemChannels.textInput.invokeMethod(
                                  'TextInput.hide',
                                );
                              }
                              FocusManager.instance.primaryFocus?.unfocus();
                            },
                            child: ChatViewScope(
                              prefs: ref.watch(
                                appSettingsProvider.select(
                                  (s) => ChatViewPrefs.resolve(
                                    conv,
                                    s.valueOrNull,
                                  ),
                                ),
                              ),
                              child: _buildMessageList(
                                conv: conv,
                                isAgent: isAgent,
                                messages: messages,
                                isInitialLoading:
                                    !messagesAsync.hasValue &&
                                    messages.isEmpty &&
                                    stagedMessages.isEmpty,
                                transientMessages: transientMessages,
                                listTopSpacing: listTopSpacing,
                                hasMoreMessages: hasMoreMessages,
                                actions: actions,
                              ),
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
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildAssistantPanel(isAgent && !_selection.active),
                    if (_selection.active) _buildSelectionToolbar(conv),
                    Offstage(
                      offstage: _selection.active,
                      child: _buildComposer(
                        typingCall: typingCall,
                        actions: actions,
                      ),
                    ),
                  ],
                ),
              ),
              if (conv != null && !_selection.active)
                Positioned(
                  right: 16,
                  bottom: _composerOverlayHeight + _assistantPanelHeight + 12,
                  child: VoiceAutoplayPrompt(
                    conversationId: conv.id,
                    messages: messages,
                  ),
                ),
              if (typingCall != null &&
                  !windowCall &&
                  typingCall.minimized &&
                  conv != null)
                Positioned.fill(
                  child: VoiceCallFloatingWindow(
                    call: typingCall,
                    topInset: listTopSpacing,
                    onTap: () => _openVoiceCall(conv),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
