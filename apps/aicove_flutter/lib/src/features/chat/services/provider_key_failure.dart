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
  try {
    return await failures.run(execute);
  } catch (error) {
    if (failures.owns(error)) {
      await recorder?._record(config, error, cancellation: cancellation);
    }
    rethrow;
  }
}
