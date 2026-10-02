/// 低频前端诊断契约。不得传聊天正文、URL、凭据或逐帧数据。
library;

enum FrontendStage {
  runtimeStarted('诊断运行开始'),
  viewportAttached('视口实例开始'),
  segmentCreated('生成分段气泡'),
  projectionApplied('分段投影已提交'),
  projectionCommitted('分段最终映射已提交'),
  projectionSkipped('分段投影未提交'),
  routePopInterrupted('中断入场并返回'),
  animationDecision('气泡入场动画裁决'),
  ttsRequested('语音合成请求'),
  ttsSynthesisStarted('语音合成开始'),
  ttsSynthesisResult('语音合成返回'),
  ttsApplyDecision('语音结果应用裁决'),
  ttsPersisted('语音结果写回'),
  ttsFailed('语音链路失败'),
  pageOpened('打开聊天'),
  historyReady('历史数据到达页面'),
  historyColdLoad('历史窗口冷加载'),
  pageLayoutReady('聊天列表完成布局'),
  pageLeft('离开聊天'),
  pageLeftBeforeLayout('离开聊天，布局尚未确认'),
  sendRequested('提交发送'),
  turnLinked('已关联本轮对话'),
  firstTextLayout('首段回复完成布局（视口内）'),
  messageDelivered('消息处理与投递完成'),
  turnCompleted('本轮生成结束'),
  turnFailed('本轮生成失败'),
  turnCancelled('已停止生成'),
  scrollDetached('手动浏览，暂停跟随'),
  scrollFollowRequested('请求回到最新消息'),
  audioAvailable('语音资源已就绪'),
  audioReady('播放器已加载语音'),
  audioPlayRequested('点击播放或暂停'),
  audioPlaying('播放器开始播放'),
  audioFailed('语音播放异常'),
  historyFailed('历史消息加载失败'),
  frameworkError('界面框架异常'),
  unhandledError('未处理的异步异常');

  const FrontendStage(this.label);
  final String label;

  bool get isError => switch (this) {
        ttsFailed ||
        turnFailed ||
        audioFailed ||
        historyFailed ||
        frameworkError ||
        unhandledError =>
          true,
        _ => false,
      };
}

enum DiagnosticPhase { start, end, decision, skip, error }

enum DiagnosticReason {
  pendingAnimationId,
  notPending,
  pinnedLatestTail,
  userGesture,
  structuralChange,
  staleWriteEpoch,
  disposed,
  noManager,
  emptyText,
  joinedExisting,
  providerCompleted,
  providerReturnedEmpty,
  invalidFormat,
  timeout,
  ownerRejected,
  callbackOnly,
  persisted,
  persistenceFailed,
  operationFailed,
  fallbackText,
  streaming,
  committing,
  committed,
  discarded,
  unknownMessage,
  rawInactive,
}

/// 仅接收数值/布尔状态。正文、URL、动态错误消息没有可写入口。
class DiagnosticFacts {
  const DiagnosticFacts(
      {this.phase = DiagnosticPhase.decision,
      this.reason,
      this.sourceMessageId,
      this.pageInstanceId,
      this.state = const {}});
  final DiagnosticPhase phase;
  final DiagnosticReason? reason;
  final String? sourceMessageId;
  final String? pageInstanceId;
  final Map<String, Object?> state;
}

/// 同一操作共享单调时钟；追加关联信息不重置耗时。
class FrontendDiagnosticContext {
  FrontendDiagnosticContext({
    required this.operationId,
    this.conversationId,
    this.turnId,
    this.traceId,
    this.parentOperationId,
    Stopwatch? clock,
  }) : _clock = clock ?? (Stopwatch()..start());

  final String operationId;
  final String? conversationId;
  final String? turnId;
  final String? traceId;
  final String? parentOperationId;
  final Stopwatch _clock;
  int get elapsedMs => _clock.elapsedMilliseconds;

  /// Associate an earlier message operation without inheriting its clock.
  FrontendDiagnosticContext withParent(FrontendDiagnosticContext? parent) =>
      FrontendDiagnosticContext(
        operationId: operationId,
        parentOperationId: parent?.operationId ?? parentOperationId,
        conversationId: conversationId ?? parent?.conversationId,
        turnId: parent?.turnId ?? turnId,
        traceId: parent?.traceId ?? traceId,
        clock: _clock,
      );

  FrontendDiagnosticContext linked(String turnId, String traceId) =>
      FrontendDiagnosticContext(
        operationId: operationId,
        conversationId: conversationId,
        turnId: turnId,
        traceId: traceId,
        parentOperationId: parentOperationId,
        clock: _clock,
      );
}

abstract interface class TraceExportPort {
  /// 完整单轮诊断文本，包含模型链路和关联应用/前端记录。
  Future<String?> exportTurn(String traceId);
}

abstract interface class FrontendDiagnosticsPort {
  bool get enabled;
  set enabled(bool value);

  FrontendDiagnosticContext begin(FrontendStage stage,
      {String? conversationId});
  FrontendDiagnosticContext child(
      FrontendDiagnosticContext? parent, FrontendStage stage,
      {String? conversationId, String? messageId});
  FrontendDiagnosticContext linkTurn({
    required String conversationId,
    required String turnId,
    required String traceId,
  });
  FrontendDiagnosticContext? forTurn(String? turnId);
  void bindMessage(String messageId, FrontendDiagnosticContext? context);
  FrontendDiagnosticContext? forMessage(String messageId);
  void record(
    FrontendDiagnosticContext? context,
    FrontendStage stage, {
    String? messageId,
    int? itemCount,
    bool once = false,
    Object? error,
    StackTrace? stackTrace,
    DiagnosticFacts? facts,
  });
}
