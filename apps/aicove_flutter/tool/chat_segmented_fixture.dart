/// 离线多气泡夹具：只替换模型输入，保留 ChatActions 的真实分段、
/// 占位符、时间线写入及收尾流程。数据库仅在内存，不读取用户配置。
library;

import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:aicove_flutter/src/core/app_logger.dart';
import 'package:aicove_flutter/src/core/database/database.dart' as db;
import 'package:aicove_flutter/src/core/database/database_provider.dart';
import 'package:aicove_flutter/src/core/utils/message_formatter.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/analyzer_scheduler.dart';
import 'package:aicove_flutter/src/features/chat/application/active_stream_projection.dart';
import 'package:aicove_flutter/src/features/chat/chat_actions.dart';
import 'package:aicove_flutter/src/features/chat/conversation_providers.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_send_service.dart';
import 'package:aicove_flutter/src/features/chat/services/conversation_short_window_store.dart';
import 'package:aicove_flutter/src/features/observability/trace_models.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';

const segmentedProbeSettings = AppSettings(
  ttsEnabled: false,
  defaultModelName: 'offline:probe',
  defaultPersonaPrompt: '',
  modelList: ['offline:probe'],
  allKnownModels: ['offline:probe'],
  modelDisplayNames: {},
  modelTypes: {},
  modelConfigs: {},
  apiKey: '',
  apiBaseUrl: '',
  imageGenerationEnabled: false,
  maxFileUploadMB: 10,
  contextWindowTokens: 272000,
  customModels: [],
  providers: [],
  modelProviderMap: {},
  backendApiKey: '',
  messageChunkingEnabled: true,
  messageFormatConfig: MessageFormatConfig(enableChunking: true),
  textScaleFactor: 1,
  uiScaleFactor: 1,
  imagePreviewScale: 1,
  autoReplySettings: AutoReplySettings(),
  globalBackgroundColor: GlobalBackgroundColor.white,
  chatBackgroundColor: ChatBackgroundColor.defaultColor,
  isDarkMode: false,
  useSystemTheme: false,
  accentColor: 'FC96AA',
  hideUserAvatar: false,
);

class _Settings extends AppSettingsNotifier {
  _Settings(this.settings);
  final AppSettings settings;
  @override
  Future<AppSettings> build() async => settings;
}

class _Conversations extends ConversationsNotifier {
  _Conversations(this.conversation);
  final Conversation conversation;
  @override
  Future<List<Conversation>> build() async => [conversation];
  @override
  Future<void> setAll(List<Conversation> list, {bool persist = true}) async {
    // 禁止触碰用户会话索引；消息仍由真实 ChatActions 写入内存 DB。
    state = AsyncData(list);
  }
}

// 自动关怀与本次滚动无关；禁用它的真实偏好存储和后台任务。
class _NoAutoReply extends AnalyzerScheduler {
  _NoAutoReply(super.ref);
  @override
  Future<void> refreshFromStorage() async {}
  @override
  Future<void> handleUserMessageActivity({
    required String conversationId,
    required String? messageId,
    required DateTime occurredAt,
  }) async {}
}

class SegmentedChatFixture {
  SegmentedChatFixture._(this.database, this.container, this.conversation,
      this._input, this._ready);

  final db.AppDatabase database;
  final ProviderContainer container;
  final Conversation conversation;
  final StreamController<String> _input;
  final Completer<void> _ready;
  final timeline = ValueNotifier<List<Message>>([]);
  StreamSubscription<ConversationTimelineWindowState>? _subscription;
  Future<void>? _send;
  int timelineEmissions = 0;
  int deltaCount = 0;
  int characters = 0;
  bool _finished = false;

  List<Message> get bubbles => timeline.value
      .where((m) =>
          m.role == 'assistant' &&
          m.sourceMessageId != null &&
          m.displayText != '生成中...')
      .toList(growable: false);

  static Future<SegmentedChatFixture> create({
    AppSettings settings = segmentedProbeSettings,
    int historyCount = 80,
    String personaPrompt = '',
    List<String>? enabledPlugins,
    List<Override> extraOverrides = const [],
  }) async {
    // 整个探针是独立入口；连插件/主动回复的旁路偏好也只用内存替身。
    // ignore: invalid_use_of_visible_for_testing_member
    SharedPreferences.setMockInitialValues({});
    final now = DateTime.now();
    final history = List.generate(
        historyCount,
        (index) => Message.text(
              id: 'probe_history_$index',
              role: index.isEven ? 'assistant' : 'user',
              content: '第 $index 条历史消息：用于验证一次生成不断分成多个气泡时是否跟手。',
              createdAt: now.subtract(Duration(minutes: historyCount - index)),
            ));
    final conversation = Conversation(
      id: 'offline_segmented_probe',
      title: '离线多气泡测试',
      displayName: '离线多气泡测试',
      createdAt: now,
      updatedAt: now,
      messages: history,
      lastMessage: '',
      lastMessageTime: now,
      personaPrompt: personaPrompt,
      enabledPlugins: enabledPlugins,
    );
    final database = db.AppDatabase.forTesting(NativeDatabase.memory());
    await database.customStatement('PRAGMA foreign_keys = ON');
    await database.into(database.conversations).insert(
          db.ConversationsCompanion.insert(
            id: conversation.id,
            title: conversation.title,
            displayName: conversation.displayName,
            createdAt: now.millisecondsSinceEpoch,
            updatedAt: now.millisecondsSinceEpoch,
          ),
        );
    final input = StreamController<String>();
    final ready = Completer<void>();
    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(database),
      analyzerSchedulerProvider.overrideWith((ref) {
        final scheduler = _NoAutoReply(ref);
        ref.onDispose(scheduler.cancel);
        return scheduler;
      }),
      appSettingsProvider.overrideWith(() => _Settings(settings)),
      conversationsProvider.overrideWith(() => _Conversations(conversation)),
      activeConversationProvider.overrideWith((ref) => conversation),
      streamProjectionPolicyProvider.overrideWithValue(
          const StreamProjectionPolicy(useActiveStreamChannel: true)),
      chatSendServiceProvider.overrideWith(
          (ref) => _OfflineSendService(ref, settings, input.stream, ready)),
      ...extraOverrides,
    ]);
    container.read(activeConversationIdProvider.notifier).state =
        conversation.id;
    await container.read(appSettingsProvider.future);
    await container.read(conversationsProvider.future);
    final cache = container.read(conversationTimelineCacheProvider);
    await cache.upsertMessages(
        conversationId: conversation.id, messages: history);
    final fixture =
        SegmentedChatFixture._(database, container, conversation, input, ready);
    fixture._subscription = cache
        .watchWindow(
      conversationId: conversation.id,
      limit: 250,
    )
        .listen((window) {
      fixture.timelineEmissions++;
      fixture.timeline.value = window.messages;
    });
    await fixture
        .waitUntil(() => fixture.timeline.value.length == historyCount);
    return fixture;
  }

  Future<void> start() async {
    _send = container.read(chatActionsProvider).send('离线测试：一次回复连续分段');
    await Future.any([
      _ready.future,
      _send!.then((_) {
        if (!_ready.isCompleted) throw StateError('发送未进入离线模型输入');
      }),
    ]).timeout(const Duration(seconds: 10));
  }

  void add(String text) {
    deltaCount++;
    characters += text.length;
    _input.add(text);
  }

  Future<void> finish() async {
    if (_finished) return;
    _finished = true;
    if (!_ready.isCompleted) unawaited(_input.stream.drain<void>());
    await _input.close();
    await _send;
  }

  Future<void> waitUntil(bool Function() condition) async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException('离线分段夹具没有产生预期状态');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  Future<void> dispose() async {
    await finish();
    await _subscription?.cancel();
    container.dispose();
    timeline.dispose();
    await database.close();
  }
}

class _OfflineSendService extends ChatSendService {
  _OfflineSendService(super.ref, this.settings, this.input, this.ready);
  final AppSettings settings;
  final Stream<String> input;
  final Completer<void> ready;

  @override
  Future<ApiConfig> prepareApiConfig({
    required Conversation conv,
    required List<Message> history,
    required String? userText,
    TraceLogger? trace,
    String? overrideModel,
    String? conversationId,
    TraceContext? traceContext,
  }) async =>
      ApiConfig(
        settings: settings,
        modelFullId: settings.defaultModelName,
        providerApiBase: '',
        providerApiKey: null,
        customConfig: const {},
        toolPrefs: const {},
        messages: const [],
        tools: null,
        enabledPluginIds: null,
        modelTemperature: null,
        modelTopP: null,
        modelContextMessageLimit: null,
      );

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
    if (!enableStreaming || onStreamTextDelta == null) {
      throw StateError('多气泡探针必须实际启用流式生成');
    }
    final text = StringBuffer();
    ready.complete();
    await for (final delta in input) {
      text.write(delta);
      onStreamTextDelta(delta);
    }
    return ApiCallResult(
        replyText: text.toString(),
        processedText: text.toString(),
        pluginEvents: const [],
        toolResults: const []);
  }
}
