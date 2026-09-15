import '../../../theme/moe_interaction_theme.dart';
import 'chat_image_export_page.dart';
import '../widgets/chat_share_sheet.dart';
import '../../plugins/widgets/drawing_preset_picker_sheet.dart';
import '../widgets/chat_message_selection.dart';
import 'chat_background_settings_page.dart';
import 'dart:async';
import 'dart:io';
import '../../../shared/widgets/desktop_window_frame.dart';
import '../../character/pages/contact_edit_page.dart';
import '../../character/services/contact_edit_snapshot_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
import '../../../../features/chat/domain/persona_prompt_codec.dart';
import '../../../../features/plugins/image/drawing_preset_provider.dart';
import '../../../../ui/theme/tokens.dart';
import '../../../../ui/shared/widgets/index.dart';
import '../../../../features/settings/app_settings.dart';
import '../../../../core/models/message_block.dart';
import '../../../../core/services/attachment_picker_service.dart';
import '../../../../core/utils/blurred_background_service.dart';
import '../../../../core/utils/data_image.dart';
import '../../../../core/utils/image_preheat_queue.dart';
import '../../../../features/observability/trace_models.dart';
import '../../../../features/observability/frontend_diagnostics_port.dart';
import '../../../../features/observability/frontend_diagnostics_provider.dart';
import '../../../../features/observability/trace_query_service.dart';
import '../../../../features/observability/trace_store.dart';
import '../../../../ui/features/settings/pages/log_formatters.dart';
import 'deferred_conversation_activation.dart';
import '../widgets/chat_message_list.dart';
import '../widgets/topic_compaction_button.dart';
import '../widgets/frontend_message_probe.dart';
import '../widgets/chat_viewport_controller.dart';

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
  final normalizedDisplayName = displayName.trim().isEmpty
      ? '聊天'
      : displayName.trim();
  final statusLabel = switch (chatStatus) {
    ChatStatus.generatingImage ||
    ChatStatus.generatingVoice ||
    ChatStatus.toolCalling => chatStatus.label.trim(),
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

  void _openCharacterSettings(Conversation conv) => MoeWorkspace.open(
    context,
    ContactEditPage(
      conversation: conv,
      initialSnapshot: ContactEditSnapshot.fromConversation(conv),
      editMode: EditMode.editConversation,
    ),
  );

  Future<bool> _confirmAction(String title, String message) async =>
      await showDialog<bool>(
        context: context,
        useRootNavigator: false,
        builder: (ctx) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(
                '确定',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          ],
        ),
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
    setState(() => _selectionBusy = true);
    try {
      await ref
          .read(chatPageConversationActionsProvider)
          .hideMessages(conv.id, ids);
      if (mounted) _selection.clear();
    } catch (_) {
      if (mounted) MoeToast.error(context, '删除失败，请重试');
    } finally {
      if (mounted) setState(() => _selectionBusy = false);
    }
  }

  void _selectionChanged() {
    if (!mounted) return;
    if (_selection.active) FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      if (!_selection.active) _composerOverlayHeight = _normalComposerHeight;
    });
  }

  Future<void> _showShareSheet(Conversation conv) async {
    final messages = List<Message>.of(_selection.selectedMessages);
    final raw = conv.chatBackgroundImage?.trim();
    final bytes = raw == null ? null : decodeDataImage(raw);
    final wallpaper = raw == null || raw.isEmpty ? null
        : bytes != null ? MemoryImage(bytes) : _getImageProvider(raw);
    final setting = ref.read(appSettingsProvider).valueOrNull?.chatBackgroundColor.color;
    final fallback = Theme.of(context).brightness == Brightness.dark
        ? telegramChatBackgroundDark
        : setting == null || setting == Colors.white ? telegramChatBackground : setting;
    final background = wallpaper == null &&
        (fallback == telegramChatBackground || fallback == telegramChatBackgroundDark)
        ? Theme.of(context).scaffoldBackgroundColor : fallback;
    final height = MediaQuery.sizeOf(context).height * 0.85;
    final exported = await showMoeBottomSheet<String>(
      context: context,
      title: '分享',
      showCloseButton: true,
      maxHeight: height,
      builder: (sheetContext) => ChatShareSheet(
          onExport: () => Navigator.of(sheetContext).pop('export'),
          onSend: (id, note) => ref.read(chatActionsProvider).forwardMessages(
            conversationId: id, sourceTitle: conv.displayName, messages: messages, note: note,
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
    MoeWorkspace.open(context, ChatImageExportPage(
      messages: messages,
      title: conv.displayName,
      avatarUrl: conv.avatarUrl ?? conv.characterImage,
      background: background,
      wallpaper: wallpaper,
      wallpaperMaskOpacity: conv.chatBackgroundMaskOpacity ?? 0.8,
      wallpaperBlurSigma: conv.chatBackgroundBlurSigma ?? 0,
    ));
  }

  Widget _buildSelectionToolbar(Conversation? conv) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_selection.active) return;
      final box = _selectionBarKey.currentContext?.findRenderObject();
      if (box is RenderBox &&
          (box.size.height - _composerOverlayHeight).abs() >= 0.5) {
        setState(() => _composerOverlayHeight = box.size.height);
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
          label: '壁纸',
          onTap: () => MoeWorkspace.open(
            context,
            ChatBackgroundSettingsPage(conversation: conv),
          ),
        ),
        if (conv.allowsPlugin('image'))
          MoePopupMenuItem(
            label: '绘图预设',
            onTap: () => showDrawingPresetPicker(
              context: context,
              ref: ref,
              personaPrompt: conv.personaPrompt,
              onSelected: (presetId) => _switchDrawingPreset(conv, presetId),
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

  Future<void> _switchDrawingPreset(
    Conversation conv,
    String? presetId,
  ) async {
    try {
      final latest =
          ref.read(resolvedConversationByIdProvider(conv.id)) ?? conv;
      final parts = PersonaPromptCodec.parse(latest.personaPrompt);
      await ref
          .read(chatPageConversationActionsProvider)
          .applyConversationEdits(
            conv.id,
            personaPrompt: PersonaPromptCodec.compose(
              userPrompt: parts.userPrompt,
              customDrawingPrompt: parts.customDrawingPrompt,
              drawingPresetId: presetId,
            ),
          );
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
        presetName == null ? '绘图预设已切换' : '绘图预设：$presetName',
      );
    } catch (_) {
      if (mounted) MoeToast.error(context, '切换失败，请重试');
    }
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
  late final ChatViewportController _viewportController;
  Timer? _imagePrecacheTimer;
  Timer? _clearUnreadTimer;
  Animation<double>? _entryRouteAnimation;
  String? _pendingUnreadConversationId;
  bool _imagePrecachePending = false;
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
    final targetId = widget.conversationId;
    if (targetId == null) return;
    _startEntrySideEffects(targetId);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _bindEntryRouteAnimation();
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
    _viewportController.onUserSend();
  }

  void _showSendingInProgressToast() {
    MoeToast.brief(context, 'Please wait for current message to finish');
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

  Future<bool> _checkVisionCompat({
    required Conversation conv,
    bool currentMessageHasImage = false,
  }) async {
    final decision = await ref
        .read(chatPageSendSupportProvider)
        .resolveVisionCompatibility(
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

    ref
        .read(modelFailoverPromptProvider.notifier)
        .dismiss(defaultDecision: ModelFailoverDecision.cancel);
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

      ref
          .read(modelFailoverPromptProvider.notifier)
          .resolve(
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
                '请切换到支持图片输入的聊天模型。继续发送仅会使用已有文字内容。',
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
                        style: TextStyle(fontSize: 12, color: colors.muted),
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
              child: Text('取消', style: TextStyle(color: colors.muted)),
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
                '仍然发送',
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

    final httpMatch = RegExp(
      r'HTTP\s*(\d{3})',
      caseSensitive: false,
    ).firstMatch(text);
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
      if (fallbackColor == telegramChatBackground ||
          fallbackColor == telegramChatBackgroundDark) {
        return MoeWorkspaceBackground(
          background: const MoeChatWallpaper(child: SizedBox.expand()),
          child: child,
        );
      }
      return MoeWorkspaceBackground(
        background: ColoredBox(color: fallbackColor),
        child: child,
      );
    }

    final image = _buildBackgroundImage(raw);
    if (image == null) {
      return MoeWorkspaceBackground(
        background: ColoredBox(color: fallbackColor),
        child: child,
      );
    }
    final maskOpacity = (conv?.chatBackgroundMaskOpacity ?? 0.8).clamp(
      0.0,
      1.0,
    );
    final topMaskOpacity = (maskOpacity + 0.12).clamp(0.0, 1.0);
    final blurSigma = (conv?.chatBackgroundBlurSigma ?? 0.0).clamp(0.0, 30.0);
    final blurOverlayOpacity = _staticBlurOverlayOpacity(blurSigma);
    final blurOverlay = blurOverlayOpacity > 0
        ? _buildStaticBackgroundBlurLayer(raw, opacity: blurOverlayOpacity)
        : null;

    return MoeWorkspaceBackground(
      background: Container(
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
                        alpha: (maskOpacity * 0.9).clamp(0.0, 1.0),
                      ),
                      fallbackColor.withValues(alpha: maskOpacity),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      child: child,
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
    _modelFailoverPromptController.dismiss();
    _conversationActivation.clear();
    _entryRouteAnimation?.removeStatusListener(_onEntryRouteStatus);
    _imagePrecacheTimer?.cancel();
    _clearUnreadTimer?.cancel();
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
    _observeFrontendEntry(currentConversationId, messagesAsync);
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
    final chatStatus = ref.watch(chatStatusProvider);
    // 字段级订阅：页面只关心聊天背景色，设置里其他字段变化不再重建整页
    final chatBackgroundColorSetting = deferEntryShell
        ? null
        : ref.watch(
            appSettingsProvider.select(
              (settings) => settings.valueOrNull?.chatBackgroundColor,
            ),
          );
    final colors = context.moeColors;

    // 监听模型切换确认请求，弹公共确认框
    ref.listen<ModelFailoverPromptRequest?>(modelFailoverPromptProvider, (
      prev,
      next,
    ) {
      if (next == null || !mounted) return;
      unawaited(_showModelFailoverPrompt(next));
    });

    // 监听发送错误，弹出失败原因提示
    ref.listen<String?>(errorProvider, (prev, next) {
      if (next != null && next.isNotEmpty && mounted) {
        final briefMessage = _buildBriefSendErrorMessage(next);
        MoeToast.show(
          context,
          briefMessage,
          type: ToastType.error,
          duration: const Duration(seconds: 3),
        );
      }
    });

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final chatBgColor = isDark
        ? telegramChatBackgroundDark
        : (chatBackgroundColorSetting?.color == null ||
              chatBackgroundColorSetting?.color == Colors.white)
        ? telegramChatBackground
        : (chatBackgroundColorSetting?.color ?? telegramChatBackground);
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
      canPop: !_selection.active,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && !_selectionBusy) _selection.clear();
      },
      child: Scaffold(
        backgroundColor: Colors.transparent,
        // (注释已丢失)
        resizeToAvoidBottomInset: false,
        extendBodyBehindAppBar: true,
        appBar: MoeChatHeader(
          showBackButton: MoeWorkspace.showsBackButton(context),
          nativeInset: nativeInset,
          toolbarHeight: toolbarHeight,
          title: Row(
            children: [
              if (conv != null) ...[
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
                        valueListenable: TraceStore.instance.entries,
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
          actions: [
            if (_selection.active)
              IconButton(
                tooltip: '取消选择',
                onPressed: _selectionBusy ? null : _selection.clear,
                icon: const Icon(Icons.close),
              ),
            if (!_selection.active && !deferEntryShell && conv != null) ...[
              TopicCompactionButton(
                ownerId: conv.id,
                isGenerating: isGenerating,
              ),
              Listener(
                onPointerDown: (event) => _chatMenuPosition = event.position,
                child: IconButton(
                  icon: Icon(
                    Icons.more_horiz,
                    color: colors.headerContentColor,
                  ),
                  tooltip: '更多',
                  key: _chatMenuKey,
                  onPressed: () => _showConversationMenu(conv),
                ),
              ),
            ],
          ],
        ),
        body: _buildConversationBackground(
          conv: conv,
          fallbackColor: chatBgColor,
          child: Stack(
            children: [
              if (conv != null && messagesAsync.hasValue && messages.isEmpty)
                Center(
                  child: MoeFloatingSurface(
                    radius: 20,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 12,
                    ),
                    child: Text(
                      '暂无消息',
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
                                return;
                              }
                              FocusManager.instance.primaryFocus?.unfocus();
                            },
                            child: ChatMessageList(
                              key: ValueKey(conv.id),
                              conversationId: conv.id,
                              selection: _selection,
                              messages: messages,
                              isInitialLoading:
                                  !messagesAsync.hasValue && messages.isEmpty,
                              transientMessages: transientMessages,
                              avatarUrl: conv.avatarUrl ?? conv.characterImage,
                              displayName: conv.displayName,
                              topOverlayHeight: listTopSpacing,
                              bottomOverlayHeight: _composerOverlayHeight,
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
                                      ref
                                              .read(activeConversationProvider)
                                              ?.id ==
                                          conv.id) {
                                    MoeToast.error(
                                      context,
                                      error is StateError
                                          ? error.message.toString()
                                          : '无法进入编辑，原历史未改变',
                                    );
                                  }
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
                                actions.regenerateWithEnhancement(message.id);
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
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_selection.active) _buildSelectionToolbar(conv),
                    Offstage(
                      offstage: _selection.active,
                      child: Composer(
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
                            currentMessageHasImage:
                                attachment?.type == AttachmentType.image,
                          );
                          if (!compatible ||
                              !mounted ||
                              ref.read(activeConversationProvider)?.id !=
                                  owner.id) {
                            throw StateError('未确认发送，编辑草稿已保留');
                          }
                          await actions.submitEditedMessage(
                            draft,
                            text: text,
                            attachment: attachment,
                          );
                          if (mounted &&
                              ref.read(activeConversationProvider)?.id ==
                                  owner.id) {
                            _forceChatListToBottom();
                          }
                        },
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
                          _diagnostics.begin(
                            FrontendStage.sendRequested,
                            conversationId: _resolveCurrentConversationId(),
                          );
                          _forceChatListToBottom();
                          actions.sendWithImage(imagePath, text: text);
                        },
                        onFileSelected: (filePath, {String? text}) {
                          if (ref.read(sendingProvider)) {
                            _showSendingInProgressToast();
                            return;
                          }
                          _diagnostics.begin(
                            FrontendStage.sendRequested,
                            conversationId: _resolveCurrentConversationId(),
                          );
                          _forceChatListToBottom();
                          actions.sendWithFile(filePath, text: text);
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
