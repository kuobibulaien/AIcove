part of 'chat_actions.dart';

extension ChatActionsFailover on ChatActions {
  Future<ModelFailoverDecision> _requestModelFailoverDecision({
    required String convId,
    required String failedModel,
    required String nextModel,
    required AppSettings settings,
    required Object error,
    DateTime? roundStartedAt,
    KernelCancellation? cancellation,
  }) async {
    var detail = error.toString();
    try {
      final runs = await ModelRequestLedger.instance.forConversation(convId);
      if (runs.isNotEmpty) detail += '\n\n${ModelRequestErrorReport.formatModelRuns(runs)}';
    } catch (ledgerError) {
      AppLogger.warning('ModelRequestLedger', '读取模型请求记录失败', metadata: {'error': '$ledgerError'});
    }
    return _ref.read(modelFailoverPromptProvider.notifier).request(
          conversationId: convId,
          failedModelName: settings.getModelDisplayName(failedModel),
          nextModelName: settings.getModelDisplayName(nextModel),
          errorMessage: error.toString(),
          errorDetail: detail,
          roundStartedAt: roundStartedAt,
          cancellation: cancellation,
        );
  }

  // ===== 内部：模型轮询 =====

  /// 按模型列表顺序尝试发送，失败后自动切换下一个模型
  /// 返回 (API调用结果, 使用的设置)
  Future<(ApiCallResult, AppSettings)> _executeWithFailover({
    required String convId,
    required List<String> modelsToTry,
    required Future<ApiConfig> Function(String model) buildConfig,
    required Future<ApiCallResult> Function(ApiConfig config) execute,
    required AppSettings settings,
  }) async {
    final generation = _activeGenerations[convId];
    final cancellation = generation?.cancellation;
    final progress = generation?.toolProgress;
    var modelAttempt = 0;
    Future<ApiCallResult> executeControlled(ApiConfig config) async {
      modelAttempt++;
      cancellation?.throwIfCancelled();
      final calls = <int, String>{};
      // 无前台 generation 的即时主动回复也有独立的执行作用域。
      if (generation == null || _isGenerationCurrent(convId, generation.id)) {
        _clearToolActivity(convId);
        _runningTools[convId] = calls;
      }
      final attempt = progress?.beginAttempt();
      try {
        final result = await ModelRunScope(purpose: ModelRunScope.current?.purpose ?? (generation == null ? 'proactive_reply' : 'chat'), conversationId: convId, turnId: generation?.userMsgId, attempt: modelAttempt).run(() => execute(config.copyWith(
          cancellation: cancellation,
          onModelRetry: (attempt, maxRetries, delay) {
            if (generation != null && _isGenerationCurrent(convId, generation.id)) {
              _setConversationRetryStatus(convId, ModelRetryStatus(attempt: attempt, maxAttempts: maxRetries));
            }
          },
          onYieldReady: generation?.bindYield,
          onToolActivity: (call) =>
              _startToolActivity(convId, generation?.id, calls, call),
          onToolRounds: progress == null || config.toolPolicy == null
              ? null
              : (rounds, roundCalls) async {
                  if (!_isGenerationCurrent(convId, generation!.id)) return;
                  await progress.recordRounds(
                    rounds,
                    roundCalls,
                    attempt!,
                    () => _isGenerationCurrent(convId, generation.id)
                        ? _writeToolProgress(convId, progress)
                        : Future<void>.value(),
                  );
                },
          onToolCompleted: progress == null
              ? null
              : (call, result) async {
                  if (!_isGenerationCurrent(convId, generation!.id)) return;
                  progress.record(
                    call,
                    result,
                    attempt!,
                    () => _isGenerationCurrent(convId, generation.id)
                        ? _writeToolProgress(convId, progress)
                        : Future<void>.value(),
                  );
                },
        )));
        return result;
      } finally {
        // 超时、异常、模型切换也不等待工具迟到的 finally。
        _clearToolActivity(convId, expected: calls);
        if (generation != null && _isGenerationCurrent(convId, generation.id)) {
          _setConversationRetryStatus(convId, null);
        }
      }
    }
    // 只有一个模型时，直接调用不做轮询
    if (modelsToTry.length <= 1) {
      final model = modelsToTry.isNotEmpty
          ? modelsToTry.first
          : settings.defaultModelName;
      final config = await buildConfig(model);
      final result = await executeControlled(config);
      return (result, settings);
    }

    Object? lastError;
    var index = 0;
    while (index < modelsToTry.length) {
      final model = modelsToTry[index];
      try {
        final config = await buildConfig(model);
        final result = await executeControlled(config);
        return (result, settings);
      } catch (e, st) {
        if (e is KernelCancelledException) rethrow;
        if (e is ContextCompactionException) rethrow;
        cancellation?.throwIfCancelled();
        if (isProviderRefreshTimingError(e)) {
          AppLogger.info(
            'ChatActions',
            '模型 $model 在本地组装阶段命中 Provider 刷新窗口，交由外层统一重试',
            metadata: {
              'failedModel': model,
              'attempt': index + 1,
              'total': modelsToTry.length,
            },
          );
          Error.throwWithStackTrace(e, st);
        }
        lastError = e;
        AppLogger.warning('ChatActions', '模型 $model 调用失败，等待用户决定后续动作',
            metadata: {
              'failedModel': model,
              'attempt': index + 1,
              'total': modelsToTry.length,
              'error': e.toString(),
            });

        // 还有下一个模型可以尝试
        if (index < modelsToTry.length - 1) {
          final nextModel = modelsToTry[index + 1];
          final decision = await _requestModelFailoverDecision(
            convId: convId,
            failedModel: model,
            nextModel: nextModel,
            settings: settings,
            error: e,
            roundStartedAt: generation?.startedAt,
            cancellation: cancellation,
          );
          if (decision == ModelFailoverDecision.retryCurrent) {
            AppLogger.info('ChatActions', '用户选择重试当前模型', metadata: {
              'model': model,
              'attempt': index + 1,
            });
            continue;
          }
          if (decision == ModelFailoverDecision.cancel) {
            throw StateError('模型切换已取消');
          }
          AppLogger.info('ChatActions', '用户选择尝试下一个模型', metadata: {
            'failedModel': model,
            'nextModel': nextModel,
            'attempt': index + 1,
          });
          index += 1;
          continue;
        }
      }
      index += 1;
    }

    // 所有模型都失败了，抛出最后一个错误
    throw lastError!;
  }
}
