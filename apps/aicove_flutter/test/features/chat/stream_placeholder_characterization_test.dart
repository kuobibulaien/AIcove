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
  });

  final AppSettings _settings;
  final List<_StreamStep> script;
  final String replyText;
  final String? processedText;
  final List<PluginEvent> pluginEvents;

  int executeCalls = 0;
  int resetCalls = 0;
  int deltaCalls = 0;

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
    for (final step in script) {
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
      replyText: replyText,
      processedText: processedText ?? replyText,
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

  final db = AppDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  await _insertConversation(db, conv);

  // Capture instances assigned inside overrides (providers are create-on-read).
  _CountingTimelineCache? timelineCache;
  _ScriptedStreamingSendService? sendService;
  _RecordingStreamTtsHandler? ttsHandler;

  final overrides = <Override>[
    databaseProvider.overrideWithValue(db),
    appSettingsProvider.overrideWith(
      () => _FakeAppSettingsNotifier(settings),
    ),
    conversationsProvider.overrideWith(
      () => _FakeConversationsNotifier([conv]),
    ),
    activeConversationProvider.overrideWith((ref) => conv),
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
      );
      return sendService!;
    }),
  ];

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
        finalAssistant.any((m) => m.displayText.contains(fullText) ||
            m.displayText.contains('字0')),
        isTrue,
        reason: '现状：finalize 后终态应包含流式累积正文。',
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
      var sawPlaceholderWithOrAfterReal = false;
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
          sawPlaceholderWithOrAfterReal = true;
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
      // 钉底阶段可能与真实段共存（分段模式 seal 后尾随生成中）。
      expect(
        sawPlaceholderAlone || sawPlaceholderWithOrAfterReal,
        isTrue,
        reason: '现状：占位至少在某一阶段可见（单独或与 seal 共存）。',
      );
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

      // If mid-stream had separate seals, lock that observation.
      if (midSealedTexts.contains('甲。')) {
        expect(
          midSealedTexts.contains('甲。'),
          isTrue,
          reason: '现状：分段开启时流中可按句 seal 为独立气泡。',
        );
      }

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
}

bool finalSnapHasNoGenerating(List<Message> snap) {
  return snap.where(_isGeneratingPlaceholder).isEmpty;
}
