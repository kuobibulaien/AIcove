import 'dart:async';

import '../../observability/model_request_ledger.dart';
import '../../observability/token_usage_ledger.dart';
import 'package:aicove_agent_kernel/aicove_agent_kernel.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/request_control.dart';
import '../../../core/app_logger.dart';
import '../../settings/app_settings.dart';
import '../../settings/provider_detail/provider_detail_support.dart';
import 'chat_types.dart';

final providerKeyFailureRecorderProvider = Provider<ProviderKeyFailureRecorder>(
  (ref) =>
      ProviderKeyFailureRecorder(() => ref.read(appSettingsProvider.notifier)),
);

/// Persists failures attributed by [executeWithProviderKeyFailureRecording].
/// Local errors, nested requests and cancellation never poison credentials.
class ProviderKeyFailureRecorder {
  const ProviderKeyFailureRecorder(this.settings);
  final AppSettingsNotifier Function() settings;

  Future<void> _record(
    ApiConfig config,
    Object error, {
    KernelCancellation? cancellation,
  }) async {
    if (error is KernelCancelledException ||
        config.cancellation?.isCancelled == true ||
        cancellation?.isCancelled == true ||
        RequestControl.cancellation?.isCancelled == true ||
        config.providerApiKeyStrategy != providerMultiKeyStrategyExhaust) {
      return;
    }
    final key = config.providerApiKey?.trim();
    if (key == null || key.isEmpty) return;
    try {
      await settings().recordProviderMultiKeyFailure(
        providerId: config.providerId,
        failedKey: key,
        failedItemId: config.providerApiKeyItemId,
        failedItemIndex: config.providerApiKeyItemIndex,
        strategy: config.providerApiKeyStrategy,
        error: error,
      );
    } catch (storageError) {
      // Do not replace the model's error with a bookkeeping failure.
      AppLogger.warning(
        'ProviderKeyFailure',
        '保存多 Key 失败状态失败',
        metadata: {'providerId': config.providerId, 'error': '$storageError'},
      );
    }
  }
}

Future<T> executeWithProviderKeyFailureRecording<T>({
  required ApiConfig config,
  required Future<T> Function() execute,
  ProviderKeyFailureRecorder? recorder,
  KernelCancellation? cancellation,
}) async {
  final failures = ModelRequestFailureTracker();
  ModelRunRecord? record;
  Timer? renewal;
  final scope = ModelRunScope.current;
  final usageCapture = TokenUsageCaptureScope(
    settings: config.settings,
    providerId: config.providerId,
    modelFullId: config.modelFullId,
    scope: scope,
  );
  if (scope != null) {
    try {
      record = await ModelRequestLedger.instance.begin(
        scope,
        config.providerId,
        config.modelFullId,
      );
      renewal = Timer.periodic(const Duration(seconds: 60), (_) {
        final current = record;
        if (current == null) return;
        record = current.advance(
          'running',
          DateTime.now().millisecondsSinceEpoch,
        );
        unawaited(ModelRequestLedger.instance.write(record!));
      });
    } catch (error) {
      AppLogger.warning(
        'ModelRequestLedger',
        '开始模型请求记录失败',
        metadata: {'error': '$error'},
      );
    }
  }
  try {
    final result = await usageCapture.run(() => failures.run(execute));
    final status =
        result is ApiCallResult && result.status == ApiRunStatus.cancelled
        ? 'cancelled'
        : result is ApiCallResult && result.status == ApiRunStatus.failed
        ? 'failed'
        : 'succeeded';
    if (record != null) {
      await ModelRequestLedger.instance.write(
        record!.advance(
          status,
          DateTime.now().millisecondsSinceEpoch,
          usage: usageCapture.hasUsage ? usageCapture.usage : null,
        ),
      );
    }
    return result;
  } catch (error) {
    final cancelled =
        error is KernelCancelledException ||
        config.cancellation?.isCancelled == true ||
        cancellation?.isCancelled == true ||
        RequestControl.cancellation?.isCancelled == true;
    if (record != null) {
      await ModelRequestLedger.instance.write(
        record!.advance(
          cancelled ? 'cancelled' : 'failed',
          DateTime.now().millisecondsSinceEpoch,
          error: cancelled ? null : error.toString(),
          usage: usageCapture.hasUsage ? usageCapture.usage : null,
        ),
      );
    }
    if (failures.owns(error)) {
      await recorder?._record(config, error, cancellation: cancellation);
    }
    rethrow;
  } finally {
    renewal?.cancel();
  }
}
