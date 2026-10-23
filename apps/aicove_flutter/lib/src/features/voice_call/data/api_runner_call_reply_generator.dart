import 'dart:async';

import '../../../core/api/providers/provider_adapter_factory.dart';
import '../../../core/api/thinking/thinking_level_resolver.dart';
import '../../../core/services/system_reminder_service.dart';
import '../../chat/domain/conversation.dart';
import '../../chat/domain/conversation_context_window.dart';
import '../../chat/domain/message.dart';
import '../../chat/services/api_runner.dart';
import '../../chat/services/chat_send_service.dart';
import '../../observability/trace_models.dart';
import '../../observability/trace_store.dart';
import '../../settings/app_settings.dart';
import '../domain/voice_call_ports.dart';

/// 通话场景的输出约束（ADR0074 决定 2），每轮以系统提醒插在用户最新一句之前。
const String kVoiceCallInstruction =
    '''你们现在正在打语音电话，你说的每个字都会被直接念出来；在这之前的消息是你们的文字聊天。
- 像真人打电话一样说话：口语、短句，每次回复两到四句。
- 开口先用一两个字给出自然的即时反应（比如“诶？”“嗯……”“哈哈”），再展开。
- 不要使用 Markdown、列表、表情符号、圆括号里的动作描写或尖括号标签。
- 用户的话来自语音识别，可能有错字或断句不准，按最合理的意思理解。''';

/// 接通后还没人说话时追加：让角色先开口说一句简短的开场白。
const String kVoiceCallOpening =
    '- 电话刚接通，用户还没说话，由你先开口：一两句简单自然的开场白，像平时接通电话那样打个招呼，可以顺口提一句最近聊过的事，别长篇大论。';

/// 没有语气控制说明时补上的约束：方括号也会被原样念出来。
const String kVoiceCallNoSpeechTags = '- 不要使用方括号标签，写出来的字都会被原样念出来。';

/// 通话里只保留给模型补背景的插件；语音、绘图、表情包、触发器等输出标签与工具
/// 在电话里没有意义，念出来还会出错。
const Set<String> kVoiceCallContextPluginIds = {'memory', 'time_awareness'};

/// 角色已开启的插件里，通话可用的那部分；`null` 表示角色开启了全部插件。
List<String> voiceCallPluginIds(List<String>? enabled) => [
  for (final id in kVoiceCallContextPluginIds)
    if (enabled == null || enabled.contains(id)) id,
];

/// 通话轮次在快照里的占位。装配时它是历史的最后一条，预设的后置指令和助手预填
/// 会排在它后面；每轮把它换成本次通话的轮次。
///
/// 占位用助手角色：预设的 `{{lastusermessage}}` 和「附着到最后一条用户消息」
/// 仍指向真实的用户原文，不会把占位展开进别的指令。
const String kVoiceCallTurnsAnchor = '⟦AICOVE_VOICE_CALL_TURNS⟧';

/// 接通前摘要的占位，排在最近几条原文前面；摘要整理好之前先去掉。
const String kVoiceCallBriefAnchor = '⟦AICOVE_VOICE_CALL_BRIEF⟧';

/// 通话用的模型：与打字聊天的首选模型一致。
String voiceCallModelRef(AppSettings settings) =>
    settings.defaultChatModels.isNotEmpty
    ? settings.defaultChatModels.first
    : settings.defaultModelName;

/// 当前话题的全部原文（打字聊天的上下文窗口）。
Future<List<Message>> loadVoiceCallWindow(
  ChatSendService chat,
  Conversation conversation,
) async => sliceConversationContext(
  await chat.loadConversationMessagesFromStore(conv: conversation),
  conversation.contextStartMessageId,
);

/// 接通时按主聊天的唯一装配入口拿一份上下文快照：人设、预设、世界书、长期记忆、
/// 话题交接摘要都与打字聊天一致（ADR0074 决定 2）。文字聊天不整段带上，只带
/// [recent] 这几条原文；更早的部分由接通前摘要占位，见 [VoiceCallContextBrief]。
///
/// 通话中文字聊天不会变，快照只做一次，之后每轮只替换占位。插件提醒（时间感知）
/// 不留在快照里，每轮按发送时刻现算，见 [buildVoiceCallMessages]。
Future<ApiConfig> prepareVoiceCallBaseConfig(
  ChatSendService chat,
  Conversation conversation, {
  required AppSettings settings,
  required List<Message> recent,
  bool withBrief = false,
}) async {
  final callConversation = conversation.copyWith(
    enabledPlugins: voiceCallPluginIds(conversation.enabledPlugins),
  );
  Message anchor(String id, String content) => Message(
    id: id,
    role: 'assistant',
    content: content,
    createdAt: DateTime.now(),
  );
  final config = await chat.prepareApiConfig(
    conv: callConversation,
    history: [
      if (withBrief) anchor('voice_call_brief', kVoiceCallBriefAnchor),
      ...recent,
      anchor('voice_call_turns', kVoiceCallTurnsAnchor),
    ],
    userText: null,
    overrideModel: voiceCallModelRef(settings),
    // 历史里有占位，不能写回预设变量或自动摘要。
    persistSideEffects: false,
    deferReminders: true,
  );
  // 通话用「最低」档：能关就关，关不掉取最低档，缩短首字延迟。
  final providerType = ProviderAdapterFactory.resolveProvider(
    config.providerId,
    customConfig: config.customConfig,
    apiBaseUrl: config.providerApiBase,
  );
  final colon = config.modelFullId.indexOf(':');
  final thinking = resolveEffectiveThinkingLevel(
    providerType: providerType,
    modelId: colon < 0
        ? config.modelFullId
        : config.modelFullId.substring(colon + 1),
    sessionLevel: ThinkingLevel.lowest,
  );
  final options = config.providerRequestOptions;
  return config.copyWith(
    clearTools: true,
    // 通话必须边生成边合成，预设关掉流式也不跟随。
    presetStreamResponse: true,
    providerRequestOptions: thinking.applyTo(options),
  );
}

/// 用现有模型调用链路（[ApiRunner]）生成通话回复。通话轮次只拼进请求副本，
/// 不写回聊天记录。
class ApiRunnerCallReplyGenerator implements CallReplyGeneratorPort {
  ApiRunnerCallReplyGenerator({
    required this.runner,
    required this.base,
    required this.sessionId,
    this.traceStore,
    this.speechGuide,
    this.clock = DateTime.now,
  });

  final ApiRunner runner;

  /// 每轮通话在这里开一条对话轨迹，调试中心的对话日志才看得到；为空时不记。
  final TraceStore? traceStore;

  /// 接通时的上下文快照，见 [prepareVoiceCallBaseConfig]。
  final ApiConfig base;
  final String sessionId;

  /// 音色预设提示词包里的通话语气说明（ADR0092）；为空时禁止标签。
  final String? speechGuide;

  /// 每轮插件提醒（当前时间等）按它取时刻。
  final DateTime Function() clock;

  /// 接通前摘要；后台整理好后填入，从下一轮起生效。
  String? brief;

  @override
  Stream<String> streamReply(List<CallTurn> turns) {
    late final StreamController<String> controller;
    var cancelled = false;
    final emitted = StringBuffer();
    controller = StreamController<String>(
      onListen: () async {
        final turnId = 'call_turn_${DateTime.now().microsecondsSinceEpoch}';
        final trace = await _startTrace(turnId, turns.length);
        try {
          final result = await runner.executeApiCall(
            config: base.copyWith(
              messages: buildVoiceCallMessages(
                base.messages,
                turns,
                brief: brief,
                speechGuide: speechGuide,
                pluginReminder: base.reminders?.call(clock()),
              ),
            ),
            sessionId: sessionId,
            turnId: turnId,
            traceContext: trace,
            userText: null,
            responseProcessors: const [],
            availableTools: const [],
            enableStreaming: true,
            onStreamTextDelta: (delta) {
              emitted.write(delta);
              if (!cancelled && !controller.isClosed) controller.add(delta);
            },
          );
          // 流式失败回退成整段响应时没有增量：把还没转发的部分补上。
          final full = result.rawReplyText.trim().isNotEmpty
              ? result.rawReplyText
              : result.replyText;
          final sent = emitted.toString();
          final rest = sent.isEmpty
              ? full
              : full.startsWith(sent)
              ? full.substring(sent.length)
              : '';
          if (rest.trim().isNotEmpty && !cancelled && !controller.isClosed) {
            controller.add(rest);
          }
          _recordTrace(trace, TraceStage.turnCompleted);
        } catch (error, stack) {
          _recordTrace(
            trace,
            TraceStage.turnFailed,
            status: TraceEventStatus.failed,
          );
          if (!cancelled && !controller.isClosed) {
            controller.addError(error, stack);
          }
        } finally {
          if (!controller.isClosed) await controller.close();
        }
      },
      // 模型请求不支持中途取消，取消后只是不再转发后续文字。
      onCancel: () => cancelled = true,
    );
    return controller.stream;
  }

  Future<TraceContext?> _startTrace(String turnId, int turnCount) async {
    final store = traceStore;
    if (store == null) return null;
    try {
      return await store.startTurn(
        sessionId: sessionId,
        turnId: turnId,
        source: 'VoiceCall',
        meta: {'entry': 'voice_call', 'callTurns': turnCount},
      );
    } catch (_) {
      return null;
    }
  }

  void _recordTrace(
    TraceContext? trace,
    TraceStage stage, {
    TraceEventStatus status = TraceEventStatus.success,
  }) {
    final store = traceStore;
    if (store == null || trace == null) return;
    unawaited(() async {
      try {
        await store.record(
          traceId: trace.traceId,
          sessionId: trace.sessionId,
          turnId: trace.turnId,
          stage: stage,
          status: status,
          source: 'VoiceCall',
        );
      } catch (_) {
        // 轨迹只用于调试查看，写失败不影响通话。
      }
    }());
  }
}

/// 把快照里的占位换成接通前摘要和本次通话轮次，再插入通话约束提醒（单独导出
/// 便于测试）。通话轮次的占位被预设正则改写到找不到时，退回接在末尾。
///
/// [pluginReminder] 是本轮现算的插件提醒（当前时间等），和通话约束合成一条，
/// 紧贴用户最新一句。
List<Map<String, dynamic>> buildVoiceCallMessages(
  List<Map<String, dynamic>> baseMessages,
  List<CallTurn> turns, {
  String? brief,
  String? speechGuide,
  String? pluginReminder,
}) {
  const reminders = SystemReminderService();
  final briefMessage = brief == null || brief.trim().isEmpty
      ? null
      : reminders.buildReminderMessage(
          reminderContent: '接通电话前，你们更早的文字聊天摘要（仅供参考，不要复述）：\n${brief.trim()}',
        );
  // 有的上游只接受一问一答交替：连着的同一方（连发几句字、角色没出声就被
  // 打断）合成一条。
  final callMessages = <Map<String, dynamic>>[];
  for (final turn in turns) {
    final role = turn.isUser ? 'user' : 'assistant';
    final content = turn.interrupted ? '${turn.text}……（被用户打断）' : turn.text;
    if (callMessages.lastOrNull?['role'] == role) {
      callMessages.last['content'] =
          '${callMessages.last['content']}\n$content';
    } else {
      callMessages.add({'role': role, 'content': content});
    }
  }
  final lastUser = callMessages.lastIndexWhere((m) => m['role'] == 'user');
  final rules = [
    kVoiceCallInstruction,
    if (lastUser < 0) kVoiceCallOpening,
    if (speechGuide == null || speechGuide.trim().isEmpty)
      kVoiceCallNoSpeechTags,
  ].join('\n');
  callMessages.insert(
    lastUser < 0 ? 0 : lastUser,
    reminders.buildReminderMessage(
      reminderContent: reminders.mergeReminderContents([
        pluginReminder,
        rules,
        speechGuide,
      ]),
    )!,
  );
  var messages = baseMessages;
  final placed = _spliceAnchor(messages, kVoiceCallTurnsAnchor, callMessages);
  messages = placed ?? [...messages, ...callMessages];
  messages =
      _spliceAnchor(messages, kVoiceCallBriefAnchor, [?briefMessage]) ??
      messages;
  return reminders.ensureReminderSemanticsPrompt(messages: messages);
}

/// 用 [replacement] 替换占位所在的位置；占位所在消息的其余文字（例如被合并进来的
/// 上一条回复、预设的助手预填）按原先的前后位置保留。
///
/// 宏把占位展开进别的消息时，那些消息只去掉占位文字。找不到占位时返回 null。
List<Map<String, dynamic>>? _spliceAnchor(
  List<Map<String, dynamic>> messages,
  String anchor,
  List<Map<String, dynamic>> replacement,
) {
  bool holds(Map<String, dynamic> m) =>
      m['content'] is String && (m['content'] as String).contains(anchor);
  // 整条就是占位 > 以占位开头或结尾（被并进相邻回复或预填）> 仅包含（宏展开）。
  int find(bool Function(String text) match) => messages.lastIndexWhere(
    (m) =>
        m['role'] != 'system' &&
        holds(m) &&
        match((m['content'] as String).trim()),
  );
  var slot = find((t) => t == anchor);
  if (slot < 0) slot = find((t) => t.startsWith(anchor) || t.endsWith(anchor));
  if (slot < 0) slot = find((_) => true);
  if (slot < 0) return null;
  Map<String, dynamic>? part(Map<String, dynamic> m, String text) =>
      text.trim().isEmpty ? null : {...m, 'content': text.trim()};
  return [
    for (var i = 0; i < messages.length; i++)
      if (i == slot) ...[
        ?part(
          messages[i],
          (messages[i]['content'] as String).split(anchor).first,
        ),
        ...replacement,
        ?part(
          messages[i],
          (messages[i]['content'] as String).split(anchor).skip(1).join(),
        ),
      ] else if (holds(messages[i]))
        ?part(
          messages[i],
          (messages[i]['content'] as String).replaceAll(anchor, ''),
        )
      else
        messages[i],
  ];
}
