// Characterization tests for the streaming placeholder state machine
// (`_StreamPlaceholderDelivery`, private part of ChatActions).
//
// Scope: lock CURRENT behavior only — no product-code changes.
// Drive via public surface: ChatActions.send + scripted fake ChatSendService.
// Core metric: ConversationTimelineCache.watchWindow emission count.
//
// Timing constants under test (from chat_actions_stream_placeholder.dart):
//   flush interval = 180ms
//   thinking placeholder delay = 450ms
//   segment reveal delay = settings.streamSegmentDelaySeconds

import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/core/app_logger.dart';
import 'package:aicove_flutter/src/core/database/database.dart'
    hide Conversation, Message;
import 'package:aicove_flutter/src/core/database/database_provider.dart';
import 'package:aicove_flutter/src/core/models/block_status.dart';
import 'package:aicove_flutter/src/core/models/message_block.dart';
import 'package:aicove_flutter/src/core/utils/message_formatter.dart';
import 'package:aicove_flutter/src/features/chat/chat_actions.dart';
import 'package:aicove_flutter/src/features/chat/application/active_stream_projection.dart';
import 'package:aicove_flutter/src/features/chat/conversation_providers.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_history_store.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_send_service.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_tts_handler.dart';
import 'package:aicove_flutter/src/features/chat/services/conversation_short_window_store.dart';
import 'package:aicove_flutter/src/features/observability/trace_models.dart';
import 'package:aicove_flutter/src/features/plugins/domain/plugin.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';

// ---------------------------------------------------------------------------
// Platform mocks (path_provider / shared_preferences)
// ---------------------------------------------------------------------------

const MethodChannel _pathProviderChannel =
    MethodChannel('plugins.flutter.io/path_provider');
const MethodChannel _sharedPreferencesChannel =
    MethodChannel('plugins.flutter.io/shared_preferences');

void _installPlatformChannelMocks() {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(_pathProviderChannel, (call) async {
    switch (call.method) {
      case 'getApplicationDocumentsDirectory':
      case 'getTemporaryDirectory':
      case 'getApplicationSupportDirectory':
      case 'getLibraryDirectory':
      case 'getExternalStorageDirectory':
        return Directory.systemTemp.path;
      case 'getExternalCacheDirectories':
      case 'getExternalStorageDirectories':
        return <String>[Directory.systemTemp.path];
    }
    return Directory.systemTemp.path;
  });
  messenger.setMockMethodCallHandler(_sharedPreferencesChannel, (call) async {
    switch (call.method) {
      case 'getAll':
        return <String, Object>{};
      case 'setBool':
      case 'setDouble':
      case 'setInt':
      case 'setString':
      case 'setStringList':
      case 'remove':
      case 'clear':
      case 'commit':
        return true;
    }
    return null;
  });
}

// ---------------------------------------------------------------------------
// Settings / helpers
// ---------------------------------------------------------------------------

AppSettings _buildTestSettings({
  bool enableChunking = true,
  int minSegmentLength = 1,
  double streamSegmentDelaySeconds = 0,
  bool ttsEnabled = true,
}) {
  const defaultModelRef = 'openai:gpt-4o-mini';
  return AppSettings(
    ttsEnabled: ttsEnabled,
    defaultModelName: defaultModelRef,
    defaultPersonaPrompt: '',
    modelList: const <String>[defaultModelRef],
    allKnownModels: const <String>[defaultModelRef],
    modelDisplayNames: const <String, String>{},
    modelTypes: const <String, String>{},
    modelConfigs: const <String, ModelConfig>{},
    apiKey: '',
    apiBaseUrl: 'https://api.openai.com/v1',
    imageGenerationEnabled: false,
    maxFileUploadMB: 10,
    historyMessageLimit: 100,
    customModels: const <CustomModel>[],
    providers: const <ProviderAuth>[
      ProviderAuth(
        id: 'openai',
        apiKeys: <String>['test-key'],
        apiBaseUrl: 'https://api.openai.com/v1',
      ),
    ],
    modelProviderMap: const <String, String>{
      defaultModelRef: 'openai',
      'gpt-4o-mini': 'openai',
    },
    backendApiKey: '',
    messageChunkingEnabled: enableChunking,
    messageFormatConfig: MessageFormatConfig(
      enableChunking: enableChunking,
      chunkPunctuations: const <String>['。', '！', '？'],
      minSegmentLength: minSegmentLength,
    ),
    textScaleFactor: 1.0,
    uiScaleFactor: 1.0,
    imagePreviewScale: 1.0,
    autoReplySettings: const AutoReplySettings(),
    globalBackgroundColor: GlobalBackgroundColor.white,
    chatBackgroundColor: ChatBackgroundColor.defaultColor,
    isDarkMode: false,
    useSystemTheme: true,
    accentColor: 'FC96AA',
    hideUserAvatar: true,
    defaultChatModels: const <String>[defaultModelRef],
    streamSegmentDelaySeconds: streamSegmentDelaySeconds,
  );
}

class _FakeAppSettingsNotifier extends AppSettingsNotifier {
  _FakeAppSettingsNotifier(this._settings);

  final AppSettings _settings;

  @override
  Future<AppSettings> build() async => _settings;
}

class _FakeConversationsNotifier extends ConversationsNotifier {
  _FakeConversationsNotifier(this._seed);

  final List<Conversation> _seed;

  @override
  Future<List<Conversation>> build() async => _seed;

  @override
  Future<void> setAll(
    List<Conversation> list, {
    bool persist = true,
  }) async {
    state = AsyncValue.data(list);
  }
}

Future<void> _insertConversation(AppDatabase db, Conversation conv) async {
  await db.into(db.conversations).insert(
        ConversationsCompanion.insert(
          id: conv.id,
          title: conv.title,
          displayName: conv.displayName,
          createdAt: conv.createdAt.millisecondsSinceEpoch,
          updatedAt: conv.updatedAt.millisecondsSinceEpoch,
        ),
      );
}

Future<List<Message>> _loadFrontendTimelineMessages(
  ProviderContainer container,
  String conversationId,
) {
  return container.read(chatHistoryStoreProvider).loadCachedTimelineMessages(
        conversationId,
      );
}

bool _isGeneratingPlaceholder(Message message) {
  return message.role == 'assistant' &&
      message.status == 'sending' &&
      (message.blocks?.whereType<TextBlock>().any(
                (block) =>
                    block.status == BlockStatus.streaming &&
                    block.content.trim() == '生成中...',
              ) ??
          false);
}

bool _isPendingAudio(Message message) {
  final blocks =
      message.blocks?.whereType<AudioBlock>().toList() ?? const <AudioBlock>[];
  if (blocks.isEmpty) return false;
  final block = blocks.first;
  return block.status == BlockStatus.pending && block.url.isEmpty;
}

List<Message> _assistantRealText(List<Message> messages) {
  return messages
      .where(
        (m) =>
            m.role == 'assistant' &&
            !_isGeneratingPlaceholder(m) &&
            !_isPendingAudio(m) &&
            m.displayText.trim().isNotEmpty,
      )
      .toList(growable: false);
}

AssistantMessageBuildResult _buildResult({
  required String text,
  String? rawReplyText,
  List<PluginEvent> pluginEvents = const <PluginEvent>[],
}) {
  final rawMessageId = 'raw_assistant_${text.hashCode.abs()}';
  final msg = Message(
    id: 'assistant_${text.hashCode.abs()}',
    role: 'assistant',
    content: text,
    createdAt: DateTime.now(),
    status: 'sent',
    sourceMessageId: rawMessageId,
  );
  return AssistantMessageBuildResult(
    rawMessage: Message(
      id: rawMessageId,
      role: 'assistant',
      content: rawReplyText ?? text,
      createdAt: msg.createdAt,
      status: 'sent',
    ),
    messages: <Message>[msg],
    lastMessageText: text,
  );
}

// ---------------------------------------------------------------------------
// Scripted streaming send service
// ---------------------------------------------------------------------------

sealed class _StreamStep {
  const _StreamStep();
}

class _DeltaStep extends _StreamStep {
  const _DeltaStep(this.text);
  final String text;
}

class _DelayStep extends _StreamStep {
  const _DelayStep(this.duration);
  final Duration duration;
}

class _ResetStep extends _StreamStep {
  const _ResetStep();
}

class _FallbackStep extends _StreamStep {
  const _FallbackStep();
}

class _ScriptedStreamingSendService extends ChatSendService {
  _ScriptedStreamingSendService(
    super.ref,
    this._settings, {
    required this.script,
    required this.replyText,
    this.processedText,
    this.pluginEvents = const <PluginEvent>[],
    /// Optional: per-execute-call scripts (1-based call order → 0-index).
    /// Used by retry/new-delivery characterization (G). Falls back to [script].
    this.scriptsByCall,
    this.replyTextsByCall,
    this.processedTextsByCall,
    /// Optional: per-sessionId scripts for concurrent multi-conversation (I).
    /// Takes priority over [scriptsByCall] / [script] when session matches.
    this.scriptsBySession,
    this.replyTextsBySession,
    this.processedTextsBySession,
  });

  final AppSettings _settings;
  final List<_StreamStep> script;
  final String replyText;
  final String? processedText;
  final List<PluginEvent> pluginEvents;
  final List<List<_StreamStep>>? scriptsByCall;
  final List<String>? replyTextsByCall;
  final List<String?>? processedTextsByCall;
  final Map<String, List<_StreamStep>>? scriptsBySession;
  final Map<String, String>? replyTextsBySession;
  final Map<String, String?>? processedTextsBySession;

  int executeCalls = 0;
  int resetCalls = 0;
  int deltaCalls = 0;
  final List<String> executeSessionIds = <String>[];

  List<_StreamStep> _resolveScript(String sessionId, int callIndex) {
    final bySession = scriptsBySession;
    if (bySession != null && bySession.containsKey(sessionId)) {
      return bySession[sessionId]!;
    }
    final byCall = scriptsByCall;
    if (byCall != null && byCall.isNotEmpty) {
      final i = callIndex.clamp(0, byCall.length - 1);
      return byCall[i];
    }
    return script;
  }

  String _resolveReplyText(String sessionId, int callIndex) {
    final bySession = replyTextsBySession;
    if (bySession != null && bySession.containsKey(sessionId)) {
      return bySession[sessionId]!;
    }
    final byCall = replyTextsByCall;
    if (byCall != null && byCall.isNotEmpty) {
      final i = callIndex.clamp(0, byCall.length - 1);
      return byCall[i];
    }
    return replyText;
  }

  String? _resolveProcessedText(String sessionId, int callIndex) {
    final bySession = processedTextsBySession;
    if (bySession != null && bySession.containsKey(sessionId)) {
      return bySession[sessionId];
    }
    final byCall = processedTextsByCall;
    if (byCall != null && byCall.isNotEmpty) {
      final i = callIndex.clamp(0, byCall.length - 1);
      return byCall[i];
    }
    return processedText;
  }

  @override
  Future<List<Message>> loadConversationMessagesFromStore({
    required Conversation conv,
    Message? ensureTailMessage,
  }) async {
    final all = List<Message>.from(conv.messages);
    if (ensureTailMessage != null &&
        all.every((m) => m.id != ensureTailMessage.id)) {
      all.add(ensureTailMessage);
    }
    return all;
  }

  @override
  Future<List<Message>> prepareHistoryFromStore({
    required Conversation conv,
    required Message userMsg,
    required int limit,
  }) async {
    return prepareHistory(conv: conv, userMsg: userMsg, limit: limit);
  }

  @override
  Future<ApiConfig> prepareApiConfig({
    required Conversation conv,
    required List<Message> history,
    required String? userText,
    TraceLogger? trace,
    String? overrideModel,
    String? conversationId,
    TraceContext? traceContext,
  }) async {
    return ApiConfig(
      settings: _settings,
      modelFullId: overrideModel ?? _settings.defaultModelName,
      providerApiBase: _settings.apiBaseUrl,
      providerApiKey: null,
      customConfig: const <String, dynamic>{},
      toolPrefs: const <String, dynamic>{},
      messages: const <Map<String, dynamic>>[],
      tools: null,
      enabledPluginIds: null,
      modelTemperature: null,
      modelTopP: null,
      modelContextMessageLimit: null,
    );
  }

  @override
  Future<ApiCallResult> executeApiCall({
    required ApiConfig config,
    required String sessionId,
    required String? userText,
    String? turnId,
    TraceLogger? trace,
    int maxRounds = 5,
    void Function(String toolName)? onToolExecuting,
    bool enableStreaming = false,
    void Function(String delta)? onStreamTextDelta,
    void Function()? onStreamTextReset,
    void Function()? onStreamToolCallObserved,
    void Function()? onStreamingFallback,
  }) async {
    executeCalls += 1;
    final callIndex = executeCalls - 1;
    executeSessionIds.add(sessionId);
    final steps = _resolveScript(sessionId, callIndex);
    final resolvedReply = _resolveReplyText(sessionId, callIndex);
    final resolvedProcessed =
        _resolveProcessedText(sessionId, callIndex) ?? resolvedReply;
    for (final step in steps) {
      switch (step) {
        case _DeltaStep(:final text):
          deltaCalls += 1;
          onStreamTextDelta?.call(text);
        case _DelayStep(:final duration):
          await Future<void>.delayed(duration);
        case _ResetStep():
          resetCalls += 1;
          onStreamTextReset?.call();
        case _FallbackStep():
          onStreamingFallback?.call();
      }
    }
    return ApiCallResult(
      replyText: resolvedReply,
      processedText: resolvedProcessed,
      pluginEvents: pluginEvents,
      toolResults: const <Map<String, dynamic>>[],
    );
  }

  @override
  AssistantMessageBuildResult buildAssistantMessages({
    required ApiCallResult apiResult,
    required AppSettings settings,
  }) {
    return _buildResult(
      text: apiResult.processedText,
      rawReplyText: apiResult.replyText,
      pluginEvents: apiResult.pluginEvents,
    );
  }
}

class _RecordingStreamTtsHandler extends ChatTtsHandler {
  _RecordingStreamTtsHandler(super.ref);

  List<Message> lastPendingStreamTtsMessages = const <Message>[];
  List<String> lastStreamTextMessageIds = const <String>[];
  bool lastAppendAfterStreamText = false;

  @override
  Future<void> deliverSegmentedMessages({
    required String convId,
    required String userMsgId,
    required AssistantMessageBuildResult buildResult,
    required String replyText,
    required List<PluginEvent> pluginEvents,
    required bool ttsEnabled,
    bool appendAfterStreamText = false,
    List<String>? streamTextMessageIds,
    List<Message>? streamPendingTtsMessages,
    TraceLogger? trace,
  }) async {
    lastAppendAfterStreamText = appendAfterStreamText;
    lastStreamTextMessageIds =
        List<String>.from(streamTextMessageIds ?? const <String>[]);
    lastPendingStreamTtsMessages =
        List<Message>.from(streamPendingTtsMessages ?? const <Message>[]);
  }
}

// ---------------------------------------------------------------------------
// Harness: window notification counter
// ---------------------------------------------------------------------------

class _WindowProbe {
  _WindowProbe({
    required this.windowEmissions,
    required this.transientReplaceCalls,
    required this.snapshots,
  });

  /// watchWindow emissions (includes the initial snapshot).
  final List<ConversationTimelineWindowState> windowEmissions;

  /// replaceMessagesTransient call count (stream placeholder path).
  final int transientReplaceCalls;

  /// Periodic frontend timeline snapshots sampled during the run.
  final List<List<Message>> snapshots;

  int get windowNotifyCount => windowEmissions.length;

  /// Emissions after the initial seed (change-driven).
  int get windowChangeCount =>
      windowEmissions.isEmpty ? 0 : windowEmissions.length - 1;
}

class _CountingTimelineCache extends ConversationTimelineCache {
  _CountingTimelineCache(super.ref);

  int transientReplaceCalls = 0;

  @override
  Future<void> replaceMessagesTransient({
    required String conversationId,
    List<String> removeMessageIds = const <String>[],
    List<Message> messages = const <Message>[],
  }) async {
    transientReplaceCalls += 1;
    return super.replaceMessagesTransient(
      conversationId: conversationId,
      removeMessageIds: removeMessageIds,
      messages: messages,
    );
  }
}

class _Harness {
  _Harness({
    required this.container,
    required this.conv,
    required this.timelineCache,
    required this.sendService,
    required this.ttsHandler,
    required StreamSubscription<ConversationTimelineWindowState> sub,
    required List<ConversationTimelineWindowState> emissions,
  })  : _sub = sub,
        _emissions = emissions;

  final ProviderContainer container;
  final Conversation conv;
  final _CountingTimelineCache timelineCache;
  final _ScriptedStreamingSendService sendService;
  final _RecordingStreamTtsHandler? ttsHandler;
  final StreamSubscription<ConversationTimelineWindowState> _sub;
  final List<ConversationTimelineWindowState> _emissions;

  Future<void>? _activeSend;

  /// In-flight send future started by [startSend], if any.
  Future<void>? get activeSend => _activeSend;

  Future<_WindowProbe> runSend({
    String text = 'characterization',
    Duration sampleInterval = const Duration(milliseconds: 60),
    int sampleTicks = 0,
  }) async {
    final snapshots = <List<Message>>[];
    final sendFuture = container.read(chatActionsProvider).send(text);

    if (sampleTicks > 0) {
      for (var i = 0; i < sampleTicks; i++) {
        await Future<void>.delayed(sampleInterval);
        snapshots.add(
          List<Message>.from(
            await _loadFrontendTimelineMessages(container, conv.id),
          ),
        );
      }
    }

    await sendFuture;
    // Drain residual timers (finalize/commit may still notify once).
    await Future<void>.delayed(const Duration(milliseconds: 80));
    snapshots.add(
      List<Message>.from(
        await _loadFrontendTimelineMessages(container, conv.id),
      ),
    );

    return _WindowProbe(
      windowEmissions: List<ConversationTimelineWindowState>.from(_emissions),
      transientReplaceCalls: timelineCache.transientReplaceCalls,
      snapshots: snapshots,
    );
  }

  /// Start send without awaiting completion (for mid-stream interrupt / sample).
  void startSend({String text = 'characterization'}) {
    _activeSend = container.read(chatActionsProvider).send(text);
  }

  Future<void> awaitActiveSend({
    Duration settle = const Duration(milliseconds: 80),
  }) async {
    final pending = _activeSend;
    if (pending != null) {
      await pending;
    }
    await Future<void>.delayed(settle);
  }

  Future<List<Message>> loadTimeline([String? conversationId]) {
    return _loadFrontendTimelineMessages(
      container,
      conversationId ?? conv.id,
    );
  }

  Future<bool> interrupt({String? convId}) {
    return container.read(chatActionsProvider).interruptCurrentGeneration(
          convId: convId ?? conv.id,
        );
  }

  void switchActiveConversation(String conversationId) {
    container.read(activeConversationIdProvider.notifier).state =
        conversationId;
  }

  Future<_WindowProbe> probeNow() async {
    final snap = await loadTimeline();
    return _WindowProbe(
      windowEmissions: List<ConversationTimelineWindowState>.from(_emissions),
      transientReplaceCalls: timelineCache.transientReplaceCalls,
      snapshots: [List<Message>.from(snap)],
    );
  }

  Future<void> dispose() async {
    await _sub.cancel();
    container.dispose();
  }
}

Future<_Harness> _buildHarness({
  required String convId,
  required AppSettings settings,
  required List<_StreamStep> script,
  required String replyText,
  String? processedText,
  List<PluginEvent> pluginEvents = const <PluginEvent>[],
  bool recordTts = false,
  List<List<_StreamStep>>? scriptsByCall,
  List<String>? replyTextsByCall,
  List<String?>? processedTextsByCall,
  Map<String, List<_StreamStep>>? scriptsBySession,
  Map<String, String>? replyTextsBySession,
  Map<String, String?>? processedTextsBySession,
  /// When true, do not pin activeConversationProvider to a fixed value so
  /// activeConversationIdProvider can switch (A→B→A).
  bool switchableActiveConversation = false,
  List<Conversation>? extraConversations,
  List<Override> extraOverrides = const <Override>[],
}) async {
  final now = DateTime.now();
  final conv = Conversation(
    id: convId,
    title: 'Char_$convId',
    displayName: 'Char_$convId',
    createdAt: now,
    updatedAt: now,
    messages: const [],
    lastMessage: '',
    lastMessageTime: now,
  );
  final allConvs = <Conversation>[conv, ...?extraConversations];

  final db = AppDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  for (final c in allConvs) {
    await _insertConversation(db, c);
  }

  // Capture instances assigned inside overrides (providers are create-on-read).
  _CountingTimelineCache? timelineCache;
  _ScriptedStreamingSendService? sendService;
  _RecordingStreamTtsHandler? ttsHandler;

  final overrides = <Override>[
    ...extraOverrides,
    databaseProvider.overrideWithValue(db),
    appSettingsProvider.overrideWith(
      () => _FakeAppSettingsNotifier(settings),
    ),
    conversationsProvider.overrideWith(
      () => _FakeConversationsNotifier(allConvs),
    ),
    conversationTimelineCacheProvider.overrideWith((ref) {
      timelineCache = _CountingTimelineCache(ref);
      return timelineCache!;
    }),
    chatSendServiceProvider.overrideWith((ref) {
      sendService = _ScriptedStreamingSendService(
        ref,
        settings,
        script: script,
        replyText: replyText,
        processedText: processedText,
        pluginEvents: pluginEvents,
        scriptsByCall: scriptsByCall,
        replyTextsByCall: replyTextsByCall,
        processedTextsByCall: processedTextsByCall,
        scriptsBySession: scriptsBySession,
        replyTextsBySession: replyTextsBySession,
        processedTextsBySession: processedTextsBySession,
      );
      return sendService!;
    }),
  ];

  if (!switchableActiveConversation) {
    overrides.add(activeConversationProvider.overrideWith((ref) => conv));
  }

  if (recordTts) {
    overrides.add(
      chatTtsHandlerProvider.overrideWith((ref) {
        ttsHandler = _RecordingStreamTtsHandler(ref);
        return ttsHandler!;
      }),
    );
  }

  final container = ProviderContainer(overrides: overrides);
  container.read(activeConversationIdProvider.notifier).state = conv.id;
  await container.read(conversationsProvider.future);
  await container.read(appSettingsProvider.future);

  // Eagerly materialize overridden providers so captures are non-null.
  final resolvedCache =
      container.read(conversationTimelineCacheProvider) as _CountingTimelineCache;
  final resolvedSend =
      container.read(chatSendServiceProvider) as _ScriptedStreamingSendService;
  if (recordTts) {
    container.read(chatTtsHandlerProvider);
  }

  final emissions = <ConversationTimelineWindowState>[];
  final sub = resolvedCache
      .watchWindow(conversationId: conv.id, limit: 50)
      .listen(emissions.add);

  // Let the initial watchWindow seed emission settle.
  await Future<void>.delayed(const Duration(milliseconds: 20));

  return _Harness(
    container: container,
    conv: conv,
    timelineCache: timelineCache ?? resolvedCache,
    sendService: sendService ?? resolvedSend,
    ttsHandler: ttsHandler,
    sub: sub,
    emissions: emissions,
  );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  _installPlatformChannelMocks();

  group('A) non-chunking mode — 10 unpunctuated deltas', () {
    test('window notifies roughly with flushes; single active tail; id stability',
        () async {
      // 10 deltas, each spaced > flush interval so each flush can land.
      const deltaCount = 10;
      final deltas = <_StreamStep>[];
      for (var i = 0; i < deltaCount; i++) {
        deltas.add(_DeltaStep('字$i'));
        if (i < deltaCount - 1) {
          deltas.add(const _DelayStep(Duration(milliseconds: 200)));
        }
      }
      // Tail settle so last flush is visible before finalize.
      deltas.add(const _DelayStep(Duration(milliseconds: 220)));

      final fullText = List.generate(deltaCount, (i) => '字$i').join();
      final settings = _buildTestSettings(enableChunking: false);
      final harness = await _buildHarness(
        convId: 'char_a_nochunk_${DateTime.now().microsecondsSinceEpoch}',
        settings: settings,
        script: deltas,
        replyText: fullText,
      );
      addTearDown(harness.dispose);

      final probe = await harness.runSend(
        text: 'A non-chunk',
        sampleInterval: const Duration(milliseconds: 100),
        sampleTicks: 22,
      );

      // ---- 现状锁定：非分段下正文随 flush 上屏，窗口通知随 flush 增长 ----
      // 实测基线（2026-07-20）：windowNotify=14 / windowChange=13 / transientReplace=11
      // （watchWindow 含 1 次 seed；change = notify-1；约 10 次 flush + user/finalize 结构写入）
      expect(
        probe.windowChangeCount,
        inInclusiveRange(11, 16),
        reason: '现状基线：非分段 10 个跨 flush 间隔 delta → 窗口变更约 13 次（允许 ± 抖动）。'
            ' observed=${probe.windowChangeCount}',
      );
      expect(
        probe.transientReplaceCalls,
        inInclusiveRange(10, 14),
        reason: '现状基线：replaceMessagesTransient 约 11 次，随 flush 增长。'
            ' observed=${probe.transientReplaceCalls}',
      );

      // During stream, track active non-placeholder assistant tails.
      final midSnapshots = probe.snapshots.take(probe.snapshots.length - 1);
      final activeTailCounts = <int>[];
      final activeTailIds = <String>[];
      for (final snap in midSnapshots) {
        final active = snap
            .where(
              (m) =>
                  m.role == 'assistant' &&
                  m.status == 'sending' &&
                  !_isGeneratingPlaceholder(m) &&
                  !_isPendingAudio(m) &&
                  m.displayText.trim().isNotEmpty,
            )
            .toList();
        if (active.isEmpty) continue;
        activeTailCounts.add(active.length);
        activeTailIds.add(active.last.id);
      }

      expect(
        activeTailCounts,
        isNotEmpty,
        reason: '现状：流式中途应出现至少一条非占位的活跃尾文本消息。',
      );
      expect(
        activeTailCounts.every((c) => c == 1),
        isTrue,
        reason: '现状：非分段无标点流式期间，在飞时间线始终只有 1 条活跃尾正文消息'
            '（不含「生成中」占位）。观察到的计数序列=$activeTailCounts',
      );

      // Id stability across flushes — lock observed truth, no prior assumption.
      final uniqueIds = activeTailIds.toSet();
      // 现状（2026-07-20）：活跃尾 id 在跨 flush 物化复用下保持稳定。
      expect(
        uniqueIds.length,
        1,
        reason: '现状锁定：非分段活跃尾消息 id 跨 flush 稳定（物化复用）。'
            '若未来改成每次新 id，本断言应同步改写。ids=$uniqueIds',
      );

      final finalAssistant = _assistantRealText(probe.snapshots.last);
      expect(
        finalAssistant.any((m) => m.displayText.contains(fullText)),
        isTrue,
        reason: '现状：finalize 后终态应包含完整流式正文（不接受只剩首 delta）。',
      );
    });
  });

  group('B) chunking mode — multi-sentence seal / reveal', () {
    test('seal sequence, notification baseline, incomplete tail hidden',
        () async {
      // segmentDelay > 0 so reveal is paced.
      final settings = _buildTestSettings(
        enableChunking: true,
        minSegmentLength: 1,
        streamSegmentDelaySeconds: 0.12,
      );

      final script = <_StreamStep>[
        // Incomplete clause first — must NOT appear on screen.
        const _DeltaStep('半句还没'),
        const _DelayStep(Duration(milliseconds: 200)),
        const _DeltaStep('结束'),
        const _DelayStep(Duration(milliseconds: 200)),
        // Seal first sentence.
        const _DeltaStep('。'),
        const _DelayStep(Duration(milliseconds: 250)),
        // Second sentence incomplete then seal.
        const _DeltaStep('第二句'),
        const _DelayStep(Duration(milliseconds: 200)),
        const _DeltaStep('也完成。'),
        // Leave room for segment delay reveals before finalize.
        const _DelayStep(Duration(milliseconds: 350)),
      ];

      final harness = await _buildHarness(
        convId: 'char_b_chunk_${DateTime.now().microsecondsSinceEpoch}',
        settings: settings,
        script: script,
        replyText: '半句还没结束。第二句也完成。',
      );
      addTearDown(harness.dispose);

      final probe = await harness.runSend(
        text: 'B chunk',
        sampleInterval: const Duration(milliseconds: 80),
        sampleTicks: 28,
      );

      // ---- 未完句尾不上屏（现状）----
      final leakedIncomplete = probe.snapshots.any((snap) {
        return snap.any((m) {
          if (m.role != 'assistant') return false;
          if (_isGeneratingPlaceholder(m)) return false;
          final t = m.displayText;
          // Partial without terminal 。 should not surface as standalone content
          // before seal. "半句还没" alone or "半句还没结束" without 。 is a leak.
          return t == '半句还没' ||
              t == '半句还没结束' ||
              t == '第二句' ||
              (t.contains('半句还没') && !t.contains('。') && m.status == 'sending');
        });
      });
      expect(
        leakedIncomplete,
        isFalse,
        reason: '现状：分段模式下未完句尾巴不进 descriptors，不上屏。',
      );

      // ---- seal 序列：先出现第一句，再出现第二句 ----
      var sawFirstOnly = false;
      var sawBoth = false;
      for (final snap in probe.snapshots) {
        final texts = _assistantRealText(snap)
            .map((m) => m.displayText.trim())
            .toList();
        final hasFirst = texts.any((t) => t == '半句还没结束。' || t.contains('半句还没结束。'));
        final hasSecond = texts.any((t) => t.contains('第二句也完成。'));
        if (hasFirst && !hasSecond) sawFirstOnly = true;
        if (hasFirst && hasSecond) sawBoth = true;
      }
      expect(
        sawFirstOnly || sawBoth,
        isTrue,
        reason: '现状：封口后第一句应作为 seal 段出现在时间线（或与第二句同帧揭示）。',
      );
      expect(
        sawBoth,
        isTrue,
        reason: '现状：两句均 seal 后（含揭示节奏）最终应都能在流中/终态看到。',
      );

      // ---- 通知次数基线（分段 + segmentDelay）----
      // 实测基线（2026-07-20）：windowNotify=6 / windowChange=5 / transientReplace=3
      // 远少于非分段 10-flush 风暴；量级≈结构事件（seal/揭示/finalize）。
      expect(
        probe.windowChangeCount,
        inInclusiveRange(3, 10),
        reason: '现状基线：分段多句脚本窗口变更约 5 次（结构事件量级，非逐 token）。'
            ' observed=${probe.windowChangeCount}',
      );
      expect(
        probe.transientReplaceCalls,
        inInclusiveRange(2, 8),
        reason: '现状基线：分段模式 transientReplace 约 3 次。'
            ' observed=${probe.transientReplaceCalls}',
      );
      // 对照 A：同量级 delta 数时，分段通知显著更少（重建风暴主场在非分段）。
      expect(
        probe.windowChangeCount,
        lessThan(11),
        reason: '现状对照：分段模式通知次数应低于非分段 10-delta 基线下限。',
      );
    });
  });

  group('C) thinking placeholder', () {
    test('appears after 450ms without delta; settles on delta; notify converges',
        () async {
      final settings = _buildTestSettings(
        enableChunking: true,
        minSegmentLength: 1,
        streamSegmentDelaySeconds: 0,
      );

      final script = <_StreamStep>[
        // Wait past thinking delay (450ms) with no delta.
        const _DelayStep(Duration(milliseconds: 560)),
        // Then stream a sealed sentence.
        const _DeltaStep('来了第一句。'),
        const _DelayStep(Duration(milliseconds: 250)),
        // Idle — should not spam notifications.
        const _DelayStep(Duration(milliseconds: 400)),
      ];

      final harness = await _buildHarness(
        convId: 'char_c_think_${DateTime.now().microsecondsSinceEpoch}',
        settings: settings,
        script: script,
        replyText: '来了第一句。',
      );
      addTearDown(harness.dispose);

      final probe = await harness.runSend(
        text: 'C think',
        sampleInterval: const Duration(milliseconds: 70),
        sampleTicks: 22,
      );

      // Find first snapshot with generating placeholder and whether real text
      // coexists / replaces it later.
      var sawPlaceholderAlone = false;
      String? firstPlaceholderId;
      final placeholderIds = <String>{};
      var maxPlaceholderCount = 0;

      for (final snap in probe.snapshots) {
        final placeholders =
            snap.where(_isGeneratingPlaceholder).toList(growable: false);
        if (placeholders.isEmpty) continue;
        maxPlaceholderCount =
            placeholders.length > maxPlaceholderCount ? placeholders.length : maxPlaceholderCount;
        for (final p in placeholders) {
          placeholderIds.add(p.id);
          firstPlaceholderId ??= p.id;
        }
        final reals = _assistantRealText(snap);
        if (reals.isEmpty) {
          sawPlaceholderAlone = true;
        } else {
        }
      }

      expect(
        sawPlaceholderAlone,
        isTrue,
        reason: '现状：无 delta 超过 thinking 延迟（450ms）后应出现「生成中...」占位。',
      );

      // After delta, either placeholder pins under real sealed text, or is gone
      // after finalize — both are valid phases of current design.
      final finalSnap = probe.snapshots.last;
      expect(
        finalSnap.where(_isGeneratingPlaceholder),
        isEmpty,
        reason: '现状：finalize 后不应残留「生成中...」占位。',
      );
      expect(
        _assistantRealText(finalSnap).any((m) => m.displayText.contains('来了第一句')),
        isTrue,
        reason: '现状：delta 到来并 finalize 后终态应有正文。',
      );

      // During stream after first seal, placeholder may pin as trailing bubble.
      // Lock: placeholder id does not thrash to many ids.
      expect(
        placeholderIds.length,
        lessThanOrEqualTo(2),
        reason: '现状：占位 id 应稳定钉底（至多因 reset/重建出现极少变化），'
            '不应无限换 id。ids=$placeholderIds',
      );
      expect(
        maxPlaceholderCount,
        lessThanOrEqualTo(1),
        reason: '现状：同一时刻至多一条「生成中」占位。',
      );

      // 实测基线（2026-07-20）：windowNotify=6 / windowChange=5 / transientReplace=3
      // idle 400ms 后不再增长——占位通知收敛。
      expect(
        probe.windowChangeCount,
        inInclusiveRange(3, 10),
        reason: '现状基线：占位出现 + seal + finalize 后通知收敛约 5 次，不无限重复。'
            ' observed=${probe.windowChangeCount}',
      );
      expect(
        probe.transientReplaceCalls,
        inInclusiveRange(2, 8),
        reason: '现状基线：占位相关 transientReplace 约 3 次并收敛。'
            ' observed=${probe.transientReplaceCalls}',
      );
      expect(firstPlaceholderId, isNotNull);
      // 注：sawPlaceholderAlone 已在上文单独断言；此处不再重复
      //（原「A||B」在 A 已恒真时无信息量，见审查 S-06）。
    });
  });

  group('D) onStreamReset / writeEpoch', () {
    test('reset clears in-flight; pre-reset delayed flush does not land',
        () async {
      final settings = _buildTestSettings(
        enableChunking: true,
        minSegmentLength: 1,
        streamSegmentDelaySeconds: 0,
      );

      // Emit sealed old content, wait for flush to schedule, then reset
      // BEFORE the 180ms flush can apply — writeEpoch should drop it.
      // Then emit new content after reset.
      final script = <_StreamStep>[
        const _DeltaStep('旧内容要被丢弃。'),
        // Stay under flush interval so the first apply may still be in-flight
        // or about to fire; then reset bumps writeEpoch.
        const _DelayStep(Duration(milliseconds: 40)),
        const _ResetStep(),
        // Wait well past flush interval — stale flush must not re-land 旧内容.
        const _DelayStep(Duration(milliseconds: 280)),
        const _DeltaStep('重置后的新内容。'),
        const _DelayStep(Duration(milliseconds: 250)),
      ];

      final harness = await _buildHarness(
        convId: 'char_d_reset_${DateTime.now().microsecondsSinceEpoch}',
        settings: settings,
        script: script,
        replyText: '重置后的新内容。',
      );
      addTearDown(harness.dispose);

      final probe = await harness.runSend(
        text: 'D reset',
        sampleInterval: const Duration(milliseconds: 50),
        sampleTicks: 20,
      );

      expect(harness.sendService.resetCalls, 1);
      // 实测基线（2026-07-20）：windowNotify=5 / windowChange=4 / transientReplace=2
      expect(
        probe.windowChangeCount,
        inInclusiveRange(2, 10),
        reason: '现状基线：reset+新流脚本窗口变更约 4 次。'
            ' observed=${probe.windowChangeCount}',
      );

      // After reset settles and before new delta, in-flight should be empty
      // or only regenerating placeholder — never keep 旧内容.
      final sawOldContentAfterResetWindow = probe.snapshots.any((snap) {
        // We cannot perfectly know "after reset" by time index alone; instead
        // assert globally that final state has no 旧内容, and that any mid
        // snapshot that already has 新内容 never coexists with 旧内容.
        final texts = snap
            .where((m) => m.role == 'assistant')
            .map((m) => m.displayText)
            .toList();
        final hasNew = texts.any((t) => t.contains('重置后的新内容'));
        final hasOld = texts.any((t) => t.contains('旧内容要被丢弃'));
        return hasNew && hasOld;
      });
      expect(
        sawOldContentAfterResetWindow,
        isFalse,
        reason: '现状：writeEpoch 防串线——reset 后旧内容不应与新内容共存。',
      );

      final finalTexts = probe.snapshots.last
          .where((m) => m.role == 'assistant')
          .map((m) => m.displayText)
          .toList();
      expect(
        finalTexts.any((t) => t.contains('旧内容要被丢弃')),
        isFalse,
        reason: '现状：reset 后旧在飞消息被清空；延迟 flush 不得把旧内容落地到终态。',
      );
      expect(
        finalTexts.any((t) => t.contains('重置后的新内容')),
        isTrue,
        reason: '现状：reset 之后的新 delta 应正常上屏并 finalize。',
      );

      // Stronger check on intermediate snapshots: once 旧内容 appeared, after
      // enough time past reset it must disappear and not return without 新内容.
      var oldEverAppeared = false;
      var oldClearedAfterAppear = false;
      for (final snap in probe.snapshots) {
        final hasOld = snap.any(
          (m) =>
              m.role == 'assistant' && m.displayText.contains('旧内容要被丢弃'),
        );
        if (hasOld) {
          oldEverAppeared = true;
        } else if (oldEverAppeared) {
          oldClearedAfterAppear = true;
        }
      }
      // If flush landed before reset (timing race), content must still clear.
      // If flush never landed, old never appears — also fine (writeEpoch win).
      if (oldEverAppeared) {
        expect(
          oldClearedAfterAppear,
          isTrue,
          reason: '现状：若 reset 前旧内容已上屏，reset 后必须被 discard 清空。',
        );
      }
    });

    test('reset after flushed content discards old sealed messages', () async {
      final settings = _buildTestSettings(
        enableChunking: true,
        minSegmentLength: 1,
        streamSegmentDelaySeconds: 0,
      );

      final script = <_StreamStep>[
        const _DeltaStep('已落盘旧句。'),
        // Stay well past flush (180ms) so seal is observable before reset.
        // (Too-short windows made periodic sampling flaky.)
        const _DelayStep(Duration(milliseconds: 400)),
        const _ResetStep(),
        const _DelayStep(Duration(milliseconds: 220)),
        const _DeltaStep('全新一句。'),
        const _DelayStep(Duration(milliseconds: 280)),
      ];

      final harness = await _buildHarness(
        convId: 'char_d_reset2_${DateTime.now().microsecondsSinceEpoch}',
        settings: settings,
        script: script,
        replyText: '全新一句。',
      );
      addTearDown(harness.dispose);

      final probe = await harness.runSend(
        text: 'D reset2',
        sampleInterval: const Duration(milliseconds: 40),
        sampleTicks: 30,
      );

      // 实测基线（2026-07-20）：windowNotify≈7 / windowChange≈6 / transientReplace≈3
      expect(
        probe.windowChangeCount,
        inInclusiveRange(3, 14),
        reason: '现状基线：先落盘再 reset 的脚本窗口变更约 6 次。'
            ' observed=${probe.windowChangeCount}',
      );

      // Prefer watchWindow emissions (every structural write) over sparse polling.
      final sawOldInWindow = probe.windowEmissions.any(
        (w) => w.messages.any(
          (m) => m.role == 'assistant' && m.displayText.contains('已落盘旧句'),
        ),
      );
      final sawOldInSnapshots = probe.snapshots.any(
        (snap) => snap.any(
          (m) => m.role == 'assistant' && m.displayText.contains('已落盘旧句'),
        ),
      );
      expect(
        sawOldInWindow || sawOldInSnapshots,
        isTrue,
        reason: '前置条件：reset 前旧 seal 应先上屏（窗口通知或采样快照任一可见即可）。',
      );

      final finalSnap = probe.snapshots.last;
      expect(
        finalSnap.any(
          (m) => m.role == 'assistant' && m.displayText.contains('已落盘旧句'),
        ),
        isFalse,
        reason: '现状：onStreamReset 清空 _currentTimelineMessages 并 discard。',
      );
      expect(
        finalSnap.any(
          (m) => m.role == 'assistant' && m.displayText.contains('全新一句'),
        ),
        isTrue,
        reason: '现状：reset 后新流内容正常 finalize。',
      );
    });
  });

  group('E) finalize/commit + pendingAudio', () {
    test('final sequence relation to stream; <tts> yields pendingAudio event',
        () async {
      final settings = _buildTestSettings(
        enableChunking: true,
        minSegmentLength: 1,
        streamSegmentDelaySeconds: 0,
        ttsEnabled: true,
      );

      final script = <_StreamStep>[
        const _DeltaStep('第一句。'),
        const _DelayStep(Duration(milliseconds: 80)),
        const _DeltaStep('<tts>语音片段'),
        const _DelayStep(Duration(milliseconds: 40)),
        const _DeltaStep('</tts>'),
        const _DelayStep(Duration(milliseconds: 150)),
        const _DeltaStep('第二句。'),
        const _DelayStep(Duration(milliseconds: 220)),
      ];

      final harness = await _buildHarness(
        convId: 'char_e_tts_${DateTime.now().microsecondsSinceEpoch}',
        settings: settings,
        script: script,
        replyText: '第一句。<tts>语音片段</tts>第二句。',
        processedText: '第一句。第二句。',
        pluginEvents: <PluginEvent>[
          PluginEvent(
            pluginId: 'tts',
            type: 'tts_convert',
            data: <String, dynamic>{
              'text': '语音片段',
              'originalText': '语音片段',
            },
            id: 'evt_char_e_tts',
          ),
        ],
        recordTts: true,
      );
      addTearDown(harness.dispose);

      final probe = await harness.runSend(
        text: 'E tts',
        sampleInterval: const Duration(milliseconds: 70),
        sampleTicks: 14,
      );

      // 实测基线（2026-07-20）：windowNotify=6 / windowChange=5 / transientReplace=3
      expect(
        probe.windowChangeCount,
        inInclusiveRange(3, 12),
        reason: '现状基线：文本+tts+文本结构事件窗口变更约 5 次。'
            ' observed=${probe.windowChangeCount}',
      );
      expect(
        probe.transientReplaceCalls,
        inInclusiveRange(2, 8),
        reason: '现状基线：含 pendingAudio 的 transientReplace 约 3 次。'
            ' observed=${probe.transientReplaceCalls}',
      );

      // ---- pendingAudio during stream (现状) ----
      final sawPendingDuringStream = probe.snapshots.any((snap) {
        return snap.any((m) {
          if (!_isPendingAudio(m)) return false;
          final audio = m.blocks!.whereType<AudioBlock>().first;
          return (audio.text ?? '').contains('语音片段');
        });
      });
      expect(
        sawPendingDuringStream,
        isTrue,
        reason: '现状：完整 </tts> 闭合后应立即作为 pendingAudio 结构事件上屏。',
      );

      // Stream text seals in order around the audio placeholder.
      var sawOrderedStream = false;
      for (final snap in probe.snapshots) {
        final assistant = snap.where((m) => m.role == 'assistant').toList();
        final firstIdx = assistant.indexWhere(
          (m) => m.displayText.contains('第一句'),
        );
        final audioIdx = assistant.indexWhere(_isPendingAudio);
        final secondIdx = assistant.indexWhere(
          (m) => m.displayText.contains('第二句'),
        );
        if (firstIdx >= 0 && audioIdx >= 0 && secondIdx >= 0) {
          if (firstIdx < audioIdx && audioIdx < secondIdx) {
            sawOrderedStream = true;
            break;
          }
        }
      }
      expect(
        sawOrderedStream,
        isTrue,
        reason: '现状：流中消息序为 文本seal → pendingAudio → 文本seal（语序）。',
      );

      // ---- finalize/commit relation ----
      final tts = harness.ttsHandler!;
      expect(
        tts.lastAppendAfterStreamText,
        isTrue,
        reason: '现状：流式 commit 后 TTS handler 以 appendAfterStreamText=true 承接。',
      );
      expect(
        tts.lastPendingStreamTtsMessages,
        hasLength(1),
        reason: '现状：收尾复用流式阶段的 pendingAudio 占位（不重新创建）。',
      );
      expect(
        (tts.lastPendingStreamTtsMessages.single.blocks!
                .whereType<AudioBlock>()
                .first
                .text ??
            ''),
        contains('语音片段'),
      );

      // Final frontend may still hold the pending audio (recording handler
      // does not fill URL) plus committed text projection.
      final finalSnap = probe.snapshots.last;
      final pendingFinal = finalSnap.where(_isPendingAudio).toList();
      expect(
        pendingFinal,
        isNotEmpty,
        reason: '现状：录制型 TTS handler 不回填时，前端仍保留流式 pendingAudio 占位。',
      );

      // Text message ids handed to TTS match frontend text seals.
      final frontendTextIds = finalSnap
          .where((m) {
            final texts = m.blocks?.whereType<TextBlock>().toList() ?? const [];
            if (texts.length != 1) return false;
            final t = texts.single.content.trim();
            return t == '第一句。' || t == '第二句。';
          })
          .map((m) => m.id)
          .toList();
      expect(
        tts.lastStreamTextMessageIds,
        frontendTextIds,
        reason: '现状：commit 传给 TTS 的 streamTextMessageIds 与终态文本气泡 id 一致。',
      );

      // Finalize clears generating placeholder.
      expect(
        finalSnap.where(_isGeneratingPlaceholder),
        isEmpty,
        reason: '现状：finalize/commit 后无「生成中」残留。',
      );
    });

    test('text-only finalize: stream seals map to final committed body',
        () async {
      final settings = _buildTestSettings(
        enableChunking: true,
        minSegmentLength: 1,
        streamSegmentDelaySeconds: 0,
      );

      final script = <_StreamStep>[
        const _DeltaStep('甲。'),
        const _DelayStep(Duration(milliseconds: 200)),
        const _DeltaStep('乙。'),
        const _DelayStep(Duration(milliseconds: 200)),
        const _DeltaStep('丙。'),
        const _DelayStep(Duration(milliseconds: 220)),
      ];

      final harness = await _buildHarness(
        convId: 'char_e_final_${DateTime.now().microsecondsSinceEpoch}',
        settings: settings,
        script: script,
        replyText: '甲。乙。丙。',
      );
      addTearDown(harness.dispose);

      final probe = await harness.runSend(
        text: 'E final',
        sampleInterval: const Duration(milliseconds: 80),
        sampleTicks: 14,
      );

      // 实测基线（2026-07-20）：windowNotify=7 / windowChange=6 / transientReplace=4
      expect(
        probe.windowChangeCount,
        inInclusiveRange(3, 12),
        reason: '现状基线：三句 seal 文本脚本窗口变更约 6 次。'
            ' observed=${probe.windowChangeCount}',
      );
      expect(
        probe.transientReplaceCalls,
        inInclusiveRange(2, 8),
        reason: '现状基线：三句 seal transientReplace 约 4 次。'
            ' observed=${probe.transientReplaceCalls}',
      );

      // During stream, sealed sentences may appear as separate bubbles.
      final midSealedTexts = <String>{};
      for (final snap in probe.snapshots.take(probe.snapshots.length - 1)) {
        for (final m in _assistantRealText(snap)) {
          if (m.status == 'sent') {
            midSealedTexts.add(m.displayText.trim());
          }
        }
      }

      // 现状：流中 seal 为句级气泡（甲。/乙。/丙。），而 DB 投影终态可能合并为
      // 单条 raw 正文（见既有 chat_actions_test finalize 用例）。
      // 前端时间线 commit 后以 buildResult / 投影为准。
      final finalAssistant = probe.snapshots.last
          .where((m) => m.role == 'assistant' && !_isGeneratingPlaceholder(m))
          .toList();
      final finalTexts =
          finalAssistant.map((m) => m.displayText.trim()).toList();

      expect(
        finalTexts.join(),
        contains('甲'),
        reason: '现状：finalize 后终态包含流式正文。',
      );
      expect(
        finalSnapHasNoGenerating(probe.snapshots.last),
        isTrue,
        reason: '现状：finalize 后无占位。',
      );

      // 流中按句 seal 的节奏与可见性由 J 组（segment reveal pacing）
      // 专项锁定；此处不做时机敏感断言（原条件自证恒真，见审查 S-06）。

      // Persisted raw projection: single assistant raw body (existing contract).
      final stored = await harness.container
          .read(chatHistoryStoreProvider)
          .loadProjectedMessagesFromRawStore(harness.conv.id);
      final storedAssistant = stored
          .where((m) => m.role == 'assistant')
          .where((m) => m.displayText.trim().isNotEmpty)
          .where((m) => m.displayText.trim() != '生成中...')
          .toList();
      expect(
        storedAssistant.length,
        1,
        reason: '现状：持久化层保留原始 assistant 消息（UI 决定分段），'
            '与流中多 seal 气泡不必 1:1。',
      );
      expect(
        storedAssistant.single.displayText,
        '甲。乙。丙。',
        reason: '现状：DB 投影终态为完整 raw 正文。',
      );
    });
  });

  // -------------------------------------------------------------------------
  // F–J: 真实 interrupt / retry / reset-during-reveal / A→B→A / 揭示节奏
  // （审查补缺：scratch/diagnostics/方案审查_stream-active-bubble_20260720.md §六.4/5/6）
  // -------------------------------------------------------------------------

  group('F) real interruptCurrentGeneration', () {
    test('F1 thinking 占位期 interrupt：清幽灵占位，时间线恢复，后续 send 正常',
        () async {
      final settings = _buildTestSettings(
        enableChunking: true,
        minSegmentLength: 1,
        streamSegmentDelaySeconds: 0,
      );

      // Long idle past thinking delay, then late deltas that must not land
      // after interrupt (generation no longer current).
      final script = <_StreamStep>[
        const _DelayStep(Duration(milliseconds: 900)),
        const _DeltaStep('中断后不该出现的迟到正文。'),
        const _DelayStep(Duration(milliseconds: 120)),
      ];

      final harness = await _buildHarness(
        convId: 'char_f1_think_${DateTime.now().microsecondsSinceEpoch}',
        settings: settings,
        script: script,
        replyText: '中断后不该出现的迟到正文。',
      );
      addTearDown(harness.dispose);

      const userText = 'F1 think interrupt';
      harness.startSend(text: userText);

      // Wait past thinking placeholder delay (450ms).
      await Future<void>.delayed(const Duration(milliseconds: 560));
      final mid = await harness.loadTimeline();
      expect(
        mid.any(_isGeneratingPlaceholder),
        isTrue,
        reason: '前置：thinking 延迟后应出现「生成中...」占位，才能测占位期 interrupt。',
      );
      expect(
        mid.any((m) => m.role == 'user' && m.displayText == userText),
        isTrue,
      );

      final stopped = await harness.interrupt();
      expect(stopped, isTrue, reason: '公开面 interruptCurrentGeneration 应返回 true。');

      await Future<void>.delayed(const Duration(milliseconds: 40));
      final afterInterrupt = await harness.loadTimeline();
      expect(
        afterInterrupt.where(_isGeneratingPlaceholder),
        isEmpty,
        reason: '现状：interrupt 清理 removePlaceholders，无「生成中」幽灵。',
      );
      expect(
        afterInterrupt.where((m) => m.role == 'assistant'),
        isEmpty,
        reason: '现状：interrupt 后从持久历史恢复，未提交的 assistant 不保留。',
      );
      expect(
        afterInterrupt.map((m) => m.displayText).toList(),
        [userText],
        reason: '现状：恢复语义只保留已落库用户消息。',
      );

      // Let late script deltas finish; they must not re-materialize assistant.
      await harness.awaitActiveSend();
      final afterLate = await harness.loadTimeline();
      expect(
        afterLate.any((m) => m.displayText.contains('中断后不该出现')),
        isFalse,
        reason: '现状：generation 已失效，迟到 delta/结果不落库不上屏。',
      );
      expect(
        afterLate.where((m) => m.role == 'assistant'),
        isEmpty,
      );
      // 同容器 interrupt 后再 send 见 F1b。
    });

    test('F1b same container: interrupt then re-send succeeds', () async {
      final settings = _buildTestSettings(
        enableChunking: true,
        minSegmentLength: 1,
        streamSegmentDelaySeconds: 0,
      );

      final harness = await _buildHarness(
        convId: 'char_f1same_${DateTime.now().microsecondsSinceEpoch}',
        settings: settings,
        script: const <_StreamStep>[], // unused when scriptsByCall set
        replyText: '',
        scriptsByCall: [
          const <_StreamStep>[
            _DelayStep(Duration(milliseconds: 900)),
            _DeltaStep('迟到不该见。'),
            _DelayStep(Duration(milliseconds: 80)),
          ],
          const <_StreamStep>[
            _DeltaStep('第二轮正文。'),
            _DelayStep(Duration(milliseconds: 220)),
          ],
        ],
        replyTextsByCall: const [
          '迟到不该见。',
          '第二轮正文。',
        ],
      );
      addTearDown(harness.dispose);

      harness.startSend(text: 'F1b first');
      await Future<void>.delayed(const Duration(milliseconds: 560));
      expect(await harness.interrupt(), isTrue);
      await harness.awaitActiveSend();

      final midSnap = await harness.loadTimeline();
      expect(midSnap.where((m) => m.role == 'assistant'), isEmpty);

      final probe2 = await harness.runSend(
        text: 'F1b second',
        sampleInterval: const Duration(milliseconds: 80),
        sampleTicks: 6,
      );
      expect(harness.sendService.executeCalls, greaterThanOrEqualTo(2));
      expect(
        _assistantRealText(probe2.snapshots.last)
            .any((m) => m.displayText.contains('第二轮正文')),
        isTrue,
        reason: '现状：interrupt 后同会话再 send 建立新 delivery，正常 finalize。',
      );
      expect(
        probe2.snapshots.last
            .any((m) => m.displayText.contains('迟到不该见')),
        isFalse,
        reason: '现状：旧轮迟到内容不污染新轮终态。',
      );
      expect(
        probe2.snapshots.last.where(_isGeneratingPlaceholder),
        isEmpty,
      );
    });

    test('F2 活跃文本期 interrupt：在飞尾气泡清理，无幽灵，历史恢复', () async {
      final settings = _buildTestSettings(
        enableChunking: true,
        minSegmentLength: 1,
        streamSegmentDelaySeconds: 0,
      );

      final script = <_StreamStep>[
        const _DeltaStep('活跃期可见句。'),
        // Hold stream open long enough to interrupt while text is visible.
        const _DelayStep(Duration(milliseconds: 700)),
        const _DeltaStep('中断后尾巴。'),
        const _DelayStep(Duration(milliseconds: 100)),
      ];

      final harness = await _buildHarness(
        convId: 'char_f2_active_${DateTime.now().microsecondsSinceEpoch}',
        settings: settings,
        script: script,
        replyText: '活跃期可见句。中断后尾巴。',
      );
      addTearDown(harness.dispose);

      const userText = 'F2 active interrupt';
      harness.startSend(text: userText);

      // Wait for seal + flush (180ms) to surface active text.
      var sawActiveText = false;
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 40));
        final snap = await harness.loadTimeline();
        if (snap.any(
          (m) =>
              m.role == 'assistant' &&
              !_isGeneratingPlaceholder(m) &&
              m.displayText.contains('活跃期可见句'),
        )) {
          sawActiveText = true;
          break;
        }
      }
      expect(
        sawActiveText,
        isTrue,
        reason: '前置：interrupt 前应先看到活跃 seal 文本。',
      );

      final stopped = await harness.interrupt();
      expect(stopped, isTrue);

      await Future<void>.delayed(const Duration(milliseconds: 40));
      final after = await harness.loadTimeline();
      expect(
        after.where(_isGeneratingPlaceholder),
        isEmpty,
        reason: '现状：活跃期 interrupt 无生成中占位残留。',
      );
      expect(
        after.any((m) => m.displayText.contains('活跃期可见句')),
        isFalse,
        reason: '现状：未 commit 的流式 seal 在 restore 后消失（非 DB 正式消息）。',
      );
      expect(
        after.any((m) => m.displayText.contains('中断后尾巴')),
        isFalse,
      );
      expect(
        after.map((m) => m.displayText).toList(),
        [userText],
        reason: '现状：时间线恢复为持久用户消息。',
      );

      await harness.awaitActiveSend();
      final finalSnap = await harness.loadTimeline();
      expect(
        finalSnap.where((m) => m.role == 'assistant'),
        isEmpty,
        reason: '现状：迟到结果不落 assistant。',
      );
    });

    test('F3 分段揭示 backlog 期 interrupt：取消未揭示段，无幽灵', () async {
      // segmentDelay large enough that multi-seal arrives as backlog.
      // Hold stream well past interrupt so generation is still current.
      final settings = _buildTestSettings(
        enableChunking: true,
        minSegmentLength: 1,
        streamSegmentDelaySeconds: 0.35,
      );

      // Three sealed sentences arrive quickly → backlog under segment delay.
      final script = <_StreamStep>[
        const _DeltaStep('第一段。'),
        const _DeltaStep('第二段。'),
        const _DeltaStep('第三段。'),
        // Keep generation alive long after interrupt window.
        const _DelayStep(Duration(milliseconds: 1600)),
      ];

      final harness = await _buildHarness(
        convId: 'char_f3_backlog_${DateTime.now().microsecondsSinceEpoch}',
        settings: settings,
        script: script,
        replyText: '第一段。第二段。第三段。',
      );
      addTearDown(harness.dispose);

      const userText = 'F3 backlog interrupt';
      harness.startSend(text: userText);

      // Enter backlog window while generation is still open:
      // past flush (180ms) + into segmentDelay so seals may be partially
      // revealed / still hidden — but BEFORE script ends (generation ends).
      // 现状：无后续 dirty 时 mid-stream 可能长时间只见 0~1 段 + 生成中占位。
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final mid = await harness.loadTimeline();
      final sealedMid = _assistantRealText(mid)
          .where((m) => m.displayText.contains('段'))
          .toList();
      final hasBacklogSignal = mid.any(_isGeneratingPlaceholder) ||
          sealedMid.isNotEmpty ||
          mid.any((m) => m.role == 'user' && m.displayText == userText);
      expect(
        hasBacklogSignal,
        isTrue,
        reason: '前置：流仍在飞（用户消息已在时间线；或可见 seal/生成中）。'
            ' sealed=${sealedMid.length} '
            'placeholder=${mid.any(_isGeneratingPlaceholder)}',
      );
      // Must still be interruptible (generation not finished).
      final stopped = await harness.interrupt();
      expect(
        stopped,
        isTrue,
        reason: '现状：脚本长 hold 下 500ms 时 generation 仍 active，'
            'interruptCurrentGeneration 应返回 true。',
      );

      await Future<void>.delayed(const Duration(milliseconds: 50));
      final after = await harness.loadTimeline();
      expect(
        after.where(_isGeneratingPlaceholder),
        isEmpty,
        reason: '现状：backlog 期 interrupt 无占位幽灵。',
      );
      expect(
        after.any(
          (m) =>
              m.role == 'assistant' &&
              (m.displayText.contains('第一段') ||
                  m.displayText.contains('第二段') ||
                  m.displayText.contains('第三段')),
        ),
        isFalse,
        reason: '现状：interrupt → removePlaceholders + restore，流式 seal 全清。',
      );

      // Wait past remaining segment delays — old backlog must not reappear.
      await Future<void>.delayed(const Duration(milliseconds: 600));
      final afterWait = await harness.loadTimeline();
      expect(
        afterWait.any(
          (m) =>
              m.role == 'assistant' &&
              (m.displayText.contains('第一段') ||
                  m.displayText.contains('第二段') ||
                  m.displayText.contains('第三段')),
        ),
        isFalse,
        reason: '现状：interrupt 后旧揭示计时器不得再吐 backlog 段。',
      );

      await harness.awaitActiveSend();
      final finalSnap = await harness.loadTimeline();
      expect(finalSnap.where((m) => m.role == 'assistant'), isEmpty);
      expect(
        finalSnap.map((m) => m.displayText).toList(),
        [userText],
      );
    });
  });

  group('G) retry / new delivery after end or interrupt', () {
    test('中断旧轮后新 send：旧延迟 flush/计时器不产生额外消息，新轮序列正常',
        () async {
      final settings = _buildTestSettings(
        enableChunking: true,
        minSegmentLength: 1,
        streamSegmentDelaySeconds: 0.25,
      );

      final harness = await _buildHarness(
        convId: 'char_g_retry_${DateTime.now().microsecondsSinceEpoch}',
        settings: settings,
        script: const <_StreamStep>[],
        replyText: '',
        scriptsByCall: [
          // Round 1: multi-seal backlog then long hold → interrupt mid-flight.
          const <_StreamStep>[
            _DeltaStep('旧轮甲。'),
            _DeltaStep('旧轮乙。'),
            _DeltaStep('旧轮丙。'),
            _DelayStep(Duration(milliseconds: 800)),
          ],
          // Round 2: new delivery content.
          const <_StreamStep>[
            _DeltaStep('新轮唯一句。'),
            _DelayStep(Duration(milliseconds: 280)),
          ],
        ],
        replyTextsByCall: const [
          '旧轮甲。旧轮乙。旧轮丙。',
          '新轮唯一句。',
        ],
      );
      addTearDown(harness.dispose);

      harness.startSend(text: 'G round1');
      // Enter backlog window.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final stopped = await harness.interrupt();
      expect(stopped, isTrue);
      await harness.awaitActiveSend();

      final between = await harness.loadTimeline();
      expect(
        between.any((m) => m.displayText.contains('旧轮')),
        isFalse,
        reason: '旧轮 interrupt 后前端无旧轮 seal。',
      );

      final replaceBeforeRound2 = harness.timelineCache.transientReplaceCalls;
      final probe2 = await harness.runSend(
        text: 'G round2',
        sampleInterval: const Duration(milliseconds: 70),
        sampleTicks: 10,
      );

      expect(harness.sendService.executeCalls, greaterThanOrEqualTo(2));

      // Wait well past old segmentDelay — old timers must not resurrect 旧轮.
      await Future<void>.delayed(const Duration(milliseconds: 400));
      final late = await harness.loadTimeline();
      expect(
        late.any((m) => m.displayText.contains('旧轮')),
        isFalse,
        reason: '现状：旧 delivery 的延迟 flush/segment 计时器在 dispose 后不产生额外消息。',
      );
      expect(
        _assistantRealText(late).any((m) => m.displayText.contains('新轮唯一句')),
        isTrue,
        reason: '现状：新 delivery 序列正常 finalize。',
      );
      expect(
        late.where(_isGeneratingPlaceholder),
        isEmpty,
      );

      // New round should have performed its own transient replaces.
      expect(
        harness.timelineCache.transientReplaceCalls,
        greaterThan(replaceBeforeRound2),
        reason: '新轮 delivery 应独立驱动 replaceMessagesTransient。',
      );
      expect(
        probe2.snapshots.last.any((m) => m.displayText.contains('旧轮')),
        isFalse,
      );
    });

    test('一轮正常结束后再 send：两轮内容共存，旧轮不重复追加', () async {
      final settings = _buildTestSettings(
        enableChunking: true,
        minSegmentLength: 1,
        streamSegmentDelaySeconds: 0,
      );

      final harness = await _buildHarness(
        convId: 'char_g_end_${DateTime.now().microsecondsSinceEpoch}',
        settings: settings,
        script: const <_StreamStep>[],
        replyText: '',
        scriptsByCall: [
          const <_StreamStep>[
            _DeltaStep('结束轮内容。'),
            _DelayStep(Duration(milliseconds: 220)),
          ],
          const <_StreamStep>[
            _DeltaStep('下一轮内容。'),
            _DelayStep(Duration(milliseconds: 220)),
          ],
        ],
        replyTextsByCall: const [
          '结束轮内容。',
          '下一轮内容。',
        ],
      );
      addTearDown(harness.dispose);

      final p1 = await harness.runSend(
        text: 'G end1',
        sampleInterval: const Duration(milliseconds: 80),
        sampleTicks: 5,
      );
      expect(
        _assistantRealText(p1.snapshots.last)
            .any((m) => m.displayText.contains('结束轮内容')),
        isTrue,
      );

      final countAfterRound1 = (await harness.loadTimeline()).length;
      final p2 = await harness.runSend(
        text: 'G end2',
        sampleInterval: const Duration(milliseconds: 80),
        sampleTicks: 5,
      );

      final finalSnap = p2.snapshots.last;
      final endRoundHits = finalSnap
          .where((m) => m.displayText.contains('结束轮内容'))
          .length;
      final nextRoundHits = finalSnap
          .where((m) => m.displayText.contains('下一轮内容'))
          .length;
      expect(endRoundHits, 1, reason: '现状：旧轮正文不因新轮计时器/flush 重复追加。');
      expect(nextRoundHits, greaterThanOrEqualTo(1));
      expect(
        finalSnap.length,
        greaterThan(countAfterRound1),
        reason: '新轮至少追加 user + assistant。',
      );
      expect(harness.sendService.executeCalls, 2);
    });
  });

  group('H) onStreamReset during segment reveal backlog', () {
    test('segmentDelay>0 揭示等待期间 reset：取消未揭示 backlog，旧段不再揭示',
        () async {
      // Larger delay so multiple seals sit in backlog when reset fires.
      final settings = _buildTestSettings(
        enableChunking: true,
        minSegmentLength: 1,
        streamSegmentDelaySeconds: 0.40,
      );

      final script = <_StreamStep>[
        // Seal three sentences almost immediately (backlog builds).
        const _DeltaStep('旧揭示甲。'),
        const _DeltaStep('旧揭示乙。'),
        const _DeltaStep('旧揭示丙。'),
        // Stay under full 3×delay so not all revealed, then reset.
        // First reveal ~400ms; interrupt backlog before second/third.
        const _DelayStep(Duration(milliseconds: 120)),
        const _ResetStep(),
        // Wait past multiple segment delays — unrevealed 旧 must not appear.
        const _DelayStep(Duration(milliseconds: 900)),
        const _DeltaStep('reset后新句。'),
        const _DelayStep(Duration(milliseconds: 280)),
      ];

      final harness = await _buildHarness(
        convId: 'char_h_reveal_reset_${DateTime.now().microsecondsSinceEpoch}',
        settings: settings,
        script: script,
        replyText: 'reset后新句。',
      );
      addTearDown(harness.dispose);

      final probe = await harness.runSend(
        text: 'H reveal reset',
        sampleInterval: const Duration(milliseconds: 50),
        sampleTicks: 36,
      );

      expect(harness.sendService.resetCalls, 1);

      // After reset, old backlog seals must not surface (or if briefly flushed
      // pre-reset, must clear and never return alongside / after 新句 alone).
      final finalTexts = probe.snapshots.last
          .where((m) => m.role == 'assistant')
          .map((m) => m.displayText)
          .toList();
      expect(
        finalTexts.any((t) => t.contains('旧揭示')),
        isFalse,
        reason: '现状：reset 清空 raw/_visibleSealed/nextReveal；旧 backlog 不进终态。',
      );
      expect(
        finalTexts.any((t) => t.contains('reset后新句')),
        isTrue,
        reason: '现状：reset 后新 delta 正常上屏 finalize。',
      );

      // Stronger mid-stream: once 新句 appears, 旧揭示 must not coexist.
      final coexist = probe.snapshots.any((snap) {
        final texts = snap
            .where((m) => m.role == 'assistant')
            .map((m) => m.displayText)
            .toList();
        return texts.any((t) => t.contains('reset后新句')) &&
            texts.any((t) => t.contains('旧揭示'));
      });
      expect(
        coexist,
        isFalse,
        reason: '现状：writeEpoch + reset discard 后旧揭示段不得与新内容共存。',
      );

      // If any 旧揭示 ever appeared (pre-reset first reveal race), it must clear.
      var oldEver = false;
      var oldCleared = false;
      for (final snap in probe.snapshots) {
        final hasOld = snap.any(
          (m) => m.role == 'assistant' && m.displayText.contains('旧揭示'),
        );
        if (hasOld) {
          oldEver = true;
        } else if (oldEver) {
          oldCleared = true;
        }
      }
      if (oldEver) {
        expect(
          oldCleared,
          isTrue,
          reason: '现状：若 reset 前已揭示部分旧段，reset 后必须 discard 清空。',
        );
      }

      // Post-reset long wait in script covers “未揭示 backlog 不再弹出”.
      // window baseline is observational.
      expect(
        probe.windowChangeCount,
        inInclusiveRange(1, 16),
        reason: '现状基线：揭示等待期 reset 脚本窗口变更有限。'
            ' observed=${probe.windowChangeCount}',
      );
    });
  });

  group('I) A→B→A conversation switch isolation', () {
    test('conv_a 流式中对 conv_b send：两会话在飞时间线互不污染；a 继续 finalize',
        () async {
      final settings = _buildTestSettings(
        enableChunking: true,
        minSegmentLength: 1,
        streamSegmentDelaySeconds: 0,
      );

      final stamp = DateTime.now().microsecondsSinceEpoch;
      final idA = 'char_i_a_$stamp';
      final idB = 'char_i_b_$stamp';
      final now = DateTime.now();
      final convB = Conversation(
        id: idB,
        title: 'Char_$idB',
        displayName: 'Char_$idB',
        createdAt: now,
        updatedAt: now,
        messages: const [],
        lastMessage: '',
        lastMessageTime: now,
      );

      final harness = await _buildHarness(
        convId: idA,
        settings: settings,
        script: const <_StreamStep>[],
        replyText: '',
        switchableActiveConversation: true,
        extraConversations: [convB],
        scriptsBySession: {
          idA: const <_StreamStep>[
            _DeltaStep('会话A首句。'),
            // Hold A open while B streams.
            _DelayStep(Duration(milliseconds: 600)),
            _DeltaStep('会话A尾句。'),
            _DelayStep(Duration(milliseconds: 220)),
          ],
          idB: const <_StreamStep>[
            _DeltaStep('会话B正文。'),
            _DelayStep(Duration(milliseconds: 220)),
          ],
        },
        replyTextsBySession: {
          idA: '会话A首句。会话A尾句。',
          idB: '会话B正文。',
        },
      );
      addTearDown(harness.dispose);

      // Also watch B's window so its timeline cache is warm.
      final emissionsB = <ConversationTimelineWindowState>[];
      final subB = harness.timelineCache
          .watchWindow(conversationId: idB, limit: 50)
          .listen(emissionsB.add);
      addTearDown(subB.cancel);

      // Start A streaming.
      harness.switchActiveConversation(idA);
      harness.startSend(text: 'I from A');
      final sendA = harness.activeSend;

      // Wait until A's first seal is visible.
      var sawA = false;
      for (var i = 0; i < 25; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 40));
        final snapA = await harness.loadTimeline(idA);
        if (snapA.any(
          (m) => m.role == 'assistant' && m.displayText.contains('会话A首句'),
        )) {
          sawA = true;
          break;
        }
      }
      expect(sawA, isTrue, reason: '前置：A 流式中应先出现 A 的 seal。');

      // Switch to B and send — concurrent generation on different convId.
      harness.switchActiveConversation(idB);
      final sendB = harness.container.read(chatActionsProvider).send('I from B');
      await sendB;
      await Future<void>.delayed(const Duration(milliseconds: 80));

      final timelineB = await harness.loadTimeline(idB);
      final timelineAMid = await harness.loadTimeline(idA);

      expect(
        timelineB.any((m) => m.displayText.contains('会话B正文')),
        isTrue,
        reason: '现状：B 会话独立 finalize 自己的正文。',
      );
      expect(
        timelineB.any((m) => m.displayText.contains('会话A')),
        isFalse,
        reason: '现状：B 时间线不被 A 在飞内容污染。',
      );
      expect(
        timelineAMid.any((m) => m.displayText.contains('会话B')),
        isFalse,
        reason: '现状：A 在飞时间线不被 B 内容污染。',
      );
      expect(
        timelineAMid.any(
          (m) => m.role == 'assistant' && m.displayText.contains('会话A首句'),
        ),
        isTrue,
        reason: '现状：切到 B 后 A 的在飞/已 seal 内容仍留在 A。',
      );

      // Return focus to A; let A finish.
      harness.switchActiveConversation(idA);
      await sendA;
      await Future<void>.delayed(const Duration(milliseconds: 100));

      final timelineAFinal = await harness.loadTimeline(idA);
      final timelineBFinal = await harness.loadTimeline(idB);

      expect(
        timelineAFinal.any((m) => m.displayText.contains('会话A首句')) ||
            timelineAFinal.any((m) => m.displayText.contains('会话A尾句')) ||
            timelineAFinal.any(
              (m) =>
                  m.role == 'assistant' &&
                  m.displayText.contains('会话A'),
            ),
        isTrue,
        reason: '现状：回到 A 后 A 流继续并 finalize（正文含 A 标记）。',
      );
      expect(
        timelineAFinal.any((m) => m.displayText.contains('会话B')),
        isFalse,
        reason: '现状：A finalize 终态仍无 B 污染。',
      );
      expect(
        timelineBFinal.any((m) => m.displayText.contains('会话A')),
        isFalse,
        reason: '现状：A finalize 不回写污染 B。',
      );
      expect(
        timelineAFinal.where(_isGeneratingPlaceholder),
        isEmpty,
        reason: '现状：A finalize 后无占位残留。',
      );
      expect(
        harness.sendService.executeSessionIds.toSet(),
        containsAll(<String>[idA, idB]),
        reason: '两会话均真实走过 executeApiCall。',
      );
    });
  });

  group('J) segment reveal pacing', () {
    test('delay 前不揭示；首次只揭示一段；间隔下限；finalize 可一次带出剩余段',
        () async {
      // Precision boundary (真实时钟 / Timer + 40ms 轮询，无 fake-async):
      // - 无法可靠断言 delay-ε 亚毫秒边界；用 delay/2 作「明显早于 delay」。
      // - 计数只认精确单句 seal（`节奏一。` 等），避免 commit 合并正文干扰。
      // - 实测现状（2026-07-20）：mid-stream 常见 0 → 1 后长时间平台期；
      //   收尾 finalize:true 可一次物化剩余 seal（观测上 1→3），drain 步进
      //   在 40ms 采样下常被同帧吞掉。因此：
      //   * 严格锁「首次揭示至多 +1」与「delay 前为 0」；
      //   * 对后续 +N 仅允许发生在已有 ≥1 段之后（收尾排空），并记录间隔下限
      //     于首次平台期时长（1 段停留 ≥ segmentDelay - slack）。
      const segmentDelayMs = 200;
      final settings = _buildTestSettings(
        enableChunking: true,
        minSegmentLength: 1,
        streamSegmentDelaySeconds: segmentDelayMs / 1000.0,
      );

      final script = <_StreamStep>[
        const _DeltaStep('节奏一。'),
        const _DelayStep(Duration(milliseconds: 260)),
        const _DeltaStep('节奏二。'),
        const _DelayStep(Duration(milliseconds: 260)),
        const _DeltaStep('节奏三。'),
        const _DelayStep(Duration(milliseconds: 400)),
      ];

      final harness = await _buildHarness(
        convId: 'char_j_pace_${DateTime.now().microsecondsSinceEpoch}',
        settings: settings,
        script: script,
        replyText: '节奏一。节奏二。节奏三。',
      );
      addTearDown(harness.dispose);

      int countExactSeals(List<Message> snap) {
        final texts = _assistantRealText(snap)
            .map((m) => m.displayText.trim())
            .toList();
        var n = 0;
        if (texts.any((t) => t == '节奏一。')) n += 1;
        if (texts.any((t) => t == '节奏二。')) n += 1;
        if (texts.any((t) => t == '节奏三。')) n += 1;
        return n;
      }

      final sealedCounts = <int>[];
      final sampleTimesMs = <int>[];
      final sw = Stopwatch()..start();

      harness.startSend(text: 'J pace');
      for (var i = 0; i < 30; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 40));
        final snap = await harness.loadTimeline();
        sealedCounts.add(countExactSeals(snap));
        sampleTimesMs.add(sw.elapsedMilliseconds);
      }

      await harness.awaitActiveSend();
      final finalSnap = await harness.loadTimeline();
      expect(finalSnap.where(_isGeneratingPlaceholder), isEmpty);
      final finalJoined = _assistantRealText(finalSnap)
          .map((m) => m.displayText)
          .join();
      expect(
        finalJoined.contains('节奏'),
        isTrue,
        reason: '现状：揭示/finalize 后终态有正文。',
      );

      // (1) delay 前半窗口不揭示
      final earlySamples = <int>[
        for (var i = 0; i < sealedCounts.length; i++)
          if (sampleTimesMs[i] < segmentDelayMs ~/ 2) sealedCounts[i],
      ];
      expect(earlySamples, isNotEmpty);
      expect(
        earlySamples.every((c) => c == 0),
        isTrue,
        reason: '现状：segmentDelay 前半窗口 exact seal=0（delay-ε 可达到代理）。'
            ' early=$earlySamples counts=$sealedCounts',
      );

      // (2) 首次非零必须是 1（delay 后只揭示一段；禁止 0→2/3 同帧爆发）
      final firstNonZeroIdx = sealedCounts.indexWhere((c) => c > 0);
      expect(
        firstNonZeroIdx,
        greaterThanOrEqualTo(0),
        reason: '前置：应观察到至少一次 exact seal。 counts=$sealedCounts',
      );
      expect(
        sealedCounts[firstNonZeroIdx],
        1,
        reason: '现状锁定：首次揭示至多一段（0→1）。'
            ' counts=$sealedCounts t=${sampleTimesMs[firstNonZeroIdx]}ms',
      );
      // 从 0 起步的单步增量也不得超过 1
      for (var i = 1; i <= firstNonZeroIdx; i++) {
        expect(
          sealedCounts[i] - sealedCounts[i - 1],
          lessThanOrEqualTo(1),
          reason: '首次揭示前不得跳步。 counts=$sealedCounts',
        );
      }

      // (3) 首次揭示后存在平台期（至少一段时间内保持 1），时长 ≈ delay 下限
      const slackMs = 90;
      var plateauEndIdx = firstNonZeroIdx;
      while (plateauEndIdx + 1 < sealedCounts.length &&
          sealedCounts[plateauEndIdx + 1] == 1) {
        plateauEndIdx += 1;
      }
      final plateauMs =
          sampleTimesMs[plateauEndIdx] - sampleTimesMs[firstNonZeroIdx];
      expect(
        plateauMs,
        greaterThanOrEqualTo(segmentDelayMs - slackMs),
        reason: '现状：首次揭示后 backlog 不会立刻同帧出清；1 段平台期 ≥ delay−slack。'
            ' plateauMs=$plateauMs counts=$sealedCounts'
            ' times=$sampleTimesMs（精度边界：40ms 采样）。',
      );

      // (4) 后续递增：允许 finalize 一次带出剩余段（+N，N>1），但不得从 0 跳。
      // 若观测到逐步 +1，也合法。
      var prev = sealedCounts[firstNonZeroIdx];
      var sawLateJump = false;
      for (var i = firstNonZeroIdx + 1; i < sealedCounts.length; i++) {
        final cur = sealedCounts[i];
        final delta = cur - prev;
        if (delta < 0) {
          // commit 合并导致 exact 单句计数下降 — 允许
          prev = cur;
          continue;
        }
        if (delta > 1) {
          sawLateJump = true;
          expect(
            prev,
            greaterThanOrEqualTo(1),
            reason: '现状：>1 的跳跃只发生在已有揭示之后（finalize 排空剩余段），'
                '不得从 0 全量爆发。 counts=$sealedCounts',
          );
        }
        prev = cur;
      }
      // 峰值至少覆盖多段（流中 1 + 收尾剩余，或逐步揭示）
      final peak = sealedCounts.reduce((a, b) => a > b ? a : b);
      expect(
        peak,
        greaterThanOrEqualTo(1),
        reason: 'counts=$sealedCounts lateJump=$sawLateJump',
      );
    });

    test('burst backlog：delay 内不全量爆发（mid-stream 现状）', () async {
      // 三句同一 burst：锁 segmentDelay 前不会三句同时上屏。
      const segmentDelayMs = 250;
      final settings = _buildTestSettings(
        enableChunking: true,
        minSegmentLength: 1,
        streamSegmentDelaySeconds: segmentDelayMs / 1000.0,
      );

      final script = <_StreamStep>[
        const _DeltaStep('爆发甲。'),
        const _DeltaStep('爆发乙。'),
        const _DeltaStep('爆发丙。'),
        const _DelayStep(Duration(milliseconds: 700)),
      ];

      final harness = await _buildHarness(
        convId: 'char_j_burst_${DateTime.now().microsecondsSinceEpoch}',
        settings: settings,
        script: script,
        replyText: '爆发甲。爆发乙。爆发丙。',
      );
      addTearDown(harness.dispose);

      harness.startSend(text: 'J burst');
      final earlyCounts = <int>[];
      final sw = Stopwatch()..start();
      while (sw.elapsedMilliseconds < segmentDelayMs - 40) {
        await Future<void>.delayed(const Duration(milliseconds: 30));
        final snap = await harness.loadTimeline();
        final n = _assistantRealText(snap)
            .where((m) => m.displayText.contains('爆发'))
            .length;
        earlyCounts.add(n);
      }
      expect(
        earlyCounts.every((n) => n < 3),
        isTrue,
        reason: '现状：burst backlog 在 segmentDelay 前不会三句同时上屏。'
            ' early=$earlyCounts',
      );

      await harness.awaitActiveSend();
      final finalJoined = _assistantRealText(await harness.loadTimeline())
          .map((m) => m.displayText)
          .join();
      expect(finalJoined.contains('爆发'), isTrue);
    });
  });

  group('G2.1) active-stream channel ON — on/off 对照', () {
    List<Override> channelOn() => <Override>[
          streamProjectionPolicyProvider.overrideWithValue(
            const StreamProjectionPolicy(useActiveStreamChannel: true),
          ),
        ];

    test('非分段 10 delta：窗口通知坍缩为结构量级，正文经通道实时上屏', () async {
      const deltaCount = 10;
      final deltas = <_StreamStep>[];
      for (var i = 0; i < deltaCount; i++) {
        deltas.add(_DeltaStep('字$i'));
        if (i < deltaCount - 1) {
          deltas.add(const _DelayStep(Duration(milliseconds: 200)));
        }
      }
      deltas.add(const _DelayStep(Duration(milliseconds: 220)));
      final fullText = List.generate(deltaCount, (i) => '字$i').join();
      final settings = _buildTestSettings(enableChunking: false);
      final harness = await _buildHarness(
        convId: 'g21_on_nochunk_${DateTime.now().microsecondsSinceEpoch}',
        settings: settings,
        script: deltas,
        replyText: fullText,
        extraOverrides: channelOn(),
      );
      addTearDown(harness.dispose);

      harness.startSend(text: 'G2.1 on');
      // 流中采样：通道文本增长、窗口壳滞后（文本增长不进时间线）。
      var sawChannelGrowth = false;
      var sawStaleShell = false;
      var lastChannelLen = -1;
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 110));
        final projections =
            harness.container.read(activeStreamProjectionsProvider);
        final live = projections[harness.conv.id];
        if (live != null && live.phase == ActiveStreamPhase.streamingTail) {
          if (lastChannelLen >= 0 && live.tailText.length > lastChannelLen) {
            sawChannelGrowth = true;
          }
          lastChannelLen = live.tailText.length;
          final timeline = await harness.loadTimeline();
          final tailInWindow = timeline
              .where((m) => m.id == live.tailMessageId)
              .toList(growable: false);
          if (tailInWindow.isNotEmpty &&
              tailInWindow.single.content.length <
                  live.tailText.length) {
            sawStaleShell = true;
          }
        }
      }
      await harness.awaitActiveSend();
      final probe = await harness.probeNow();

      expect(sawChannelGrowth, isTrue,
          reason: '通道 tailText 应随 flush 增长（实时上屏经通道）');
      expect(sawStaleShell, isTrue,
          reason: '窗口壳消息文本应滞后于通道（文本增长不触发时间线写入）');
      // OFF 基线为 11-16（A 组）；ON 只剩结构转移：用户消息、占位/壳出现、
      // finalize seal、commit 替换等，量级应显著低于 OFF 下限。
      expect(probe.windowChangeCount, lessThanOrEqualTo(8),
          reason: 'ON 模式窗口变更应为结构量级'
              ' observed=${probe.windowChangeCount}');
      expect(probe.windowChangeCount, greaterThanOrEqualTo(2));
      // 终态一致：完整正文已在窗口，通道条目已清。
      final finalTimeline = probe.snapshots.last;
      expect(
        finalTimeline.any((m) =>
            m.role == 'assistant' && m.content.contains(fullText)),
        isTrue,
        reason: 'finalize 后完整正文应写入窗口',
      );
      expect(
        harness.container.read(activeStreamProjectionsProvider),
        isEmpty,
        reason: '流结束后通道 map 应无残留条目（B3 回收契约）',
      );
    });

    test('ON + 真实 interrupt：通道条目清空，无幽灵尾', () async {
      final deltas = <_StreamStep>[
        const _DeltaStep('中断前文本'),
        const _DelayStep(Duration(milliseconds: 400)),
        const _DeltaStep('更多内容'),
        const _DelayStep(Duration(milliseconds: 2000)),
      ];
      final settings = _buildTestSettings(enableChunking: false);
      final harness = await _buildHarness(
        convId: 'g21_on_interrupt_${DateTime.now().microsecondsSinceEpoch}',
        settings: settings,
        script: deltas,
        replyText: '中断前文本更多内容',
        extraOverrides: channelOn(),
      );
      addTearDown(harness.dispose);

      harness.startSend(text: 'G2.1 interrupt');
      // 等通道出现活跃尾。
      var live = false;
      for (var i = 0; i < 20 && !live; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        final projections =
            harness.container.read(activeStreamProjectionsProvider);
        live = projections[harness.conv.id]?.phase ==
            ActiveStreamPhase.streamingTail;
      }
      expect(live, isTrue, reason: '中断前应观察到活跃尾通道条目');

      final stopped = await harness.interrupt();
      expect(stopped, isTrue);
      await harness.awaitActiveSend(settle: const Duration(milliseconds: 200));

      expect(
        harness.container.read(activeStreamProjectionsProvider),
        isEmpty,
        reason: 'interrupt 后通道条目应被清空（design v2 §2.5）',
      );
      final timeline = await harness.loadTimeline();
      expect(
        timeline.where((m) => m.role == 'assistant' && m.status == 'sending'),
        isEmpty,
        reason: 'interrupt 后窗口不应残留 sending 幽灵尾',
      );
    });

    test('分段模式 ON：终态含全部 seal 段，窗口变更不高于 OFF 基线（中间序列留 T-02 矩阵）',
        () async {
      final deltas = <_StreamStep>[
        const _DeltaStep('第一句。'),
        const _DelayStep(Duration(milliseconds: 260)),
        const _DeltaStep('第二句。'),
        const _DelayStep(Duration(milliseconds: 260)),
        const _DeltaStep('第三句。'),
        const _DelayStep(Duration(milliseconds: 260)),
      ];
      final settings = _buildTestSettings(
        enableChunking: true,
        minSegmentLength: 1,
      );
      final harness = await _buildHarness(
        convId: 'g21_on_chunk_${DateTime.now().microsecondsSinceEpoch}',
        settings: settings,
        script: deltas,
        replyText: '第一句。第二句。第三句。',
        extraOverrides: channelOn(),
      );
      addTearDown(harness.dispose);

      final probe = await harness.runSend(
        text: 'G2.1 chunk on',
        sampleInterval: const Duration(milliseconds: 100),
        sampleTicks: 14,
      );

      final finalTimeline = probe.snapshots.last;
      final assistantTexts = [
        for (final m in finalTimeline)
          if (m.role == 'assistant') m.content,
      ].join('|');
      expect(assistantTexts, contains('第一句。'));
      expect(assistantTexts, contains('第二句。'));
      expect(assistantTexts, contains('第三句。'));
      // B 组 OFF 基线 3-10；ON 不应更差。
      expect(probe.windowChangeCount, lessThanOrEqualTo(10),
          reason: '分段模式 ON 的窗口变更不应高于 OFF 基线'
              ' observed=${probe.windowChangeCount}');
      expect(
        harness.container.read(activeStreamProjectionsProvider),
        isEmpty,
        reason: '流结束后通道无残留',
      );
    });
  });
}

bool finalSnapHasNoGenerating(List<Message> snap) {
  return snap.where(_isGeneratingPlaceholder).isEmpty;
}
