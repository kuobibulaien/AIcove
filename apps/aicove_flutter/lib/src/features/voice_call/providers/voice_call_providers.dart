import 'dart:async';

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/app_logger.dart';
import '../../../core/database/database_provider.dart';
import '../../background_agent/background_agent_service.dart';
import '../../chat/domain/conversation.dart';
import '../../chat/id_gen.dart';
import '../../chat/services/api_runner.dart';
import '../../chat/services/chat_history_store.dart';
import '../../chat/services/chat_send_service.dart';
import '../../context/providers/context_providers.dart';
import '../../observability/trace_store.dart';
import '../../plugins/tts/voice_preset_application.dart';
import '../../settings/app_settings.dart';
import '../application/active_voice_call.dart';
import '../application/voice_call_archiver.dart';
import '../application/scripted_opening_reply_generator.dart';
import '../application/voice_call_session.dart';
import '../data/cloud_asr/cloud_speech_recognizer_factory.dart';
import '../data/api_runner_call_reply_generator.dart';
import '../data/device_call_audio.dart';
import '../data/fish_audio_streaming_tts.dart';
import '../data/sherpa_local_speech_recognizer.dart';
import '../data/sqlite_call_record_store.dart';
import '../data/voice_call_context_brief.dart';
import '../data/voice_call_summarizer.dart';
import '../domain/call_record_port.dart';
import '../domain/speech_recognizer_port.dart';
import '../domain/voice_call_ports.dart';
import 'voice_call_settings.dart';

export 'voice_call_settings.dart';

/// 通话无法接通的原因，直接展示给用户。
class VoiceCallUnavailable implements Exception {
  const VoiceCallUnavailable(this.message);
  final String message;
  @override
  String toString() => message;
}

final callRecordStoreProvider = Provider<CallRecordStorePort>(
  (ref) => SqliteCallRecordStore(ref.watch(databaseProvider)),
);

final voiceCallArchiverProvider = Provider<VoiceCallArchiver>(
  (ref) => VoiceCallArchiver(
    newId: genId,
    appendBubble: (conversationId, bubble) => ref
        .read(chatHistoryStoreProvider)
        .appendUserMessage(
          conversationId: conversationId,
          message: bubble,
          displayText: bubble.displayText,
        ),
    summarize: (conversationId, turns) async {
      final settings = await ref.read(appSettingsProvider.future);
      return VoiceCallSummarizer(
        ref.read(backgroundAgentServiceProvider),
        modelRef: await resolveCompactionModel(settings),
      ).summarize(conversationId, turns);
    },
    attachSummary: ref.read(chatHistoryStoreProvider).attachCallSummary,
    appendAssistantBubble: (conversationId, bubble) => ref
        .read(chatHistoryStoreProvider)
        .appendAssistantMessages(
          conversationId: conversationId,
          userMessageId: '',
          messages: [bubble],
          lastMessagePreview: '[未接来电]',
        ),
    log: (message) => AppLogger.info('VoiceCall', message),
  ),
);

/// 接通前摘要只缓存在内存里，同一段原文再打电话直接复用。
final voiceCallContextBriefProvider = Provider<VoiceCallContextBrief>(
  (ref) => VoiceCallContextBrief(
    store: ref.read(contextSummaryStoreProvider),
    summarizer: () => ref.read(contextSummarizerProvider.future),
  ),
);

/// 当前这通电话；同一时间只有一通。通话页和聊天页悬浮窗共用它。
final activeVoiceCallProvider =
    NotifierProvider<ActiveVoiceCallNotifier, ActiveVoiceCall?>(
      ActiveVoiceCallNotifier.new,
    );

class ActiveVoiceCallNotifier extends Notifier<ActiveVoiceCall?> {
  @override
  ActiveVoiceCall? build() => null;

  /// 打给这个角色；已有通话时返回那一通，不另开。
  /// [openingLine] 是角色主动来电时预先写好的第一句，接通后直接说出来。
  ActiveVoiceCall start(Conversation conversation, {String? openingLine}) {
    final current = state;
    if (current != null) return current;
    late final ActiveVoiceCall call;
    call = ActiveVoiceCall(
      conversationId: conversation.id,
      createSession: () => ref
          .read(voiceCallFactoryProvider)
          .create(conversation, openingLine: openingLine),
      archiver: ref.read(voiceCallArchiverProvider),
      describeError: (e) => e is VoiceCallUnavailable ? e.message : '通话接通失败：$e',
      log: (message) => AppLogger.info('VoiceCall', message),
      onFinished: () {
        if (identical(state, call)) state = null;
      },
    );
    state = call;
    unawaited(call.connect());
    return call;
  }

  /// 收成悬浮窗的通话离开了它的聊天（换角色或关掉聊天页）就挂断，
  /// 不留一通看不见的电话。
  void hangUpIfMinimizedAwayFrom(String? conversationId) {
    final call = state;
    if (call == null || !call.minimized) return;
    if (call.conversationId == conversationId) return;
    unawaited(call.hangUp());
  }
}

final voiceCallFactoryProvider = Provider<VoiceCallFactory>(
  VoiceCallFactory.new,
);

/// 按角色装配一通电话：音色预设 → 流式合成，识别来源 → 识别器，角色模型 → 回复生成。
class VoiceCallFactory {
  VoiceCallFactory(this._ref);

  final Ref _ref;

  /// 这个角色现在打不了电话的原因；能打时为 null。只检查配置，不建立连接。
  Future<String?> unavailableReason(Conversation conversation) async {
    try {
      final settings = await _ref.read(appSettingsProvider.future);
      await _resolveTts(conversation);
      await _resolveRecognizer(settings);
      return null;
    } on VoiceCallUnavailable catch (e) {
      return e.message;
    }
  }

  Future<VoiceCallSession> create(
    Conversation conversation, {
    String? openingLine,
  }) async {
    final settings = await _ref.read(appSettingsProvider.future);
    final tts = await _resolveTts(conversation);
    final recognizer = await _resolveRecognizer(settings);
    final watch = Stopwatch()..start();
    final chat = _ref.read(chatSendServiceProvider);
    final window = await loadVoiceCallWindow(chat, conversation);
    final split = splitVoiceCallWindow(window);
    final base = await prepareVoiceCallBaseConfig(
      chat,
      conversation,
      settings: settings,
      recent: split.recent,
      withBrief: split.earlier.isNotEmpty,
    );
    AppLogger.info(
      'VoiceCall',
      '通话上下文已就绪：最近 ${split.recent.length} 条原文，较早 ${split.earlier.length} 条待压缩，'
          '${watch.elapsedMilliseconds} ms',
    );
    final generator = ApiRunnerCallReplyGenerator(
      runner: createApiRunner(useKernel: kAgentKernelChat),
      base: base,
      sessionId: 'voice_call_${conversation.id}',
      traceStore: TraceStore.instance,
      speechGuide: tts is FishAudioStreamingTts
          ? kFishAudioCallSpeechGuide
          : null,
    );
    if (split.earlier.isNotEmpty) {
      // 接通不等摘要；整理好之后从下一轮起带上。
      final briefWatch = Stopwatch()..start();
      unawaited(
        _ref
            .read(voiceCallContextBriefProvider)
            .build(conversation, window, split.earlier)
            .then((brief) {
              generator.brief = brief;
              AppLogger.info(
                'VoiceCall',
                '接通前摘要已就绪：${brief?.length ?? 0} 字，${briefWatch.elapsedMilliseconds} ms',
              );
            })
            .catchError((Object e) {
              AppLogger.warning('VoiceCall', '接通前摘要整理失败：${e.runtimeType}');
            }),
      );
    }
    final voiceProcessing =
        callVoiceProcessingSupported(defaultTargetPlatform) &&
        !const bool.fromEnvironment('AICOVE_CALL_NO_VOICE_PROCESSING');
    AppLogger.info('VoiceCall', '系统语音处理：${voiceProcessing ? '开' : '关'}');
    return VoiceCallSession(
      recognizer: recognizer,
      tts: tts,
      input: RecordCallAudioInput(voiceProcessing: voiceProcessing),
      output: StreamCallAudioOutput(),
      generator: openingLine == null
          ? generator
          : ScriptedOpeningReplyGenerator(generator, openingLine),
      log: (message) => AppLogger.info('VoiceCall', message),
    );
  }

  /// 复用角色的音色预设，保证通话和语音条是同一个声音（ADR0074 决定 1）。
  Future<StreamingTtsPort> _resolveTts(Conversation conversation) async {
    final request = await _ref
        .read(voicePresetApplicationProvider)
        .forRole(conversation);
    final service = request.service;
    if (service == null) {
      throw VoiceCallUnavailable(request.error ?? '此角色没有可用的音色');
    }
    final format = service.requestFormat.toLowerCase();
    if (format != 'fish_audio' && format != 'fishaudio') {
      throw const VoiceCallUnavailable('通话目前只支持 Fish Audio 音色，其它供应商的流式合成还没接入');
    }
    final voiceId =
        service.config.selectedVoicePreset?.synthesis?.voiceId?.trim() ?? '';
    final apiKey = service.apiKey?.trim() ?? '';
    if (voiceId.isEmpty) {
      throw const VoiceCallUnavailable('音色预设还没有填写 Fish Audio 音色 ID');
    }
    if (apiKey.isEmpty) {
      throw const VoiceCallUnavailable(
        'Fish Audio 渠道还没有填写 API Key，请先在「设置 · 模型」里填写',
      );
    }
    return FishAudioStreamingTts(
      apiKey: apiKey,
      referenceId: voiceId,
      model: service.model?.trim().isNotEmpty == true
          ? service.model!.trim()
          : 's2.1-pro-free',
    );
  }

  /// 按设置里的识别来源选识别器；「自动」时装了本地模型就用本地，否则用渠道商里第一个能用的识别模型。
  Future<SpeechRecognizerPort> _resolveRecognizer(AppSettings settings) async {
    final source = await _ref.read(callRecognizerSourceProvider.future);
    if (source.kind != CallRecognizerKind.cloud) {
      final local = await installedLocalCallModel();
      if (local != null) {
        AppLogger.info('VoiceCall', '识别来源：本地模型');
        return SherpaLocalSpeechRecognizer(models: local);
      }
      if (source == CallRecognizerSource.local) {
        throw const VoiceCallUnavailable(
          '本机还没有安装本地识别模型，请在「语音 · 语音通话」里下载，或换一个识别来源',
        );
      }
    }
    final options = cloudRecognizerOptions(settings);
    final CloudRecognizerOption? option;
    if (source.kind == CallRecognizerKind.cloud) {
      option = options
          .where(
            (o) =>
                o.provider.id == source.providerId && o.model == source.model,
          )
          .firstOrNull;
      if (option == null) {
        throw VoiceCallUnavailable(
          '选中的识别模型 ${source.model} 已不在渠道商里，请在「语音 · 语音通话」里重新选择',
        );
      }
      if (!option.ready) {
        throw VoiceCallUnavailable(
          '「${option.label}」缺少 ${option.missing}，请先在渠道商里填写',
        );
      }
    } else {
      option = options.where((o) => o.ready).firstOrNull;
      if (option == null) {
        throw const VoiceCallUnavailable(
          '还没有可用的语音识别：请在「语音 · 语音通话」里下载本地识别模型，或在渠道商里添加语音识别模型',
        );
      }
    }
    try {
      final recognizer = createCloudSpeechRecognizer(
        option.provider,
        option.model,
      );
      AppLogger.info(
        'VoiceCall',
        '识别来源：${option.format.label} ${option.model}',
      );
      return recognizer;
    } on CloudRecognizerConfigError catch (e) {
      throw VoiceCallUnavailable(e.message);
    }
  }
}
